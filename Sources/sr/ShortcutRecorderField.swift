import AppKit
import KeyboardShortcuts
import SwiftUI

/// Minimal shortcut recorder that receives keys through the ordinary
/// responder chain (`keyDown`), replacing `KeyboardShortcuts.Recorder`,
/// whose local-event-monitor capture receives nothing on this macOS.
/// Storage and hotkey registration still go through KeyboardShortcuts
/// (`setShortcut`), so recorded shortcuts work exactly as before.
struct ShortcutRecorderField: NSViewRepresentable {
    let name: KeyboardShortcuts.Name

    func makeNSView(context: Context) -> RecorderView {
        RecorderView(name: name)
    }

    func updateNSView(_ view: RecorderView, context: Context) {
        view.needsDisplay = true
    }
}

final class RecorderView: NSView {
    private let name: KeyboardShortcuts.Name
    private var isRecording = false {
        didSet {
            // Suspend hotkey handling while recording so pressing the current
            // shortcut re-records instead of triggering speak/pause.
            KeyboardShortcuts.isEnabled = !isRecording
            needsDisplay = true
        }
    }

    init(name: KeyboardShortcuts.Name) {
        self.name = name
        super.init(frame: .zero)
        setContentHuggingPriority(.defaultHigh, for: .vertical)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 180, height: 24) }

    override func mouseDown(with event: NSEvent) {
        if isRecording {
            window?.makeFirstResponder(nil)
        } else {
            window?.makeFirstResponder(self)
        }
    }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        isRecording = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        let modifiers = event.modifierFlags
            .intersection([.command, .option, .control, .shift])

        if modifiers.isEmpty {
            switch event.keyCode {
            case 53: // Esc — cancel
                window?.makeFirstResponder(nil)
                return
            case 51, 117: // Delete / Forward Delete — clear
                KeyboardShortcuts.setShortcut(nil, for: name)
                window?.makeFirstResponder(nil)
                return
            default:
                break
            }
        }

        // Require a real modifier beyond bare Shift (⇧A is just typing).
        guard !modifiers.subtracting(.shift).isEmpty,
              let shortcut = KeyboardShortcuts.Shortcut(event: event) else {
            NSSound.beep()
            return
        }
        KeyboardShortcuts.setShortcut(shortcut, for: name)
        window?.makeFirstResponder(nil)
    }

    /// ⌘-combos are routed as key equivalents, not plain keyDown.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, event.type == .keyDown else {
            return super.performKeyEquivalent(with: event)
        }
        keyDown(with: event)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        (isRecording ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.25)
                     : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = 1
        path.stroke()

        let text: String
        let color: NSColor
        if isRecording {
            text = "Type shortcut — ⎋ cancels, ⌫ clears"
            color = .secondaryLabelColor
        } else if let shortcut = KeyboardShortcuts.getShortcut(for: name) {
            text = "\(shortcut)"
            color = .labelColor
        } else {
            text = "Click to record"
            color = .tertiaryLabelColor
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: color,
        ]
        let size = text.size(withAttributes: attributes)
        let origin = NSPoint(x: rect.midX - size.width / 2,
                             y: rect.midY - size.height / 2)
        text.draw(at: origin, withAttributes: attributes)
    }
}
