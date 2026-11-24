import Darwin
import Foundation

@main
enum FileDeletionTests {
    static func main() throws {
        let manager = FileManager.default
        let fixture = manager.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("spacetrail-deletion-\(UUID())")
        let directory = fixture.appendingPathComponent("data")
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: fixture) }
        setenv("SPACETRAIL_ROOT", directory.path, 1)
        setenv("SPACETRAIL_SUPPORT", fixture.appendingPathComponent("index").path, 1)
        guard let fixtureRoot = SpaceTrailPaths.fixtureRoot, let home = SpaceTrailPaths.personalFolder else {
            preconditionFailure("Missing test path")
        }
        let root = URL(fileURLWithPath: home.path, isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)

        let data = URL(fileURLWithPath: fixtureRoot, isDirectory: true)
        for url in [data.appendingPathComponent("System/Library/service"),
                    data.appendingPathComponent("Library/LaunchAgents/service.plist"),
                    data.appendingPathComponent("Users/Shared/shared.txt"),
                    root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + "-other/test.txt"),
                    root.appendingPathComponent("Library/Preferences/test.plist"),
                    root.appendingPathComponent("lIbRaRy/Preferences/test.txt"),
                    root.appendingPathComponent(".ssh/config"),
                    root.appendingPathComponent("Downloads/Test.APP/Contents/Resources/test.txt")] {
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("unchanged".utf8).write(to: url)
            try verifyProtected(snapshot(url, kind: .file))
            precondition(manager.fileExists(atPath: url.path))
        }

        let locked = root.appendingPathComponent("locked.txt")
        try Data("unchanged".utf8).write(to: locked)
        precondition(chflags(locked.path, UInt32(UF_IMMUTABLE)) == 0)
        defer { _ = chflags(locked.path, 0) }
        try verifyProtected(snapshot(locked, kind: .file), expectedInIndex: false)
        precondition(manager.fileExists(atPath: locked.path))

        let original = root.appendingPathComponent("SpaceTrail-test-\(UUID()).txt")
        try Data("test".utf8).write(to: original)
        let first = try snapshot(original, kind: .file)
        try FileDeletion.remove(first, access: .complete)
        precondition(!manager.fileExists(atPath: original.path))
        do {
            try FileDeletion.remove(first, access: .complete)
            preconditionFailure("A missing file should be reported")
        } catch FileDeletion.Failure.missing { }

        try Data("indexed version".utf8).write(to: original)
        let stale = try snapshot(original, kind: .file)
        let saved = root.appendingPathComponent("saved.txt")
        try manager.moveItem(at: original, to: saved)
        let replacement = Data("new version".utf8)
        try replacement.write(to: original)
        try mustReject { try FileDeletion.remove(stale, access: .complete) }
        try mustReject { try FileDeletion.moveToTrash(stale, access: .complete) }
        let remaining = try Data(contentsOf: original)
        precondition(remaining == replacement)

        let parent = root.appendingPathComponent("SpaceTrail-test-\(UUID())")
        try manager.createDirectory(at: parent, withIntermediateDirectories: false)
        let nested = parent.appendingPathComponent("other.txt")
        try Data("keep".utf8).write(to: nested)
        let previousLocation = try snapshot(nested, kind: .file)
        let moved = fixture.appendingPathComponent("outside-root")
        try manager.moveItem(at: parent, to: moved)
        try manager.createSymbolicLink(at: parent, withDestinationURL: moved)
        try mustReject { try FileDeletion.remove(previousLocation, access: .complete) }
        try mustReject { try FileDeletion.moveToTrash(previousLocation, access: .complete) }
        precondition(manager.fileExists(atPath: moved.appendingPathComponent("other.txt").path))

        let link = try snapshot(parent, kind: .symbolicLink)
        if CommandLine.arguments.contains("--trash") {
            try verifyTrash(link)
            try verifyTrash(snapshot(original, kind: .file))
            print("Verified moving a test file and symlink to the Trash and restoring both.")
        }
        try FileDeletion.remove(link, access: .complete)
        precondition(!manager.fileExists(atPath: parent.path))
        precondition(manager.fileExists(atPath: moved.appendingPathComponent("other.txt").path))
        try checkFolderTrash(home: root, manager: manager)
        print("Verified protected paths and files, deletion, replacement, and symbolic links.")
    }

    private static func checkFolderTrash(home: URL, manager: FileManager) throws {
        for path in ["Documents", "Library", "Archive/Test.app"] {
            let folder = home.appendingPathComponent(path)
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            try verifyProtected(snapshot(folder, kind: .directory))
        }

        let folder = home.appendingPathComponent("Test-folder-\(UUID())")
        let child = folder.appendingPathComponent("Subfolder/test.txt")
        try manager.createDirectory(at: child.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data("folder contents".utf8)
        try data.write(to: child)
        let entry = try snapshot(folder, kind: .directory)
        precondition(FileDeletion.canMoveToTrash(entry, access: .complete))
        precondition(!FileDeletion.canRemove(entry, access: .complete))
        do {
            try FileDeletion.remove(entry, access: .complete)
            preconditionFailure("Permanent file deletion must reject directories")
        } catch FileDeletion.Failure.unavailable { }
        if CommandLine.arguments.contains("--trash") {
            try verifyTrash(entry)
            let restored = try Data(contentsOf: child)
            precondition(restored == data)
            print("Verified restoring a folder and its contents from the Trash.")
        }
        try manager.moveItem(at: folder, to: folder.appendingPathExtension("previous"))
        try manager.createDirectory(at: folder, withIntermediateDirectories: false)
        try mustReject { try FileDeletion.moveToTrash(entry, access: .complete) }
        precondition(manager.fileExists(atPath: folder.path))
    }

    private static func snapshot(_ url: URL, kind: EntryKind) throws -> StorageEntry {
        let info = try diskStat(url.path)
        return StorageEntry(id: EntryKey(tree: .data, path: url.path), parent: parentPath(url.path),
                            name: url.lastPathComponent, kind: kind,
                            logical: kind == .directory ? 12_345 : info.st_size, allocated: 0, files: 1,
                            modified: fileDate(info.st_mtimespec), created: fileDate(info.st_birthtimespec),
                            inode: Int64(bitPattern: info.st_ino), mode: Int64(info.st_mode), links: Int64(info.st_nlink))
    }

    private static func mustReject(_ perform: () throws -> Void) throws {
        do {
            try perform()
            preconditionFailure("A replacement item should remain on disk")
        } catch FileDeletion.Failure.changed { }
    }

    private static func verifyProtected(_ entry: StorageEntry, expectedInIndex: Bool = true) throws {
        if expectedInIndex {
            precondition(!FileDeletion.canRemove(entry, access: .complete))
            precondition(!FileDeletion.canMoveToTrash(entry, access: .complete))
        }
        do {
            try FileDeletion.remove(entry, access: .complete)
            preconditionFailure("A protected item must not be deleted")
        } catch FileDeletion.Failure.unavailable { }
        do {
            try FileDeletion.moveToTrash(entry, access: .complete)
            preconditionFailure("A protected item must not be moved to the Trash")
        } catch FileDeletion.Failure.unavailable { }
    }

    private static func verifyTrash(_ entry: StorageEntry) throws {
        let source = URL(fileURLWithPath: entry.id.path)
        guard let destination = try FileDeletion.moveToTrash(entry, access: .complete) else {
            preconditionFailure("The Trash operation should report its destination")
        }
        let sourceRemoved = (try? diskStat(entry.id.path)) == nil
        let destinationInfo = try? diskStat(destination.path)
        try FileManager.default.moveItem(at: destination, to: source)
        precondition(sourceRemoved)
        precondition(destinationInfo.map { Int64(bitPattern: $0.st_ino) } == entry.inode)
        precondition(FileDeletion.isCurrent(entry, access: .complete))
    }
}
