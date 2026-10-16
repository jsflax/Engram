@testable import EngramKit
import Foundation
import Logging
import MCP
import Testing

@Suite("Native MCP shutdown ownership", .serialized)
struct MCPServerShutdownTests {
    @Test func receiveEOFWaitsForEnteredHandlerBeforeLifetimeRelease() async throws {
        let entered = ShutdownGate(), release = ShutdownGate(), returned = ShutdownGate()
        let transport = ShutdownTransport()
        let server = Server(name: "shutdown-fixture", version: "1")
        await server.withMethodHandler(ListTools.self) { _ in
            await entered.open()
            await release.wait() // Deliberately remains entered after cancellation.
            return ListTools.Result(tools: [])
        }
        try await server.start(transport: transport)
        await transport.emit(request)
        await entered.wait()
        await transport.finishInput()
        let owner = Task {
            let complete = await waitForMCPServerShutdown(server)
            await returned.open()
            return complete
        }
        await transport.disconnectEntered.wait()
        #expect(await returned.isOpen == false)
        #expect(await server.isShutdownComplete == false)
        await release.open()
        #expect(await owner.value)
        #expect(await returned.isOpen)
        #expect(await server.isShutdownComplete)
    }

    @Test func receiveEOFWaitsForResponseWriteBeforeLifetimeRelease() async throws {
        let release = ShutdownGate(), returned = ShutdownGate()
        let transport = ShutdownTransport(sendRelease: release)
        let server = Server(name: "shutdown-fixture", version: "1")
        await server.withMethodHandler(ListTools.self) { _ in ListTools.Result(tools: []) }
        try await server.start(transport: transport)
        await transport.emit(request)
        await transport.sendEntered.wait()
        await transport.finishInput()
        let owner = Task {
            let complete = await waitForMCPServerShutdown(server)
            await returned.open()
            return complete
        }
        await transport.disconnectEntered.wait()
        #expect(await returned.isOpen == false)
        #expect(await transport.activeSends == 1)
        await release.open()
        #expect(await owner.value)
        #expect(await transport.activeSends == 0)
        #expect(await server.isShutdownComplete)
    }

    @Test func enteredCallbackCannotReportFullShutdown() async throws {
        let entered = ShutdownGate(), reported = ShutdownResult()
        let transport = ShutdownTransport()
        let server = Server(name: "shutdown-fixture", version: "1")
        await server.withMethodHandler(ListTools.self) { _ in
            await entered.open()
            await reported.set(waitForMCPServerShutdown(server))
            return ListTools.Result(tools: [])
        }
        try await server.start(transport: transport)
        await transport.emit(request)
        await entered.wait()
        await transport.finishInput()
        await reported.ready.wait()
        #expect(await reported.value == false)
        #expect(await waitForMCPServerShutdown(server))
        #expect(await server.isShutdownComplete)
    }

    private var request: Data {
        Data(#"{"jsonrpc":"2.0","id":"fixture","method":"tools/list","params":{}}"#.utf8)
    }
}

private actor ShutdownGate {
    private(set) var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private actor ShutdownResult {
    let ready = ShutdownGate()
    private(set) var value: Bool?
    func set(_ value: Bool) async {
        self.value = value
        await ready.open()
    }
}

private actor ShutdownTransport: Transport {
    nonisolated let logger = Logger(label: "engram.shutdown-fixture", factory: { _ in SwiftLogNoOpLogHandler() })
    let disconnectEntered = ShutdownGate()
    let sendEntered = ShutdownGate()
    private let sendRelease: ShutdownGate?
    private let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var closed = false
    private(set) var activeSends = 0

    init(sendRelease: ShutdownGate? = nil) {
        self.sendRelease = sendRelease
        let pair = AsyncThrowingStream<Data, Error>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }
    func connect() async throws {}
    func send(_ data: Data) async throws {
        guard !closed else { throw CancellationError() }
        activeSends += 1
        defer { activeSends -= 1 }
        await sendEntered.open()
        if let sendRelease { await sendRelease.wait() }
        guard !closed else { throw CancellationError() }
    }
    func receive() -> AsyncThrowingStream<Data, Error> { stream }
    func disconnect() async {
        closed = true
        continuation.finish()
        await disconnectEntered.open()
    }
    func emit(_ data: Data) { continuation.yield(data) }
    func finishInput() { continuation.finish() }
}
