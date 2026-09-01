import MegaKit
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

    private var finishedCount: Int {
        manager.transfers.count { $0.isFinished }
    }

    var body: some View {
        content
            .navigationTitle("Transfers")
            .navigationSubtitle(subtitle)
            .toolbar {
                ToolbarItem {
                    Button("Clear") { manager.clearFinished() }
                        .disabled(finishedCount == 0)
                        .help("Remove finished transfers from the list")
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if manager.transfers.isEmpty {
            ContentUnavailableView {
                Label("No Transfers", systemImage: "arrow.down.circle")
            } description: {
                Text("Downloads and uploads appear here while they run.")
            }
        } else {
            List {
                ForEach(manager.transfers) { transfer in
                    TransferRow(transfer: transfer, manager: manager)
                        .listRowInsets(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
                }
            }
            .listStyle(.inset)
            .alternatingRowBackgrounds()
        }
    }

    private var subtitle: String {
        let active = manager.activeCount
        guard active > 0 else {
            return finishedCount == 0 ? "" : "\(finishedCount) finished"
        }
        let rate = manager.aggregateBytesPerSecond
        let label = active == 1 ? "1 active" : "\(active) active"
        return rate > 0 ? "\(label) — \(rateText(rate))" : label
    }
}

struct TransferRow: View {
    let transfer: Transfer
    let manager: TransferManager

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NodeIcon.image(named: transfer.name))
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

                if transfer.state == .running {
                    ProgressView(value: transfer.fraction)
                        .progressViewStyle(.linear)
                }

                Text(status)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(transfer.state.isFailure ? .red : .secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
            action
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(.rect)
        .onTapGesture(count: 2) {
            if transfer.state == .completed { manager.revealInFinder(transfer) }
        }
        .contextMenu {
            if transfer.state == .completed, !transfer.isUpload {
                Button("Show in Finder") { manager.revealInFinder(transfer) }
                Divider()
            }
            if transfer.isFinished, transfer.state != .completed {
                Button("Try Again") { manager.retry(transfer) }
                Divider()
            }
            Button(transfer.isFinished ? "Remove from List" : "Cancel", role: .destructive) {
                manager.remove(transfer)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(transfer.isUpload ? "Upload" : "Download"), \(transfer.name)")
        .accessibilityValue(status)
    }

    private var status: String {
        switch transfer.state {
        case .queued:
            "Waiting — \(transfer.size.formatted(.byteCount(style: .file)))"
        case .running:
            "\(byteText(transfer.bytesCompleted)) of \(byteText(transfer.size))"
                + (transfer.bytesPerSecond > 0 ? " — \(rateText(transfer.bytesPerSecond))" : "")
        case .completed:
            byteText(transfer.size)
        case .cancelled:
            "Cancelled"
        case .failed(let message):
            message
        }
    }

    @ViewBuilder
    private var action: some View {
        switch transfer.state {
        case .queued, .running:
            Button {
                manager.cancel(transfer)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Cancel")

        case .completed where !transfer.isUpload:
            Button {
                manager.revealInFinder(transfer)
            } label: {
                Image(systemName: "magnifyingglass.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Show in Finder")

        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.secondary)

        case .failed, .cancelled:
            Button {
                manager.retry(transfer)
            } label: {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Try Again")
        }
    }
}

func byteText(_ bytes: Int) -> String {
    bytes.formatted(.byteCount(style: .file, allowedUnits: .all, spellsOutZero: false))
}

func rateText(_ bytesPerSecond: Double) -> String {
    "\(byteText(Int(bytesPerSecond)))/s"
}
