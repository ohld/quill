import AppKit
import CoreAudio
import CoreGraphics
import Foundation

enum CallPlatform: String, CaseIterable, Equatable, Sendable {
    case googleMeet
    case zoom

    var displayName: String {
        switch self {
        case .googleMeet: "Google Meet"
        case .zoom: "Zoom"
        }
    }
}

struct CallPlatformSignals: Equatable, Sendable {
    let inputActive: Bool
    let outputActive: Bool
    let windowVisible: Bool

    /// Require all three independent signals before interrupting the user.
    var qualifiesForStart: Bool {
        inputActive && outputActive && windowVisible
    }

    /// Once a call is established, two signals are enough to survive a
    /// minimized window, a background Meet tab, or a temporarily muted route.
    var supportsActiveCall: Bool {
        [inputActive, outputActive, windowVisible].filter { $0 }.count >= 2
    }
}

struct CallPresenceSnapshot: Equatable, Sendable {
    let googleMeet: CallPlatformSignals
    let zoom: CallPlatformSignals

    subscript(_ platform: CallPlatform) -> CallPlatformSignals {
        switch platform {
        case .googleMeet: googleMeet
        case .zoom: zoom
        }
    }

    static let empty = CallPresenceSnapshot(
        googleMeet: .init(inputActive: false, outputActive: false, windowVisible: false),
        zoom: .init(inputActive: false, outputActive: false, windowVisible: false)
    )
}

enum CallPresenceEvent: Equatable, Sendable {
    case started(CallPlatform)
    case ended(CallPlatform)
}

/// Pure debounce/state logic. System observation is deliberately outside this
/// type so call lifecycle behavior can be tested without audio or UI access.
struct CallPresenceStateMachine {
    private(set) var activePlatform: CallPlatform?
    private var startCandidate: (platform: CallPlatform, since: Date)?
    private var endingSince: Date?
    private let startDelay: TimeInterval
    private let endDelay: TimeInterval

    init(startDelay: TimeInterval = 2, endDelay: TimeInterval = 4) {
        self.startDelay = startDelay
        self.endDelay = endDelay
    }

    mutating func update(
        _ snapshot: CallPresenceSnapshot,
        at now: Date = Date()
    ) -> CallPresenceEvent? {
        if let activePlatform {
            if snapshot[activePlatform].supportsActiveCall {
                endingSince = nil
                return nil
            }

            if let endingSince {
                guard now.timeIntervalSince(endingSince) >= endDelay else { return nil }
                self.activePlatform = nil
                self.endingSince = nil
                startCandidate = nil
                return .ended(activePlatform)
            }

            endingSince = now
            return nil
        }

        guard let platform = CallPlatform.allCases.first(where: {
            snapshot[$0].qualifiesForStart
        }) else {
            startCandidate = nil
            return nil
        }

        if let startCandidate, startCandidate.platform == platform {
            guard now.timeIntervalSince(startCandidate.since) >= startDelay else { return nil }
            activePlatform = platform
            self.startCandidate = nil
            return .started(platform)
        }

        startCandidate = (platform, now)
        return nil
    }
}

/// Polls lightweight, read-only macOS process and window state. It never taps,
/// records, or analyzes audio; Core Audio only reports whether an application's
/// input/output streams are running.
@MainActor
final class CallPresenceDetector {
    private var stateMachine: CallPresenceStateMachine
    private let snapshot: () -> CallPresenceSnapshot
    private var timer: Timer?

    var onEvent: ((CallPresenceEvent) -> Void)?
    var activePlatform: CallPlatform? { stateMachine.activePlatform }

    init(
        startDelay: TimeInterval = 2,
        endDelay: TimeInterval = 4,
        snapshot: @escaping () -> CallPresenceSnapshot = NativeCallObservation.snapshot
    ) {
        stateMachine = CallPresenceStateMachine(
            startDelay: startDelay,
            endDelay: endDelay
        )
        self.snapshot = snapshot
    }

    func start() {
        guard timer == nil else { return }
        poll()
        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = 0.2
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        if let event = stateMachine.update(snapshot()) {
            onEvent?(event)
        }
    }
}

