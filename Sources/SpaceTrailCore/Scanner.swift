import Darwin
import Foundation

struct FilesystemFailure: LocalizedError {
    let path: String
    let code: Int32

    var errorDescription: String? {
        "\(SpaceTrailPaths.displayPath(path)) · \(String(cString: strerror(code)))"
    }

    var disappeared: Bool { code == ENOENT || code == ENOTDIR }
    var denied: Bool { code == EACCES || code == EPERM }
}

func diskStat(_ path: String) throws -> stat {
    var info = stat()
    guard lstat(path, &info) == 0 else { throw FilesystemFailure(path: path, code: errno) }
    return info
}

func mountInfo(_ path: String) throws -> (mount: String, capacity: Int64, available: Int64, entries: Int64) {
    var info = statfs()
    guard statfs(path, &info) == 0 else { throw FilesystemFailure(path: path, code: errno) }
    let mount = withUnsafeBytes(of: info.f_mntonname) { buffer in
        String(cString: buffer.bindMemory(to: CChar.self).baseAddress!)
    }
    let blockSize = Int64(info.f_bsize)
    return (mount, Int64(info.f_blocks) * blockSize, Int64(info.f_bavail) * blockSize, Int64(info.f_files) - Int64(info.f_ffree))
}

private func isDirectory(_ info: stat) -> Bool {
    info.st_mode & S_IFMT == S_IFDIR
}

func fileDate(_ time: timespec) -> Date {
    Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000)
}

enum RepairMode: Int64 {
    case shallow = -1
    case walk = 0
    case remove = 1
}

final class FileScanner {
    private let index: IndexWriter
    private let support: String
    private let devices: [VolumeTree: dev_t]
    private let systemDevice: dev_t?
    private let access: DiskAccess
    private let progress: (Int64) -> Void
    private(set) var processed: Int64 = 0
    private var reportedAt: UInt64 = 0

    init(index: IndexWriter, support: URL, devices: [VolumeTree: dev_t], access: DiskAccess,
         progress: @escaping (Int64) -> Void) {
        self.index = index
        self.support = SpaceTrailPaths.identityPath(support.path)
        self.devices = devices
        self.systemDevice = devices[.system] == nil ? nil : APFSAttributes.read(at: "/", deviceOnly: true)?.device
        self.access = access
        self.progress = progress
    }

    func resetProgress() {
        processed = 0
        reportedAt = 0
    }

    func footprint(for key: EntryKey, inode: Int64) -> FileFootprint {
        guard access.includes(key), !StartupVolumeLayout.isSystemAlias(key),
              !isWithin(SpaceTrailPaths.identityPath(key.path), support),
              let info = try? diskStat(key.path), Int64(bitPattern: info.st_ino) == inode,
              !isDirectory(info), belongsToTree(key, info: info) else { return .unavailable }
        return FileFootprint(path: key.path, info: info)
    }

    private func excludes(_ key: EntryKey) throws -> Bool {
        if isWithin(SpaceTrailPaths.identityPath(key.path), support)
            || isWithin(key.path, childPath(key.tree.root, ".fseventsd"))
            || StartupVolumeLayout.isSystemAlias(key) {
            return true
        }
        if let excluded = access.excludedScope(for: key) {
            try index.rememberLimited(excluded)
            return true
        }
        return false
    }

    private func belongsToTree(_ key: EntryKey, info: stat) -> Bool {
        guard info.st_dev == devices[key.tree] else { return false }
        if key.tree == .system, let systemDevice, let actual = APFSAttributes.read(at: key.path, deviceOnly: true)?.device {
            return actual == systemDevice
        }
        return true
    }

    /// The queue and ancestor totals remain consistent at each commit. An interrupted directory
    /// stays in the queue; only its direct children are revisited on restart.
    func buildInitial(from checkpoint: Int64) throws {
        processed = checkpoint
        var sinceCommit: Int64 = 0
        try index.db.transaction("BEGIN IMMEDIATE") {
            while let key = try index.nextInitial() {
                let before = processed
                try readInitialDirectory(key) {
                    sinceCommit = 0
                    try index.set("initialCount", String(before))
                    try index.finishBatch()
                }
                sinceCommit += max(1, processed - before)
                if sinceCommit >= 8_192 {
                    try index.set("initialCount", String(processed))
                    try index.finishBatch()
                    sinceCommit = 0
                }
            }
            try index.set("initialCount", String(processed))
        }
    }

