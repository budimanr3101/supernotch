import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - Settings preview

struct DeveloperCommandCenterView: View {
    @ObservedObject private var registry = SuperNotchFeatureRegistry.shared
    @StateObject private var monitor = SuperNotchSystemMonitor()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Developer Command Center")
                        .font(.title2.weight(.semibold))
                    Text("Fast signals and shortcuts without leaving SuperNotch.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    monitor.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh")
            }

            if registry.isEnabled(.systemPulse) {
                HStack(spacing: 10) {
                    settingsMetric("CPU", value: monitor.snapshot.cpuPercent, icon: "cpu")
                    settingsMetric("Memory", value: monitor.snapshot.memoryPercent, icon: "memorychip")
                    settingsMetric("Disk", value: monitor.snapshot.diskPercent, icon: "internaldrive")
                }
            }

            if registry.isEnabled(.quickLinks) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("QUICK LINKS")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        ForEach(SuperNotchQuickLink.allCases) { link in
                            Link(destination: link.url) {
                                Label(link.title, systemImage: link.icon)
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else { break }
                monitor.refresh()
            }
        }
    }

    private func settingsMetric(_ title: String, value: Int, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("\(value)%")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
            ProgressView(value: Double(value), total: 100)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }
}

struct SuperNotchFeatureSettingsView: View {
    @ObservedObject private var registry = SuperNotchFeatureRegistry.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(SuperNotchFeatureID.allCases) { feature in
                HStack(spacing: 12) {
                    Image(systemName: feature.icon)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(feature.title)
                                .font(.system(size: 13, weight: .medium))
                            if feature.isCore {
                                Text("CORE")
                                    .font(.system(size: 8.5, weight: .bold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(feature.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()

                    if feature.isCore {
                        Text("Always on")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Toggle("", isOn: Binding(
                            get: { registry.isEnabled(feature) },
                            set: { registry.setEnabled(feature, enabled: $0) }
                        ))
                        .labelsHidden()
                    }
                }
                .padding(.vertical, 4)

                if feature.id != SuperNotchFeatureID.allCases.last?.id {
                    Divider()
                }
            }
        }
    }
}

// MARK: - Physical notch Command Center

@MainActor
private final class NotchCommandCenterModel: ObservableObject {
    @Published var presented = false
}

private struct NotchCommandCenterMetrics {
    let wingWidth: CGFloat
    let depth: CGFloat
    let maxDepth: CGFloat
    let contentWidth: CGFloat
    let windowSize: CGSize

    init(geometry: NotchGeometry, screen: NSScreen) {
        let availableHalfWidth = max(210, (screen.frame.width - geometry.hardwareWidth - 48) / 2)
        wingWidth = min(300, availableHalfWidth - NotchGeometry.topRadius)
        depth = 286
        maxDepth = 294
        contentWidth = geometry.hardwareWidth + 2 * wingWidth
        windowSize = CGSize(
            width: geometry.hardwareWidth + 2 * (wingWidth + NotchGeometry.topRadius) + 32,
            height: geometry.hardwareHeight + maxDepth + 4
        )
    }
}

@MainActor
final class NotchCommandCenterFeature {
    // The primary-surface manager already reserves +3 / NSLA for the launcher slot.
    // Command Center owns that slot now, preserving single-surface behavior without
    // changing File Shelf or Drop Zone overlay geometry.
    private let surfaceSignature: OSType = 0x4E534C41 // NSLA
    private let model = NotchCommandCenterModel()

    private static let hoverDelay: TimeInterval = 0.12
    private static let hoverSidePadding: CGFloat = 18
    private static let hoverBelowPadding: CGFloat = 12
    private static let hoverReopenCooldown: TimeInterval = 0.45

    private var panel: NotchCommandCenterPanel?
    private var started = false
    private var requestedVisible = false
    private var pendingDismissal: DispatchWorkItem?
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?
    private var hoverLocalEventMonitor: Any?
    private var hoverGlobalEventMonitor: Any?
    private var hoverOpenTask: DispatchWorkItem?
    private var hoverSuppressedUntil: TimeInterval = 0

    var isVisible: Bool { requestedVisible && panel?.isVisible == true }

    func start() {
        guard !started else { return }

        let status = CarbonHotKeyCenter.shared.setHandler(
            signature: surfaceSignature,
            id: 1
        ) { [weak self] in
            guard let self else { return OSStatus(eventNotHandledErr) }
            self.toggle()
            return noErr
        }

        guard status == noErr else {
            NSLog("[SuperNotch] Command Center surface handler failed: %d", status)
            return
        }

        started = true
        installHoverMonitors()
        NSLog("[SuperNotch] Command Center notch surface ready with hover activation")
    }

    func stop() {
        requestedVisible = false
        pendingDismissal?.cancel()
        pendingDismissal = nil
        hoverOpenTask?.cancel()
        hoverOpenTask = nil
        model.presented = false
        removeEventMonitors()
        removeHoverMonitors()
        panel?.orderOut(nil)
        panel = nil

        if started {
            CarbonHotKeyCenter.shared.removeHandler(signature: surfaceSignature, id: 1)
        }
        started = false
    }

    func toggle() {
        if isVisible { hide() }
        else { show() }
    }

    func show() {
        if isVisible {
            panel?.makeKeyAndOrderFront(nil)
            return
        }

        guard let screen = NSScreen.screens.first(where: { NotchGeometry.measure($0) != nil }),
              let geometry = NotchGeometry.measure(screen) else {
            NSSound.beep()
            return
        }

        hoverOpenTask?.cancel()
        hoverOpenTask = nil
        pendingDismissal?.cancel()
        pendingDismissal = nil
        requestedVisible = true

        let metrics = NotchCommandCenterMetrics(geometry: geometry, screen: screen)
        let frame = NSRect(
            x: screen.frame.midX - metrics.windowSize.width / 2,
            y: screen.frame.maxY - metrics.windowSize.height,
            width: metrics.windowSize.width,
            height: metrics.windowSize.height
        )

        if panel?.frame != frame {
            panel?.orderOut(nil)
            panel = NotchCommandCenterPanel(
                frame: frame,
                model: model,
                geometry: geometry,
                metrics: metrics,
                onClose: { [weak self] in self?.hide() }
            )
        }

        installEventMonitors()
        // The panel is non-activating on purpose. Hovering the physical notch must
        // never steal focus from Terminal, Xcode, a browser, or another foreground app.
        panel?.ignoresMouseEvents = false
        panel?.makeKeyAndOrderFront(nil)
        panel?.contentView?.layoutSubtreeIfNeeded()
        panel?.displayIfNeeded()

        DispatchQueue.main.async { [weak self] in
            guard let self, self.requestedVisible else { return }
            self.model.presented = true
        }
    }

    func hide() {
        hoverOpenTask?.cancel()
        hoverOpenTask = nil
        hoverSuppressedUntil = ProcessInfo.processInfo.systemUptime + Self.hoverReopenCooldown

        guard requestedVisible, let panel else {
            removeEventMonitors()
            return
        }

        requestedVisible = false
        removeEventMonitors()
        panel.ignoresMouseEvents = true
        panel.makeFirstResponder(nil)
        panel.resignKey()
        model.presented = false
        pendingDismissal?.cancel()

        let work = DispatchWorkItem { [weak self, weak panel] in
            guard let self, !self.requestedVisible, self.panel === panel else { return }
            panel?.orderOut(nil)
            self.pendingDismissal = nil
        }
        pendingDismissal = work

        let delay = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.12 : 0.26
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: Hover activation

    private func installHoverMonitors() {
        removeHoverMonitors()

        let movementMask: NSEvent.EventTypeMask = [
            .mouseMoved,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged,
        ]

        hoverLocalEventMonitor = NSEvent.addLocalMonitorForEvents(matching: movementMask) { [weak self] event in
            self?.handlePointerMoved(to: NSEvent.mouseLocation)
            return event
        }

        hoverGlobalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: movementMask) { [weak self] _ in
            Task { @MainActor in
                self?.handlePointerMoved(to: NSEvent.mouseLocation)
            }
        }
    }

    private func removeHoverMonitors() {
        hoverOpenTask?.cancel()
        hoverOpenTask = nil

        if let hoverLocalEventMonitor {
            NSEvent.removeMonitor(hoverLocalEventMonitor)
            self.hoverLocalEventMonitor = nil
        }
        if let hoverGlobalEventMonitor {
            NSEvent.removeMonitor(hoverGlobalEventMonitor)
            self.hoverGlobalEventMonitor = nil
        }
    }

    private func handlePointerMoved(to location: NSPoint) {
        guard started, !requestedVisible else { return }

        let now = ProcessInfo.processInfo.systemUptime
        guard now >= hoverSuppressedUntil else {
            hoverOpenTask?.cancel()
            hoverOpenTask = nil
            return
        }

        guard !anotherPrimarySurfaceIsVisible(),
              isInsideNotchHoverRegion(location) else {
            hoverOpenTask?.cancel()
            hoverOpenTask = nil
            return
        }

        guard hoverOpenTask == nil else { return }

        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  !self.requestedVisible,
                  !self.anotherPrimarySurfaceIsVisible(),
                  self.isInsideNotchHoverRegion(NSEvent.mouseLocation) else {
                self?.hoverOpenTask = nil
                return
            }

            self.hoverOpenTask = nil
            self.show()
        }
        hoverOpenTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverDelay, execute: work)
    }

