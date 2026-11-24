import Darwin
import Foundation

@main
enum FileDeletionTests {
    static func main() throws {
        let manager = FileManager.default
        let fixture = manager.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("spacetrail-deletion-\(UUID())")
        let directory = fixture.appendingPathComponent("dati")
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: fixture) }
        setenv("SPACETRAIL_ROOT", directory.path, 1)
        setenv("SPACETRAIL_SUPPORT", fixture.appendingPathComponent("indice").path, 1)
        guard let fixtureRoot = SpaceTrailPaths.fixtureRoot, let home = SpaceTrailPaths.personalFolder else {
            preconditionFailure("Percorso di prova assente")
        }
        let root = URL(fileURLWithPath: home.path, isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)

        let data = URL(fileURLWithPath: fixtureRoot, isDirectory: true)
        for url in [data.appendingPathComponent("System/Library/servizio"),
                    data.appendingPathComponent("Library/LaunchAgents/servizio.plist"),
                    data.appendingPathComponent("Users/Shared/condiviso.txt"),
                    root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + "-altra/prova.txt"),
                    root.appendingPathComponent("Library/Preferences/prova.plist"),
                    root.appendingPathComponent("lIbRaRy/Preferenze/prova.txt"),
                    root.appendingPathComponent(".ssh/config"),
                    root.appendingPathComponent("Downloads/Prova.APP/Contents/Resources/prova.txt")] {
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("intatto".utf8).write(to: url)
            try verifyProtected(snapshot(url, kind: .file))
            precondition(manager.fileExists(atPath: url.path))
        }

        let locked = root.appendingPathComponent("bloccato.txt")
        try Data("intatto".utf8).write(to: locked)
        precondition(chflags(locked.path, UInt32(UF_IMMUTABLE)) == 0)
        defer { _ = chflags(locked.path, 0) }
        try verifyProtected(snapshot(locked, kind: .file), expectedInIndex: false)
        precondition(manager.fileExists(atPath: locked.path))

        let original = root.appendingPathComponent("SpaceTrail-prova-\(UUID()).txt")
        try Data("prova".utf8).write(to: original)
        let first = try snapshot(original, kind: .file)
        try FileDeletion.remove(first, access: .complete)
        precondition(!manager.fileExists(atPath: original.path))
        do {
            try FileDeletion.remove(first, access: .complete)
            preconditionFailure("Un file già rimosso dovrebbe essere segnalato")
        } catch FileDeletion.Failure.missing { }

        try Data("versione indicizzata".utf8).write(to: original)
        let stale = try snapshot(original, kind: .file)
        let saved = root.appendingPathComponent("salvato.txt")
        try manager.moveItem(at: original, to: saved)
        let replacement = Data("versione nuova".utf8)
        try replacement.write(to: original)
        try mustReject { try FileDeletion.remove(stale, access: .complete) }
        try mustReject { try FileDeletion.moveToTrash(stale, access: .complete) }
        let remaining = try Data(contentsOf: original)
        precondition(remaining == replacement)

        let parent = root.appendingPathComponent("SpaceTrail-prova-\(UUID())")
        try manager.createDirectory(at: parent, withIntermediateDirectories: false)
        let nested = parent.appendingPathComponent("altro.txt")
        try Data("mantieni".utf8).write(to: nested)
        let previousLocation = try snapshot(nested, kind: .file)
        let moved = fixture.appendingPathComponent("fuori-radice")
        try manager.moveItem(at: parent, to: moved)
        try manager.createSymbolicLink(at: parent, withDestinationURL: moved)
        try mustReject { try FileDeletion.remove(previousLocation, access: .complete) }
        try mustReject { try FileDeletion.moveToTrash(previousLocation, access: .complete) }
        precondition(manager.fileExists(atPath: moved.appendingPathComponent("altro.txt").path))

        let link = try snapshot(parent, kind: .symbolicLink)
        if CommandLine.arguments.contains("--trash") {
            try verifyTrash(link)
            try verifyTrash(snapshot(original, kind: .file))
            print("Verificato lo spostamento nel Cestino e il recupero di un file e di un collegamento di prova.")
        }
        try FileDeletion.remove(link, access: .complete)
        precondition(!manager.fileExists(atPath: parent.path))
        precondition(manager.fileExists(atPath: moved.appendingPathComponent("altro.txt").path))
        try checkFolderTrash(home: root, manager: manager)
        print("Verificati percorsi e file protetti, eliminazione, sostituzione del file e collegamenti simbolici.")
    }

    private static func checkFolderTrash(home: URL, manager: FileManager) throws {
        for path in ["Documents", "Library", "Archivio/Prova.app"] {
            let folder = home.appendingPathComponent(path)
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            try verifyProtected(snapshot(folder, kind: .directory))
        }

        let folder = home.appendingPathComponent("Cartella-prova-\(UUID())")
        let child = folder.appendingPathComponent("Sottocartella/prova.txt")
        try manager.createDirectory(at: child.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data("contenuto della cartella".utf8)
        try data.write(to: child)
        let entry = try snapshot(folder, kind: .directory)
        precondition(FileDeletion.canMoveToTrash(entry, access: .complete))
        precondition(!FileDeletion.canRemove(entry, access: .complete))
        do {
            try FileDeletion.remove(entry, access: .complete)
            preconditionFailure("La rimozione definitiva dei file deve rifiutare una cartella")
        } catch FileDeletion.Failure.unavailable { }
        if CommandLine.arguments.contains("--trash") {
            try verifyTrash(entry)
            let restored = try Data(contentsOf: child)
            precondition(restored == data)
            print("Verificato il recupero dal Cestino di una cartella con sottocartella e file.")
        }
        try manager.moveItem(at: folder, to: folder.appendingPathExtension("prima"))
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
            preconditionFailure("L’elemento sostituito dovrebbe restare sul disco")
        } catch FileDeletion.Failure.changed { }
    }

    private static func verifyProtected(_ entry: StorageEntry, expectedInIndex: Bool = true) throws {
        if expectedInIndex {
            precondition(!FileDeletion.canRemove(entry, access: .complete))
            precondition(!FileDeletion.canMoveToTrash(entry, access: .complete))
        }
        do {
            try FileDeletion.remove(entry, access: .complete)
            preconditionFailure("Un file protetto non può essere eliminato")
        } catch FileDeletion.Failure.unavailable { }
        do {
            try FileDeletion.moveToTrash(entry, access: .complete)
            preconditionFailure("Un file protetto non può essere spostato nel Cestino")
        } catch FileDeletion.Failure.unavailable { }
    }

    private static func verifyTrash(_ entry: StorageEntry) throws {
        let source = URL(fileURLWithPath: entry.id.path)
        guard let destination = try FileDeletion.moveToTrash(entry, access: .complete) else {
            preconditionFailure("Il Cestino dovrebbe restituire la destinazione")
        }
        let sourceRemoved = (try? diskStat(entry.id.path)) == nil
        let destinationInfo = try? diskStat(destination.path)
        try FileManager.default.moveItem(at: destination, to: source)
        precondition(sourceRemoved)
        precondition(destinationInfo.map { Int64(bitPattern: $0.st_ino) } == entry.inode)
        precondition(FileDeletion.isCurrent(entry, access: .complete))
    }
}
