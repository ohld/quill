import AppKit
import Foundation
// UserNotifications still exposes pre-concurrency reference types such as
// UNNotificationSettings. The center callbacks are safe here because this
// controller owns them on the main actor.
@preconcurrency import UserNotifications

struct TranscriptNotificationPresentation: Equatable {
    let subtitle: String
    let preview: String

    static func load(
        from sessionDir: URL,
        timeZone: TimeZone = .current
    ) -> TranscriptNotificationPresentation {
        let start = recordingStartTime(from: sessionDir, timeZone: timeZone)
        let preview = transcriptPreview(from: sessionDir)
            ?? "Транскрипт сохранён локально"
        return TranscriptNotificationPresentation(
            subtitle: "Запись в \(start)",
            preview: preview
        )
    }

    private static func recordingStartTime(
        from sessionDir: URL,
        timeZone: TimeZone
    ) -> String {
        let metaURL = sessionDir.appendingPathComponent("meta.json")
        if let data = try? Data(contentsOf: metaURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let started = json["started"] as? String,
           let date = ISO8601DateFormatter().date(from: started) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "ru_RU")
            formatter.timeZone = timeZone
            formatter.dateFormat = "HH:mm"
            return formatter.string(from: date)
        }

        // Old sessions may not have a readable meta.json. Their directory
        // still starts with yyyy.MM.dd-HHmm, optionally followed by -2, -3…
        let parts = sessionDir.lastPathComponent.split(separator: "-")
        if parts.count >= 2 {
            let compact = parts[1]
            if compact.count == 4, compact.allSatisfy(\.isNumber) {
                return "\(compact.prefix(2)):\(compact.suffix(2))"
            }
        }
        return "неизвестное время"
    }

    private static func transcriptPreview(from sessionDir: URL) -> String? {
        let url = sessionDir.appendingPathComponent("transcript.json")
        guard
            let data = try? Data(contentsOf: url),
            let transcript = try? JSONDecoder().decode(Transcript.self, from: data),
            let first = UtteranceGrouper.group(transcript.segments).first
        else { return nil }

        let normalized = first.text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !normalized.isEmpty else { return nil }
        let limit = 120
        return normalized.count > limit
            ? String(normalized.prefix(limit - 1)) + "…"
            : normalized
    }
}

enum TranscriptCompletionRoute: Equatable {
    case nativeNotification
    case trayFallback

    static func resolve(nativeNotificationAccepted: Bool) -> Self {
        nativeNotificationAccepted ? .nativeNotification : .trayFallback
    }
}

/// Native notifications owned by Quill itself. Unlike `osascript`, clicks and
/// action buttons are delivered back to this process, so they can reveal the
/// exact transcript in Finder.
@MainActor
final class TranscriptNotificationController: NSObject, UNUserNotificationCenterDelegate {
    nonisolated private static let categoryID = "TRANSCRIPT_READY"
    nonisolated private static let openActionID = "OPEN_TRANSCRIPT_IN_FINDER"
    nonisolated private static let sessionPathKey = "sessionPath"

    private let center: UNUserNotificationCenter
    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        super.init()
        center.delegate = self
        let open = UNNotificationAction(
            identifier: Self.openActionID,
            title: "Открыть в Finder",
            options: [.foreground]
        )
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.categoryID,
                actions: [open],
                intentIdentifiers: [],
                options: []
            ),
        ])
    }

    func requestAuthorizationIfNeeded() async {
        let settings = await center.notificationSettings()
        Self.logSettings(settings, prefix: "notification settings")
        guard settings.authorizationStatus == .notDetermined else { return }
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound])
            Self.logSettings(
                await center.notificationSettings(),
                prefix: "notification settings after request"
            )
        } catch {
            FileHandle.standardError.write(Data(
                "notification authorization failed: \(error)\n".utf8
            ))
        }
    }

    nonisolated private static func logSettings(
        _ settings: UNNotificationSettings,
        prefix: String
    ) {
        let line = "\(prefix): authorization=\(settings.authorizationStatus.rawValue) "
            + "alerts=\(settings.alertSetting.rawValue) "
            + "center=\(settings.notificationCenterSetting.rawValue)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    /// Returns true only when macOS accepted a native alert. The caller uses
    /// false to show the tray popover fallback; showing both would stack them
    /// in the same top-right corner and the popover would cover the banner.
    func notifyTranscriptReady(sessionDir: URL) async -> Bool {
        let presentation = TranscriptNotificationPresentation.load(from: sessionDir)
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized,
              settings.alertSetting == .enabled
        else { return false }

        let content = UNMutableNotificationContent()
        content.title = "Транскрипт готов"
        content.subtitle = presentation.subtitle
        content.body = presentation.preview
        content.sound = .default
        content.categoryIdentifier = Self.categoryID
        content.threadIdentifier = "transcripts"
        content.userInfo = [Self.sessionPathKey: sessionDir.path]

        let identifier = "transcript-\(sessionDir.lastPathComponent)"
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        do {
            try await center.add(UNNotificationRequest(
                identifier: identifier,
                content: content,
                trigger: nil
            ))
            return true
        } catch {
            FileHandle.standardError.write(Data(
                "notification delivery failed: \(error)\n".utf8
            ))
            return false
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier
                || response.actionIdentifier == Self.openActionID,
              let sessionDir = Self.actionTarget(
                userInfo: response.notification.request.content.userInfo
              )
        else { return }
        DispatchQueue.main.async { [sessionDir] in
            let transcript = sessionDir.appendingPathComponent("transcript.md")
            if FileManager.default.fileExists(atPath: transcript.path) {
                NSWorkspace.shared.activateFileViewerSelecting([transcript])
            } else {
                NSWorkspace.shared.open(sessionDir)
            }
        }
    }

    nonisolated static func actionTarget(userInfo: [AnyHashable: Any]) -> URL? {
        guard let path = userInfo[sessionPathKey] as? String else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}
