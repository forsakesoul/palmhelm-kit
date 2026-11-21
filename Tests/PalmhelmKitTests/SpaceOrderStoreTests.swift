import Testing
import Foundation
@testable import PalmhelmKit

// #98 偏好存储：roundtrip、损坏与未知版本回退为空、与其它偏好键隔离。
@Suite struct SpaceOrderStoreTests {
    private func defaults() -> (UserDefaults, String) {
        let name = "space-order-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test func roundTripKeepsOrderPinsAndPromotions() {
        let (d, name) = defaults()
        defer { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        let store = SpaceOrderStore(defaults: d)
        var doc = SpaceOrderDocument()
        doc.state.layout = ["b", "a"]
        doc.state.pinned = ["c"]
        doc.state.promoted = ["b"]
        doc.fingerprints["b"] = SpaceFingerprint(label: "beta", terminalIds: ["t1"])
        #expect(store.save(doc))
        #expect(SpaceOrderStore(defaults: d).load() == doc)
    }

    @Test func corruptDataFallsBackToEmpty() {
        let (d, name) = defaults()
        defer { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        d.set(Data("not json".utf8), forKey: SpaceOrderStore.defaultKey)
        #expect(SpaceOrderStore(defaults: d).load() == SpaceOrderDocument())
    }

    @Test func unknownVersionFallsBackToEmpty() throws {
        let (d, name) = defaults()
        defer { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        var doc = SpaceOrderDocument()
        doc.version = 99
        d.set(try JSONEncoder().encode(doc), forKey: SpaceOrderStore.defaultKey)
        #expect(SpaceOrderStore(defaults: d).load() == SpaceOrderDocument())
    }

    @Test func clearRemovesOnlyTheSpaceKey() throws {
        let (d, name) = defaults()
        defer { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        d.set(Data("archive".utf8), forKey: "palmhelm.threadArchive.v1")
        let store = SpaceOrderStore(defaults: d)
        store.save(SpaceOrderDocument())
        store.clear()
        #expect(store.load() == SpaceOrderDocument())
        #expect(d.data(forKey: "palmhelm.threadArchive.v1") == Data("archive".utf8), "other keys are untouched")
    }

    @Test func keyIsIsolatedFromTheArchiveStore() {
        #expect(SpaceOrderStore.defaultKey == "palmhelm.spaceOrder.v1")
        #expect(SpaceOrderStore.defaultKey != "palmhelm.threadArchive.v1")
    }
}
