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
                Text("Prepara l’accesso al disco")
                    .font(.system(size: 29, weight: .semibold))
                    .tracking(-0.55)
                    .accessibilityAddTraits(.isHeader)
                Text("SpaceTrail legge nomi, percorsi e dimensioni per trovare i file e mostrarti quanto spazio occupano. L’indice resta su questo Mac.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Dopo la configurazione, SpaceTrail terrà aggiornato l’indice anche a finestra chiusa, se autorizzato da macOS.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Label("Accesso completo al disco", systemImage: "lock.shield")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text("In Privacy e sicurezza, aggiungi e abilita SpaceTrail Broker nell’elenco Accesso completo al disco. Puoi trascinarlo dal Finder.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if openedSettings {
                    Text("SpaceTrail usa l’accesso del broker per la scansione. Puoi aggiungere anche SpaceTrail per le anteprime e le azioni sui file protetti.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    if openedSettings {
                        Button("Riapri Impostazioni") { openSettings() }
                        Button("Mostra il broker") { model.revealBroker() }
                    } else {
                        Button("Apri Impostazioni di Sistema") { openSettings() }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .padding(.top, 3)
            }

            Divider()
            VStack(alignment: .leading, spacing: 9) {
                if openedSettings {
                    Button("Continua") { choose(.complete) }
                        .buttonStyle(.borderedProminent)
                }
                Button("Continua con accesso limitato") { choose(.limited) }
                    .buttonStyle(.bordered)
                Text("La scansione delle cartelle protette parte quando macOS riconosce l’accesso. Nel frattempo SpaceTrail aggiorna le cartelle accessibili.")
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
