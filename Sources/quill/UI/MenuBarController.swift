import AppKit

/// Status bar item in the top-right of the menu bar. Shows recording state at
/// a glance and provides the only persistent control surface for the daemon
/// (since we run as `.accessory` — no dock icon, no main window).
@MainActor
final class MenuBarController {
    private let statusItem: NSStatusItem
    private let stateLabel: NSMenuItem
    private let micLabel: NSMenuItem
    private let systemLabel: NSMenuItem
    private let transcriptionLabel: NSMenuItem
    private let toggleItem: NSMenuItem

    var onToggle: (() -> Void)?
    var onOpenFolder: (() -> Void)?
    var onOpenLatestTranscript: (() -> Void)?
    var onQuit: (() -> Void)?

    init() {
        // Keep the item compact: on notched MacBooks a variable-width title
        // is the first thing macOS hides when the right-hand menu bar fills.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = "com.ohld.quill.status-item"

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

        if let button = statusItem.button {
            let image = Self.featherImage() ?? NSImage(
                systemSymbolName: "waveform.circle",
                accessibilityDescription: "Quill meeting recorder"
            )
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageOnly
            button.title = ""
            button.toolTip = "Quill meeting recorder"
        }
    }

    /// Keep the product's feather identity in both states; red means that the
    /// recorder is live. The elapsed counter stays in the menu's state label.
    func update(recording: Bool, elapsed: String?) {
        stateLabel.title = recording ? "● recording · \(elapsed ?? "0:00")" : "idle"
        toggleItem.title = recording ? "Stop recording" : "Start recording"
        if let button = statusItem.button {
            let image = Self.featherImage() ?? NSImage(
                systemSymbolName: "waveform.circle",
                accessibilityDescription: stateLabel.title
            )
            image?.isTemplate = true
            button.image = image
            button.contentTintColor = recording ? .systemRed : nil
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

    @objc private func toggleClicked() { onToggle?() }
    @objc private func openFolderClicked() { onOpenFolder?() }
    @objc private func openLatestTranscriptClicked() { onOpenLatestTranscript?() }
    @objc private func quitClicked() { onQuit?() }
}
