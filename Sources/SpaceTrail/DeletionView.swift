import AppKit
import SpaceTrailCore
import SwiftUI

struct DeletionSelection: Identifiable {
    let id = UUID()
    let entries: [StorageEntry]
}

struct DeletionSpace: Identifiable, Equatable, Sendable {
    let id = UUID()
    let bytes: Int64?

    var message: String {
        guard let bytes else { return "Freed space could not be measured" }
        if bytes == 0 { return "Free space did not increase" }
        return "\(StorageStyle.size(bytes)) freed"
    }
}

struct DeletionSpaceNotice: View {
    let space: DeletionSpace

    var body: some View {
        Label {
            Text(space.message).font(.callout.weight(.semibold)).monospacedDigit()
        } icon: {
            Image(systemName: (space.bytes ?? 0) > 0 ? "checkmark.circle.fill" : "internaldrive")
                .foregroundStyle(StorageStyle.accent)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.secondary.opacity(0.2)))
        .accessibilityElement(children: .combine)
    }
}

struct ConfirmDeletionView: View {
    let entries: [StorageEntry]
    let confirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(entries.count == 1 ? "Permanently delete this file?" :
                    "Permanently delete \(StorageStyle.count(entries.count)) files?")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text("This permanently removes the selected files.")
                .foregroundStyle(.secondary)
            List(entries) { entry in
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.name).fontWeight(.medium).lineLimit(1)
                    Text(StorageStyle.location(entry.parent ?? entry.id.path))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                .help(entry.displayPath)
                .accessibilityElement(children: .combine)
            }
            .listStyle(.inset)
            .frame(height: min(224, CGFloat(entries.count) * 44 + 22))
            .accessibilityLabel("Files to Delete")
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.defaultAction)
                Button("Delete Permanently", role: .destructive, action: confirm)
            }
        }
        .padding(20)
        .frame(width: 478)
        .onExitCommand { dismiss() }
    }
}

struct DeletionFailuresView: View {
    let report: DeletionReport
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(report.method.failureTitle).font(.headline).accessibilityAddTraits(.isHeader)
            List(report.failures) { failure in
                VStack(alignment: .leading, spacing: 3) {
                    Text(failure.entry.name).fontWeight(.medium)
                    Text(StorageStyle.location(failure.entry.parent ?? failure.entry.id.path))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Text(failure.reason).font(.callout).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
            }
            .listStyle(.inset)
            .frame(height: min(280, CGFloat(report.failures.count) * 75 + 16))
            Button("Close") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(20)
        .frame(width: 478)
        .onExitCommand { dismiss() }
    }
}

struct DeletionStatusView: View {
    let model: DashboardModel
    @State private var showsFailures = false

    var body: some View {
        HStack(spacing: 8) {
            if let method = model.removalInProgress {
                ProgressView().controlSize(.small).accessibilityHidden(true)
                Text(method.progress)
            } else if let report = model.deletionReport {
                VStack(alignment: .leading, spacing: 3) {
                    Label(report.summary, systemImage: report.failures.isEmpty ? "checkmark.circle" : "exclamationmark.circle")
                    if report.hasItemsInTrash {
                        Text("Items still take up space in the Trash.")
                            .font(.caption)
                    }
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 0)
                if report.hasItemsInTrash {
                    Button("Open Trash") { NSWorkspace.shared.open(FileDeletion.trashDirectory) }
                        .fixedSize()
                }
                if !report.failures.isEmpty {
                    Button("Show Errors") { showsFailures = true }
                }
                Button { model.deletionReport = nil } label: {
                    Label("Dismiss Result", systemImage: "xmark").labelStyle(.iconOnly)
                }
            }
        }
        .foregroundStyle(.secondary)
        .font(.callout)
        .controlSize(.small)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $showsFailures) {
            if let report = model.deletionReport { DeletionFailuresView(report: report) }
        }
    }
}
