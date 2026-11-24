import Darwin
import Foundation
import SpaceTrailCore

umask(0o077)
let arguments = CommandLine.arguments
let parentPID = arguments.firstIndex(of: "--session-parent").flatMap { index in
    arguments.indices.contains(index + 1) ? Int32(arguments[index + 1]) : nil
}

do {
    let preference = DiskAccess.read(in: SpaceTrailPaths.support)
    guard let access = preference ?? (SpaceTrailPaths.fixtureRoot == nil ? nil : .complete) else {
        exit(EXIT_SUCCESS)
    }
    let broker = try StorageBroker(access: access, parentPID: parentPID)
    broker.start()
    withExtendedLifetime(broker) { RunLoop.main.run() }
} catch is BrokerAlreadyRunning {
    exit(EXIT_SUCCESS)
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(EXIT_FAILURE)
}
