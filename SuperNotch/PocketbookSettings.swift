import AppKit
import Carbon.HIToolbox
import SwiftUI

enum SuperNotchSettingsSection: String, CaseIterable, Identifiable {
    case general
    case dropZone
    case pocketbook
    case terminal
    case updates
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .dropZone: return "Drop Zone"
        case .pocketbook: return "Pocketbook"
        case .terminal: return "Terminal"
        case .updates: return "Updates"
        case .about: return "About"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .dropZone: return "shippingbox"
        case .pocketbook: return "books.vertical"
        case .terminal: return "terminal"
        case .updates: return "arrow.triangle.2.circlepath"
        case .about: return "info.circle"
        }
    }
}

@MainActor
final class PocketbookV3SettingsWindowController: NSObject, NSWindowDelegate {
    private let configuration: PocketbookV3Configuration
    private let shortcutDescription: () -> String
    private let configureShortcut: () -> Void
    private let onChanged: () -> Void
    private var window: NSWindow?
    private var selection = SuperNotchSettingsSelection()

    init(
        configuration: PocketbookV3Configuration,
        shortcutDescription: @escaping () -> String,
        configureShortcut: @escaping () -> Void,
        onChanged: @escaping () -> Void
    ) {
        self.configuration = configuration
        self.shortcutDescription = shortcutDescription
        self.configureShortcut = configureShortcut
        self.onChanged = onChanged
    }

