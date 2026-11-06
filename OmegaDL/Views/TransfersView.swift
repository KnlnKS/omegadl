import AppKit
import SwiftUI

struct TransferRing: View {
    let fraction: Double
    @Environment(\.fluidAnimation) private var fluidAnimation

    var body: some View {
        Circle()
            .trim(from: 0, to: max(0.02, fraction))
            .stroke(.tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .rotationEffect(.degrees(-90))
            .frame(width: 15, height: 15)
            .animation(fluidAnimation, value: fraction)
            .accessibilityHidden(true)
    }
}

struct TransfersView: View {
    let manager: TransferManager

    var body: some View {
        TransferRows(manager: manager)
            .navigationTitle("Transfers")
            .navigationSubtitle(subtitle)
            .toolbar {
                ToolbarItem {
                    Button("Clear") { manager.clearFinished() }
                        .disabled(manager.list.finishedCount == 0)
                        .help("Remove finished transfers from the list")
                }
            }
    }

    private var subtitle: String {
        let active = manager.list.activeCount
        guard active > 0 else {
            return manager.list.finishedCount == 0 ? "" : "\(manager.list.finishedCount) finished"
        }
        let rate = manager.aggregateBytesPerSecond
        let label = active == 1 ? "1 active" : "\(active) active"
        return rate > 0 ? "\(label) — \(rateText(rate))" : label
    }
}

/// Separate from the subtitle, which changes every progress tick, so the list re-renders only when transfers change.
private struct TransferRows: View {
    let manager: TransferManager

    var body: some View {
        if manager.list.transfers.isEmpty {
            ContentUnavailableView {
                Label("No Transfers", systemImage: "arrow.up.arrow.down")
            } description: {
                Text("Downloads and uploads appear here")
            }
        } else {
            List {
                ForEach(manager.list.transfers, id: \.serial) { transfer in
                    TransferRow(transfer: transfer, manager: manager)
                        .listRowInsets(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
                }
            }
            .listStyle(.inset)
            .alternatingRowBackgrounds()
        }
    }
}

private struct TransferRow: View {
    let transfer: Transfer
    let manager: TransferManager

    /// Only running rows read the manager's runs, so progress re-renders nothing else.
    private var run: TransferManager.Run? {
        transfer.state == .running ? manager.run(transfer.serial) : nil
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NodeIcon.image(named: transfer.name, isDirectory: transfer.isFolder))
                .resizable()
                .frame(width: 24, height: 24)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: transfer.isUpload ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.white, Color.accentColor)
                        .offset(x: 3, y: 3)
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(transfer.name)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let run, !transfer.isFolder {
                    ProgressView(value: transfer.size > 0 ? min(1, Double(run.bytes) / Double(transfer.size)) : 0)
                        .progressViewStyle(.linear)
                }

                Text(status)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(transfer.state == .failed ? .red : .secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
            action
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(.rect)
        .onTapGesture(count: 2) {
            if transfer.state == .completed { reveal() }
        }
        .contextMenu {
            if transfer.state == .completed, !transfer.isUpload {
                Button("Show in Finder", action: reveal)
                Divider()
            }
            if transfer.state == .failed || transfer.state == .cancelled {
                Button("Try Again") { manager.retry(transfer.serial) }
                Divider()
            }
            if transfer.state.isFinished {
                Button("Remove from List", role: .destructive) { manager.remove(transfer.serial) }
            } else {
                Button("Cancel", role: .destructive) { manager.cancel(transfer.serial) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(transfer.isUpload ? "Upload" : "Download"), \(transfer.name)")
        .accessibilityValue(status)
    }

    private var status: String {
        switch transfer.state {
        case .queued where transfer.isFolder:
            "Waiting"
        case .queued:
            "Waiting — \(byteText(transfer.size))"
        case .running where transfer.isFolder:
            "Creating folder…"
        case .running:
            "\(byteText(run?.bytes ?? transfer.bytes)) of \(byteText(transfer.size))\(rate)"
        case .completed where transfer.isFolder:
            "Folder created"
        case .completed:
            byteText(transfer.size)
        case .cancelled:
            "Cancelled"
        case .failed:
            transfer.failure
        }
    }

    @ViewBuilder
    private var action: some View {
        switch transfer.state {
        case .queued, .running:
            iconButton("xmark.circle.fill", help: "Cancel") { manager.cancel(transfer.serial) }

        case .completed where !transfer.isUpload:
            iconButton("magnifyingglass.circle.fill", help: "Show in Finder", action: reveal)

        case .completed:
            icon("checkmark.circle.fill")

        case .failed, .cancelled:
            iconButton("arrow.clockwise.circle.fill", help: "Try Again") { manager.retry(transfer.serial) }
        }
    }

    private var rate: String {
        guard let speed = run?.bytesPerSecond, speed > 0 else { return "" }
        return " — \(rateText(speed))"
    }

    private func reveal() {
        if let destination = transfer.destination { NSWorkspace.shared.activateFileViewerSelecting([destination]) }
    }

    private func icon(_ symbol: String) -> some View {
        Image(systemName: symbol).foregroundStyle(.secondary)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { icon(symbol) }
            .buttonStyle(.plain)
            .help(help)
    }
}