    private func isInsideNotchHoverRegion(_ location: NSPoint) -> Bool {
        guard let screen = NSScreen.screens.first(where: { NotchGeometry.measure($0) != nil }),
              let geometry = NotchGeometry.measure(screen) else {
            return false
        }

        let region = NSRect(
            x: screen.frame.midX - geometry.hardwareWidth / 2 - Self.hoverSidePadding,
            y: screen.frame.maxY - geometry.hardwareHeight - Self.hoverBelowPadding,
            width: geometry.hardwareWidth + 2 * Self.hoverSidePadding,
            height: geometry.hardwareHeight + Self.hoverBelowPadding
        )
        return region.contains(location)
    }

    private func anotherPrimarySurfaceIsVisible() -> Bool {
        let terminalLevel = NSWindow.Level.mainMenu.rawValue + 1
        let pocketbookLevel = NSWindow.Level.mainMenu.rawValue + 2

        return NSApp.windows.contains { window in
            guard window.isVisible, window.canBecomeKey else { return false }
            let level = window.level.rawValue
            return level == terminalLevel || level == pocketbookLevel
        }
    }

    // MARK: Dismissal

    private func installEventMonitors() {
        removeEventMonitors()

        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self else { return event }

            if event.type == .keyDown, event.keyCode == UInt16(kVK_Escape) {
                self.hide()
                return nil
            }

            if event.type != .keyDown, let panel = self.panel {
                if let eventWindow = event.window {
                    if eventWindow !== panel { self.hide() }
                } else {
                    self.hide()
                }
            }
            return event
        }

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self,
                      self.requestedVisible,
                      let panel = self.panel else { return }
                if !panel.frame.contains(NSEvent.mouseLocation) {
                    self.hide()
                }
            }
        }
    }

    private func removeEventMonitors() {
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }
    }
}

