import AppKit
import AVFoundation
import Darwin
import ImageIO
import QuickLookThumbnailing
import SpaceTrailCore
import SwiftUI
import UniformTypeIdentifiers

extension StorageEntry {
    var browserSymbol: String {
        switch kind {
        case .directory: return "folder.fill"
        case .file:
            if isEPUB { return "book.closed" }
            guard let type = contentType else { return "doc" }
            if type.conforms(to: .image) { return "photo" }
            if type.conforms(to: .movie) { return "film" }
            if type.conforms(to: .audio) { return "music.note" }
            if type.conforms(to: .pdf) || type.conforms(to: .text) { return "doc.text" }
            if type.conforms(to: .archive) { return "archivebox" }
            return "doc"
        case .symbolicLink: return "arrowshape.turn.up.right"
        case .other: return "doc.questionmark"
        }
    }

    var previewURL: URL? {
        kind == .file ? URL(fileURLWithPath: id.path) : nil
    }

    var contentType: UTType? {
        guard let suffix = previewURL?.pathExtension, !suffix.isEmpty else { return nil }
        return UTType(filenameExtension: suffix)
    }

    var isEPUB: Bool { previewURL?.pathExtension.caseInsensitiveCompare("epub") == .orderedSame }

    var hasThumbnail: Bool {
        guard let url = previewURL else { return false }
        let suffix = url.pathExtension.lowercased()
        if ["epub", "pdf", "doc", "docx", "odt", "pages", "ppt", "pptx", "key", "xls", "xlsx", "numbers"].contains(suffix) {
            return true
        }
        guard let type = contentType else { return false }
        return type.conforms(to: .image) || type.conforms(to: .text) || type.conforms(to: .movie) || type.conforms(to: .audio)
    }
}

struct FileThumbnail: View {
    enum Size: Equatable, Sendable {
        case row, cover

        var points: CGSize {
            switch self {
            case .row: return CGSize(width: 34, height: 30)
            case .cover: return CGSize(width: 200, height: 114)
            }
        }

        var iconSize: CGFloat { self == .row ? 16 : 34 }
    }

    let entry: StorageEntry
    let size: Size
    let source: URL?
    var loadsAutomatically = true
    var preparedImage: CGImage?

    @Environment(\.displayScale) private var displayScale
    @State private var loaded: (key: String, image: CGImage)?

    private var scale: CGFloat { min(2, max(1, displayScale)) }

    private var key: String {
        ThumbnailResources.key(for: entry, size: size, scale: scale) + "-\(source?.path ?? "")"
    }

    @ViewBuilder
    var body: some View {
        if loadsAutomatically {
            thumbnail.task(id: key) { await load(key: key) }.onDisappear { loaded = nil }
        } else {
            thumbnail
        }
    }

    private var thumbnail: some View {
        Group {
            if source != nil, let bitmap = preparedImage ?? (loaded?.key == key ? loaded?.image : nil) {
                Image(bitmap, scale: scale, label: Text("Preview available"))
                    .resizable()
                    .scaledToFit()
                    .accessibilityLabel("Preview available")
            } else {
                let locked = entry.hasThumbnail && source == nil
                Image(systemName: entry.browserSymbol)
                    .font(.system(size: size.iconSize, weight: .medium))
                    .foregroundStyle(entry.isFolder ? StorageStyle.accent : Color.secondary)
                    .overlay(alignment: .bottomTrailing) {
                        if locked {
                            Image(systemName: "lock.fill")
                                .font(.system(size: size == .row ? 8 : 12, weight: .semibold))
                                .offset(x: 5, y: 3)
                                .accessibilityHidden(true)
                        }
                    }
                    .accessibilityLabel("Preview protected by macOS")
                    .accessibilityHidden(!locked)
            }
        }
    }

    @MainActor
    private func load(key: String) async {
        guard let source, entry.hasThumbnail, !Task.isCancelled else { return }
        do { try await Task.sleep(for: .milliseconds(80)) }
        catch { return }
        let image = await ThumbnailResources.shared.image(for: entry, at: source, size: size, scale: scale,
                                                          deadline: .now + .seconds(2))
        if let image, !Task.isCancelled {
            loaded = (key, image)
        }
    }
}

