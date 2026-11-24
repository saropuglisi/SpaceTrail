import Darwin
import Foundation

public enum SpaceTrailPaths {
    public static let agentPlist = "io.spacetrail.broker.plist"
    public static let agentBundle = "Contents/Helpers/SpaceTrail Broker.app"
    public static let agentExecutable = "Contents/MacOS/SpaceTrailBroker"
    public static let accessNotification = Notification.Name("io.spacetrail.access-changed")
    static let backgroundTakeoverNotification = Notification.Name("io.spacetrail.background-takeover")
    public static let reviewNotification = Notification.Name("io.spacetrail.review-index")

    public static var support: URL {
        if let path = ProcessInfo.processInfo.environment["SPACETRAIL_SUPPORT"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath()
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SpaceTrail", isDirectory: true)
            .resolvingSymlinksInPath()
    }

    public static let fixtureRoot: String? = {
        guard let path = ProcessInfo.processInfo.environment["SPACETRAIL_ROOT"], !path.isEmpty else {
            return nil
        }
        guard let canonical = realpath(path, nil) else { return path }
        defer { free(canonical) }
        return String(cString: canonical)
    }()

    static func identityPath(_ path: String) -> String {
        let visible = displayPath(path)
        if isWithin(visible, "/var") || isWithin(visible, "/tmp") || isWithin(visible, "/etc") {
            return "/private" + visible
        }
        return visible
    }

    public static let dataRoot = "/System/Volumes/Data"

    public static let personalFolder: EntryKey? = {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let parts = identityPath(home).split(separator: "/")
        guard parts.count == 2, parts[0] == "Users", parts[1].lowercased() != "shared" else { return nil }
        return EntryKey(tree: .data, path: childPath(VolumeTree.data.root, parts.joined(separator: "/")))
    }()

    public static func database(in support: URL) -> URL {
        support.appendingPathComponent("index.sqlite")
    }

    public static func displayPath(_ path: String) -> String {
        if path == dataRoot { return "/" }
        if path.hasPrefix(dataRoot + "/") { return String(path.dropFirst(dataRoot.count)) }
        return path
    }
}

public enum VolumeTree: Int64, CaseIterable, Codable, Sendable {
    case data, system

    public var root: String {
        switch self {
        case .data: return SpaceTrailPaths.fixtureRoot ?? SpaceTrailPaths.dataRoot
        case .system: return "/"
        }
    }
}

public struct EntryKey: Hashable, Codable, Sendable {
    public let tree: VolumeTree
    public let path: String

    public init(tree: VolumeTree, path: String) {
        self.tree = tree
        self.path = path
    }
}

public enum EntryKind: Int64, Sendable {
    case file, directory, symbolicLink, other
}

public struct StorageEntry: Identifiable, Equatable, Sendable {
    public let id: EntryKey
    public let parent: String?
    public let name: String
    public let kind: EntryKind
    public let logical: Int64
    public let allocated: Int64
    public let files: Int64
    public let modified: Date
    public let created: Date
    public let inode: Int64
    public let mode: Int64
    public let links: Int64
    public internal(set) var footprint: PhysicalFootprint?

    public var displayPath: String { SpaceTrailPaths.displayPath(id.path) }
    public var isFolder: Bool { kind == .directory }
    public var diskBytes: Int64 { isFolder ? (footprint?.bytes ?? allocated) : allocated }
}

public enum EntrySort: String, CaseIterable, Sendable {
    case name, logical, allocated, modified
}

public enum EntryScope: Equatable, Sendable {
    case files
    case search
    case children(EntryKey)
}

public struct SearchFilters: Equatable, Sendable {
    public enum Kind: Hashable, Sendable {
        case all, files, folders
    }

    public var kind: Kind = .all
    public var similar = true

    public init() {}
}

public struct EntryPage: Equatable, Sendable {
    public let rows: [StorageEntry]
    public let hasMore: Bool
    public var similarNames: Set<EntryKey> = []
}

public struct MapPage: Equatable, Sendable {
    public let contents: EntryPage
    public let previews: [EntryKey: [StorageEntry]]
}

public struct StorageSample: Identifiable, Equatable, Sendable {
    public let date: Date
    public let capacity: Int64
    public let available: Int64
    public let indexed: Int64

    public var id: Date { date }
    public var used: Int64 { max(0, capacity - available) }
}

public struct Overview: Sendable {
    public let indexedFiles: Int64
    public let indexedBytes: Int64
    public let gaps: Int64
    public let lastUpdated: Date
    public let lastAudit: Date?
    public let sample: StorageSample?
    public let history: [StorageSample]
    public let largeFiles: [StorageEntry]
    public let largeFolders: [StorageEntry]
}

public struct BrokerState: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable {
        case preparing, scanning, finishing, recovering, compacting, monitoring, checking, failed
    }

    public let phase: Phase
    public let processed: Int64
    public let detail: String?
    public let fraction: Double?
    public let secondsRemaining: Double?
    public let resumed: Bool?
    public let pid: Int32
    public let background: Bool?
    public let build: String?
    public let effectiveAccess: DiskAccess?

    public init(phase: Phase, processed: Int64 = 0, detail: String? = nil, fraction: Double? = nil,
                secondsRemaining: Double? = nil, resumed: Bool? = nil, pid: Int32 = getpid(),
                background: Bool? = nil, build: String? = nil, effectiveAccess: DiskAccess? = nil) {
        self.phase = phase
        self.processed = processed
        self.detail = detail
        self.fraction = fraction
        self.secondsRemaining = secondsRemaining
        self.resumed = resumed
        self.pid = pid
        self.background = background
        self.build = build
        self.effectiveAccess = effectiveAccess
    }

    public var isRunning: Bool { pid > 0 && kill(pid, 0) == 0 }

    public static func read(in support: URL) -> BrokerState? {
        guard let data = try? Data(contentsOf: support.appendingPathComponent("broker.json")),
              let state = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        if state.phase == .failed || state.isRunning { return state }
        return nil
    }

    public func write(in support: URL) throws {
        let data = try JSONEncoder().encode(self)
        try data.write(to: support.appendingPathComponent("broker.json"), options: .atomic)
    }
}
