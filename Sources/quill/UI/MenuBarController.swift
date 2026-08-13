import AppKit

/// Status bar item in the top-right of the menu bar. Shows recording state at
/// a glance and provides the only persistent control surface for the daemon
/// (since we run as `.accessory` — no dock icon, no main window).
@MainActor
final class MenuBarController {
    static let autosaveName = "com.ohld.quill.status-item"
    static let preferredPositionKey = "NSStatusItem Preferred Position \(autosaveName)"
    static let preferredPosition = 120

    private let statusItem: NSStatusItem
    private let stateLabel: NSMenuItem
    private let micLabel: NSMenuItem
    private let systemLabel: NSMenuItem
    private let transcriptionLabel: NSMenuItem
    private let toggleItem: NSMenuItem
    private let completionPopover = NSPopover()
    private var closePopoverWorkItem: DispatchWorkItem?

    var onToggle: (() -> Void)?
    var onOpenFolder: (() -> Void)?
    var onOpenLatestTranscript: (() -> Void)?
    var onOpenRecording: ((URL) -> Void)?
    var onQuit: (() -> Void)?

    init() {
        Self.seedPreferredPosition()
        // Keep the item compact: on notched MacBooks a variable-width title
        // is the first thing macOS hides when the right-hand menu bar fills.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = Self.autosaveName

        let menu = NSMenu()
        menu.autoenablesItems = false

        stateLabel = NSMenuItem(title: "idle", action: nil, keyEquivalent: "")
        stateLabel.isEnabled = false
        menu.addItem(stateLabel)

        micLabel = NSMenuItem(title: "Microphone: waiting", action: nil, keyEquivalent: "")
        micLabel.isEnabled = false
        menu.addItem(micLabel)

        systemLabel = NSMenuItem(title: "System audio: waiting", action: nil, keyEquivalent: "")
        systemLabel.isEnabled = false
        menu.addItem(systemLabel)

        transcriptionLabel = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        transcriptionLabel.isEnabled = false
        transcriptionLabel.isHidden = true
        menu.addItem(transcriptionLabel)

        menu.addItem(.separator())

        toggleItem = NSMenuItem(
            title: "Start recording",
            action: #selector(toggleClicked),
            keyEquivalent: "r"
        )
        menu.addItem(toggleItem)

        let openFolder = NSMenuItem(
            title: "Open recordings folder",
            action: #selector(openFolderClicked),
            keyEquivalent: "o"
        )
        menu.addItem(openFolder)

        let openLatestTranscript = NSMenuItem(
            title: "Open latest transcript",
            action: #selector(openLatestTranscriptClicked),
            keyEquivalent: "t"
        )
        menu.addItem(openLatestTranscript)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit quill",
            action: #selector(quitClicked),
            keyEquivalent: "q"
        )
        menu.addItem(quit)

        for item in [toggleItem, openFolder, openLatestTranscript, quit] {
            item.target = self
        }

        statusItem.menu = menu
        statusItem.isVisible = true

        completionPopover.behavior = .transient
        completionPopover.animates = true

