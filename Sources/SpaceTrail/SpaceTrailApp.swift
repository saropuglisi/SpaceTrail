import AppKit
import SwiftUI

final class AppLifecycle: NSObject, NSApplicationDelegate {
    weak var model: DashboardModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

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
    @State private var model = DashboardModel()

    var body: some Scene {
        Window("SpaceTrail", id: "main") {
            Group {
                if model.diskAccess == nil { DiskAccessSetupView(model: model) }
                else { DashboardView(model: model) }
            }
            .frame(minWidth: 780, minHeight: 520)
            .environment(\.locale, StorageStyle.locale)
            .onAppear { lifecycle.model = model }
        }
        .defaultSize(width: 1_100, height: 720)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView(model: model)
                .environment(\.locale, StorageStyle.locale)
        }
    }
}
