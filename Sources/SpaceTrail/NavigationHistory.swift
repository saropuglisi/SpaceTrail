import AppKit
import SpaceTrailCore
import SwiftUI

enum DashboardLocation: Equatable {
    case files, folders(EntryKey), search, map(EntryKey), space

    var section: DashboardSection {
        switch self {
        case .files: return .files
        case .folders: return .folders
        case .search: return .search
        case .map: return .map
        case .space: return .space
        }
    }
}

enum HistoryDirection: Int {
    case back = -1
    case forward = 1

    init?(mouseButton: Int) {
        switch mouseButton {
        case 3: self = .back
        case 4: self = .forward
        default: return nil
        }
    }
}

struct NavigationHistory {
    private var locations: [DashboardLocation] = [.files]
    private var index = 0

    var current: DashboardLocation { locations[index] }

    func canStep(_ direction: HistoryDirection) -> Bool {
        locations.indices.contains(index + direction.rawValue)
    }

    mutating func visit(_ location: DashboardLocation) -> Bool {
        guard current != location else { return false }
        locations.removeLast(locations.count - index - 1)
        locations.append(location)
        if locations.count > 64 { locations.removeFirst() }
        index = locations.count - 1
        return true
    }

    mutating func step(_ direction: HistoryDirection) -> DashboardLocation? {
        guard canStep(direction) else { return nil }
        index += direction.rawValue
        return current
    }
}

/// Listens only in the dashboard window, without requiring global mouse access.
struct MouseHistoryTarget: NSViewRepresentable {
    let navigate: (HistoryDirection) -> Bool

    func makeNSView(context: Context) -> Target { Target() }

    func updateNSView(_ view: Target, context: Context) { view.navigate = navigate }

    final class Target: NSView {
        var navigate: ((HistoryDirection) -> Bool)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      window.attachedSheet == nil, NSApp.modalWindow == nil,
                      let direction = HistoryDirection(mouseButton: event.buttonNumber),
                      self.navigate?(direction) == true else { return event }
                return nil
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