        if let button = statusItem.button {
            button.image = Self.statusImage(recording: false)
            button.imagePosition = .imageOnly
            button.title = ""
            button.toolTip = "Quill meeting recorder"
        }
    }

    /// Seed a notch-safe position once. macOS updates the same autosave value
    /// if the user later Command-drags the item, so personal ordering wins.
    static func seedPreferredPosition(defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: preferredPositionKey) == nil else { return }
        defaults.set(preferredPosition, forKey: preferredPositionKey)
    }

    /// Keep the product's feather identity in both states; red means that the
    /// recorder is live. The elapsed counter stays in the menu's state label.
    func update(recording: Bool, elapsed: String?) {
        stateLabel.title = recording ? "● recording · \(elapsed ?? "0:00")" : "idle"
        toggleItem.title = recording ? "Stop recording" : "Start recording"
        if let button = statusItem.button {
            // `contentTintColor` is unreliable for status-item template SVGs
            // on macOS 14 and can turn the icon black on a black menu bar.
            // Supply a real red bitmap while recording instead.
            button.contentTintColor = nil
            button.image = Self.statusImage(recording: recording)
        }
    }

    /// A recorder is considered connected only after its first audio buffer
    /// arrives. This distinguishes "the API started" from "audio is flowing".
    func updateSources(recording: Bool, micActive: Bool, systemActive: Bool) {
        if !recording {
            micLabel.title = "Microphone: ready"
            systemLabel.title = "System audio: ready"
            return
        }
        micLabel.title = micActive ? "Microphone: ● audio flowing" : "Microphone: … waiting for audio"
        systemLabel.title = systemActive ? "System audio: ● audio flowing" : "System audio: … waiting for audio"
    }

    /// Show transcription progress/failure as a second status line in the
    /// menu; nil hides it. Independent of recording state — a new recording
    /// can run while the last one transcribes.
    func updateTranscription(_ text: String?) {
        transcriptionLabel.title = text ?? ""
        transcriptionLabel.isHidden = text == nil
    }

    func showCompletion(sessionDir: URL) {
        let presentation = TranscriptNotificationPresentation.load(from: sessionDir)
        showPopover(
            title: "Транскрипт готов",
            detail: presentation.subtitle,
            buttonTitle: "Открыть в Finder",
            dismissAfter: 5
        ) { [weak self] in
            self?.onOpenRecording?(sessionDir)
        }
    }

    func showTranscriptionFailure(sessionName: String) {
        showPopover(
            title: "Не удалось расшифровать",
            detail: "\(sessionName) · подробности в transcribe.log",
            buttonTitle: nil,
            dismissAfter: 8,
            onAction: nil
        )
    }

    func showMessage(title: String, detail: String) {
        showPopover(
            title: title,
            detail: detail,
            buttonTitle: nil,
            dismissAfter: 8,
            onAction: nil
        )
    }

    private func showPopover(
        title: String,
        detail: String,
        buttonTitle: String?,
        dismissAfter delay: TimeInterval,
        onAction: (() -> Void)?
    ) {
        guard let button = statusItem.button else { return }

        closePopoverWorkItem?.cancel()
        completionPopover.performClose(nil)

        let content = CompletionPopoverViewController(
            title: title,
            detail: detail,
            buttonTitle: buttonTitle
        )
        content.onAction = { [weak self] in
            self?.completionPopover.performClose(nil)
            onAction?()
        }
        completionPopover.contentViewController = content
        completionPopover.show(
            relativeTo: button.bounds,
            of: button,
            preferredEdge: .minY
        )

        let close = DispatchWorkItem { [weak self] in
            self?.completionPopover.performClose(nil)
        }
        closePopoverWorkItem = close
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: close)
    }

    // Inlined Lucide feather SVG. Keeping it in source means the executable
    // has no separate resource bundle to install alongside it — true
    // single-binary.
    private static let featherSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" \
    viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" \
    stroke-linecap="round" stroke-linejoin="round">\
    <path d="M12.67 19a2 2 0 0 0 1.416-.588l6.154-6.172a6 6 0 0 0-8.49-8.49L5.586 9.914A2 2 0 0 0 5 11.328V18a1 1 0 0 0 1 1z"/>\
    <path d="M16 8 2 22"/>\
    <path d="M17.5 15H9"/>\
    </svg>
    """

    private static func featherImage() -> NSImage? {
        guard let data = featherSVG.data(using: .utf8),
              let image = NSImage(data: data)
        else { return nil }
        // Menu-bar status icons are nominally 18pt tall; size the SVG to match.
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    static func statusImage(recording: Bool) -> NSImage? {
        let base = featherImage() ?? NSImage(
            systemSymbolName: "waveform.circle",
            accessibilityDescription: "Quill meeting recorder"
        )
        guard let base else { return nil }
        guard recording else {
            base.isTemplate = true
            return base
        }

        let red = NSImage(size: base.size)
        red.lockFocus()
        base.draw(
            in: NSRect(origin: .zero, size: base.size),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        NSColor.systemRed.setFill()
        NSRect(origin: .zero, size: base.size).fill(using: .sourceAtop)
        red.unlockFocus()
        red.isTemplate = false
        return red
    }

    @objc private func toggleClicked() { onToggle?() }
    @objc private func openFolderClicked() { onOpenFolder?() }
    @objc private func openLatestTranscriptClicked() { onOpenLatestTranscript?() }
    @objc private func quitClicked() { onQuit?() }
}

@MainActor
private final class CompletionPopoverViewController: NSViewController {
    var onAction: (() -> Void)?

    init(title: String, detail: String, buttonTitle: String?) {
        super.init(nibName: nil, bundle: nil)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)

        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle

        var views: [NSView] = [titleLabel, detailLabel]
        if let buttonTitle {
            let actionButton = NSButton(
                title: buttonTitle,
                target: self,
                action: #selector(actionClicked)
            )
            actionButton.bezelStyle = .rounded
            views.append(actionButton)
        }

        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 290, height: buttonTitle == nil ? 82 : 116))
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -14),
        ])
        view = content
        preferredContentSize = content.frame.size
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    @objc private func actionClicked() {
        onAction?()
    }
}
