import AppKit
import SpaceTrailCore

@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let openDashboard: (DashboardSection?) -> Void
    private weak var model: DashboardModel?
    private let storage = NSMenuItem(title: "Open Storage", action: #selector(showStorage), keyEquivalent: "")
    private let freeSpace = NSMenuItem()
    private let indexStatus = NSMenuItem()

    init(model: DashboardModel, openDashboard: @escaping (DashboardSection?) -> Void) {
        self.model = model
        self.openDashboard = openDashboard
        super.init()

        item.button?.image = Self.icon
        item.button?.imagePosition = .imageOnly
        item.button?.toolTip = "SpaceTrail"
        item.button?.setAccessibilityLabel("SpaceTrail")

        let menu = NSMenu(title: "SpaceTrail")
        menu.delegate = self
        menu.autoenablesItems = false
        let open = NSMenuItem(title: "Open SpaceTrail", action: #selector(showDashboard), keyEquivalent: "")
        let quit = NSMenuItem(title: "Quit SpaceTrail", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        open.target = self
        storage.target = self
        quit.target = NSApp
        freeSpace.isEnabled = false
        indexStatus.isEnabled = false
        for entry in [open, storage, .separator(), freeSpace, indexStatus, .separator(), quit] {
            menu.addItem(entry)
        }
        item.menu = menu
    }

    func remove() {
        NSStatusBar.system.removeStatusItem(item)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let space = VolumeSpace.read()
        freeSpace.title = space.map { "\(StorageStyle.size($0.available)) free" } ?? "Disk Usage Unavailable"
        storage.isEnabled = model?.diskAccess != nil
        if storage.isEnabled {
            indexStatus.title = status(BrokerState.read(in: SpaceTrailPaths.support))
        } else {
            indexStatus.title = "Setup Required"
        }
    }

    @objc private func showDashboard() { openDashboard(nil) }
    @objc private func showStorage() { openDashboard(.space) }

    private func status(_ state: BrokerState?) -> String {
        switch state?.phase {
        case .preparing, .scanning, .finishing: return "Indexing…"
        case .compacting: return "Optimizing Index…"
        case .recovering, .checking: return "Updating Index…"
        case .monitoring: return state?.background == true ? "Automatic Updates" : "Updates While Open"
        case .failed: return "Updates Paused"
        case nil: return "Index Offline"
        }
    }

    private static let icon: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setStrokeColor(CGColor(gray: 0, alpha: 1))
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.setLineWidth(1.45)
            context.setLineCap(.round)
            context.setLineJoin(.round)

            // A drive and the magnifying glass from the SpaceTrail app icon.
            context.addPath(CGPath(roundedRect: CGRect(x: 1.5, y: 2.7, width: 14.8, height: 5.5),
                                   cornerWidth: 2.3, cornerHeight: 2.3, transform: nil))
            context.move(to: CGPoint(x: 2, y: 7))
            context.addLine(to: CGPoint(x: 4.6, y: 13))
            context.addQuadCurve(to: CGPoint(x: 6, y: 14), control: CGPoint(x: 5, y: 14))
            context.addLine(to: CGPoint(x: 8.3, y: 14))
            context.strokePath()
            context.fillEllipse(in: CGRect(x: 4.1, y: 4.65, width: 1.6, height: 1.6))
            context.strokeEllipse(in: CGRect(x: 10.5, y: 10.1, width: 5.5, height: 5.5))
            context.move(to: CGPoint(x: 15.2, y: 10.9))
            context.addLine(to: CGPoint(x: 17.1, y: 9))
            context.strokePath()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "SpaceTrail"
        return image
    }()
}
