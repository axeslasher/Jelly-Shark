import Foundation
import JellyfinAPI
@testable import JellyfinKit
import Synchronization
import Testing

@Suite("ServerDiscovery")
struct ServerDiscoveryTests {
    // MARK: - Wire format

    @Test("The probe datagram is the bare protocol string, sent to port 7359")
    func probeDatagramMatchesTheProtocol() {
        // Both values come from the server's own AutoDiscoveryHost: a const 7359, and
        // a Contains() check against this exact string. A typo in either is invisible
        // until someone tries it on a real network.
        #expect(ServerDiscoveryMessage.port == 7359)
        #expect(ServerDiscoveryMessage.probePayload == Data("who is JellyfinServer?".utf8))
        #expect(ServerDiscoveryMessage.probePayload.count == 22)
    }

    @Test("The probe reaches the transport unchanged")
    func probeIsHandedToTheTransportVerbatim() async {
        let log = ProbeLog()
        let discovery = ServerDiscovery(transport: FakeTransport(log: log), window: ImmediateWindow())

        _ = await discovery.discoverServers(within: .seconds(60))

        #expect(log.recorded?.payload == Data("who is JellyfinServer?".utf8))
        #expect(log.recorded?.port == 7359)
    }

    // MARK: - Reply decoding

    @Test("A server's reply decodes into ServerDiscoveryInfo and maps to a pick-list entry")
    func replyDecodesIntoADiscoveredServer() async {
        // The shape System.Text.Json emits for ServerDiscoveryInfo(localUrl, SystemId,
        // FriendlyName) with default options: PascalCase keys, and EndpointAddress
        // always null because the server never populates it.
        let reply = Data(#"""
        {"Address":"http://192.168.1.50:8096","Id":"a1b2c3","Name":"Living Room","EndpointAddress":null}
        """#.utf8)

        let info = try? JSONDecoder().decode(ServerDiscoveryInfo.self, from: reply)
        #expect(info?.address == "http://192.168.1.50:8096")
        #expect(info?.id == "a1b2c3")
        #expect(info?.name == "Living Room")
        #expect(info?.endpointAddress == nil)

        let servers = await collect([reply])
        #expect(servers == [
            DiscoveredServer(id: "a1b2c3", name: "Living Room", address: "http://192.168.1.50:8096"),
        ])
    }

    @Test("Malformed replies are dropped without taking the round down with them")
    func malformedRepliesAreDropped() async {
        let servers = await collect([
            Data(),
            // A broadcast port hears whatever else is shouting on the network.
            Data("not json at all".utf8),
            Data(#"{"Address":"http://10.0.0.9:8096""#.utf8),
            // Decodes, but there is nothing to dedup on...
            Data(#"{"Address":"http://10.0.0.9:8096","Name":"No id"}"#.utf8),
            // ...and nothing to connect to.
            Data(#"{"Id":"server-b","Name":"No address"}"#.utf8),
            Data(#"{"Address":"   ","Id":"  ","Name":"Blank"}"#.utf8),
            reply(id: "server-a", name: "Attic", address: "http://10.0.0.4:8096"),
        ])

        #expect(servers.map(\.id) == ["server-a"])
    }

    @Test("A nameless server falls back to its address rather than a blank row")
    func namelessServerFallsBackToItsAddress() async {
        let servers = await collect([reply(id: "server-a", name: "", address: "http://10.0.0.4:8096")])

        #expect(servers.first?.name == "http://10.0.0.4:8096")
    }

    @Test("Duplicate ids collapse, first reply winning")
    func duplicateIDsCollapse() async {
        // What a multi-homed server looks like: the same server answering the probe
        // once per network it heard it on, with a different address each time.
        let servers = await collect([
            reply(id: "same-server", name: "Basement", address: "http://10.0.0.4:8096"),
            reply(id: "same-server", name: "Basement", address: "http://192.168.1.4:8096"),
            reply(id: "other-server", name: "Attic", address: "http://10.0.0.9:8096"),
        ])

        #expect(servers.map(\.id) == ["same-server", "other-server"])
        #expect(servers.first?.address == "http://10.0.0.4:8096")
    }

    // MARK: - The collection window

    @Test("A silent network returns empty once the window elapses")
    func silentNetworkReturnsEmpty() async {
        // The stream never yields and never finishes, so only the window can end this
        // round — which is the point: no sleeping, no timing assertion, just proof
        // that the window, not a reply, is what ends it.
        let discovery = ServerDiscovery(
            transport: FakeTransport(datagrams: [], finishesStream: false),
            window: ImmediateWindow(),
        )

        #expect(await discovery.discoverServers(within: .seconds(60)).isEmpty)
    }

    @Test("A refused socket resolves to empty rather than an error")
    func refusedSocketResolvesToEmpty() async {
        // The contract #30 depends on: discovery failing must never be something the
        // connect screen has to handle, or a denied permission would block manual entry.
        let discovery = ServerDiscovery(
            transport: FakeTransport(failure: .socketUnavailable(errno: EPERM)),
            window: ImmediateWindow(),
        )

        #expect(await discovery.discoverServers().isEmpty)
    }

    @Test("A cancelled call returns instead of hanging on the window")
    func cancelledCallReturns() async {
        // Nothing is collected on either path here — the call returns early if the
        // cancellation lands before the probe, and the group is torn down if it lands
        // after. That "what had already arrived is still returned" is covered by the
        // tests above, where the stream ends the round instead of the window: there is
        // no race-free way to assert a datagram landed *before* a cancellation.
        let discovery = ServerDiscovery(
            transport: FakeTransport(datagrams: [], finishesStream: false),
            window: HangingWindow(),
        )

        let task = Task { await discovery.discoverServers(within: .seconds(60)) }
        task.cancel()

        #expect(await task.value.isEmpty)
    }

    // MARK: - Broadcast addressing

    @Test("A subnet's broadcast address is the host with the mask bits inverted")
    func subnetBroadcastAddresses() {
        #expect(broadcast(host: "192.168.1.50", netmask: "255.255.255.0") == "192.168.1.255")
        #expect(broadcast(host: "10.0.5.9", netmask: "255.255.0.0") == "10.0.255.255")
        #expect(broadcast(host: "172.16.3.4", netmask: "255.240.0.0") == "172.31.255.255")
        #expect(broadcast(host: "192.168.1.50", netmask: "255.255.255.252") == "192.168.1.51")
    }

    @Test("Masks with no meaningful directed broadcast are skipped")
    func degenerateMasksAreSkipped() {
        // A /32's broadcast address is the host itself, and a /0's is 255.255.255.255,
        // which every probe goes to anyway.
        #expect(broadcast(host: "192.168.1.50", netmask: "255.255.255.255") == nil)
        #expect(broadcast(host: "192.168.1.50", netmask: "0.0.0.0") == nil)
    }
}

// MARK: - Helpers

private extension ServerDiscoveryTests {
    /// Runs a round whose replies are `datagrams` and whose stream — not window — ends
    /// it, so every datagram is guaranteed to have been collected before the result is
    /// read back.
    func collect(_ datagrams: [Data]) async -> [DiscoveredServer] {
        let discovery = ServerDiscovery(
            transport: FakeTransport(datagrams: datagrams),
            window: HangingWindow(),
        )
        return await discovery.discoverServers(within: .seconds(60))
    }

    func reply(id: String, name: String, address: String) -> Data {
        Data(#"{"Address":"\#(address)","Id":"\#(id)","Name":"\#(name)","EndpointAddress":null}"#.utf8)
    }

    func broadcast(host: String, netmask: String) -> String? {
        guard let host = parseIPv4(host),
              let netmask = parseIPv4(netmask),
              let broadcast = IPv4Broadcast.address(host: host, netmask: netmask)
        else { return nil }
        return formatIPv4(broadcast)
    }

    func parseIPv4(_ text: String) -> UInt32? {
        var address = in_addr()
        guard inet_pton(AF_INET, text, &address) == 1 else { return nil }
        return address.s_addr
    }

    func formatIPv4(_ value: UInt32) -> String {
        var address = in_addr(s_addr: value)
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buffer)
    }
}

/// A transport that never touches the network — which also keeps the host suite from
/// tripping macOS's own local-network prompt.
private struct FakeTransport: DiscoveryTransport {
    var datagrams: [Data] = []
    /// When false the stream stays open forever, so only the window (or a
    /// cancellation) can end the round.
    var finishesStream = true
    var failure: DiscoveryFailure?
    var log: ProbeLog?

    func probe(payload: Data, port: UInt16) throws(DiscoveryFailure) -> AsyncStream<Data> {
        log?.record(payload: payload, port: port)
        if let failure {
            throw failure
        }

        return AsyncStream { continuation in
            for datagram in datagrams {
                continuation.yield(datagram)
            }
            if finishesStream {
                continuation.finish()
            }
        }
    }
}

/// Records what the transport was asked to send. Locked because `probe` is called from
/// inside the discovery round, not from the test's own thread.
private final class ProbeLog: Sendable {
    private let state = Mutex<(payload: Data, port: UInt16)?>(nil)

    var recorded: (payload: Data, port: UInt16)? {
        state.withLock { $0 }
    }

    func record(payload: Data, port: UInt16) {
        state.withLock { $0 = (payload, port) }
    }
}

/// A window that elapses at once: stands in for a round that timed out.
private struct ImmediateWindow: DiscoveryWindow {
    func wait(_: Duration) async {}
}

/// A window that never elapses on its own, so the transport is what ends the round.
/// The sleep is bounded only so a broken teardown fails the suite instead of wedging
/// it forever; when the round ends normally this is cancelled immediately.
private struct HangingWindow: DiscoveryWindow {
    func wait(_: Duration) async {
        try? await Task.sleep(for: .seconds(60))
    }
}
