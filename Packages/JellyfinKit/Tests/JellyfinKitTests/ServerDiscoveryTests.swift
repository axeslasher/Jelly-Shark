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

    @Test("Replies still in hand when the window elapses are returned")
    func windowEndsTheRoundWithRepliesCollected() async {
        // The production shape, and the one no other test here covers: a socket never
        // closes itself, so on a real network it is always the window that ends the
        // round, with the reply stream still open underneath it.
        let gate = HandshakeGate()
        let discovery = ServerDiscovery(
            transport: PendingReplyTransport(
                datagrams: [
                    reply(id: "server-a", name: "Attic", address: "http://10.0.0.4:8096"),
                    reply(id: "server-b", name: "Basement", address: "http://10.0.0.9:8096"),
                ],
                gate: gate,
            ),
            window: GatedWindow(gate: gate),
        )

        let servers = await discovery.discoverServers(within: .seconds(60))

        #expect(servers.map(\.id) == ["server-a", "server-b"])
    }

    @Test("A cancelled round returns the replies it had already collected")
    func cancelledRoundReturnsWhatItCollected() async {
        // Gated on the handshake, so the cancellation provably lands after the reply
        // was accepted and while the window is still open. That is the teardown path —
        // not the early return at the top of discoverServers, which an ungated cancel
        // would hit about as often.
        let gate = HandshakeGate()
        let discovery = ServerDiscovery(
            transport: PendingReplyTransport(
                datagrams: [reply(id: "server-a", name: "Attic", address: "http://10.0.0.4:8096")],
                gate: gate,
            ),
            window: HangingWindow(),
        )

        let task = Task { await discovery.discoverServers(within: .seconds(60)) }
        await gate.waitUntilOpen()
        task.cancel()

        #expect(await task.value.map(\.id) == ["server-a"])
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
    func degenerateMasksAreSkipped() throws {
        // Asserted against the function itself rather than through the dotted-quad
        // helper, whose nil would also be what a failed parse looks like.
        let host = try #require(parseIPv4("192.168.1.50"))

        // A /32's broadcast address is the host itself...
        #expect(IPv4Broadcast.address(host: host, netmask: .max) == nil)
        // ...and a /0's is 255.255.255.255, which every probe goes to anyway.
        #expect(IPv4Broadcast.address(host: host, netmask: 0) == nil)
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

/// A transport whose reply stream never ends on its own, like a real socket's, and
/// which hands back a signal once every reply it was given has provably been taken by
/// the collector.
///
/// The proof is a handshake rather than a timer. The stream buffers exactly one
/// element, so `yield` reports `.dropped` until the consumer has taken the previous
/// one; a trailing datagram that decodes to nothing is yielded last, and its
/// acceptance into the buffer is what proves the final real reply was consumed.
private struct PendingReplyTransport: DiscoveryTransport {
    let datagrams: [Data]
    let gate: HandshakeGate

    func probe(payload _: Data, port _: UInt16) throws(DiscoveryFailure) -> AsyncStream<Data> {
        AsyncStream(bufferingPolicy: .bufferingOldest(1)) { continuation in
            Task {
                for datagram in datagrams {
                    await enqueue(datagram, into: continuation)
                }
                await enqueue(Data("handshake".utf8), into: continuation)
                gate.open()
                // Deliberately never finished: only the window can end this round.
            }
        }
    }

    private func enqueue(_ datagram: Data, into continuation: AsyncStream<Data>.Continuation) async {
        while true {
            switch continuation.yield(datagram) {
            case .dropped:
                await Task.yield()
            default:
                return
            }
        }
    }
}

/// A one-shot signal: opened by the transport, awaited by a window or by the test.
private final class HandshakeGate: Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        (stream, continuation) = AsyncStream<Void>.makeStream()
    }

    func open() {
        continuation.finish()
    }

    func waitUntilOpen() async {
        for await _ in stream {}
    }
}

/// A window that elapses the moment the transport says every reply has landed.
private struct GatedWindow: DiscoveryWindow {
    let gate: HandshakeGate

    func wait(_: Duration) async {
        await gate.waitUntilOpen()
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
