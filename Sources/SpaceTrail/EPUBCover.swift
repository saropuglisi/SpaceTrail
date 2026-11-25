import Foundation
import ImageIO
import ZIPFoundation

enum EPUBCover {
    private static let xmlLimit = 512 * 1_024
    private static let imageLimit = 12 * 1_024 * 1_024

    static func thumbnail(at url: URL, maxPixelSize: Int, progress: Progress) -> CGImage? {
        guard !progress.isCancelled, let archive = try? Archive(url: url, accessMode: .read, pathEncoding: nil),
              let container = read("META-INF/container.xml", in: archive, limit: xmlLimit, progress: progress) else { return nil }
        var package: String?
        guard elements(in: container, visit: { name, attributes in
            if name == "rootfile", package == nil {
                package = attributes["full-path"].flatMap { memberPath($0) }
            }
        }), let package, let metadata = read(package, in: archive, limit: xmlLimit, progress: progress) else { return nil }

        var manifest: [String: String] = [:]
        var coverImage: String?
        var legacyCoverID: String?
        var coverPage: String?
        var namedCover: String?
        guard elements(in: metadata, visit: { name, attributes in
            if name == "item", let id = attributes["id"], let href = attributes["href"] {
                manifest[id] = href
                if attributes["properties"]?.split(whereSeparator: \.isWhitespace).contains("cover-image") == true {
                    coverImage = coverImage ?? href
                }
                let stem = (href as NSString).deletingPathExtension
                if attributes["media-type"]?.hasPrefix("image/") == true,
                   (stem as NSString).lastPathComponent.lowercased() == "cover" {
                    namedCover = namedCover ?? href
                }
            } else if name == "meta", attributes["name"]?.lowercased() == "cover" {
                legacyCoverID = attributes["content"]
            } else if name == "reference", attributes["type"] == "cover" {
                coverPage = attributes["href"]
            }
        }) else { return nil }

        var tried = Set<String>()
        for reference in [coverImage, legacyCoverID.flatMap { manifest[$0] }, coverPage, namedCover].compactMap({ $0 }) {
            guard !progress.isCancelled else { return nil }
            guard let path = memberPath(reference, relativeTo: package), tried.insert(path).inserted else { continue }
            if let image = cover(at: path, in: archive, maxPixelSize: maxPixelSize, progress: progress) { return image }
        }
        return nil
    }

    private static func cover(at path: String, in archive: Archive, maxPixelSize: Int, progress: Progress) -> CGImage? {
        let suffix = (path as NSString).pathExtension.lowercased()
        let imagePath: String
        if ["xhtml", "html", "htm", "svg"].contains(suffix) {
            guard let wrapper = read(path, in: archive, limit: xmlLimit, progress: progress) else { return nil }
            var embedded: String?
            guard elements(in: wrapper, visit: { name, attributes in
                guard embedded == nil else { return }
                let reference = name == "img" ? attributes["src"]
                    : name == "image" ? attributes["href"] ?? attributes["xlink:href"] : nil
                embedded = reference.flatMap { memberPath($0, relativeTo: path) }
            }), let embedded else { return nil }
            imagePath = embedded
        } else {
            imagePath = path
        }
        guard let image = read(imagePath, in: archive, limit: imageLimit, progress: progress),
              !progress.isCancelled,
              let source = CGImageSourceCreateWithData(image as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as CFDictionary)
    }

    private static func memberPath(_ reference: String, relativeTo document: String = "") -> String? {
        guard let url = URLComponents(string: reference), url.scheme == nil, url.host == nil,
              !url.path.isEmpty, !url.path.hasPrefix("/"), !url.path.contains("\\"), !url.path.contains("\0") else { return nil }
        var parts = Array(document.split(separator: "/").dropLast())
        for part in url.path.split(separator: "/") {
            if part == ".." {
                guard !parts.isEmpty else { return nil }
                parts.removeLast()
            } else if part != "." {
                parts.append(part)
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "/")
    }

    private static func read(_ path: String, in archive: Archive, limit: Int, progress: Progress) -> Data? {
        guard !progress.isCancelled, let entry = archive[path], entry.type == .file,
              entry.uncompressedSize <= UInt64(limit), entry.compressedSize <= UInt64(limit) else { return nil }
        var data = Data()
        do {
            let checksum = try archive.extract(entry, progress: progress) { chunk in
                guard !progress.isCancelled, chunk.count <= limit - data.count else { throw CocoaError(.fileReadCorruptFile) }
                data.append(chunk)
            }
            return checksum == entry.checksum && UInt64(data.count) == entry.uncompressedSize ? data : nil
        } catch {
            return nil
        }
    }

    private static func elements(in data: Data, visit: @escaping (String, [String: String]) -> Void) -> Bool {
        let parser = XMLParser(data: data)
        let delegate = ElementReader(visit: visit)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.delegate = delegate
        return withExtendedLifetime(delegate) { parser.parse() }
    }

    private final class ElementReader: NSObject, XMLParserDelegate {
        let visit: (String, [String: String]) -> Void

        init(visit: @escaping (String, [String: String]) -> Void) {
            self.visit = visit
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String]) {
            visit(elementName, attributes)
        }

        func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
            parser.abortParsing()
        }
    }
}
