import SwiftUI

struct SettingsView: View {
    @Bindable var model: DashboardModel
    @State private var showingAccess = false

    var body: some View {
        Form {
            Section("Indicizzazione") {
                if !model.isFixture, model.diskAccess != nil {
                    Toggle("Aggiorna anche ad app chiusa", isOn: Binding(
                        get: { model.wantsBackground },
                        set: { model.setBackground($0) }
                    ))
                    if model.needsBackgroundApproval {
                        Button("Apri Impostazioni di Sistema") { model.openBackgroundSettings() }
                    }
                    Text(backgroundDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let overview = model.overview {
                    LabeledContent("Ultimo aggiornamento") {
                        Text(overview.lastUpdated.formatted(date: .abbreviated, time: .shortened))
                    }
                    if let lastAudit = overview.lastAudit {
                        LabeledContent("Ultima verifica") {
                            Text(lastAudit.formatted(date: .abbreviated, time: .shortened))
                        }
                    }
                }
                if model.diskAccess != nil {
                    Button("Verifica ora") { model.requestCheck() }
                        .disabled(model.state?.phase == .checking || model.state?.phase == .scanning)
                }
                if model.state?.phase == .checking {
                    Label("Verifica in corso", systemImage: "arrow.clockwise")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let error = model.serviceError ?? model.connectionError ?? model.brokerProblem {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Accesso al disco") {
                LabeledContent("Indicizzazione in uso") {
                    Text(model.indexAccess == .complete ? "Accesso completo" :
                            (model.indexAccess == .limited ? "Accesso limitato" : "Da configurare"))
                }
                Button("Configura accesso al disco…") { showingAccess = true }
                if model.diskAccess == .complete, model.indexAccess == .limited {
                    Text("Il broker aggiorna le cartelle accessibili. Le cartelle protette tornano ad aggiornarsi quando macOS riconosce l’accesso completo al disco.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if model.indexAccess?.scansAppData == false {
                    Text("Per i contenitori protetti di altre app, SpaceTrail usa le informazioni già presenti nell’indice.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Dimensioni") {
                Text("SpaceTrail calcola e aggiorna lo spazio delle cartelle in background, anche a finestra chiusa.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Quando alcune parti della cartella non sono misurabili, il valore preceduto da ≥ indica lo spazio minimo rilevato.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 510, height: 460)
        .onAppear { model.refreshService() }
        .sheet(isPresented: $showingAccess) {
            VStack(spacing: 0) {
                DiskAccessSetupView(model: model) { showingAccess = false }
                Button("Chiudi") { showingAccess = false }
                    .keyboardShortcut(.cancelAction)
                    .padding(.bottom, 16)
            }
            .frame(width: 550, height: 540)
        }
    }

    private var backgroundDescription: String {
        if model.backgroundRunning { return "Attivo. L’indice rimane aggiornato anche dopo che chiudi SpaceTrail." }
        if model.needsBackgroundApproval {
            return "Consenti SpaceTrail in Elementi login ed estensioni. Nel frattempo l’indice si aggiorna con l’app aperta."
        }
        if model.wantsBackground { return "SpaceTrail prova ad avviare gli aggiornamenti automatici." }
        return "L’indice si aggiorna mentre SpaceTrail è aperto."
    }
}
