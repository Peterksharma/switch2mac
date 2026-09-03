// WebSocketHub.swift
// Browser sink: re-broadcasts controller state over a local WebSocket so a
// small browser extension (browser/extension) can present the controllers to
// web games through the Gamepad API — Xbox Cloud Gaming, GeForce NOW, Luna,
// gamepad testers — with rumble flowing back. No entitlement, no root, no
// driver: it is the UDP/SDL bridge idea applied to the browser.
//
// Endpoint: ws://127.0.0.1:24810 (loopback only). Messages are JSON text:
//   hub → page:
//     {"t":"hello","v":1}
//     {"t":"connected","slot":0,"model":"Pro Controller 2","name":"…"}
//     {"t":"name","slot":0,"name":"…"}
//     {"t":"state","slot":0,"seq":123,"b":<Switch2.Buttons raw u32>,
//      "lx":…,"ly":…,"rx":…,"ry":…,"lt":0-255,"rt":0-255}   (y: +1 = up)
//     {"t":"disconnected","slot":0}
//     {"t":"ping"}   every 15 s (keeps extension service workers alive)
//   page → hub:
//     {"t":"rumble","slot":0,"strong":0…1,"weak":0…1}
//     {"t":"stats",…}   extension delivery telemetry, echoed to all clients
// Every new client receives "hello" plus one "connected"/"name" per
// currently connected player, so late joiners (a tab opened after the
// controller paired) see the full picture immediately.

import Foundation
import Network

final class WebSocketHub: ControllerOutputSink, @unchecked Sendable {

    static let port: UInt16 = 24810

    var onRumble: ((Int, Double, Double) -> Void)?

    private let queue = DispatchQueue(label: "com.petersharma.ftcw.wshub")
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: NWConnection] = [:]
    private var connected: [Int: (model: String, name: String)] = [:]
    private var seq: [Int: UInt32] = [:]
    private var lastState: [Int: (buttons: UInt32, packet: Data)] = [:]

    private var pingTimer: DispatchSourceTimer?

    init() {
        queue.async { [weak self] in
            self?.startListener()
            self?.startPing()
        }
    }

    /// Chrome unloads an idle extension service worker after ~30 s; a
    /// periodic message keeps the bridge's socket owner alive between inputs.
    private func startPing() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 15, repeating: 15)
        timer.setEventHandler { [weak self] in self?.broadcast(#"{"t":"ping"}"#) }
        timer.resume()
        pingTimer = timer
    }

    // MARK: Listener

    private func startListener() {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)

        let listener: NWListener
        do {
            listener = try NWListener(using: params)
        } catch {
            bridgeLog(.warning, "wshub", "cannot create listener (\(error)) — retrying in 5 s")
            queue.asyncAfter(deadline: .now() + 5) { [weak self] in self?.startListener() }
            return
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                bridgeLog(.info, "wshub", "browser bridge on ws://127.0.0.1:\(Self.port)")
            case .failed(let error):
                bridgeLog(.warning, "wshub", "listener failed (\(error)) — retrying in 5 s")
                listener.cancel()
                self.listener = nil
                self.queue.asyncAfter(deadline: .now() + 5) { [weak self] in self?.startListener() }
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.clients[id] = connection
                bridgeLog(.info, "wshub", "browser client connected (\(self.clients.count) total)")
                self.send(#"{"t":"hello","v":1}"#, to: connection)
                for (slot, info) in self.connected.sorted(by: { $0.key < $1.key }) {
                    self.send(Self.connectedMessage(slot: slot, model: info.model, name: info.name),
                              to: connection)
                }
                self.receive(on: connection)
            case .failed, .cancelled:
                if self.clients.removeValue(forKey: id) != nil {
                    bridgeLog(.info, "wshub", "browser client left (\(self.clients.count) total)")
                    // A page that disappears mid-rumble should not leave the
                    // controller buzzing.
                    for slot in self.connected.keys { self.onRumble?(slot, 0, 0) }
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.handle(data) }
            if error == nil, context?.isFinal != true {
                self.receive(on: connection)
            } else {
                connection.cancel()
            }
        }
    }

    private func handle(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["t"] as? String else { return }
        switch type {
        case "rumble":
            guard let slot = object["slot"] as? Int else { return }
            let strong = min(max((object["strong"] as? Double) ?? 0, 0), 1)
            let weak = min(max((object["weak"] as? Double) ?? 0, 0), 1)
            onRumble?(slot, strong, weak)
        case "stats":
            // Page-side delivery telemetry from the extension: log it and
            // echo to every client so it can be read outside the browser.
            bridgeLog(.debug, "wshub", "client stats: \(String(decoding: data, as: UTF8.self))")
            broadcast(String(decoding: data, as: UTF8.self))
        default:
            break
        }
    }

    // MARK: Sending

    private func send(_ text: String, to connection: NWConnection) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        connection.send(content: Data(text.utf8), contentContext: context,
                        isComplete: true, completion: .contentProcessed { _ in })
    }

    private func broadcast(_ text: String) {
        for connection in clients.values { send(text, to: connection) }
    }

    private static func connectedMessage(slot: Int, model: String, name: String) -> String {
        #"{"t":"connected","slot":\#(slot),"model":\#(json(model)),"name":\#(json(name))}"#
    }

    private static func json(_ string: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [string])) ?? Data("[\"\"]".utf8)
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }

    // MARK: ControllerOutputSink (called on the Bluetooth queue)

    func controllerConnected(slot: Int, model: Switch2.Model) {
        queue.async { [weak self] in
            guard let self else { return }
            let name = self.connected[slot]?.name ?? model.displayName
            self.connected[slot] = (model.displayName, name)
            self.seq[slot] = 0
            self.broadcast(Self.connectedMessage(slot: slot, model: model.displayName, name: name))
        }
    }

    func controllerDisconnected(slot: Int) {
        queue.async { [weak self] in
            guard let self, self.connected.removeValue(forKey: slot) != nil else { return }
            self.lastState.removeValue(forKey: slot)
            self.broadcast(#"{"t":"disconnected","slot":\#(slot)}"#)
        }
    }

    func controllerName(slot: Int, name: String) {
        queue.async { [weak self] in
            guard let self else { return }
            if let info = self.connected[slot] {
                guard info.name != name else { return }
                self.connected[slot] = (info.model, name)
                self.broadcast(#"{"t":"name","slot":\#(slot),"name":\#(Self.json(name))}"#)
            } else {
                self.connected[slot] = ("", name)
            }
        }
    }

    func controllerState(slot: Int, state: ControllerState) {
        queue.async { [weak self] in
            guard let self, !self.clients.isEmpty else { return }
            let next = (self.seq[slot] ?? 0) &+ 1
            self.seq[slot] = next
            let text = String(
                format: #"{"t":"state","slot":%d,"seq":%u,"b":%u,"lx":%.4f,"ly":%.4f,"rx":%.4f,"ry":%.4f,"lt":%d,"rt":%d}"#,
                slot, next, state.buttons.rawValue,
                state.leftStick.x, state.leftStick.y, state.rightStick.x, state.rightStick.y,
                Int(state.leftTrigger), Int(state.rightTrigger))
            self.broadcast(text)
        }
    }
}
