import Foundation
import SpaceTrailCore

struct VolumeSpace: Equatable, Sendable {
    let capacity: Int64
    let available: Int64

    var used: Int64 { max(0, capacity - available) }

    static func read() -> VolumeSpace? {
        let volume = URL(fileURLWithPath: VolumeTree.data.root, isDirectory: true)
        guard let values = try? volume.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]),
              let capacity = values.volumeTotalCapacity, capacity > 0,
              let available = values.volumeAvailableCapacity, available >= 0 else { return nil }
        return VolumeSpace(capacity: Int64(capacity), available: Int64(available))
    }

    func increase(since previous: VolumeSpace) -> Int64? {
        guard capacity == previous.capacity else { return nil }
        return max(0, available - previous.available)
    }
}
