import AppKit
import SwiftUI
import DiskDiscovery

@MainActor
final class DiskWindowModel: ObservableObject {
    @Published var disks: [Disk] = []
    @Published var usage: [UInt64: DiskUsage] = [:]
    @Published var refreshing = false
    @Published var ejecting = false
    @Published var message: String?
    @Published var monitoringError: String?
    @Published var failures: [UInt64: String] = [:]
    @Published var blockers: [UInt64: BlockerReport] = [:]
    var refresh: () -> Void = {}
    var ejectAll: () -> Void = {}
}

struct CompactDiskWindow: View {
    @ObservedObject var model: DiskWindowModel

    var body: some View {
        VStack(spacing: 0) {
            if model.disks.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: model.monitoringError == nil ? "externaldrive" : "exclamationmark.triangle")
                        .font(.title2).foregroundStyle(.secondary)
                    Text(model.monitoringError == nil ? "No external disks or SD cards" : "Disk inventory unavailable")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 66)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.disks) { disk in
                            DiskRow(disk: disk, usage: model.usage[disk.id], error: model.failures[disk.id], report: model.blockers[disk.id])
                            if disk.id != model.disks.last?.id { Divider().padding(.leading, 39) }
                        }
                    }
                }
                .frame(height: min(CGFloat(model.disks.count) * 48, 240))
            }
            Divider()
            HStack(spacing: 8) {
                Button(action: model.refresh) {
                    Image(systemName: "arrow.clockwise").frame(width: 18, height: 18)
                }
                .buttonStyle(.borderless)
                .disabled(model.refreshing || model.ejecting)
                .help("Refresh disk details")
                .accessibilityLabel("Refresh disk details")
                Text(model.monitoringError ?? model.message ?? "\(model.disks.count) connected")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .help(model.monitoringError ?? model.message ?? "Monitoring continues when this window closes.")
                Spacer(minLength: 4)
                if model.ejecting { ProgressView().controlSize(.small).scaleEffect(0.8) }
                Button(model.ejecting ? "Ejecting…" : "Eject All", action: model.ejectAll)
                    .disabled(model.disks.isEmpty || model.ejecting || model.monitoringError != nil)
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .help("Eject all disks. If a disk is busy, save and close its documents and, if needed, quit the blocking app.")
            }
            .padding(.horizontal, 10).padding(.vertical, 9)
        }
        .font(.system(size: 12))
        .frame(width: 340)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct DiskRow: View {
    let disk: Disk
    let usage: DiskUsage?
    let error: String?
    let report: BlockerReport?
    @State private var hovering = false
    @State private var pinned = false

    private var details: Binding<Bool> {
        Binding(get: { hovering || pinned }, set: { presented in
            if !presented { hovering = false; pinned = false }
        })
    }

    var body: some View {
        Button { pinned.toggle() } label: {
            HStack(spacing: 9) {
                Image(systemName: disk.cardType != nil || disk.connection == .builtInSDReader ? "sdcard" : "externaldrive")
                    .font(.system(size: 21)).foregroundStyle(error == nil ? Color.accentColor : .orange)
                    .frame(width: 25)
                VStack(alignment: .leading, spacing: 3) {
                    Text(disk.name).fontWeight(.medium).lineLimit(1)
                    Text(bytes(disk.sizeBytes)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if let percent = usage?.percentUsed {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("\(percent, specifier: "%.0f")% full").monospacedDigit()
                        ProgressView(value: percent, total: 100).frame(width: 70).tint(percent > 90 ? .orange : .accentColor)
                    }
                } else {
                    Text(usage == nil ? "Reading…" : "Usage unavailable")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 11).frame(height: 47)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .popover(isPresented: details, arrowEdge: .trailing) {
            DiskDetails(disk: disk, usage: usage, error: error, report: report)
        }
        .accessibilityLabel("\(disk.name), \(bytes(disk.sizeBytes))")
        .accessibilityHint("Click to keep disk details open")
    }
}

struct DiskDetails: View {
    let disk: Disk
    let usage: DiskUsage?
    let error: String?
    var report: BlockerReport? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(disk.name).font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 7) {
                detail("Disk", disk.bsdName)
                detail("Capacity", bytes(disk.sizeBytes))
                detail("Connection", disk.connection == .builtInSDReader ? "Built-in SD reader" : disk.transport)
                detail(disk.link?.kind ?? "Link speed", disk.link?.value ?? "Not reported")
                detail("Card type", disk.cardType ?? "Not reported")
                if let used = usage?.usedBytes, let total = usage?.totalBytes, let free = usage?.freeBytes {
                    detail("Used", "\(bytes(used)) of \(bytes(total))")
                    detail("Free", bytes(free))
                }
            }
            if let reason = usage?.unavailableReason { Text(reason).foregroundStyle(.secondary) }
            if let error { Text(error).foregroundStyle(.orange) }
            if let report {
                ForEach(report.blockers) { blocker in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(blocker.name) · PID \(blocker.pid)").fontWeight(.medium)
                        Text(blocker.paths.joined(separator: "\n")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(report.limitations, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            }
            Text("Fullness is based on formatted space. Link rates are reported by macOS, not benchmarked.")
                .font(.caption).foregroundStyle(.secondary)
            if let usage {
                Text("Usage checked \(usage.sampledAt.formatted(date: .omitted, time: .standard))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12)).padding(16).frame(width: 286, alignment: .leading)
    }
    private func detail(_ name: String, _ value: String) -> some View {
        GridRow {
            Text(name).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}

func bytes(_ value: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
}