    private func readInitialDirectory(_ key: EntryKey, checkpoint: () throws -> Void) throws {
        try index.db.run("DELETE FROM seen")
        if try excludes(key) {
            try pruneInitialChildren(of: key)
            try index.finishInitialDirectory(key)
            return
        }
        let info: stat
        do {
            info = try diskStat(key.path)
        } catch let error as FilesystemFailure where error.disappeared || error.denied {
            if error.denied { try index.markGap(key) }
            try pruneInitialChildren(of: key)
            try index.finishInitialDirectory(key)
            return
        }
        guard belongsToTree(key, info: info), isDirectory(info) else {
            try pruneInitialChildren(of: key)
            if belongsToTree(key, info: info) {
                let entry = makeEntry(key, info: info, contents: Totals())
                let previous = try index.entry(key)?.totals ?? Totals()
                try index.insert(entry)
                try index.adjustAncestors(of: key, by: entry.totals - previous)
            }
            try index.finishInitialDirectory(key)
            return
        }

        var visited = 0
        do {
            let complete = try withChildren(of: key.path, info: info) { name in
                let child = EntryKey(tree: key.tree, path: childPath(key.path, name))
                guard try !excludes(child) else { return }
                let metadata: stat
                do {
                    metadata = try diskStat(child.path)
                } catch let error as FilesystemFailure where error.disappeared || error.denied {
                    if error.denied { try index.markGap(child) }
                    return
                }
                guard belongsToTree(child, info: metadata) else { return }
                if isDirectory(metadata) {
                    try index.queueInitial(child)
                } else {
                    try index.finishInitialDirectory(child)
                    try index.db.run("INSERT OR IGNORE INTO seen VALUES (?)", [.text(child.path)])
                    try index.insert(makeEntry(child, info: metadata, contents: Totals()))
                }
                countProgress()
                visited += 1
                if visited.isMultiple(of: 8_192) { try checkpoint() }
            }
            if !complete { try index.markGap(key) }
        } catch let error as FilesystemFailure where error.path == key.path && (error.denied || error.disappeared) {
            if error.denied { try index.markGap(key) }
        }
        try pruneInitialChildren(of: key)
        let totals = try index.directTotals(key)
        try index.insert(makeEntry(key, info: info, contents: totals))
        try index.adjustAncestors(of: key, by: totals)
        try index.finishInitialDirectory(key)
    }

    private func pruneInitialChildren(of key: EntryKey) throws {
        // Partial rows from a previous run were never added to the ancestors' totals.
        while true {
            let missing = try index.missingChildren(key)
            guard !missing.isEmpty else { return }
            for path in missing {
                try index.db.run("DELETE FROM entries WHERE tree = ? AND path = ?",
                                 EntryKey(tree: key.tree, path: path).values)
            }
        }
    }

    private func countProgress() {
        processed += 1
        if processed.isMultiple(of: 512) {
            let now = DispatchTime.now().uptimeNanoseconds
            if now - reportedAt > 1_000_000_000 {
                reportedAt = now
                progress(processed)
            }
        }
    }

    @discardableResult
    func refresh(_ requested: EntryKey, recursive: Bool = false, refreshAllocation: Bool = false) throws -> Bool {
        guard try !excludes(requested) else { return false }
        let root = requested.tree.root
        var key = requested
        if requested.path != root {
            var current = parentPath(requested.path)
            while let path = current, path != root {
                let parent = EntryKey(tree: key.tree, path: path)
                if try index.entry(parent)?.isFolder == true { break }
                key = parent
                current = parentPath(path)
            }
        }
        return try refreshNode(key, recursive: recursive, refreshAllocation: refreshAllocation)
    }