@MainActor
private final class NotchCommandCenterPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(
        frame: NSRect,
        model: NotchCommandCenterModel,
        geometry: NotchGeometry,
        metrics: NotchCommandCenterMetrics,
        onClose: @escaping () -> Void
    ) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        identifier = NSUserInterfaceItemIdentifier("NotchCommandCenterPanel")
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        level = .mainMenu + 3
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false

        let hosting = NSHostingView(
            rootView: NotchCommandCenterSurfaceView(
                model: model,
                geometry: geometry,
                metrics: metrics,
                onClose: onClose
            )
        )
        hosting.safeAreaRegions = []
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: frame.size)
        hosting.autoresizingMask = [.width, .height]
        contentView = hosting
    }
}

private struct NotchCommandCenterSurfaceView: View {
    @ObservedObject var model: NotchCommandCenterModel
    let geometry: NotchGeometry
    let metrics: NotchCommandCenterMetrics
    let onClose: () -> Void

    @ObservedObject private var registry = SuperNotchFeatureRegistry.shared
    @StateObject private var monitor = SuperNotchSystemMonitor()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var shoulderExpansion: CGFloat = 0
    @State private var bridgeExpansion: CGFloat = 0
    @State private var contentVisible = false
    @State private var pendingMotion: [DispatchWorkItem] = []

    private var surface: PocketbookV3Wings {
        PocketbookV3Wings(
            geometry: geometry,
            expansion: shoulderExpansion,
            extraDepth: bridgeExpansion * metrics.depth,
            wingWidth: metrics.wingWidth,
            maximumDepth: metrics.maxDepth
        )
    }

