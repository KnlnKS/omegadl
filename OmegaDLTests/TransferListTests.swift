import Foundation
import MegaKit
import Testing
@testable import OmegaDL

private func transfers(sized sizes: [Int]) -> [Transfer] {
    sizes.enumerated().map { offset, size in
        Transfer(
            serial: UInt32(offset + 1), job: .upload(URL(filePath: "/f"), parent: NodeHandle("AAAAAAAA")!),
            source: .account(email: "a"), name: "f", size: size
        )
    }
}

@Suite struct TransferListTests {
    @Test func `tallies queued transfers as they are appended`() {
        var list = TransferList()
        list.append(contentsOf: transfers(sized: [10, 20, 30]))
        #expect(list.queued == (3, 60, 0))
        #expect(list.activeCount == 3 && list.finishedCount == 0)
    }

    @Test func `moves tallies through a transfer's lifecycle`() {
        var list = TransferList()
        list.append(contentsOf: transfers(sized: [10, 20]))
        list.update(0) { $0.state = .running }
        #expect(list.queued == (1, 20, 0) && list.activeCount == 2)
        list.update(0) {
            $0.state = .failed
            $0.bytes = 4
        }
        #expect(list.finishedCount == 1 && list.activeCount == 1)
        list.update(0) { $0.state = .queued }
        #expect(list.queued == (2, 30, 4) && list.finishedCount == 0)
    }

    @Test func `finds the next queued transfer, including one requeued behind it`() {
        var list = TransferList()
        list.append(contentsOf: transfers(sized: [1, 1, 1, 1]))
        list.update(list.nextQueued()) { $0.state = .running }
        list.update(list.nextQueued()) { $0.state = .failed }
        #expect(list.nextQueued() == 2)
        list.update(1) { $0.state = .queued }
        #expect(list.nextQueued() == 1)
    }

    @Test func `keeps tallies and lookups right after removals`() {
        var list = TransferList()
        list.append(contentsOf: transfers(sized: [1, 2, 3, 4]))
        list.update(2) { $0.state = .completed }
        list.remove(RangeSet([0..<1, 2..<3]))
        #expect(list.transfers.map(\.serial) == [2, 4])
        #expect(list.queued == (2, 6, 0) && list.finishedCount == 0)
        #expect(list.index(of: 4) == 1 && list.index(of: 3) == nil)
        #expect(list.nextQueued() == 0)
    }
}
