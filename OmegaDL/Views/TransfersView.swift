import MegaKit
import SwiftUI

struct TransfersButton: View {
    let manager: TransferManager
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Label("Transfers", systemImage: "arrow.down.circle")
                .overlay(alignment: .center) {
                    if manager.activeCount > 0 {
                        TransferRing(fraction: manager.aggregateFraction)
                    }
                }
        }
        .help("Transfers")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            TransfersList(manager: manager)
        }
    }
}

private struct TransferRing: View {
    let fraction: Double

    var body: some View {
        Circle()
            .trim(from: 0, to: max(0.02, fraction))
            .stroke(.tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .rotationEffect(.degrees(-90))
            .frame(width: 15, height: 15)
            .animation(.spring(duration: 0.35, bounce: 0), value: fraction)
    }
}

struct TransfersList: View {
    let manager: TransferManager

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if manager.transfers.isEmpty {
                ContentUnavailableView("No Transfers", systemImage: "arrow.down.circle")
                    .frame(height: 180)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(manager.transfers) { transfer in
                            TransferRow(transfer: transfer, manager: manager)
                            Divider().padding(.leading, 12)
                        }
                    }
                }
                .frame(height: min(320, Double(manager.transfers.count) * 58))
            }
        }
        .frame(width: 380)
    }

    private var header: some View {
        HStack {
            Text("Transfers").font(.headline)
            Spacer()
            if manager.aggregateBytesPerSecond > 0 {
                Text(rate: manager.aggregateBytesPerSecond)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Button("Clear") { manager.clearFinished() }
                .buttonStyle(.accessoryBar)
                .disabled(!manager.transfers.contains { $0.isFinished })
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct TransferRow: View {
    let transfer: Transfer
    let manager: TransferManager

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NodeIcon.image(for: transfer.node))
                .resizable()
                .frame(width: 24, height: 24)

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

        case .completed:
            Button {
                manager.revealInFinder(transfer)
            } label: {
                Image(systemName: "magnifyingglass.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Show in Finder")

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

extension Text {
    init(rate bytesPerSecond: Double) {
        self.init(rateText(bytesPerSecond))
    }
}

extension Transfer.State {
    var isFailure: Bool {
        if case .failed = self { true } else { false }
    }
}
