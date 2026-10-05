import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The window for adding or editing a Shortcuts key.
final class DeckEditor: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    /// `key` is nil for a new key. `onSave` gets the result, `onDelete` the
    /// key to remove.
    func show(_ key: DeckKey?, onSave: @escaping (DeckKey) -> Void, onDelete: @escaping (DeckKey) -> Void) {
        window?.close()

        let view = DeckEditorView(
            draft: DeckDraft(key),
            isNew: key == nil,
            onSave: { [weak self] saved in
                onSave(saved)
                self?.window?.close()
            },
            onDelete: { [weak self] in
                if let key { onDelete(key) }
                self?.window?.close()
            },
            onCancel: { [weak self] in self?.window?.close() }
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 620),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = key == nil ? "New Shortcut" : "Edit Shortcut"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: view)
        window.setContentSize(NSSize(width: 460, height: 620))
        window.center()
        self.window = window

        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        DispatchQueue.main.async { NSApp.deactivate() }
    }
}

/// Everything the editor form edits, flattened so switching the action type
/// doesn't lose what was typed.
struct DeckDraft {
    enum Kind: String, CaseIterable, Identifiable {
        case text = "Paste Text"
        case website = "Open Website"
        case app = "Open App"
        case shortcut = "Run Shortcut"
        case command = "Run Command"
        var id: String { rawValue }
    }

    var id = UUID()
    var title = ""
    var symbol = "text.bubble"
    var color = DeckColor.blue
    var kind = Kind.text
    var text = ""
    var pressReturn = false
    var website = ""
    var appPath = ""
    var shortcutName = ""
    var command = ""

    init(_ key: DeckKey?) {
        guard let key else { return }
        id = key.id
        title = key.title
        symbol = key.symbol
        color = key.color
        switch key.action {
        case .text(let value, let enter): kind = .text; text = value; pressReturn = enter
        case .website(let value): kind = .website; website = value
        case .app(let path): kind = .app; appPath = path
        case .shortcut(let name): kind = .shortcut; shortcutName = name
        case .command(let value): kind = .command; command = value
        }
    }

    var action: DeckAction {
        switch kind {
        case .text: .text(text, pressReturn: pressReturn)
        case .website: .website(website)
        case .app: .app(path: appPath)
        case .shortcut: .shortcut(shortcutName)
        case .command: .command(command)
        }
    }

