import AppKit
import SwiftUI

/// One key on the Shortcuts page, like a Stream Deck button.
struct DeckKey: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var symbol: String
    var color: DeckColor
    var action: DeckAction
}

enum DeckAction: Codable, Equatable {
    /// Pastes into whatever text field has focus.
    case text(String, pressReturn: Bool)
    case website(String)
    case app(path: String)
    /// A shortcut from the Shortcuts app, by name.
    case shortcut(String)
    /// Runs in zsh.
    case command(String)

    var kindLabel: String {
        switch self {
        case .text: "Paste Text"
        case .website: "Website"
        case .app: "App"
        case .shortcut: "Shortcut"
        case .command: "Command"
        }
    }
}

enum DeckColor: String, Codable, CaseIterable {
    case blue, indigo, purple, pink, red, orange, yellow, green, teal, graphite

    private var rgb: (CGFloat, CGFloat, CGFloat) {
        switch self {
        case .blue: (0.04, 0.52, 1.0)
        case .indigo: (0.35, 0.34, 0.84)
        case .purple: (0.69, 0.32, 0.87)
        case .pink: (1.0, 0.22, 0.37)
        case .red: (1.0, 0.27, 0.23)
        case .orange: (1.0, 0.58, 0.0)
        case .yellow: (1.0, 0.8, 0.0)
        case .green: (0.2, 0.78, 0.35)
        case .teal: (0.19, 0.69, 0.78)
        case .graphite: (0.45, 0.45, 0.47)
        }
    }

    private var nsColor: NSColor { NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1) }

    var base: Color { Color(nsColor: nsColor) }

    /// A key-cap gradient: lighter at the top, like light catching it.
    var gradient: LinearGradient {
        let top = nsColor.blended(withFraction: 0.18, of: .white) ?? nsColor
        let bottom = nsColor.blended(withFraction: 0.12, of: .black) ?? nsColor
        return LinearGradient(colors: [Color(nsColor: top), Color(nsColor: bottom)], startPoint: .top, endPoint: .bottom)
    }
}

enum DeckStore {
    private static let key = "deckKeys"

    static func load() -> [DeckKey] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let keys = try? JSONDecoder().decode([DeckKey].self, from: data)
        else { return examples }
        return keys
    }

    /// False until the user changes anything, while the deck is still the examples.
    static var hasSavedKeys: Bool { UserDefaults.standard.data(forKey: key) != nil }

    static func save(_ keys: [DeckKey]) {
        if let data = try? JSONEncoder().encode(keys) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// A few keys to show what's possible. Delete or edit them freely.
    private static let examples: [DeckKey] = [
        DeckKey(
            title: "Summarize",
            symbol: "text.append",
            color: .purple,
            action: .text("Summarize this in three short bullet points:\n\n{clipboard}", pressReturn: false)
        ),
        DeckKey(
            title: "Proofread",
            symbol: "checkmark.seal",
            color: .blue,
            action: .text("Fix spelling and grammar in the text below. Keep my tone and wording otherwise.\n\n{clipboard}", pressReturn: false)
        ),
        DeckKey(
            title: "Today's Date",
            symbol: "calendar",
            color: .orange,
            action: .text("{date}", pressReturn: false)
        ),
    ]
}

enum DeckRunner {
    enum Failure: Error { case needsAccessibility, failed }

    static func run(_ key: DeckKey, completion: @escaping (Result<Void, Failure>) -> Void) {
        switch key.action {
        case .text(let text, let pressReturn):
            paste(expand(text), pressReturn: pressReturn, completion: completion)

        case .website(let address):
            let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
            let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
            guard let url = URL(string: withScheme) else { return completion(.failure(.failed)) }
            completion(NSWorkspace.shared.open(url) ? .success(()) : .failure(.failed))

        case .app(let path):
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: .init()) { _, error in
                DispatchQueue.main.async { completion(error == nil ? .success(()) : .failure(.failed)) }
            }

        case .shortcut(let name):
            runProcess("/usr/bin/shortcuts", ["run", name], completion: completion)

        case .command(let command):
            runProcess("/bin/zsh", ["-lc", command], completion: completion)
        }
    }

    /// Fills in {clipboard}, {date} and {time}.
    static func expand(_ text: String) -> String {
        let now = Date()
        return text
            .replacingOccurrences(of: "{clipboard}", with: NSPasteboard.general.string(forType: .string) ?? "")
            .replacingOccurrences(of: "{date}", with: now.formatted(date: .long, time: .omitted))
            .replacingOccurrences(of: "{time}", with: now.formatted(date: .omitted, time: .shortened))
    }

    /// Puts the text on the clipboard, presses ⌘V in the app in front, then
    /// puts the clipboard back the way it was.
    private static func paste(_ text: String, pressReturn: Bool, completion: @escaping (Result<Void, Failure>) -> Void) {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else { return completion(.failure(.needsAccessibility)) }

        let pasteboard = NSPasteboard.general
        let saved = pasteboard.pasteboardItems?.map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        } ?? []

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let ours = pasteboard.changeCount

        press(key: 9, flags: .maskCommand) // V
        if pressReturn {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { press(key: 36, flags: []) }
        }

        // Give the app time to read the clipboard before restoring it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if pasteboard.changeCount == ours, !saved.isEmpty {
                pasteboard.clearContents()
                pasteboard.writeObjects(saved)
            }
        }
        completion(.success(()))
    }

    private static func press(key: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: isDown)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }

    private static func runProcess(_ path: String, _ arguments: [String], completion: @escaping (Result<Void, Failure>) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { process in
            DispatchQueue.main.async {
                completion(process.terminationStatus == 0 ? .success(()) : .failure(.failed))
            }
        }
        do {
            try process.run()
        } catch {
            completion(.failure(.failed))
        }
    }
}
