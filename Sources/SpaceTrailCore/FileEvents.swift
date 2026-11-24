import CoreServices
import Darwin
import Foundation

struct EventBatch {
    struct Scope: OptionSet {
        let rawValue: UInt8
        static let recursive = Self(rawValue: 1 << 0)
        static let allocation = Self(rawValue: 1 << 1)
    }

    var paths: [String: Scope] = [:]
    var checkpoint: UInt64?
    var dropped = false
    var wrapped = false

    mutating func add(path: String, flags: FSEventStreamEventFlags, id: UInt64, root: String) {
        let wasWrapped = flags & UInt32(kFSEventStreamEventFlagEventIdsWrapped) != 0
        let mustRecover = flags & UInt32(kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped) != 0
        if wasWrapped {
            wrapped = true
            checkpoint = nil
        }
        if id != 0 { checkpoint = max(checkpoint ?? 0, id) }
        if wasWrapped || mustRecover || paths.count >= 65_536 {
            dropped = true
            paths = [root: .recursive]
        }
        guard !dropped else { return }

        let directoryChange = flags & UInt32(kFSEventStreamEventFlagItemIsDir) != 0
            && flags & UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRenamed) != 0
        let recursive = directoryChange
            || flags & UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged) != 0
        let allocationChange = flags & UInt32(kFSEventStreamEventFlagItemCloned | kFSEventStreamEventFlagItemModified
            | kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRenamed) != 0
        var scope = paths[path, default: []]
        if recursive { scope.insert(.recursive) }
        if allocationChange { scope.insert(.allocation) }
        paths[path] = scope
    }

    func forEachScope(_ visit: (String, Scope) throws -> Void) rethrows {
        entries: for path in paths.keys.sorted() {
            let scope = paths[path, default: []]
            if !scope.contains(.allocation) {
                var ancestor = parentPath(path)
                while let parent = ancestor {
                    if paths[parent]?.contains(.recursive) == true { continue entries }
                    ancestor = parentPath(parent)
                }
            }
            try visit(path, scope)
        }
    }
}

final class FileEvents {
    private let root: String
    private let base: String
    private let support: String
    private let queue = DispatchQueue(label: "io.spacetrail.fsevents", qos: .utility)
    private let lock = NSLock()
    private let notify: () -> Void
    private var pending = EventBatch()
    private var stream: FSEventStreamRef?

    init(root: String, mount: String, support: String, notify: @escaping () -> Void) {
        self.root = root
        self.base = isWithin(root, mount) ? mount : "/"
        self.support = SpaceTrailPaths.identityPath(support)
        self.notify = notify
    }

    deinit { stop() }

    static func journalID(device: dev_t) -> String? {
        FSEventsCopyUUIDForDevice(device).map { CFUUIDCreateString(nil, $0) as String }
    }

    static func currentCheckpoint() -> UInt64 {
        FSEventsGetCurrentEventId()
    }

    func start(device: dev_t, since: UInt64) throws {
        var context = FSEventStreamContext(version: 0,
                                           info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let prefix = base == "/" ? "" : base
        let relative = String(root.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        let callback: FSEventStreamCallback = { _, context, count, rawPaths, flags, ids in
            guard let context else { return }
            let watcher = Unmanaged<FileEvents>.fromOpaque(context).takeUnretainedValue()
            let paths = unsafeBitCast(rawPaths, to: NSArray.self)
            watcher.collect(paths: paths, count: count, flags: flags, ids: ids)
        }

        guard let stream = FSEventStreamCreateRelativeToDevice(nil, callback, &context, device,
                                                               [relative] as CFArray, since, 2, flags) else {
            throw FilesystemFailure(path: root, code: EIO)
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            throw FilesystemFailure(path: root, code: EIO)
        }
        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        queue.sync {}
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    func drain() -> EventBatch {
        lock.lock()
        defer { lock.unlock() }
        let result = pending
        pending = EventBatch()
        return result
    }

    private func collect(paths: NSArray, count: Int,
                         flags: UnsafePointer<FSEventStreamEventFlags>, ids: UnsafePointer<FSEventStreamEventId>) {
        lock.lock()
        var changed = false
        for index in 0..<count {
            let mask = flags[index]
            if mask & UInt32(kFSEventStreamEventFlagHistoryDone) != 0 { continue }
            let severe = mask & UInt32(kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
                | kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagRootChanged) != 0
            guard let rawPath = paths[index] as? String else { continue }
            let relative = rawPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let path = relative.isEmpty ? base : childPath(base, relative)
            let candidate = severe ? root : path
            guard isWithin(candidate, root),
                  !isWithin(SpaceTrailPaths.identityPath(candidate), support),
                  !isWithin(candidate, childPath(root, ".fseventsd")) else { continue }
            pending.add(path: candidate, flags: mask, id: ids[index], root: root)
            changed = true
        }
        lock.unlock()
        if changed { notify() }
    }
}
