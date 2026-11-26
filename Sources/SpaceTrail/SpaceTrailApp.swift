import AppKit
import SwiftUI

@MainActor
final class AppLifecycle: NSObject, NSApplicationDelegate {
    private weak var model: DashboardModel?
    private var openMainWindow: OpenWindowAction?
    private var statusMenu: StatusMenu?

    func prepare(model: DashboardModel, openWindow: OpenWindowAction, showsMenuBarIcon: Bool) {
        self.model = model
        openMainWindow = openWindow
        setMenuBarVisible(showsMenuBarIcon)
    }

    func setMenuBarVisible(_ visible: Bool) {
        if visible, statusMenu == nil, let model {
            statusMenu = StatusMenu(model: model) { [weak self] section in self?.showDashboard(section) }
        } else if !visible {
            statusMenu?.remove()
            statusMenu = nil
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        guard statusMenu != nil else { return true }
        sender.setActivationPolicy(.accessory)
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard statusMenu != nil, !hasVisibleWindows else { return true }
        showDashboard(nil)
        return false
    }

    private func showDashboard(_ section: DashboardSection?) {
        NSApp.setActivationPolicy(.regular)
        if let section { model?.selectSection(section) }
        openMainWindow?(id: "main")
        NSApp.activate()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let registration = model?.backgroundRegistrationTask else { return .terminateNow }
        Task {
            await registration.value
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct SpaceTrailApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycle.self) private var lifecycle
    @AppStorage("showsMenuBarIcon") private var showsMenuBarIcon = true
    @State private var model = DashboardModel()

    var body: some Scene {
        Window("SpaceTrail", id: "main") {
            MainWindow(model: model, lifecycle: lifecycle, showsMenuBarIcon: showsMenuBarIcon)
        }
        .defaultSize(width: 1_100, height: 720)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView(model: model, showsMenuBarIcon: Binding(get: { showsMenuBarIcon }, set: { visible in
                showsMenuBarIcon = visible
                lifecycle.setMenuBarVisible(visible)
            }))
            .environment(\.locale, StorageStyle.locale)
        }
    }
}

private struct MainWindow: View {
    @Environment(\.openWindow) private var openWindow
    let model: DashboardModel
    let lifecycle: AppLifecycle
    let showsMenuBarIcon: Bool

    var body: some View {
        Group {
            if model.diskAccess == nil { DiskAccessSetupView(model: model) }
            else { DashboardView(model: model) }
        }
        .frame(minWidth: 780, minHeight: 520)
        .environment(\.locale, StorageStyle.locale)
        .onAppear {
            lifecycle.prepare(model: model, openWindow: openWindow, showsMenuBarIcon: showsMenuBarIcon)
        }
    }
}