    var body: some View {
        ZStack(alignment: .top) {
            surface
                .fill(Color.black)
                .overlay {
                    PocketbookV3OuterEdge(
                        geometry: geometry,
                        expansion: shoulderExpansion,
                        extraDepth: bridgeExpansion * metrics.depth,
                        wingWidth: metrics.wingWidth,
                        maximumDepth: metrics.maxDepth
                    )
                    .stroke(Color.white.opacity(0.10), lineWidth: 0.75)
                }
                .shadow(
                    color: Color.black.opacity(0.36 * Double(bridgeExpansion)),
                    radius: 16,
                    y: 6
                )

            content
                .frame(width: metrics.windowSize.width, height: metrics.windowSize.height, alignment: .top)
                .mask(surface)
                .opacity(contentVisible ? 1 : 0)
                .offset(y: reduceMotion || contentVisible ? 0 : -5)
                .allowsHitTesting(model.presented && contentVisible)
        }
        .frame(width: metrics.windowSize.width, height: metrics.windowSize.height, alignment: .top)
        .clipped()
        .opacity(reduceMotion && !model.presented ? 0 : 1)
        .onChange(of: model.presented) { visible in
            animatePresentation(visible)
            if visible { monitor.refresh() }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else { break }
                if model.presented { monitor.refresh() }
            }
        }
        .onDisappear { cancelMotion() }
    }

    private var content: some View {
        VStack(spacing: 12) {
            header

            if registry.isEnabled(.systemPulse) {
                HStack(spacing: 10) {
                    notchMetric("CPU", value: monitor.snapshot.cpuPercent, icon: "cpu")
                    notchMetric("Memory", value: monitor.snapshot.memoryPercent, icon: "memorychip")
                    notchMetric("Disk", value: monitor.snapshot.diskPercent, icon: "internaldrive")
                }
            }

            if registry.isEnabled(.quickLinks) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("QUICK LINKS")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.42))

                    HStack(spacing: 8) {
                        ForEach(SuperNotchQuickLink.allCases) { link in
                            Button {
                                NSWorkspace.shared.open(link.url)
                            } label: {
                                Label(link.title, systemImage: link.icon)
                                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(Color.white.opacity(0.075))
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .stroke(Color.white.opacity(0.07), lineWidth: 0.75)
                            }
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            HStack {
                Label("Esc to close", systemImage: "escape")
                Spacer()
                Text("Click outside to collapse")
            }
            .font(.system(size: 9, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.38))
        }
        .padding(.horizontal, 16)
        .padding(.top, geometry.hardwareHeight + 10)
        .padding(.bottom, 11)
        .frame(
            width: metrics.contentWidth,
            height: geometry.hardwareHeight + metrics.depth,
            alignment: .top
        )
        .foregroundStyle(.white)
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "rectangle.grid.2x2.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 25, height: 25)
                .background(Circle().fill(Color.accentColor.opacity(0.13)))

            VStack(alignment: .leading, spacing: 1) {
                Text("Command Center")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                Text("System pulse & developer shortcuts")
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.46))
            }

            Spacer()

            Button {
                monitor.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 25, height: 25)
                    .background(Circle().fill(Color.white.opacity(0.07)))
            }
            .buttonStyle(.plain)
            .help("Refresh")

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 25, height: 25)
                    .background(Circle().fill(Color.white.opacity(0.07)))
            }
            .buttonStyle(.plain)
        }
        .frame(height: 30)
    }

    private func notchMetric(_ title: String, value: Int, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: icon)
                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.50))

            Text("\(value)%")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .contentTransition(.numericText())

            ProgressView(value: Double(value), total: 100)
                .progressViewStyle(.linear)
                .tint(Color.accentColor)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.065))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.055), lineWidth: 0.75)
        }
    }

    private func animatePresentation(_ visible: Bool) {
        cancelMotion()

        if reduceMotion {
            shoulderExpansion = visible ? 1 : 0
            bridgeExpansion = visible ? 1 : 0
            withAnimation(.easeOut(duration: 0.12)) {
                contentVisible = visible
            }
            return
        }

        if visible {
            withAnimation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.14)) {
                shoulderExpansion = 1
            }
            schedule(after: 0.06) {
                withAnimation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.22)) {
                    bridgeExpansion = 1
                }
            }
            schedule(after: 0.15) {
                withAnimation(.easeOut(duration: 0.12)) {
                    contentVisible = true
                }
            }
        } else {
            withAnimation(.easeOut(duration: 0.09)) {
                contentVisible = false
            }
            schedule(after: 0.04) {
                withAnimation(.timingCurve(0.55, 0, 0.85, 0.40, duration: 0.17)) {
                    bridgeExpansion = 0
                }
            }
            schedule(after: 0.12) {
                withAnimation(.timingCurve(0.55, 0, 0.85, 0.40, duration: 0.14)) {
                    shoulderExpansion = 0
                }
            }
        }
    }

    private func schedule(after delay: TimeInterval, _ block: @escaping () -> Void) {
        let item = DispatchWorkItem(block: block)
        pendingMotion.append(item)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func cancelMotion() {
        pendingMotion.forEach { $0.cancel() }
        pendingMotion.removeAll()
    }
}
