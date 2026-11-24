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
        case .verifying: return "In verifica"
        case .protected: return "Protetta"
        case .unavailable: return "Non disponibile"
        }
    }

    var accessibleText: String {
        switch self {
        case .estimate(let result, _):
            return (result.incomplete ? "Almeno " : "Circa ") + StorageStyle.size(result.bytes)
        case .verifying: return "SpaceTrail sta verificando lo spazio in background"
        case .protected: return "Cartella protetta da macOS"
        default: return text
        }
    }

    var explanation: String {
        switch self {
        case .allocated(let bytes):
            return "\(StorageStyle.exactSize(bytes)) allocati al file, inclusi eventuali blocchi condivisi."
        case .estimate(let result, let files):
            let bytes = StorageStyle.exactSize(result.bytes)
            if result.scannedFiles < files {
                return "Almeno \(bytes). Verificati \(result.scannedFiles.formatted()) di \(files.formatted()) elementi."
            }
            return result.incomplete ? "Almeno \(bytes). Alcuni blocchi o percorsi non sono misurabili." : "Circa \(bytes)."
        case .verifying: return "SpaceTrail verifica lo spazio in background, anche ad app chiusa."
        case .protected: return "L’accesso al percorso è limitato. La dimensione logica resta visibile per gli elementi già indicizzati."
        case .unavailable: return "SpaceTrail non dispone ancora di una misura utilizzabile."
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