    @discardableResult
    func refreshPeer(_ key: EntryKey) throws -> Bool {
        guard try !excludes(key) else { return false }
        return try refreshNode(key, recursive: false, refreshAllocation: true, trackPeers: false)
    }

    @discardableResult
    private func refreshNode(_ key: EntryKey, recursive: Bool, refreshAllocation: Bool = false,
                             trackPeers: Bool = true) throws -> Bool {
        let previous = try index.entry(key)
        let info: stat
        do {
            info = try diskStat(key.path)
        } catch let error as FilesystemFailure where error.disappeared {
            if key.path == key.tree.root { throw error }
            try forget(key, previous: previous, trackPeers: trackPeers)
            return previous != nil
        } catch let error as FilesystemFailure where error.denied {
            try index.markGap(key)
            if let previous, !previous.isFolder {
                try index.footprints.update(key, footprint: .unavailable, trackPeers: trackPeers)
            }
            return true
        }

        guard belongsToTree(key, info: info) else {
            try forget(key, previous: previous, trackPeers: trackPeers)
            return previous != nil
        }
        if previous?.isFolder == true, !isDirectory(info) {
            try index.scheduleRepair(key, mode: .remove)
            return true
        }

        let contents = previous.flatMap { $0.isFolder ? $0.totals : nil } ?? Totals()
        let candidate = makeEntry(key, info: info, contents: contents)
        let accessRestored = candidate.isFolder ? false : try index.clearGap(key)
        let needsWalk = candidate.isFolder && (recursive || previous?.isFolder != true
                                               || previous?.inode != candidate.inode || previous?.mode != candidate.mode)
        if needsWalk { try index.scheduleRepair(key) }
        let metadataChanged = candidate != previous
        if metadataChanged {
            if candidate.isFolder { try index.forgetFootprint(key, trackPeers: trackPeers) }
            try index.insert(candidate)
            try index.adjustAncestors(of: key, by: candidate.totals - (previous?.totals ?? Totals()))
        }
        let allocationChanged = candidate.kind != previous?.kind || candidate.inode != previous?.inode
            || candidate.allocated != previous?.allocated || candidate.logical != previous?.logical
            || candidate.links != previous?.links || candidate.created != previous?.created
        if !candidate.isFolder, allocationChanged || refreshAllocation || accessRestored {
            let footprintChanged = try index.footprints.update(
                key, footprint: FileFootprint(path: key.path, info: info), trackPeers: trackPeers
            )
            return metadataChanged || footprintChanged || accessRestored
        }
        return metadataChanged || needsWalk
    }

    func audit(_ key: EntryKey, recursive: Bool = false, verifyAllocation: Bool = false) throws {
        guard try !excludes(key) else { return }
        if try index.entry(key)?.isFolder != true {
            try refresh(key)
            if try index.entry(key)?.isFolder != true { return }
        }

        let info: stat
        do {
            info = try diskStat(key.path)
            guard belongsToTree(key, info: info), isDirectory(info) else {
                try refreshNode(key, recursive: false)
                return
            }
        } catch let error as FilesystemFailure where error.disappeared || error.denied {
            try refreshNode(key, recursive: false)
            return
        }

        // Rechecking the direct children is small enough to checkpoint, even for wide folders.
        try index.db.run("DELETE FROM seen")
        var visited = 0
        do {
            let complete = try withChildren(of: key.path, info: info) { name in
                let child = EntryKey(tree: key.tree, path: childPath(key.path, name))
                try index.db.run("INSERT OR IGNORE INTO seen VALUES (?)", [.text(child.path)])
                if try !excludes(child) {
                    try refreshNode(child, recursive: recursive, refreshAllocation: verifyAllocation)
                }
                countProgress()
                visited += 1
                if visited.isMultiple(of: 4_096) { try index.finishBatch() }
            }
            guard complete else {
                try index.markGap(key)
                return
            }
        } catch let error as FilesystemFailure where error.path == key.path && (error.denied || error.disappeared) {
            try refreshNode(key, recursive: false)
            if error.denied { try index.markGap(key) }
            return
        }
        try index.clearGap(key)
        while true {
            let missing = try index.missingChildren(key)
            guard !missing.isEmpty else { break }
            for path in missing {
                let child = EntryKey(tree: key.tree, path: path)
                try forget(child, previous: index.entry(child))
                try index.db.run("INSERT OR IGNORE INTO seen VALUES (?)", [.text(path)])
            }
            visited += missing.count
            if visited >= 4_096 {
                try index.finishBatch()
                visited = 0
            }
        }
        if let previous = try index.entry(key) {
            try index.insert(makeEntry(key, info: info, contents: previous.totals))
        }
    }

