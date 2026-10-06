import AppKit
import Carbon.HIToolbox
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let defaultOpenerDefaultsKey = "SuperNotch.defaultDropOpener"
    private static let customOpenerPathDefaultsKey = "SuperNotch.customDropOpenerPath"

    private let coordinator = ShelfCoordinator()
    private let pocketbook = PocketbookFeatureV3()
    private let commandCenter = NotchCommandCenterFeature()
    private lazy var volumeHUD = SuperNotchVolumeHUDFeature()
    private lazy var liveTranslate = SuperNotchLiveTranslateFeature()
    private lazy var terminal = NotchTerminalFeature(
        workingDirectoryProvider: { [weak self] in
            return self?.coordinator.recentProjectURL
        },
        beforeShow: { [weak self] in
            self?.pocketbook.hide()
            self?.commandCenter.hide()
        }
    )

    private var statusItem: NSStatusItem?
    private var shelfStatusItem: NSMenuItem?
    private var projectStatusItem: NSMenuItem?
    private var defaultDropAppItem: NSMenuItem?
    private var openRecentItem: NSMenuItem?
    private var clearProjectItem: NSMenuItem?
    private var pocketbookShortcutItem: NSMenuItem?
    private var terminalShortcutItem: NSMenuItem?
    private var liveTranslateEnabledItem: NSMenuItem?
    private var liveTranslateMenuItem: NSMenuItem?
    private var liveTranslateShortcutItem: NSMenuItem?
    private var liveTranslateSourceItem: NSMenuItem?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()

        coordinator.onShelfChanged = { [weak self] count in
            self?.updateShelfStatus(count: count)
        }
        coordinator.onProjectChanged = { [weak self] url in
            self?.updateProjectStatus(url: url)
        }
        coordinator.onDropOpenerChanged = { [weak self] in
            self?.updateDropOpenerUI()
        }
        pocketbook.onShortcutChanged = { [weak self] in
            self?.updatePocketbookUI()
        }
        terminal.onShortcutChanged = { [weak self] in
            self?.updateTerminalUI()
        }

        volumeHUD.onVolumeChanged = { [weak self] level, muted in
            self?.coordinator.showVolumeHUD(level: level, muted: muted)
        }

        liveTranslate.onCaption = { [weak self] source, target, partial in
            guard let self else { return }

            // Live Translate keeps listening in the background, but the physical
            // notch has a single visual owner. Never let captions stack over
            // Terminal, Pocketbook, or Command Center.
            let canPresent = !self.terminal.isVisible
                && !self.pocketbook.isVisible
                && !self.commandCenter.isVisible

            self.coordinator.showLiveTranslate(
                source: source,
                target: target,
                partial: partial,
                present: canPresent
            )
        }
        liveTranslate.onStateChanged = { [weak self] state in
            self?.updateLiveTranslateUI()
            if state == .idle { self?.coordinator.stopLiveTranslatePresentation() }
        }
        liveTranslate.onShortcutChanged = { [weak self] in
            self?.updateLiveTranslateUI()
        }

        coordinator.start()
        volumeHUD.start()
        commandCenter.start()
        pocketbook.start()
        terminal.start()
        liveTranslate.installShortcut()
        updateProjectStatus(url: coordinator.recentProjectURL)
        updateDropOpenerUI()
        updatePocketbookUI()
        updateTerminalUI()
    }

    func applicationWillTerminate(_ notification: Notification) {
        liveTranslate.stop(waitForCleanup: true)
        liveTranslate.uninstallShortcut()
        terminal.stop()
        pocketbook.stop()
        commandCenter.stop()
        volumeHUD.stop()
        coordinator.stop()
    }

    private func setupMenuBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "tray.full.fill",
            accessibilityDescription: "SuperNotch"
        )

        let menu = NSMenu()
        menu.delegate = self

        let shelf = NSMenuItem(title: "Shelf: Empty", action: nil, keyEquivalent: "")
        shelf.isEnabled = false
        menu.addItem(shelf)
        shelfStatusItem = shelf

        let clear = NSMenuItem(
            title: "Clear Shelf",
            action: #selector(clearShelf),
            keyEquivalent: ""
        )
        clear.target = self
        menu.addItem(clear)

        let commandCenter = NSMenuItem(
            title: "Command Center",
            action: #selector(openCommandCenterAction),
            keyEquivalent: ""
        )
        commandCenter.target = self
        menu.addItem(commandCenter)

        menu.addItem(.separator())

        let dropHeader = NSMenuItem(title: "Developer Drop Zone", action: nil, keyEquivalent: "")
        dropHeader.isEnabled = false
        menu.addItem(dropHeader)

        let defaultApp = NSMenuItem(
            title: "Default Drop App",
            action: nil,
            keyEquivalent: ""
        )
        defaultApp.submenu = NSMenu(title: "Default Drop App")
        menu.addItem(defaultApp)
        defaultDropAppItem = defaultApp

        let project = NSMenuItem(title: "Recent: None", action: nil, keyEquivalent: "")
        project.isEnabled = false
        menu.addItem(project)
        projectStatusItem = project

        let openRecent = NSMenuItem(
            title: "Open Recent With",
            action: nil,
            keyEquivalent: ""
        )
        openRecent.submenu = NSMenu(title: "Open Recent With")
        menu.addItem(openRecent)
        openRecentItem = openRecent

        let clearProject = NSMenuItem(
            title: "Clear Recent Project",
            action: #selector(clearRecentProject),
            keyEquivalent: ""
        )
        clearProject.target = self
        menu.addItem(clearProject)
        clearProjectItem = clearProject

        menu.addItem(.separator())

        let pocketHeader = NSMenuItem(title: "Pocketbook", action: nil, keyEquivalent: "")
        pocketHeader.isEnabled = false
        menu.addItem(pocketHeader)

        let openPocketbook = NSMenuItem(
            title: "Open Pocketbook",
            action: #selector(openPocketbookAction),
            keyEquivalent: ""
        )
        openPocketbook.target = self
        menu.addItem(openPocketbook)

        let shortcutItem = NSMenuItem(
            title: "Shortcut: \(pocketbook.shortcutDescription)…",
            action: #selector(configurePocketbookShortcut),
            keyEquivalent: ""
        )
        shortcutItem.target = self
        menu.addItem(shortcutItem)
        pocketbookShortcutItem = shortcutItem

        menu.addItem(.separator())

        let translateHeader = NSMenuItem(title: "Live Translate", action: nil, keyEquivalent: "")
        translateHeader.isEnabled = false
        menu.addItem(translateHeader)

        let liveTranslateEnabled = NSMenuItem(
            title: "Enable Live Translate",
            action: #selector(toggleLiveTranslateFeatureAction),
            keyEquivalent: ""
        )
        liveTranslateEnabled.target = self
        menu.addItem(liveTranslateEnabled)
        liveTranslateEnabledItem = liveTranslateEnabled

        let liveTranslateItem = NSMenuItem(
            title: "Start Live Translate",
            action: #selector(toggleLiveTranslateAction),
            keyEquivalent: ""
        )
        liveTranslateItem.target = self
        menu.addItem(liveTranslateItem)
        liveTranslateMenuItem = liveTranslateItem

        let liveTranslateShortcut = NSMenuItem(
            title: "Shortcut: \(liveTranslate.shortcutDescription)…",
            action: #selector(configureLiveTranslateShortcut),
            keyEquivalent: ""
        )
        liveTranslateShortcut.target = self
        menu.addItem(liveTranslateShortcut)
        liveTranslateShortcutItem = liveTranslateShortcut

        let liveTranslateSource = NSMenuItem(
            title: "Show English Source",
            action: #selector(toggleLiveTranslateSourceAction),
            keyEquivalent: ""
        )
        liveTranslateSource.target = self
        menu.addItem(liveTranslateSource)
        liveTranslateSourceItem = liveTranslateSource

        menu.addItem(.separator())

        let terminalHeader = NSMenuItem(title: "Notch Terminal", action: nil, keyEquivalent: "")
        terminalHeader.isEnabled = false
        menu.addItem(terminalHeader)

        let openTerminal = NSMenuItem(
            title: "Open Notch Terminal",
            action: #selector(openTerminalAction),
            keyEquivalent: ""
        )
        openTerminal.target = self
        menu.addItem(openTerminal)

        let restartTerminal = NSMenuItem(
            title: "Restart Terminal Shell",
            action: #selector(restartTerminalAction),
            keyEquivalent: ""
        )
        restartTerminal.target = self
        menu.addItem(restartTerminal)

        let terminalShortcut = NSMenuItem(
            title: "Shortcut: \(terminal.shortcutDescription)…",
            action: #selector(configureTerminalShortcut),
            keyEquivalent: ""
        )
        terminalShortcut.target = self
        menu.addItem(terminalShortcut)
        terminalShortcutItem = terminalShortcut

        menu.addItem(.separator())

        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ""
        )
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit SuperNotch",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quit)

        item.menu = menu
        statusItem = item

        updateShelfStatus(count: 0)
        updateProjectStatus(url: nil)
        updateDropOpenerUI()
        updatePocketbookUI()
        updateTerminalUI()
        updateLiveTranslateUI()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        updateShelfStatus(count: coordinator.stagedCount)
        updateProjectStatus(url: coordinator.recentProjectURL)
        updateDropOpenerUI()
        updatePocketbookUI()
        updateTerminalUI()
        updateLiveTranslateUI()
    }

    private func updateShelfStatus(count: Int) {
        shelfStatusItem?.title = count == 0
            ? "Shelf: Empty"
            : "Shelf: \(count) item\(count == 1 ? "" : "s")"

        statusItem?.button?.image = NSImage(
            systemSymbolName: count == 0 ? "tray" : "tray.full.fill",
            accessibilityDescription: "SuperNotch"
        )
    }

    private func updateProjectStatus(url: URL?) {
        let hasProject = url != nil
        projectStatusItem?.title = url.map { "Recent: \($0.lastPathComponent)" }
            ?? "Recent: None"
        openRecentItem?.isEnabled = hasProject
        clearProjectItem?.isEnabled = hasProject
    }

    private func updateDropOpenerUI() {
        defaultDropAppItem?.title = "Default Drop App: \(coordinator.defaultDropOpenerName)"

        let availableOptions = coordinator.dropOpenerMenuOptions.filter { $0.isAvailable }

        if let submenu = defaultDropAppItem?.submenu {
            submenu.removeAllItems()

            for option in availableOptions {
                let item = NSMenuItem(
                    title: option.displayName,
                    action: #selector(selectDropOpener(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = option.id
                item.state = option.isSelected ? .on : .off
                submenu.addItem(item)
            }

            submenu.addItem(.separator())

            let custom = NSMenuItem(
                title: "Choose Custom App…",
                action: #selector(chooseCustomDropApp),
                keyEquivalent: ""
            )
            custom.target = self
            submenu.addItem(custom)
        }

        if let recentMenu = openRecentItem?.submenu {
            recentMenu.removeAllItems()

            for option in availableOptions {
                let item = NSMenuItem(
                    title: option.displayName,
                    action: #selector(openRecentWithOpener(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = option.id
                recentMenu.addItem(item)
            }

            recentMenu.addItem(.separator())

            let chooseOther = NSMenuItem(
                title: "Choose Other App…",
                action: #selector(chooseOtherAppForRecent),
                keyEquivalent: ""
            )
            chooseOther.target = self
            recentMenu.addItem(chooseOther)
        }
    }

    private func updatePocketbookUI() {
        pocketbookShortcutItem?.title = "Shortcut: \(pocketbook.shortcutDescription)…"
    }

    private func updateTerminalUI() {
        terminalShortcutItem?.title = "Shortcut: \(terminal.shortcutDescription)…"
    }

    private func updateLiveTranslateUI() {
        liveTranslateEnabledItem?.state = liveTranslate.isEnabled ? .on : .off

        liveTranslateMenuItem?.title = liveTranslate.isRunning
            ? "Stop Live Translate"
            : "Start Live Translate"
        liveTranslateMenuItem?.state = liveTranslate.isRunning ? .on : .off
        liveTranslateMenuItem?.isEnabled = liveTranslate.isEnabled

        liveTranslateShortcutItem?.title = "Shortcut: \(liveTranslate.shortcutDescription)…"
        liveTranslateSourceItem?.state = coordinator.liveTranslateShowsSource ? .on : .off
        liveTranslateSourceItem?.isEnabled = liveTranslate.isEnabled
    }

    @objc private func clearShelf() {
        coordinator.clearShelf()
    }

    @objc private func selectDropOpener(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        coordinator.setDefaultDropOpener(id: id)
    }

    @objc private func chooseCustomDropApp() {
        coordinator.chooseCustomDropApp()
    }

    @objc private func openRecentWithOpener(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        performRecentOpen(usingTemporaryOpenerID: id)
    }

    @objc private func chooseOtherAppForRecent() {
        let picker = NSOpenPanel()
        picker.title = "Open Recent With"
        picker.message = "Choose an application for this open only. Your default Drop Zone app will not change."
        picker.prompt = "Open"
        picker.canChooseFiles = true
        picker.canChooseDirectories = false
        picker.allowsMultipleSelection = false
        picker.allowedContentTypes = [.application]
        picker.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)

        NSApp.activate(ignoringOtherApps: true)
        guard picker.runModal() == .OK, let appURL = picker.url else { return }

        let defaults = UserDefaults.standard
        let previousDefault = defaults.string(forKey: Self.defaultOpenerDefaultsKey)
        let previousCustomPath = defaults.string(forKey: Self.customOpenerPathDefaultsKey)

        defaults.set(appURL.path, forKey: Self.customOpenerPathDefaultsKey)
        defaults.set("custom", forKey: Self.defaultOpenerDefaultsKey)

        coordinator.openRecentWithDefaultApp()

        restoreDefaults(
            previousDefault: previousDefault,
            previousCustomPath: previousCustomPath
        )
        updateDropOpenerUI()
    }

    private func performRecentOpen(usingTemporaryOpenerID id: String) {
        let defaults = UserDefaults.standard
        let previousDefault = defaults.string(forKey: Self.defaultOpenerDefaultsKey)

        defaults.set(id, forKey: Self.defaultOpenerDefaultsKey)
        coordinator.openRecentWithDefaultApp()

        if let previousDefault = previousDefault {
            defaults.set(previousDefault, forKey: Self.defaultOpenerDefaultsKey)
        } else {
            defaults.removeObject(forKey: Self.defaultOpenerDefaultsKey)
        }

        updateDropOpenerUI()
    }

    private func restoreDefaults(previousDefault: String?, previousCustomPath: String?) {
        let defaults = UserDefaults.standard

        if let previousDefault = previousDefault {
            defaults.set(previousDefault, forKey: Self.defaultOpenerDefaultsKey)
        } else {
            defaults.removeObject(forKey: Self.defaultOpenerDefaultsKey)
        }

        if let previousCustomPath = previousCustomPath {
            defaults.set(previousCustomPath, forKey: Self.customOpenerPathDefaultsKey)
        } else {
            defaults.removeObject(forKey: Self.customOpenerPathDefaultsKey)
        }
    }

    @objc private func clearRecentProject() {
        coordinator.clearRecentProject()
    }

    @objc private func checkForUpdates() {
        SuperNotchUpdateController.shared.checkForUpdates()
    }

    @objc private func toggleLiveTranslateFeatureAction() {
        let enabled = !liveTranslate.isEnabled
        liveTranslate.setFeatureEnabled(enabled)

        if !enabled {
            coordinator.hideTransientOverlay()
        }

        updateLiveTranslateUI()
    }

    @objc private func toggleLiveTranslateAction() {
        guard liveTranslate.isEnabled else {
            NSSound.beep()
            return
        }

        liveTranslate.toggle()
        updateLiveTranslateUI()
        if !liveTranslate.isRunning {
            coordinator.hideTransientOverlay()
        }
    }

    @objc private func configureLiveTranslateShortcut() {
        liveTranslate.showShortcutRecorder()
        updateLiveTranslateUI()
    }

    @objc private func toggleLiveTranslateSourceAction() {
        coordinator.setLiveTranslateShowsSource(!coordinator.liveTranslateShowsSource)
        updateLiveTranslateUI()
    }

    @objc private func openPocketbookAction() {
        terminal.hide()
        commandCenter.hide()
        pocketbook.toggle()
    }

    @objc private func openCommandCenterAction() {
        terminal.hide()
        pocketbook.hide()
        commandCenter.toggle()
    }

    @objc private func openSettings() {
        terminal.hide()
        commandCenter.hide()
        pocketbook.showSettings(section: .general)
    }

    @objc private func configurePocketbookShortcut() {
        pocketbook.showShortcutRecorder()
        updatePocketbookUI()
    }

    @objc private func openTerminalAction() {
        terminal.toggle()
    }

    @objc private func restartTerminalAction() {
        terminal.restartShell()
    }

    @objc private func configureTerminalShortcut() {
        terminal.showShortcutRecorder()
        updateTerminalUI()
    }
}