    func show(section: SuperNotchSettingsSection = .pocketbook) {
        configuration.reloadCustom()
        selection.section = section

        if window == nil {
            let frame = NSRect(x: 0, y: 0, width: 880, height: 610)
            let window = NSWindow(
                contentRect: frame,
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "SuperNotch Settings"
            window.minSize = NSSize(width: 760, height: 520)
            window.isReleasedWhenClosed = false
            window.center()
            window.delegate = self
            window.contentView = NSHostingView(
                rootView: SuperNotchSettingsView(
                    selection: selection,
                    configuration: configuration,
                    shortcutDescription: shortcutDescription,
                    configureShortcut: configureShortcut,
                    onChanged: onChanged
                )
            )
            self.window = window
        }

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
private final class SuperNotchSettingsSelection: ObservableObject {
    @Published var section: SuperNotchSettingsSection = .pocketbook
}

private struct SuperNotchSettingsView: View {
    @ObservedObject var selection: SuperNotchSettingsSelection
    @ObservedObject var configuration: PocketbookV3Configuration
    let shortcutDescription: () -> String
    let configureShortcut: () -> Void
    let onChanged: () -> Void

    var body: some View {
        NavigationSplitView {
            List(SuperNotchSettingsSection.allCases, selection: $selection.section) { section in
                Label(section.title, systemImage: section.icon)
                    .tag(section)
                    .padding(.vertical, 3)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 205, max: 235)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    content
                }
                .padding(28)
                .frame(maxWidth: 720, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 760, minHeight: 520)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(selection.section.title)
                .font(.system(size: 24, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private var subtitle: String {
        switch selection.section {
        case .general: return "SuperNotch behavior and app-level preferences."
        case .dropZone: return "Developer Drop Zone preferences live here instead of crowding the menu bar."
        case .pocketbook: return "Choose books and configure the Pocketbook shortcut."
        case .terminal: return "Native terminal preferences and shortcut."
        case .updates: return "Keep SuperNotch current from the official GitHub releases."
        case .about: return "Version and project information."
        }
    }

    @ViewBuilder private var content: some View {
        switch selection.section {
        case .general:
            card("Application") {
                Text("SuperNotch runs as a menu-bar accessory and keeps the physical notch as the primary workspace surface.")
                    .foregroundStyle(.secondary)
            }
        case .dropZone:
            card("Developer Drop Zone") {
                Text("Default opener and recent-project actions remain available from the compact menu while their configuration is being moved into this Settings workspace.")
                    .foregroundStyle(.secondary)
            }
        case .pocketbook:
            pocketbookContent
        case .terminal:
            card("Global Shortcut") {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Open SuperNotch Terminal")
                        Text("Configure the terminal shortcut from the menu-bar command.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("⇧⌘N")
                        .font(.system(.body, design: .rounded).weight(.semibold))
                }
            }
        case .updates:
            card("Software Update") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Current version")
                            Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Check for Updates…") {
                            SuperNotchUpdateController.shared.checkForUpdates()
                        }
                    }
                    Divider()
                    Text("Updates are checked against official SuperNotch GitHub Releases.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .about:
            card("SuperNotch") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("SuperNotch")
                        .font(.title3.weight(.semibold))
                    Text("Version " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"))
                        .foregroundStyle(.secondary)
                    Text("A native productivity command surface built around your MacBook notch.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var pocketbookContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            card("Built-in Books") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(configuration.builtinBooks) { book in
                        bookToggle(book)
                    }
                }
            }

            card("Custom JSON") {
                VStack(alignment: .leading, spacing: 10) {
                    Text(configuration.configURL.path)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)

                    if let error = configuration.customError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.orange)
                    }

                    if configuration.customBooks.isEmpty {
                        Text(configuration.customFileExists
                            ? "No custom books found in the JSON file."
                            : "No custom config yet. Create one to add personal books or override built-in entries.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(configuration.customBooks) { book in bookToggle(book) }
                    }

                    HStack {
                        Button(configuration.customFileExists ? "Open Config" : "Create Config") {
                            configuration.openConfig()
                            onChanged()
                        }
                        Button("Reload") {
                            configuration.reloadCustom()
                            onChanged()
                        }
                    }
                }
            }

            card("Default Book") {
                if configuration.enabledBooks.isEmpty {
                    Text("Enable at least one book.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Open on", selection: Binding(
                        get: { configuration.resolvedDefaultBook?.id ?? "" },
                        set: {
                            configuration.setDefaultBook($0)
                            onChanged()
                        }
                    )) {
                        ForEach(configuration.enabledBooks) { book in
                            Text(book.title).tag(book.id)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }

            card("Global Shortcut") {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Open Pocketbook")
                        Text(shortcutDescription())
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                    }
                    Spacer()
                    Button("Change…", action: configureShortcut)
                }
            }
        }
    }

    @ViewBuilder
    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
    }

    private func bookToggle(_ book: PocketbookV3Book) -> some View {
        HStack(spacing: 10) {
            Image(systemName: book.icon)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(book.title).font(.system(size: 12, weight: .medium))
                Text(book.isBuiltin ? "Built in" : "Custom JSON")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { configuration.isEnabled(book.id) },
                set: {
                    configuration.setEnabled(book.id, enabled: $0)
                    onChanged()
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
        }
        .frame(maxWidth: .infinity, minHeight: 36)
    }
}

// MARK: - Shortcut recorder

@MainActor
final class PocketbookV3ShortcutCaptureView: NSView {
    private let shortcutLabel = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "Press a new shortcut")
    var captured: PocketbookV3Shortcut?

    override var acceptsFirstResponder: Bool { return true }

    init(current: PocketbookV3Shortcut) {
        captured = current
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 74))
        shortcutLabel.stringValue = current.displayString
        shortcutLabel.font = .systemFont(ofSize: 24, weight: .semibold)
        shortcutLabel.alignment = .center
        hint.font = .systemFont(ofSize: 11)
        hint.alignment = .center
        hint.textColor = .secondaryLabelColor
        [shortcutLabel, hint].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            shortcutLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            shortcutLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            hint.centerXAnchor.constraint(equalTo: centerXAnchor),
            hint.topAnchor.constraint(equalTo: shortcutLabel.bottomAnchor, constant: 6),
        ])
    }

    required init?(coder: NSCoder) { return nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.window?.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        guard let value = PocketbookV3Shortcut(event: event),
              !value.conflictsWithFileShelf else {
            NSSound.beep()
            hint.stringValue = "Use modifier + key. Cmd+X / Cmd+V are reserved."
            return
        }
        captured = value
        shortcutLabel.stringValue = value.displayString
        hint.stringValue = "Ready to save"
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}