@MainActor
final class ThumbnailResources {
    static let shared = ThumbnailResources()
    private let cache = NSCache<NSString, CGImage>()
    private let imageDecoding = DispatchQueue(label: "io.spacetrail.preview.images", qos: .utility)

    private struct PendingRequest {
        let cancel: () -> Void
        let continuation: CheckedContinuation<CGImage?, Never>
        let timeout: Task<Void, Never>
    }

    private var active = 0
    private var waiters: [(UUID, CheckedContinuation<Bool, Never>)] = []
    private var requests: [UUID: PendingRequest] = [:]
    private let pressure: DispatchSourceMemoryPressure

    private init() {
        cache.countLimit = 72
        cache.totalCostLimit = 8 * 1_024 * 1_024
        pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        pressure.setEventHandler { [weak self] in
            Task { @MainActor in self?.cache.removeAllObjects() }
        }
        pressure.activate()
    }

    nonisolated static func key(for entry: StorageEntry, size: FileThumbnail.Size, scale: CGFloat) -> String {
        "\(entry.id.path)\u{1f}\(entry.inode)-\(entry.modified.timeIntervalSince1970)-\(entry.logical)-\(size.points.width)-\(scale)"
    }

    func clear() {
        cache.removeAllObjects()
    }

    func prepare(_ entries: [(StorageEntry, URL)], size: FileThumbnail.Size, scale: CGFloat) async -> [EntryKey: CGImage] {
        let workers = min(entries.count, ProcessInfo.processInfo.isLowPowerModeEnabled ? 2 : 3)
        guard workers > 0 else { return [:] }
        return await withTaskGroup(of: (EntryKey, CGImage?).self) { group in
            var queue = entries.makeIterator()
            func enqueue() {
                guard let (entry, url) = queue.next() else { return }
                group.addTask { [self] in
                    (entry.id, await image(for: entry, at: url, size: size, scale: scale, deadline: .now + .seconds(2)))
                }
            }
            for _ in 0..<workers { enqueue() }
            var images: [EntryKey: CGImage] = [:]
            while let (key, image) = await group.next() {
                if let image { images[key] = image }
                guard !Task.isCancelled else {
                    group.cancelAll()
                    break
                }
                enqueue()
            }
            return images
        }
    }

    func image(for entry: StorageEntry, at url: URL, size: FileThumbnail.Size, scale: CGFloat,
               deadline: ContinuousClock.Instant) async -> CGImage? {
        let key = Self.key(for: entry, size: size, scale: scale) as NSString
        if let image = cache.object(forKey: key) { return image }
        guard ContinuousClock.now < deadline, !Task.isCancelled, await acquire() else { return nil }
        defer { release() }
        if let image = cache.object(forKey: key) { return image }
        guard ContinuousClock.now < deadline, !Task.isCancelled else { return nil }
        let local = await Task.detached(priority: .utility) {
            var info = stat()
            return lstat(url.path, &info) == 0 && info.st_ino == UInt64(bitPattern: entry.inode) &&
                info.st_mode & S_IFMT == S_IFREG &&
                info.st_flags & UInt32(SF_DATALESS) == 0
        }.value
        guard local, ContinuousClock.now < deadline, !Task.isCancelled else { return nil }
        let image = await render(entry, at: url, size: size, scale: scale,
                                 deadline: min(deadline, .now + .milliseconds(1_450)))
        if let image {
            cache.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
        }
        return image
    }

