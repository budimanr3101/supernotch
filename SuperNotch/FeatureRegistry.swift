import AppKit
import Darwin
import Foundation

enum SuperNotchFeatureID: String, CaseIterable, Identifiable {
    case fileShelf
    case dropZone
    case pocketbook
    case terminal
    case systemPulse
    case quickLinks
    case volumeHUD
    case liveTranslate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fileShelf: return "File Shelf"
        case .dropZone: return "Developer Drop Zone"
        case .pocketbook: return "Pocketbook"
        case .terminal: return "Native Terminal"
        case .systemPulse: return "System Pulse"
        case .quickLinks: return "Dev Quick Links"
        case .volumeHUD: return "Volume HUD"
        case .liveTranslate: return "Live Translate"
        }
    }

    var subtitle: String {
        switch self {
        case .fileShelf: return "Stage Finder files and move them safely."
        case .dropZone: return "Open projects in your developer tools."
        case .pocketbook: return "Kubernetes and DevOps references."
        case .terminal: return "Real Zsh terminal inside SuperNotch."
        case .systemPulse: return "CPU, memory and disk at a glance."
        case .quickLinks: return "Jump to the tools you use every day."
        case .volumeHUD: return "Show volume changes from the physical notch and replace the macOS volume OSD when Accessibility access is granted."
        case .liveTranslate: return "Translate English meeting audio to Indonesian subtitles in real time."
        }
    }

    var icon: String {
        switch self {
        case .fileShelf: return "tray.full"
        case .dropZone: return "shippingbox"
        case .pocketbook: return "books.vertical"
        case .terminal: return "terminal"
        case .systemPulse: return "waveform.path.ecg"
        case .quickLinks: return "link"
        case .volumeHUD: return "speaker.wave.2"
        case .liveTranslate: return "captions.bubble"
        }
    }

    var isCore: Bool {
        switch self {
        case .fileShelf, .dropZone, .pocketbook, .terminal: return true
        case .systemPulse, .quickLinks, .volumeHUD, .liveTranslate: return false
        }
    }
}

@MainActor
final class SuperNotchFeatureRegistry: ObservableObject {
    static let shared = SuperNotchFeatureRegistry()

    @Published private(set) var enabled: Set<SuperNotchFeatureID>

    private let defaults = UserDefaults.standard
    private let key = "SuperNotch.enabledFeatures"
    private let schemaKey = "SuperNotch.featureSchemaVersion"
    private let currentSchemaVersion = 3

    private init() {
        let saved = defaults.stringArray(forKey: key) ?? []
        var parsed = Set(saved.compactMap(SuperNotchFeatureID.init(rawValue:)))

        if parsed.isEmpty {
            parsed = Set(SuperNotchFeatureID.allCases)
        } else if defaults.integer(forKey: schemaKey) < currentSchemaVersion {
            // New optional features default on for existing installs unless the user
            // has already seen this feature schema and explicitly disabled them.
            parsed.insert(.volumeHUD)
            parsed.insert(.liveTranslate)
        }

        enabled = parsed
        defaults.set(enabled.map(\.rawValue).sorted(), forKey: key)
        defaults.set(currentSchemaVersion, forKey: schemaKey)
    }

    func isEnabled(_ feature: SuperNotchFeatureID) -> Bool {
        enabled.contains(feature)
    }

    func setEnabled(_ feature: SuperNotchFeatureID, enabled shouldEnable: Bool) {
        if shouldEnable {
            enabled.insert(feature)
        } else {
            enabled.remove(feature)
        }
        defaults.set(enabled.map(\.rawValue).sorted(), forKey: key)
    }
}

struct SuperNotchSystemSnapshot {
    let cpuPercent: Int
    let memoryPercent: Int
    let diskPercent: Int
}

private struct SuperNotchCPUTicks {
    let user: UInt64
    let system: UInt64
    let nice: UInt64
    let idle: UInt64