enum NativeCallObservation {
    private struct AudioProcess {
        let bundleID: String
        let inputActive: Bool
        let outputActive: Bool
    }

    private struct VisibleWindow {
        let bundleID: String
        let title: String
    }

    private static let zoomBundleID = "us.zoom.xos"

    static func snapshot() -> CallPresenceSnapshot {
        let processes = audioProcesses()
        let windows = visibleWindows()

        let meetWindowBundles = Set(
            windows.lazy
                .filter { isMeetWindowTitle($0.title) }
                .map(\.bundleID)
        )
        let zoomWindowVisible = windows.contains {
            bundle($0.bundleID, belongsTo: zoomBundleID)
        }

        let meetProcesses = processes.filter { process in
            meetWindowBundles.contains { windowBundle in
                bundle(process.bundleID, belongsTo: windowBundle)
            }
        }
        let zoomProcesses = processes.filter {
            bundle($0.bundleID, belongsTo: zoomBundleID)
        }

        return CallPresenceSnapshot(
            googleMeet: signals(
                processes: meetProcesses,
                windowVisible: !meetWindowBundles.isEmpty
            ),
            zoom: signals(
                processes: zoomProcesses,
                windowVisible: zoomWindowVisible
            )
        )
    }

    static func isMeetWindowTitle(_ title: String) -> Bool {
        let normalized = title
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized == "meet"
            || normalized.hasPrefix("meet -")
            || normalized.hasPrefix("meet –")
            || normalized.hasPrefix("google meet")
            || normalized.contains(" - google meet")
            || normalized.contains(" – google meet")
    }

    private static func signals(
        processes: [AudioProcess],
        windowVisible: Bool
    ) -> CallPlatformSignals {
        CallPlatformSignals(
            inputActive: processes.contains(where: \.inputActive),
            outputActive: processes.contains(where: \.outputActive),
            windowVisible: windowVisible
        )
    }

    private static func bundle(_ candidate: String, belongsTo owner: String) -> Bool {
        candidate == owner || candidate.hasPrefix(owner + ".")
    }

    private static func visibleWindows() -> [VisibleWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
                as? [[String: Any]] else { return [] }

        return raw.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pidValue = info[kCGWindowOwnerPID as String] as? NSNumber,
                  let app = NSRunningApplication(
                    processIdentifier: pid_t(pidValue.int32Value)
                  ),
                  let bundleID = app.bundleIdentifier,
                  let title = info[kCGWindowName as String] as? String,
                  !title.isEmpty
            else { return nil }
            return VisibleWindow(bundleID: bundleID, title: title)
        }
    }

    private static func audioProcesses() -> [AudioProcess] {
        processObjectIDs().compactMap { objectID in
            guard let bundleID = stringProperty(
                objectID,
                selector: kAudioProcessPropertyBundleID
            ) else { return nil }
            return AudioProcess(
                bundleID: bundleID,
                inputActive: boolProperty(
                    objectID,
                    selector: kAudioProcessPropertyIsRunningInput
                ),
                outputActive: boolProperty(
                    objectID,
                    selector: kAudioProcessPropertyIsRunningOutput
                )
            )
        }
    }

    private static func processObjectIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(
            system, &address, 0, nil, &size
        ) == noErr else { return [] }

        var values = [AudioObjectID](
            repeating: kAudioObjectUnknown,
            count: Int(size) / MemoryLayout<AudioObjectID>.size
        )
        let status = values.withUnsafeMutableBytes { buffer in
            AudioObjectGetPropertyData(
                system,
                &address,
                0,
                nil,
                &size,
                buffer.baseAddress!
            )
        }
        return status == noErr ? values : []
    }

    private static func boolProperty(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            objectID, &address, 0, nil, &size, &value
        )
        return status == noErr && value != 0
    }

    private static func stringProperty(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = AudioObjectGetPropertyData(
            objectID, &address, 0, nil, &size, &value
        )
        guard status == noErr, let value else { return nil }
        return value.takeUnretainedValue() as String
    }
}
