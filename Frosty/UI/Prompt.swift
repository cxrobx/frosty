import AppKit

enum Prompt {
    /// Modal one-line text prompt. Returns nil on cancel, on a blank name, or on
    /// a name already in `existing`.
    static func text(title: String, message: String, initial: String = "", existing: [String] = []) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: initial)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        // Frosty is an accessory app, so it has to take focus for the alert to get keys.
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, value == initial || !existing.contains(value) else { return nil }
        return value
    }
}
