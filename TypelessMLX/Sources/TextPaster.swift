import Cocoa
import Carbon

class TextPaster {
    static let shared = TextPaster()

    private init() {}

    static var isAccessibilityGranted: Bool {
        return AXIsProcessTrusted()
    }

    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func pasteText(_ text: String) {
        logInfo("TextPaster", "Pasting \(text.count) chars: \(text.prefix(50))...")

        let pasteboard = NSPasteboard.general
        let snapshot = snapshotPasteboard(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            let success = self.performPaste()

            if success {
                logInfo("TextPaster", "Paste succeeded — restoring clipboard in 2s")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    if !snapshot.isEmpty {
                        self.restorePasteboard(pasteboard, snapshot: snapshot)
                        logDebug("TextPaster", "Clipboard restored (\(snapshot.count) item(s))")
                    }
                }
            } else {
                logError("TextPaster", "All paste methods failed — text left on clipboard for manual Cmd+V")
            }
        }
    }

    private func snapshotPasteboard(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        return pasteboard.pasteboardItems?.map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        } ?? []
    }

    private func restorePasteboard(_ pasteboard: NSPasteboard, snapshot: [[NSPasteboard.PasteboardType: Data]]) {
        pasteboard.clearContents()
        let items = snapshot.map { dict -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in dict { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(items)
    }

    private func performPaste() -> Bool {
        guard Self.isAccessibilityGranted else {
            logError("TextPaster", "Accessibility not granted — cannot paste. Text is on clipboard.")
            return false
        }
        if pasteViaCGEvent() {
            logInfo("TextPaster", "Paste succeeded via CGEvent")
            return true
        }
        logError("TextPaster", "CGEvent paste failed. Text is on clipboard.")
        return false
    }

    private func pasteViaCGEvent() -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            logError("TextPaster", "Failed to create CGEvent for paste")
            return false
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }


}
