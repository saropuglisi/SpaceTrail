import Foundation

public enum FileFormat: Hashable, Sendable {
    case all, pdf, epub, images, video, audio, documents, archives
    case custom(String)

    public init?(fileExtension: String) {
        guard let value = Self.normalizedExtension(fileExtension) else { return nil }
        self = .custom(value)
    }

    var extensions: [String] {
        switch self {
        case .all: return []
        case .pdf: return ["pdf"]
        case .epub: return ["epub"]
        case .images: return ["apng", "avif", "bmp", "dng", "gif", "heic", "heif", "jpeg", "jpg", "png", "psd", "raw", "svg", "tif", "tiff", "webp"]
        case .video: return ["avi", "m4v", "mkv", "mov", "mp4", "mpeg", "mpg", "webm"]
        case .audio: return ["aac", "aif", "aiff", "alac", "flac", "m4a", "mp3", "ogg", "opus", "wav"]
        case .documents: return ["csv", "doc", "docx", "key", "md", "numbers", "odt", "pages", "pdf", "ppt", "pptx", "rtf", "txt", "xls", "xlsx"]
        case .archives: return ["7z", "bz2", "gz", "rar", "tar", "xz", "zip", "zst"]
        case .custom(let value): return Self.normalizedExtension(value).map { [$0] } ?? []
        }
    }

    private static func normalizedExtension(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let value = trimmed.hasPrefix(".") ? String(trimmed.dropFirst()) : trimmed
        guard (1...24).contains(value.utf8.count),
              value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty }),
              value.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || [43, 45, 46, 95].contains($0) })
        else { return nil }
        return value
    }
}

struct FormatFilter {
    let predicate: String
    let values: [SQLValue]
    let indexedMatch: String?

    init?(_ format: FileFormat) {
        guard format != .all else { return nil }
        let extensions = format.extensions
        guard !extensions.isEmpty else {
            predicate = "0"
            values = []
            indexedMatch = nil
            return
        }
        let alternatives = Array(repeating: "e.name_key GLOB ?", count: extensions.count).joined(separator: " OR ")
        predicate = "(\(alternatives))"
        values = extensions.map { .text("*." + $0) }
        // Each suffix has a required ending trigram. The GLOB check verifies the exact extension.
        indexedMatch = extensions.contains(where: { $0.count == 1 }) ? nil :
            extensions.map { ftsTerm(String(("." + $0).suffix(3))) }.joined(separator: " OR ")
    }
}