    var busy: UInt64 { user + system + nice }
    var total: UInt64 { busy + idle }
}

@MainActor
final class SuperNotchSystemMonitor: ObservableObject {
    @Published private(set) var snapshot = SuperNotchSystemSnapshot(
        cpuPercent: 0,
        memoryPercent: 0,
        diskPercent: 0
    )

    private var previousCPU: SuperNotchCPUTicks?

    init() {
        refresh()
    }

    func refresh() {
        let currentCPU = Self.readCPUTicks()
        let cpuPercent: Int

        if let currentCPU {
            if let previousCPU {
                let busyDelta = currentCPU.busy >= previousCPU.busy
                    ? currentCPU.busy - previousCPU.busy
                    : 0
                let totalDelta = currentCPU.total >= previousCPU.total
                    ? currentCPU.total - previousCPU.total
                    : 0
                cpuPercent = totalDelta > 0
                    ? min(100, Int((Double(busyDelta) / Double(totalDelta)) * 100))
                    : 0
            } else {
                cpuPercent = currentCPU.total > 0
                    ? min(100, Int((Double(currentCPU.busy) / Double(currentCPU.total)) * 100))
                    : 0
            }
            previousCPU = currentCPU
        } else {
            cpuPercent = 0
        }

        snapshot = SuperNotchSystemSnapshot(
            cpuPercent: cpuPercent,
            memoryPercent: Self.readMemoryPercent(),
            diskPercent: Self.readDiskPercent()
        )
    }

    private static func readCPUTicks() -> SuperNotchCPUTicks? {
        var load = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size
        )

        let result = withUnsafeMutablePointer(to: &load) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        return withUnsafePointer(to: &load.cpu_ticks) { pointer in
            pointer.withMemoryRebound(to: UInt32.self, capacity: Int(CPU_STATE_MAX)) { ticks in
                SuperNotchCPUTicks(
                    user: UInt64(ticks[Int(CPU_STATE_USER)]),
                    system: UInt64(ticks[Int(CPU_STATE_SYSTEM)]),
                    nice: UInt64(ticks[Int(CPU_STATE_NICE)]),
                    idle: UInt64(ticks[Int(CPU_STATE_IDLE)])
                )
            }
        }
    }

    private static func readMemoryPercent() -> Int {
        autoreleasepool {
            let total = ProcessInfo.processInfo.physicalMemory
            guard total > 0 else { return 0 }

            var pageSize: vm_size_t = 0
            guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return 0 }

            var stats = vm_statistics64()
            var count = mach_msg_type_number_t(
                MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
            )
            let result = withUnsafeMutablePointer(to: &stats) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
                }
            }
            guard result == KERN_SUCCESS else { return 0 }

            let usedPages = UInt64(stats.active_count + stats.wire_count + stats.compressor_page_count)
            let usedBytes = usedPages * UInt64(pageSize)
            return max(0, min(100, Int((Double(usedBytes) / Double(total)) * 100)))
        }
    }

    private static func readDiskPercent() -> Int {
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(
            forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]
        ), let total = values.volumeTotalCapacity,
           let available = values.volumeAvailableCapacity,
           total > 0 else {
            return 0
        }

        return max(0, min(100, Int((Double(total - available) / Double(total)) * 100)))
    }
}

enum SuperNotchQuickLink: String, CaseIterable, Identifiable {
    case github
    case aws
    case kubernetes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .github: return "GitHub"
        case .aws: return "AWS Console"
        case .kubernetes: return "Kubernetes Docs"
        }
    }

    var icon: String {
        switch self {
        case .github: return "chevron.left.forwardslash.chevron.right"
        case .aws: return "cloud"
        case .kubernetes: return "hexagon"
        }
    }

    var url: URL {
        switch self {
        case .github: return URL(string: "https://github.com")!
        case .aws: return URL(string: "https://console.aws.amazon.com")!
        case .kubernetes: return URL(string: "https://kubernetes.io/docs/")!
        }
    }
}