    private func forget(_ key: EntryKey, previous: StorageEntry?, trackPeers: Bool = true) throws {
        if previous?.isFolder == true {
            try index.scheduleRepair(key, mode: .remove)
        } else {
            if let previous {
                try index.deleteEntry(key, trackPeers: trackPeers)
                try index.adjustAncestors(of: key, by: Totals() - previous.totals)
            }
            try index.clearGap(key)
        }
    }

    func repair(_ key: EntryKey, mode: RepairMode) throws {
        if try excludes(key) {
            try index.completeRepair(key, mode: mode)
            return
        }
        switch mode {
        case .shallow:
            try audit(key)
            try index.completeRepair(key, mode: .shallow)
        case .walk:
            try audit(key, recursive: true, verifyAllocation: true)
            try index.completeRepair(key, mode: .walk)
        case .remove:
            try index.prune(key)
            try index.completeRepair(key, mode: .remove)
            // A replaced item or a path recreated during an interruption still needs indexing.
            try refresh(key)
        }
    }

    private func makeEntry(_ key: EntryKey, info: stat, contents: Totals) -> StorageEntry {
        let root = key.path == key.tree.root
        let kind: EntryKind
        switch info.st_mode & S_IFMT {
        case S_IFDIR: kind = .directory
        case S_IFREG: kind = .file
        case S_IFLNK: kind = .symbolicLink
        default: kind = .other
        }
        let sizes = kind == .directory
            ? contents
            : Totals(logical: max(0, info.st_size), allocated: max(0, info.st_blocks) * 512, files: 1)
        let name = root && key.tree == .system ? VolumeTree.systemDisplayName : String(key.path.split(separator: "/").last ?? "/")
        return StorageEntry(
            id: key, parent: root ? nil : parentPath(key.path), name: name, kind: kind,
            logical: sizes.logical, allocated: sizes.allocated, files: sizes.files,
            modified: fileDate(info.st_mtimespec), created: fileDate(info.st_birthtimespec),
            inode: Int64(bitPattern: info.st_ino), mode: Int64(info.st_mode), links: Int64(info.st_nlink)
        )
    }

    /// Streams directory names without following aliases or retaining a directory listing in memory.
    private func withChildren(of path: String, info: stat, visit: (String) throws -> Void) throws -> Bool {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw FilesystemFailure(path: path, code: errno == ELOOP ? ENOTDIR : errno) }
        var opened = stat()
        if fstat(fd, &opened) != 0 {
            let error = errno
            close(fd)
            throw FilesystemFailure(path: path, code: error)
        }
        guard info.st_ino == opened.st_ino, info.st_dev == opened.st_dev else {
            close(fd)
            throw FilesystemFailure(path: path, code: ENOTDIR)
        }
        guard let directory = fdopendir(fd) else {
            let error = errno
            close(fd)
            throw FilesystemFailure(path: path, code: error)
        }
        defer { closedir(directory) }
        var complete = true
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                if errno != 0 { throw FilesystemFailure(path: path, code: errno) }
                return complete
            }
            let name = withUnsafeBytes(of: entry.pointee.d_name) { buffer in
                String(validatingCString: buffer.bindMemory(to: CChar.self).baseAddress!)
            }
            guard let name else {
                complete = false
                continue
            }
            if name != "." && name != ".." { try visit(name) }
        }
    }
}
