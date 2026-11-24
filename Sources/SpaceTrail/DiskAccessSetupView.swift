import AppKit
import SpaceTrailCore
import SwiftUI

struct DiskAccessSetupView: View {
    let model: DashboardModel
    var onFinish: () -> Void = {}

    @State private var openedSettings = false

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                setupContent
                    .frame(minHeight: geometry.size.height)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var setupContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 68, height: 68)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 9) {
                Text("Set Up Disk Access")
                    .font(.system(size: 29, weight: .semibold))
                    .tracking(-0.55)
                    .accessibilityAddTraits(.isHeader)
                Text("SpaceTrail reads file names, paths, and sizes so you can find what takes up space. Your index stays on this Mac.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("SpaceTrail keeps your index up to date after you close the app when macOS allows it to run in the background.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Label("Full Disk Access", systemImage: "lock.shield")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text("In Privacy & Security, add and enable SpaceTrail Broker under Full Disk Access. You can drag it in from Finder.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if openedSettings {
                    Text("The broker uses this permission to scan the disk. You can also add SpaceTrail for previews and actions on protected files.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    if openedSettings {
                        Button("Reopen Settings") { openSettings() }
                        Button("Show Broker in Finder") { model.revealBroker() }
                    } else {
                        Button("Open System Settings") { openSettings() }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .padding(.top, 3)
            }

            Divider()
            VStack(alignment: .leading, spacing: 9) {
                if openedSettings {
                    Button("Continue") { choose(.complete) }
                        .buttonStyle(.borderedProminent)
                }
                Button("Continue with Limited Access") { choose(.limited) }
                    .buttonStyle(.bordered)
                Text("SpaceTrail indexes the folders it can access. It will start scanning protected folders once macOS grants access.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.accessSetupError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
            }
        }
        .frame(maxWidth: 478, alignment: .leading)
        .padding(.horizontal, 28)
        .padding(.vertical, 30)
        .frame(maxWidth: .infinity)
    }

    private func openSettings() {
        openedSettings = true
        model.revealBroker()
        model.openPrivacySettings()
    }

    private func choose(_ access: DiskAccess) {
        if model.configureAccess(access) { onFinish() }
    }
}
