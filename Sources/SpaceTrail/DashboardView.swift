import Accessibility
import SpaceTrailCore
import SwiftUI

enum StorageStyle {
    static let accent = Color(hue: 0.66, saturation: 0.62, brightness: 0.86)
    static let inset: CGFloat = 22
    static let gap: CGFloat = 12
    static let locale = Locale(identifier: "en")
    static let dateAndTime = Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale)

    static func size(_ bytes: Int64) -> String {
        bytes == 0 ? "0 bytes" : bytes.formatted(.byteCount(style: .file).locale(locale))
    }

    static func count<T: BinaryInteger>(_ number: T) -> String {
        number.formatted(IntegerFormatStyle<T>(locale: locale))
    }

    static func location(_ path: String) -> String {
        if let root = SpaceTrailPaths.fixtureRoot, path == root || path.hasPrefix(root + "/") {
            return URL(fileURLWithPath: root).lastPathComponent + String(path.dropFirst(root.count))
        }
        return (SpaceTrailPaths.displayPath(path) as NSString).abbreviatingWithTildeInPath
    }

    static func exactSize(_ bytes: Int64) -> String {
        bytes == 1 ? "1 byte" : "\(count(bytes)) bytes"
    }
}

struct DashboardView: View {
    @Bindable var model: DashboardModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationSplitView {
            List(selection: Binding<DashboardSection?>(get: { model.activeSection }, set: { section in
                if let section { model.selectSection(section) }
            })) {
                ForEach(DashboardSection.allCases) { item in
                    Label(item.rawValue, systemImage: item.symbol)
                        .tag(item)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 145, ideal: 177, max: 220)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                sidebarStatus
            }
        } detail: {
            VStack(spacing: 0) {
                header
                if let banner = statusBanner { banner }
                switch model.activeSection {
                case .space: SpaceOverviewView(model: model)
                case .map: StorageMapView(model: model)
                case .files, .folders, .search: FileBrowserView(model: model)
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(alignment: .bottomTrailing) {
                ZStack {
                    if let notice = model.deletionNotice {
                        DeletionSpaceNotice(space: notice)
                            .transition(reduceMotion ? .identity : .offset(y: 8).combined(with: .opacity))
                    }
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: model.deletionNotice?.id)
                .padding(.trailing, StorageStyle.inset)
                .padding(.bottom, 76)
                .allowsHitTesting(false)
            }
            .navigationTitle("SpaceTrail")
        }
        .navigationSplitViewStyle(.balanced)
        .background {
            MouseHistoryTarget(navigate: model.step)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { model.step(.back) } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .disabled(!model.canStep(.back))
                .keyboardShortcut("[", modifiers: .command)
                .help("Back (⌘[)")
                Button { model.step(.forward) } label: {
                    Label("Forward", systemImage: "chevron.right")
                }
                .disabled(!model.canStep(.forward))
                .keyboardShortcut("]", modifiers: .command)
                .help("Forward (⌘])")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { model.showSearch() } label: {
                    Label("Search Disk", systemImage: "magnifyingglass")
                }
                .keyboardShortcut("f", modifiers: .command)
                .help("Search Disk (⌘F)")
            }
            ToolbarItem(placement: .primaryAction) {
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Settings")
            }
        }
        .task(id: model.activeSection == .space ? model.storageDays : nil) { await model.watch() }
        .task(id: model.deletionNotice?.id) {
            guard let notice = model.deletionNotice else { return }
            AccessibilityNotification.Announcement(notice.message).post()
            try? await Task.sleep(for: .seconds(3.2))
            if !Task.isCancelled, model.deletionNotice == notice { model.deletionNotice = nil }
        }
    }

