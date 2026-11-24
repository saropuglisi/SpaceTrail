import Accessibility
import SpaceTrailCore
import SwiftUI

enum StorageStyle {
    static let accent = Color(hue: 0.66, saturation: 0.62, brightness: 0.86)
    static let inset: CGFloat = 22
    static let gap: CGFloat = 12

    static func size(_ bytes: Int64) -> String {
        bytes == 0 ? "0 byte" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func location(_ path: String) -> String {
        if let root = SpaceTrailPaths.fixtureRoot, path == root || path.hasPrefix(root + "/") {
            return URL(fileURLWithPath: root).lastPathComponent + String(path.dropFirst(root.count))
        }
        return (SpaceTrailPaths.displayPath(path) as NSString).abbreviatingWithTildeInPath
    }

    static func exactSize(_ bytes: Int64) -> String {
        "\(bytes.formatted()) byte"
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
                    Label("Indietro", systemImage: "chevron.left")
                }
                .disabled(!model.canStep(.back))
                .keyboardShortcut("[", modifiers: .command)
                .help("Indietro (⌘[)")
                Button { model.step(.forward) } label: {
                    Label("Avanti", systemImage: "chevron.right")
                }
                .disabled(!model.canStep(.forward))
                .keyboardShortcut("]", modifiers: .command)
                .help("Avanti (⌘])")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { model.showSearch() } label: {
                    Label("Cerca nel disco", systemImage: "magnifyingglass")
                }
                .keyboardShortcut("f", modifiers: .command)
                .help("Cerca nel disco (⌘F)")
            }
            ToolbarItem(placement: .primaryAction) {
                SettingsLink {
                    Label("Impostazioni", systemImage: "gearshape")
                }
                .help("Impostazioni")
            }
        }
        .task(id: model.activeSection == .space) { await model.watch() }
        .task(id: model.deletionNotice?.id) {
            guard let notice = model.deletionNotice else { return }
            AccessibilityNotification.Announcement(notice.message).post()
            try? await Task.sleep(for: .seconds(3.2))
            if !Task.isCancelled, model.deletionNotice == notice { model.deletionNotice = nil }
        }
    }

    private var header: some View {
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, StorageStyle.inset)
        .padding(.top, 19)
        .padding(.bottom, 16)
    }

    private var subtitle: String {
        switch model.activeSection {
        case .files:
            if let overview = model.overview {
                return overview.indexedFiles == 1 ? "1 elemento indicizzato" :
                    "\(overview.indexedFiles.formatted()) elementi indicizzati"
            }
            return "Tutti i file del disco, in un unico elenco."
        case .folders:
            if let folder = model.folderInfo {
                let count = folder.files == 1 ? "1 elemento" : "\(folder.files.formatted()) elementi"
                guard folder.id.path != folder.id.tree.root else { return count }
                let usage = model.diskUsage(for: folder)
                return count + "  ·  " + (usage.hasSize ? "\(usage.accessibleText) su disco" : usage.accessibleText)
            }
            return "Sfoglia il disco e confronta il peso delle cartelle."
        case .search:
            return "Trova file e cartelle in tutto l’indice."
        case .map:
            return "Esplora i file e le sottocartelle che occupano più spazio."
        case .space:
            return "Capacità, andamento e contenuti che occupano più spazio."
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
                    .accessibilityLabel("Spazio utilizzato")
                Text("\(StorageStyle.size(space.available)) liberi")
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
                return AnyView(banner("Aggiornamenti in pausa", detail: "Puoi consultare l’ultimo indice salvato.", icon: "pause.circle") {
                    Button("Riprova") { model.requestCheck() }
                        .help(error)
                })
            }
            return AnyView(banner("Indice non disponibile", detail: error, icon: "exclamationmark.triangle") {
                Button("Riprova") { model.requestCheck() }
            })
        }
        if model.needsBackgroundApproval {
            return AnyView(banner("Aggiornamento ad app chiusa", detail: "macOS richiede un’autorizzazione.", icon: "clock.arrow.circlepath") {
                Button("Apri Impostazioni") { model.openBackgroundSettings() }
            })
        }
        if model.overview == nil { return nil }
        if model.state?.phase == .compacting {
            return AnyView(banner("Ottimizzazione dell’indice", detail: "Puoi continuare a consultare i risultati.", icon: "internaldrive") {
                EmptyView()
            })
        }
        if model.indexAccess == .limited {
            return AnyView(banner("Accesso limitato", detail: "Per le cartelle protette vedi gli ultimi dati salvati.", icon: "lock") {
                SettingsLink { Text("Accesso") }
            })
        }
        if model.state?.phase == .recovering {
            return AnyView(banner("Aggiornamento dell’indice", detail: "Puoi consultare i risultati già indicizzati.", icon: "arrow.trianglehead.clockwise") {
                EmptyView()
            })
        }
        if let gaps = model.overview?.gaps, gaps > 0 {
            let detail = gaps == 1 ? "1 percorso da verificare" : "\(gaps.formatted()) percorsi da verificare"
            return AnyView(banner("Copertura parziale", detail: detail, icon: "lock") {
                SettingsLink { Text("Accesso") }
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
                Text("Riprova per avviare la lettura del disco.")
            } else if state?.phase == .compacting {
                Text("SpaceTrail sta riducendo lo spazio usato dall’indice.")
            } else if state?.phase == .finishing {
                Text("SpaceTrail sta completando l’indice di ricerca.")
            } else if let state, state.processed > 0 {
                Text("\(state.processed.formatted()) elementi esaminati")
                    .monospacedDigit()
            } else {
                Text("I risultati appariranno qui al termine della lettura del disco.")
            }
        } actions: {
            if !hasError {
                if let fraction = state?.fraction {
                    VStack(spacing: 7) {
                        ProgressView(value: fraction)
                            .accessibilityLabel("Avanzamento stimato")
                        HStack {
                            Text("\(Int(fraction * 100))% circa")
                            Spacer()
                            Text(estimate)
                        }
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                    .frame(width: 260)
                } else {
                    ProgressView().controlSize(.small).accessibilityLabel("Indicizzazione in corso")
                }
            }
        }
    }

    private var title: String {
        if hasError { return "Indice in attesa" }
        if state?.phase == .compacting { return "Ottimizzazione dell’indice" }
        if state?.phase == .finishing { return "Preparazione dei risultati" }
        return state?.resumed == true ? "Indicizzazione ripresa" : "Prima indicizzazione"
    }

    private var estimate: String {
        guard let remaining = state?.secondsRemaining else {
            return (state?.fraction ?? 0) >= 0.99 ? "Stima in aggiornamento" : "Calcolo del tempo…"
        }
        if remaining < 60 { return "Meno di 1 min" }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.maximumUnitCount = 2
        formatter.unitsStyle = .abbreviated
        let rounded = (remaining / 60).rounded(.up) * 60
        return formatter.string(from: rounded).map { "Circa \($0) rimanenti" } ?? "Calcolo del tempo…"
    }
}
