import Darwin
import Foundation
import Security

public enum DiskAccess: String, Codable, Sendable {
    case complete, limited

    public static func read(in support: URL) -> Self? {
        guard let data = try? Data(contentsOf: support.appendingPathComponent("access.json")) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    public func write(in support: URL) throws {
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(self)
        try data.write(to: support.appendingPathComponent("access.json"), options: .atomic)
    }

    public func includes(_ key: EntryKey) -> Bool {
        excludedScope(for: key) == nil
    }

    public var effective: Self {
        guard self == .complete, SpaceTrailPaths.fixtureRoot == nil else { return self }
        // macOS has no Full Disk Access preflight API. These locations require Full
        // Disk Access and deny opening silently. We never read their contents.
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library").path
        let checks: [(String, Int32)] = [
            ("/Library/Preferences/com.apple.TimeMachine.plist", 0),
            (library + "/Mail", O_DIRECTORY),
            (library + "/Safari", O_DIRECTORY)
        ]
        var verified = false
        for (path, flags) in checks {
            let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | flags)
            if descriptor >= 0 {
                close(descriptor)
                verified = true
            } else if errno != ENOENT {
                return .limited
            }
        }
        return verified ? .complete : .limited
    }

    public var scansAppData: Bool { self == .complete && Self.hasTeamSignature }

    private static let hasTeamSignature: Bool = {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess
        else { return false }
        return (information as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] is String
    }()

    private static let protectedHomeFolders: Set<Substring> = [
        "Desktop", "Documents", "Downloads", "Library", "Pictures", "Music", "Movies", ".Trash"
    ]

    // Do not enter locations likely to require macOS consent during a limited scan.
    func excludedScope(for key: EntryKey) -> EntryKey? {
        if !scansAppData, let scope = key.protectedAppDataScope { return scope }
        guard self == .limited, SpaceTrailPaths.fixtureRoot == nil, key.tree == .data else { return nil }
        let path = SpaceTrailPaths.displayPath(key.path)
        if let name = ["Volumes", ".Trashes", ".DocumentRevisions-V100", ".TemporaryItems"]
            .first(where: { isWithin(path, "/" + $0) }) {
            return EntryKey(tree: .data, path: childPath(VolumeTree.data.root, name))
        }
        guard path.hasPrefix("/Users/") else { return nil }
        let parts = path.dropFirst("/Users/".count).split(separator: "/", maxSplits: 2)
        guard parts.count >= 2, Self.protectedHomeFolders.contains(parts[1]) else { return nil }
        return EntryKey(tree: .data, path: childPath(VolumeTree.data.root, "Users/\(parts[0])/\(parts[1])"))
    }
}

extension EntryKey {
    public var protectedAppDataScope: EntryKey? {
        guard tree == .data, isWithin(path, tree.root) else { return nil }
        let components = path.dropFirst(tree.root.count).split(separator: "/", maxSplits: 4)
        let library = components.first?.lowercased() == "users" ? 2 : 0
        guard components.count > library + 1, components[library].lowercased() == "library",
              ["containers", "group containers", "daemon containers"].contains(components[library + 1].lowercased())
        else { return nil }
        return EntryKey(tree: tree, path: childPath(tree.root, components.prefix(library + 2).joined(separator: "/")))
    }
}

enum StartupVolumeLayout {
    static let version = "2"

    static let systemAliases: [String] = {
        let fallback = ["/Applications", "/Library", "/Users", "/Volumes", "/private", "/cores", "/opt", "/usr/local",
                        "/System/Library/Caches", "/System/Library/Assets", "/System/Library/AssetsV2",
                        "/System/Library/PreinstalledAssets", "/System/Library/PreinstalledAssetsV2"]
        let list = (try? String(contentsOfFile: "/usr/share/firmlinks", encoding: .utf8)) ?? ""
        let roots = list.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            guard let path = line.split(separator: "\t").first, path.hasPrefix("/"), path.count > 1 else { return nil }
            return String(path)
        }
        return Array(Set(roots + fallback + ["/System/Volumes"])).sorted()
    }()

    static func isSystemAlias(_ key: EntryKey) -> Bool {
        key.tree == .system && systemAliases.contains { isWithin(key.path, $0) }
    }
}
