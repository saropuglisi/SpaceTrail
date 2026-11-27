import ServiceManagement
import SwiftUI

@MainActor
@Observable
final class LoginLaunch {
    private static let choiceKey = "loginLaunchChoiceMade"
    private let service = SMAppService.mainApp
    private(set) var status = SMAppService.Status.notRegistered
    private(set) var error: String?

    var isRegistered: Bool { status == .enabled || needsApproval }
    var needsApproval: Bool { status == .requiresApproval }
    var shouldOffer: Bool {
        status != .enabled && !UserDefaults.standard.bool(forKey: Self.choiceKey)
    }

    func refresh() {
        status = service.status
    }

    func recordChoice() {
        UserDefaults.standard.set(true, forKey: Self.choiceKey)
        error = nil
    }

    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        error = nil
        refresh()
        if isRegistered != enabled {
            do {
                if enabled { try service.register() }
                else { try service.unregister() }
            } catch {
                self.error = error.localizedDescription
            }
            refresh()
        }
        guard isRegistered == enabled else {
            error = error ?? "macOS could not save this login setting."
            return false
        }
        recordChoice()
        return true
    }

    func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

struct LoginLaunchPrompt: View {
    @Environment(\.dismiss) private var dismiss
    let launch: LoginLaunch
    @State private var requestedApproval = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Open SpaceTrail at login?")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(requestedApproval && launch.needsApproval
                 ? "Allow SpaceTrail in Login Items & Extensions to finish setup."
                 : "Have your storage overview ready when you log in. You can change this in Settings.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = launch.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Spacer()
                if requestedApproval && launch.needsApproval {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Open Login Items") { launch.openLoginItems() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Not Now", role: .cancel) {
                        launch.recordChoice()
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                    Button("Open at Login") {
                        if launch.setEnabled(true) {
                            if launch.needsApproval { requestedApproval = true }
                            else { dismiss() }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(.top, 6)
        }
        .padding(22)
        .frame(width: 413)
        .onChange(of: launch.status) { _, status in
            if requestedApproval && status == .enabled { dismiss() }
        }
    }
}