    var isValid: Bool {
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        switch kind {
        case .text: return !text.isEmpty
        case .website: return !website.trimmingCharacters(in: .whitespaces).isEmpty
        case .app: return !appPath.isEmpty
        case .shortcut: return !shortcutName.isEmpty
        case .command: return !command.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    var key: DeckKey {
        DeckKey(id: id, title: title.trimmingCharacters(in: .whitespaces), symbol: symbol, color: color, action: action)
    }
}

private struct DeckEditorView: View {
    @State var draft: DeckDraft
    let isNew: Bool
    let onSave: (DeckKey) -> Void
    let onDelete: () -> Void
    let onCancel: () -> Void

    @State private var shortcutNames: [String] = []

    private static let symbols = [
        "text.bubble", "text.append", "checkmark.seal", "sparkles", "wand.and.stars", "pencil",
        "envelope", "paperplane", "calendar", "clock", "link", "globe",
        "terminal", "hammer", "gearshape", "bolt", "star", "heart",
        "folder", "doc.text", "photo", "music.note", "video", "mic",
        "person", "bubble.left.and.bubble.right", "lightbulb", "flag", "bookmark", "cart",
    ]

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    HStack(alignment: .center, spacing: 16) {
                        DeckKeyFace(symbol: draft.symbol, color: draft.color, appPath: draft.kind == .app ? draft.appPath : nil, size: 64)
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("Name", text: $draft.title, prompt: Text("Name"))
                                .textFieldStyle(.roundedBorder)
                                .labelsHidden()
                            HStack(spacing: 6) {
                                ForEach(DeckColor.allCases, id: \.self) { color in
                                    Circle()
                                        .fill(color.gradient)
                                        .frame(width: 18, height: 18)
                                        .overlay(Circle().strokeBorder(.primary.opacity(draft.color == color ? 0.9 : 0), lineWidth: 2).padding(-3))
                                        .onTapGesture { draft.color = color }
                                        .accessibilityLabel(color.rawValue.capitalized)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)

                    if draft.kind != .app {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 10), spacing: 4) {
                            ForEach(Self.symbols, id: \.self) { symbol in
                                Image(systemName: symbol)
                                    .font(.system(size: 13))
                                    .frame(width: 30, height: 28)
                                    .background(
                                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                                            .fill(draft.symbol == symbol ? Color.accentColor.opacity(0.25) : .clear)
                                    )
                                    .contentShape(Rectangle())
                                    .onTapGesture { draft.symbol = symbol }
                            }
                        }
                    }
                }

                Section("When pressed") {
                    Picker("Action", selection: $draft.kind) {
                        ForEach(DeckDraft.Kind.allCases) { Text($0.rawValue).tag($0) }
                    }

                    switch draft.kind {
                    case .text:
                        TextEditor(text: $draft.text)
                            .font(.body)
                            .frame(minHeight: 110)
                            .scrollContentBackground(.hidden)
                        Toggle("Press Return after pasting", isOn: $draft.pressReturn)
                        Text("Pastes into the text field you're typing in. Use {clipboard}, {date} or {time} to fill those in.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                    case .website:
                        TextField("Address", text: $draft.website, prompt: Text("example.com"))

                    case .app:
                        HStack {
                            if !draft.appPath.isEmpty {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: draft.appPath))
                                    .resizable()
                                    .frame(width: 22, height: 22)
                                Text(FileManager.default.displayName(atPath: draft.appPath))
                            } else {
                                Text("No app chosen").foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Choose…", action: chooseApp)
                        }

                    case .shortcut:
                        if shortcutNames.isEmpty {
                            TextField("Shortcut name", text: $draft.shortcutName)
                        } else {
                            Picker("Shortcut", selection: $draft.shortcutName) {
                                Text("Choose…").tag("")
                                ForEach(shortcutNames, id: \.self) { Text($0).tag($0) }
                            }
                        }

                    case .command:
                        TextField("Command", text: $draft.command, prompt: Text("open -a Safari"))
                            .font(.system(.body, design: .monospaced))
                        Text("Runs in zsh. Output is ignored.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                if !isNew {
                    Button("Delete", role: .destructive, action: onDelete)
                }
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") { onSave(draft.key) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!draft.isValid)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 460, height: 620)
        .task { shortcutNames = await Self.loadShortcutNames() }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft.appPath = url.path
        if draft.title.isEmpty { draft.title = FileManager.default.displayName(atPath: url.path) }
    }

    private static func loadShortcutNames() async -> [String] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
                process.arguments = ["list"]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                guard (try? process.run()) != nil else { return continuation.resume(returning: []) }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let names = String(decoding: data, as: UTF8.self)
                    .split(separator: "\n")
                    .map(String.init)
                    .filter { !$0.isEmpty }
                continuation.resume(returning: names)
            }
        }
    }
}

/// The colored key cap, shared by the island and the editor preview. App keys
/// show the app's own icon instead.
struct DeckKeyFace: View {
    let symbol: String
    let color: DeckColor
    var appPath: String?
    var size: CGFloat = 54

    var body: some View {
        if let appPath, !appPath.isEmpty {
            Image(nsImage: NSWorkspace.shared.icon(forFile: appPath))
                .resizable()
                .interpolation(.high)
                .frame(width: size * 1.08, height: size * 1.08)
        } else {
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .fill(color.gradient)
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                        .strokeBorder(
                            LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom),
                            lineWidth: 0.75
                        )
                )
                .overlay(
                    Image(systemName: symbol)
                        .font(.system(size: size * 0.4, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
                )
                .frame(width: size, height: size)
        }
    }
}