    private var header: some View {
        HStack(spacing: StorageStyle.gap) {
            VStack(alignment: .leading, spacing: 5) {
                Text(model.activeSection == .folders ? model.folderTitle : model.activeSection.rawValue)
                    .font(.system(size: 29, weight: .semibold))
                    .tracking(-0.65)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            if model.activeSection == .space {
                Button("Find Large Files", systemImage: "magnifyingglass", action: model.findLargeFiles)
                    .help("Find files using at least 100 MB on disk")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, StorageStyle.inset)
        .padding(.top, 19)
        .padding(.bottom, 16)
    }

    private var subtitle: String {
        switch model.activeSection {
        case .files:
            if let overview = model.overview {
                return overview.indexedFiles == 1 ? "1 item indexed" :
                    "\(StorageStyle.count(overview.indexedFiles)) items indexed"
            }
            return "Browse all indexed files."
        case .folders:
            if let folder = model.folderInfo {
                let count = folder.files == 1 ? "1 item" : "\(StorageStyle.count(folder.files)) items"
                guard folder.id.path != folder.id.tree.root else { return count }
                let usage = model.diskUsage(for: folder)
                return count + "  ·  " + (usage.hasSize ? "\(usage.accessibleText) on disk" : usage.accessibleText)
            }
            return "Browse your disk and compare folder sizes."
        case .search:
            return "Find files and folders across the index."
        case .map:
            return "Explore the files and folders that take up the most space."
        case .space:
            return "See disk usage and which files are taking up more space."
        }
    }

    private var sidebarStatus: some View {
        VStack(alignment: .leading, spacing: 7) {
            Divider().padding(.bottom, 3)
            Label {
                Text(model.volumeName).lineLimit(1)
            } icon: {
                Image(systemName: "internaldrive")
            }
            .font(.subheadline.weight(.medium))
            if let space = model.volumeSpace, space.capacity > 0 {
                ProgressView(value: min(Double(space.used), Double(space.capacity)), total: Double(space.capacity))
                    .tint(StorageStyle.accent)
                    .accessibilityLabel("Space Used")
                Text("\(StorageStyle.size(space.available)) free")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(model.brokerStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusBanner: AnyView? {
        if let error = model.connectionError ?? model.brokerProblem {
            if model.overview != nil {
                return AnyView(banner("Updates Paused", detail: "Browse the last saved index.", icon: "pause.circle") {
                    Button("Retry") { model.requestCheck() }
                        .help(error)
                })
            }
            return AnyView(banner("Index Unavailable", detail: error, icon: "exclamationmark.triangle") {
                Button("Retry") { model.requestCheck() }
            })
        }
        if model.needsBackgroundApproval {
            return AnyView(banner("Background Updates", detail: "macOS requires your approval.", icon: "clock.arrow.circlepath") {
                Button("Open Settings") { model.openBackgroundSettings() }
            })
        }
        if model.overview == nil { return nil }
        if model.state?.phase == .compacting {
            return AnyView(banner("Optimizing Index", detail: "You can still browse indexed items.", icon: "internaldrive") {
                EmptyView()
            })
        }
        if model.indexAccess == .limited {
            return AnyView(banner("Limited Access", detail: "Protected folders show the last saved data.", icon: "lock") {
                SettingsLink { Text("Access") }
            })
        }
        if model.state?.phase == .recovering {
            return AnyView(banner("Updating Index", detail: "You can browse previously indexed items.", icon: "arrow.trianglehead.clockwise") {
                EmptyView()
            })
        }
        if let gaps = model.overview?.gaps, gaps > 0 {
            let detail = gaps == 1 ? "1 location to check" : "\(StorageStyle.count(gaps)) locations to check"
            return AnyView(banner("Partial Coverage", detail: detail, icon: "lock") {
                SettingsLink { Text("Access") }
            })
        }
        return nil
    }

    private func banner<Action: View>(_ title: String, detail: String, icon: String,
                                      @ViewBuilder action: () -> Action) -> some View {
        HStack(alignment: .center, spacing: 9) {
            Image(systemName: icon)
                .imageScale(.medium)
                .accessibilityHidden(true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    Text(title).fontWeight(.semibold)
                    Text(detail).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).fontWeight(.semibold)
                    Text(detail).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 6)
            action().controlSize(.small)
        }
        .font(.callout)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 7))
        .frame(maxWidth: 690, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, StorageStyle.inset)
        .padding(.bottom, 12)
        .accessibilityElement(children: .contain)
    }
}

struct IndexPlaceholder: View {
    let state: BrokerState?
    let hasError: Bool

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: hasError ? "internaldrive.badge.exclamationmark" : "internaldrive")
        } description: {
            if hasError {
                Text("Retry to start scanning the disk.")
            } else if state?.phase == .compacting {
                Text("SpaceTrail is reducing the disk space used by the index.")
            } else if state?.phase == .finishing {
                Text("SpaceTrail is finishing the search index.")
            } else if let state, state.processed > 0 {
                Text(state.processed == 1 ? "1 item scanned" : "\(StorageStyle.count(state.processed)) items scanned")
                    .monospacedDigit()
            } else {
                Text("Results will appear here after the scan.")
            }
        } actions: {
            if !hasError {
                if let fraction = state?.fraction {
                    VStack(spacing: 7) {
                        ProgressView(value: fraction)
                            .accessibilityLabel("Estimated Progress")
                        HStack {
                            Text("About \(Int(fraction * 100))%")
                            Spacer()
                            Text(estimate)
                        }
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                    .frame(width: 260)
                } else {
                    ProgressView().controlSize(.small).accessibilityLabel("Indexing in Progress")
                }
            }
        }
    }

    private var title: String {
        if hasError { return "Waiting to Index" }
        if state?.phase == .compacting { return "Optimizing Index" }
        if state?.phase == .finishing { return "Preparing Results" }
        return state?.resumed == true ? "Resuming Indexing" : "First Scan"
    }

    private var estimate: String {
        guard let remaining = state?.secondsRemaining else {
            return (state?.fraction ?? 0) >= 0.99 ? "Updating Estimate" : "Estimating Time…"
        }
        if remaining < 60 { return "Less than 1 min" }
        let formatter = DateComponentsFormatter()
        var calendar = Calendar.current
        calendar.locale = StorageStyle.locale
        formatter.calendar = calendar
        formatter.allowedUnits = [.hour, .minute]
        formatter.maximumUnitCount = 2
        formatter.unitsStyle = .abbreviated
        let rounded = (remaining / 60).rounded(.up) * 60
        return formatter.string(from: rounded).map { "About \($0) left" } ?? "Estimating Time…"
    }
}
