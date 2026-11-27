import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var model: DashboardModel
    let loginLaunch: LoginLaunch
    @Binding var showsMenuBarIcon: Bool
    @State private var showingAccess = false
    @State private var previewAccessError: String?
    @State private var showingPreviewAccessError = false

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Open SpaceTrail at login", isOn: Binding(
                    get: { loginLaunch.isRegistered },
                    set: { loginLaunch.setEnabled($0) }
                ))
                if loginLaunch.needsApproval {
                    Text("Allow SpaceTrail in Login Items & Extensions to finish setup.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Open Login Items") { loginLaunch.openLoginItems() }
                }
                if let error = loginLaunch.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Menu Bar") {
                Toggle("Show SpaceTrail in the menu bar", isOn: $showsMenuBarIcon)
            }

            Section("Indexing") {
                if !model.isFixture, model.diskAccess != nil {
                    Toggle("Keep the index updated in the background", isOn: Binding(
                        get: { model.wantsBackground },
                        set: { model.setBackground($0) }
                    ))
                    if model.needsBackgroundApproval {
                        Button("Open System Settings") { model.openBackgroundSettings() }
                    }
                    Text(backgroundDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let overview = model.overview {
                    LabeledContent("Last Updated") {
                        Text(overview.lastUpdated, format: StorageStyle.dateAndTime)
                    }
                    if let lastAudit = overview.lastAudit {
                        LabeledContent("Last Check") {
                            Text(lastAudit, format: StorageStyle.dateAndTime)
                        }
                    }
                }
                if model.diskAccess != nil {
                    Button("Check Now") { model.requestCheck() }
                        .disabled(model.state?.phase == .checking || model.state?.phase == .scanning)
                }
                if model.state?.phase == .checking {
                    Label("Checking…", systemImage: "arrow.clockwise")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let error = model.serviceError ?? model.connectionError ?? model.brokerProblem {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Disk Access") {
                LabeledContent("Index Access") {
                    Text(model.indexAccess == .complete ? "Full Disk Access" :
                            (model.indexAccess == .limited ? "Limited Access" : "Setup Required"))
                }
                Button("Set Up Disk Access…") { showingAccess = true }
                if model.diskAccess == .complete, model.indexAccess == .limited {
                    Text("The broker updates accessible folders. It will resume updating protected folders once macOS grants Full Disk Access.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if model.indexAccess?.scansAppData == false {
                    Text("SpaceTrail displays previously indexed information for protected app containers.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Previews") {
                Button("Choose Preview Folders…") {
                    Task {
                        if let error = await model.choosePreviewFolders() {
                            previewAccessError = error
                            showingPreviewAccessError = true
                        }
                    }
                }
                if !model.previewFolderNames.isEmpty {
                    ForEach(model.previewFolderNames, id: \.self) { folder in
                        Label(folder, systemImage: "folder.badge.checkmark")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Button("Forget Preview Folders") { model.forgetPreviewFolders() }
                }
            }

            Section("Disk Usage") {
                Text("SpaceTrail measures and updates folder sizes in the background, even after you close the app.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("The ≥ symbol shows the minimum measured size when parts of a folder are inaccessible.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 510, height: 460)
        .onAppear {
            model.refreshService()
            loginLaunch.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginLaunch.refresh()
        }
        .alert("Previews", isPresented: $showingPreviewAccessError, presenting: previewAccessError) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in Text(message) }
        .sheet(isPresented: $showingAccess) {
            VStack(spacing: 0) {
                DiskAccessSetupView(model: model) { showingAccess = false }
                Button("Close") { showingAccess = false }
                    .keyboardShortcut(.cancelAction)
                    .padding(.bottom, 16)
            }
            .frame(width: 550, height: 540)
        }
    }

    private var backgroundDescription: String {
        if model.backgroundRunning { return "Background updates are active while SpaceTrail is closed." }
        if model.needsBackgroundApproval {
            return "Allow SpaceTrail under Login Items & Extensions. The index continues to update while the app is open."
        }
        if model.wantsBackground { return "SpaceTrail is starting background updates." }
        return "The index updates while SpaceTrail is open."
    }
}
