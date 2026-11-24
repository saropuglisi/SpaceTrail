import Darwin
import Foundation

public struct PhysicalFootprint: Equatable, Sendable {
    public let exclusiveBytes: Int64
    public let sharedBytes: Int64
    public let scannedFiles: Int64
    public let incomplete: Bool

    public var bytes: Int64 { exclusiveBytes + sharedBytes }
}

struct FileFootprint: Equatable {
    var exclusive: Int64 = 0
    var shared: Int64 = 0
    var identity: String?
    var incomplete = false

    init() {}

    init(exclusive: Int64, shared: Int64, identity: String?, incomplete: Bool) {
        self.exclusive = exclusive
        self.shared = shared
        self.identity = identity
        self.incomplete = incomplete
    }

    static var unavailable: Self { Self(exclusive: 0, shared: 0, identity: nil, incomplete: true) }

    init(path: String, info: stat) {
        let allocated = max(0, info.st_blocks) * 512
        guard allocated > 0 else { return }
        guard info.st_mode & S_IFMT == S_IFREG else {
            exclusive = allocated
            return
        }
        guard let attributes = APFSAttributes.read(at: path) else {
            incomplete = true
            return
        }
        let device = attributes.device ?? info.st_dev
        if attributes.sharesAllBlocks, let clone = attributes.cloneID, clone != 0,
           (attributes.cloneReferences ?? 2) > 1 {
            identity = "\(device):clone:\(clone)"
            shared = allocated
            return
        }
        guard let privateBytes = attributes.privateBytes else {
            incomplete = true
            return
        }
        let bytes = max(0, privateBytes)
        if info.st_nlink > 1 {
            identity = "\(device):inode:\(info.st_ino)"
            shared = bytes
        } else {
            exclusive = bytes
            if let clone = attributes.cloneID, clone != 0, clone != info.st_ino {
                // Keep the family of a former clone so a new peer can find it again.
                identity = "\(device):clone:\(clone)"
            }
        }
        // APFS can report private extents without identifying all partially shared peers.
        incomplete = bytes < allocated
    }
}
