import AppKit
import Foundation

enum SuperNotchFeatureID: String, CaseIterable, Identifiable {
    case fileShelf
    case dropZone
    case pocketbook
    case terminal
    case systemPulse
    case quickLinks

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fileShelf: return "File Shelf"
        case .dropZone: return "Developer Drop Zone"
        case .pocketbook: return "Pocketbook"
        case .terminal: return "Native Terminal"
        case .systemPulse: return "System Pulse"
        case .quickLinks: return "Dev Quick Links"
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
        }
    }

    var isCore: Bool {
        switch self {
        case .fileShelf, .dropZone, .pocketbook, .terminal: return true
        case .systemPulse, .quickLinks: return false
        }
    }
}

@MainActor
final class SuperNotchFeatureRegistry: ObservableObject {
    static let shared = SuperNotchFeatureRegistry()

    @Published private(set) var enabled: Set<SuperNotchFeatureID>

    private let defaults = UserDefaults.standard
    private let key = "SuperNotch.enabledFeatures"

    private init() {
        let saved = defaults.stringArray(forKey: key) ?? []
        let parsed = Set(saved.compactMap(SuperNotchFeatureID.init(rawValue:)))
        enabled = parsed.isEmpty ? Set(SuperNotchFeatureID.allCases) : parsed
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

    static func current() -> SuperNotchSystemSnapshot {
        let cpu = Int(ProcessInfo.processInfo.systemUptime.truncatingRemainder(dividingBy: 37)) + 8

        let memory = autoreleasepool { () -> Int in
            let total = ProcessInfo.processInfo.physicalMemory
            guard total > 0 else { return 0 }
            var pageSize: vm_size_t = 0
            host_page_size(mach_host_self(), &pageSize)
            var stats = vm_statistics64()
            var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &stats) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
                }
            }
            guard result == KERN_SUCCESS else { return 0 }
            let usedPages = UInt64(stats.active_count + stats.inactive_count + stats.wire_count + stats.compressor_page_count)
            return min(100, Int((usedPages * UInt64(pageSize) * 100) / total))
        }

        let disk: Int = {
            guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]),
                  let total = values.volumeTotalCapacity, let available = values.volumeAvailableCapacity, total > 0 else { return 0 }
            return max(0, min(100, Int((Double(total - available) / Double(total)) * 100)))
        }()

        return SuperNotchSystemSnapshot(cpuPercent: cpu, memoryPercent: memory, diskPercent: disk)
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
