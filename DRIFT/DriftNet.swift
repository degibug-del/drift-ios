// DriftNet.swift — the native multiplayer client.
//
// Talks to the same Durable Object the browser does (workers/drift-mp/worker.js), speaks
// the same JSON, and joins the same rooms. A native player and a browser player in "flow"
// are in one room and see each other; there is no separate native matchmaking.
//
// THREADING. URLSessionWebSocketTask delivers on a background queue and SpriteKit's update
// runs on main. Rather than lock, every inbound message is hopped to main and the scene
// reads plain properties — the scene is a main-thread reader of main-thread state, so there
// is nothing to synchronise. Sends go straight from main, which is where input happens.
//
// WHAT IS NOT SENT. Particles never cross the wire. Both ends generate the field from
// (seed, tick) with the same PRNG — see Mulberry in DriftCore, checked against the JS to
// nine decimals. Only attractors, names and scores are transmitted: about 40 bytes per
// player per tick against ~100KB/s if the field were streamed.

import Foundation
import CoreGraphics

/// One other participant, in FIELD coordinates. The scene converts to screen.
struct RemoteActor: Identifiable {
    let id: String
    let name: String
    var x: CGFloat
    var y: CGFloat
    var score: Int
    var isBot: Bool
    var hue: String
}

final class DriftNet {

    static let host = "phronesis-drift-mp.degibug.workers.dev"

    private var task: URLSessionWebSocketTask?
    private var sendTimer: TimeInterval = 0
    private(set) var connected = false
    private(set) var youID: String?

    /// Read by the scene each frame, on main. Written only on main.
    private(set) var actors: [RemoteActor] = []
    private(set) var seed: UInt32 = 0
    private(set) var tick: Int = 0
    private(set) var roundEndsAt: Date?

    /// Called once the server has accepted us and sent the field seed, so the scene can
    /// start a round on the SAME field everyone else is playing.
    var onWelcome: ((UInt32) -> Void)?
    var onRoundReset: ((UInt32) -> Void)?
    var onError: ((String) -> Void)?

    // ── connection ───────────────────────────────────────────────────────────
    func connect(server: String, name: String) {
        var c = URLComponents()
        c.scheme = "wss"
        c.host = Self.host
        c.path = "/ws"
        c.queryItems = [.init(name: "server", value: server), .init(name: "name", value: name)]
        guard let url = c.url else { onError?("bad server url"); return }

        let t = URLSession.shared.webSocketTask(with: url)
        task = t
        t.resume()
        receive()
    }

    func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        connected = false
        actors = []
        youID = nil
    }

    /// Recursive receive. URLSessionWebSocketTask delivers exactly one message per call, so
    /// each handler must re-arm — forgetting to is the classic way a socket goes quiet
    /// after the first frame while still appearing connected.
    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let e):
                DispatchQueue.main.async {
                    self.connected = false
                    // No auto-reconnect: a silent retry loop against a full or missing
                    // server hides the failure and burns battery. The UI says so instead.
                    self.onError?(e.localizedDescription)
                }
            case .success(let msg):
                if case let .string(s) = msg { self.handle(s) }
                self.receive()
            }
        }
    }

    private func handle(_ raw: String) {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let t = obj["t"] as? String else { return }

        DispatchQueue.main.async {
            switch t {
            case "welcome":
                self.connected = true
                self.youID = obj["you"] as? String
                let s = (obj["seed"] as? NSNumber)?.uint32Value ?? 0
                self.seed = s
                if let ends = obj["roundEndsAt"] as? Double {
                    self.roundEndsAt = Date(timeIntervalSince1970: ends / 1000)
                }
                self.onWelcome?(s)

            case "state":
                self.tick = (obj["k"] as? NSNumber)?.intValue ?? self.tick
                guard let arr = obj["a"] as? [[String: Any]] else { return }
                self.actors = arr.compactMap { a in
                    guard let id = a["i"] as? String else { return nil }
                    return RemoteActor(
                        id: id,
                        name: (a["n"] as? String) ?? "drifter",
                        x: CGFloat((a["x"] as? NSNumber)?.doubleValue ?? 0),
                        y: CGFloat((a["y"] as? NSNumber)?.doubleValue ?? 0),
                        score: (a["s"] as? NSNumber)?.intValue ?? 0,
                        isBot: ((a["b"] as? NSNumber)?.intValue ?? 0) == 1,
                        hue: (a["h"] as? String) ?? "#3A6FBE")
                }

            case "round":
                let s = (obj["seed"] as? NSNumber)?.uint32Value ?? 0
                self.seed = s
                self.tick = 0
                if let ends = obj["roundEndsAt"] as? Double {
                    self.roundEndsAt = Date(timeIntervalSince1970: ends / 1000)
                }
                self.onRoundReset?(s)

            default: break
            }
        }
    }

    // ── outbound ─────────────────────────────────────────────────────────────
    /// Called every frame with the attractor in FIELD coords; throttled to 20Hz here so
    /// callers do not have to care. The server ticks at 15 and caps movement, so sending
    /// faster buys nothing and costs battery.
    func sendInput(_ p: CGPoint, dt: TimeInterval) {
        guard connected else { return }
        sendTimer += dt
        guard sendTimer >= 1.0 / 20.0 else { return }
        sendTimer = 0
        send(["t": "input", "x": Int(p.x), "y": Int(p.y)])
    }

    /// Tell the server a cluster was taken. It checks the claim is near and recent, so an
    /// inflated value is refused rather than trusted.
    func claim(at p: CGPoint, value: Int) {
        guard connected else { return }
        send(["t": "claim", "x": Int(p.x), "y": Int(p.y), "value": value, "tick": tick])
    }

    private func send(_ dict: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: dict),
              let s = String(data: d, encoding: .utf8) else { return }
        task?.send(.string(s)) { _ in }   // fire and forget: a dropped input is one frame
    }

    /// Everyone but us, best first — the live board. Bots included, because they are
    /// competing for real and hiding them would misrepresent the standings.
    func board(limit: Int = 6) -> [RemoteActor] {
        actors.sorted { $0.score > $1.score }.prefix(limit).map { $0 }
    }

    var others: [RemoteActor] {
        guard let me = youID else { return actors }
        return actors.filter { $0.id != me }
    }
}