    private func render(_ entry: StorageEntry, at url: URL, size: FileThumbnail.Size, scale: CGFloat,
                        deadline: ContinuousClock.Instant) async -> CGImage? {
        let pixels = CGSize(width: size.points.width * scale, height: size.points.height * scale)
        let maxPixelSize = Int(max(pixels.width, pixels.height))
        if entry.isEPUB {
            return await decode(until: min(deadline, .now + .milliseconds(1_100))) { progress in
                EPUBCover.thumbnail(at: url, maxPixelSize: maxPixelSize, progress: progress)
            }
        }
        if let type = entry.contentType, type.conforms(to: .pdf) || type.conforms(to: .image) {
            if let image = await decode(until: min(deadline, .now + .milliseconds(800)), work: { _ in
                guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
                else { return nil }
                let page = type.conforms(to: .heic) ? CGImageSourceGetPrimaryImageIndex(source) : 0
                return CGImageSourceCreateThumbnailAtIndex(source, page, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
                ] as CFDictionary)
            }) { return image }
        }
        // Restrict video decoding to local container formats with AVFoundation support.
        if ["mp4", "mov", "m4v", "3gp", "3g2", "mpeg", "mpg"].contains(url.pathExtension.lowercased()) {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = pixels
            if let frame = await generate(deadline: min(deadline, .now + .milliseconds(800)), start: { complete in
                generator.generateCGImageAsynchronously(for: .zero) { image, _, _ in complete(image) }
                return { generator.cancelAllCGImageGeneration() }
            }) { return frame }
        } else if entry.contentType?.conforms(to: .audio) == true {
            if let cover = await generate(deadline: min(deadline, .now + .milliseconds(750)), start: { complete in
                let work = Task.detached(priority: .utility) {
                    let metadata = try? await AVURLAsset(url: url).load(.commonMetadata)
                    let artwork = AVMetadataItem.metadataItems(from: metadata ?? [], withKey: AVMetadataKey.commonKeyArtwork,
                                                               keySpace: .common).first
                    guard let data = try? await artwork?.load(.dataValue), data.count <= 8 * 1_024 * 1_024,
                          !Task.isCancelled, let source = CGImageSourceCreateWithData(data as CFData, nil)
                    else { complete(nil); return }
                    complete(CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: Int(max(pixels.width, pixels.height))
                    ] as CFDictionary))
                }
                return { work.cancel() }
            }) { return cover }
        }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: size.points, scale: scale,
                                                    representationTypes: [.thumbnail, .lowQualityThumbnail])
        return await generate(deadline: deadline) { complete in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { image, _ in complete(image?.cgImage) }
            return { QLThumbnailGenerator.shared.cancel(request) }
        }
    }

    private func decode(until deadline: ContinuousClock.Instant, work: @escaping @Sendable (Progress) -> CGImage?) async -> CGImage? {
        await generate(deadline: deadline) { complete in
            let progress = Progress()
            let item = DispatchWorkItem {
                if !progress.isCancelled { complete(work(progress)) }
            }
            imageDecoding.async(execute: item)
            return {
                progress.cancel()
                item.cancel()
            }
        }
    }

    private func generate(deadline: ContinuousClock.Instant,
                          start: (@escaping @Sendable (CGImage?) -> Void) -> (() -> Void)) async -> CGImage? {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, ContinuousClock.now < deadline else {
                    continuation.resume(returning: nil)
                    return
                }
                let timeout = Task { [weak self] in
                    do { try await Task.sleep(until: deadline, clock: .continuous) }
                    catch { return }
                    self?.finish(id, image: nil, cancel: true)
                }
                let cancel = start { [weak self] image in
                    Task { @MainActor in self?.finish(id, image: image, cancel: false) }
                }
                requests[id] = PendingRequest(cancel: cancel, continuation: continuation, timeout: timeout)
            }
        } onCancel: {
            Task { @MainActor in self.finish(id, image: nil, cancel: true) }
        }
    }

    private func finish(_ id: UUID, image: CGImage?, cancel: Bool) {
        guard let pending = requests.removeValue(forKey: id) else { return }
        pending.timeout.cancel()
        if cancel { pending.cancel() }
        pending.continuation.resume(returning: image)
    }

    private func acquire() async -> Bool {
        guard !Task.isCancelled else { return false }
        if active < 3 {
            active += 1
            return true
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning: false) }
                else { waiters.append((id, continuation)) }
            }
        } onCancel: {
            Task { @MainActor in
                if let index = self.waiters.firstIndex(where: { $0.0 == id }) {
                    self.waiters.remove(at: index).1.resume(returning: false)
                }
            }
        }
    }

    private func release() {
        if waiters.isEmpty { active -= 1 }
        else { waiters.removeFirst().1.resume(returning: true) }
    }
}
