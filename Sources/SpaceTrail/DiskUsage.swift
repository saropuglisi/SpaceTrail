import SpaceTrailCore
import SwiftUI

enum DiskUsage {
    case allocated(Int64)
    case estimate(PhysicalFootprint, files: Int64)
    case verifying, protected, unavailable

    var text: String {
        switch self {
        case .allocated(let bytes): return StorageStyle.size(bytes)
        case .estimate(let result, _): return (result.incomplete ? "≥ " : "≈ ") + StorageStyle.size(result.bytes)
        case .verifying: return "Measuring…"
        case .protected: return "Protected"
        case .unavailable: return "Unavailable"
        }
    }

    var accessibleText: String {
        switch self {
        case .estimate(let result, _):
            return (result.incomplete ? "At least " : "About ") + StorageStyle.size(result.bytes)
        case .verifying: return "SpaceTrail is measuring disk usage in the background"
        case .protected: return "Folder protected by macOS"
        default: return text
        }
    }

    var explanation: String {
        switch self {
        case .allocated(let bytes):
            return "\(StorageStyle.exactSize(bytes)) allocated to this file, including any shared blocks."
        case .estimate(let result, let files):
            let bytes = StorageStyle.exactSize(result.bytes)
            if result.scannedFiles < files {
                return "At least \(bytes). Measured \(StorageStyle.count(result.scannedFiles)) of \(StorageStyle.count(files)) items."
            }
            return result.incomplete ? "At least \(bytes). Some blocks or paths could not be measured." : "About \(bytes)."
        case .verifying: return "SpaceTrail measures disk usage in the background, even after you close the app."
        case .protected: return "Access to this location is limited. You can still see the logical size of previously indexed items."
        case .unavailable: return "SpaceTrail has yet to measure this item."
        }
    }

    var bytes: Int64? {
        switch self {
        case .allocated(let bytes): return bytes
        case .estimate(let result, _): return result.bytes
        case .verifying, .protected, .unavailable: return nil
        }
    }

    var hasSize: Bool { bytes != nil }
}

struct DiskUsageLabel: View {
    let usage: DiskUsage

    var body: some View {
        Text(usage.text)
            .monospacedDigit()
            .foregroundStyle(usage.hasSize ? Color.primary : Color.secondary)
            .lineLimit(1)
            .accessibilityLabel(usage.accessibleText)
            .help(usage.explanation)
    }
}
