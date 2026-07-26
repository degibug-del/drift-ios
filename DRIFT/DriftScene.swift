// DriftScene.swift — the renderer over DriftCore.
//
// Everything here is drawing and input. No game rule lives in this file: the scene reads
// the simulation and shows it, and hands touches back as an attractor position. If a
// question is "how does the game behave", the answer is in DriftCore; if it is "what does
// it look like", it is here. That separation is why the core can be tested at all.
//
// PARTICLES ARE ONE NODE, NOT NINE HUNDRED. The obvious port gives every particle an
// SKSpriteNode and updates them each frame; at 900 particles that is 900 nodes with
// per-node transform maths and it drops frames on older phones. Instead the whole field is
// drawn into a single SKShapeNode-free custom node using one CGPath rebuilt per frame,
// which is a single draw call. The field is uniform dots, so nothing is lost.

import SpriteKit
import UIKit

/// Draws the particle field in one pass.
final class FieldNode: SKNode {
    private let layer = CAShapeLayer()
    private var texNode: SKSpriteNode?
    private var size: CGSize = .zero

    /// Renders the field to a texture each frame. One upload beats 900 node transforms, and
    /// keeps the particle count a tuning decision rather than a performance cliff.
    func render(particles: [Particle], in size: CGSize, scale: CGFloat, tint: UIColor) {
        guard size.width > 0 else { return }
        let renderer = UIGraphicsImageRenderer(size: size)
        let img = renderer.image { ctx in
            let c = ctx.cgContext
            c.setFillColor(tint.cgColor)
            for p in particles where !p.captured {
                let r = p.r * scale
                c.fillEllipse(in: CGRect(x: p.x * scale - r, y: p.y * scale - r,
                                         width: r * 2, height: r * 2))
            }
        }
        let tex = SKTexture(image: img)
        if let n = texNode {
            n.texture = tex
            n.size = size
        } else {
            let n = SKSpriteNode(texture: tex)
            n.anchorPoint = .zero
            n.size = size
            addChild(n)
            texNode = n
        }
    }
}

final class DriftScene: SKScene {

    private var sim: DriftSim
    private let field = FieldNode()
    private var attractorNode: SKShapeNode?
    private var scoreLabel: SKLabelNode?
    private var timerLabel: SKLabelNode?
    private var comboLabel: SKLabelNode?
    private var last: TimeInterval = 0

    /// Field-to-screen scale, letterboxed so the playable area is identical on every device.
    /// Without this a larger screen would literally see more of the world, which in
    /// multiplayer is an advantage bought with hardware.
    private var fieldScale: CGFloat = 1
    private var fieldOrigin: CGPoint = .zero

    private let onRoundEnd: (Int) -> Void

    /// Non-nil in an online round. The scene never creates it — DriftApp connects and hands
    /// it over already welcomed, so the scene can be built on the server's seed rather than
    /// starting on a private field and jumping to the shared one a moment later.
    var net: DriftNet?
    private var remoteNodes: [String: RemoteNode] = [:]
    private var boardLabel: SKLabelNode?

    init(size: CGSize, seed: UInt32, playerClass: PlayerClass, onRoundEnd: @escaping (Int) -> Void) {
        self.sim = DriftSim(seed: seed, playerClass: playerClass)
        self.onRoundEnd = onRoundEnd
        super.init(size: size)
        scaleMode = .resizeFill
        backgroundColor = .black
    }

    required init?(coder: NSCoder) { fatalError("not from a storyboard") }

    override func didMove(to view: SKView) {
        recomputeScale()

        addChild(field)
        field.position = fieldOrigin

        // The player's attractor. A ring rather than a dot: the capture radius is the thing
        // the player is actually aiming, so it should be the thing they can see.
        //
        // Built through rebuildAttractor rather than inline, because didChangeSize can fire
        // BEFORE didMove — SwiftUI lays the SKView out on its own schedule. Constructing a
        // ring here as well left two on screen, the orphan sitting at the origin in the
        // bottom-left corner. Seen on the simulator, not reasoned about.
        rebuildAttractor()

        scoreLabel = hud(size: 34, weight: .semibold)
        scoreLabel?.horizontalAlignmentMode = .left
        addChild(scoreLabel!)

        comboLabel = hud(size: 15, weight: .regular)
        comboLabel?.horizontalAlignmentMode = .left
        addChild(comboLabel!)

        timerLabel = hud(size: 18, weight: .regular)
        timerLabel?.horizontalAlignmentMode = .right
        addChild(timerLabel!)
        layoutHUD()
    }

    private func hud(size: CGFloat, weight: UIFont.Weight) -> SKLabelNode {
        let l = SKLabelNode(fontNamed: "Menlo")
        l.fontSize = size
        l.fontColor = UIColor(white: 0.94, alpha: 0.92)
        l.verticalAlignmentMode = .center
        return l
    }

    /// Re-seed onto a different field, keeping the class and the scene graph. Used when the
    /// server sends its seed at welcome and again at every round rollover — from the
    /// scene's side both are the same event: "you are now on this field, not that one".
    func restart(seed: UInt32) {
        sim = DriftSim(seed: seed, playerClass: sim.playerClass)
        last = 0        // otherwise the next dt is the whole interval since the socket opened
    }

    private func recomputeScale() {
        let s = min(size.width / FieldSize.width, size.height / FieldSize.height)
        fieldScale = s
        fieldOrigin = CGPoint(x: (size.width - FieldSize.width * s) / 2,
                              y: (size.height - FieldSize.height * s) / 2)
    }

    /// SpriteKit calls this whenever the scene resizes — including the FIRST real layout.
    ///
    /// This is load-bearing, not defensive. Inside SwiftUI's UIViewRepresentable the SKView
    /// is created at zero size and laid out afterwards, so didMove(to:) runs against a 0x0
    /// scene: fieldScale computes to 0, FieldNode.render early-returns on a zero-width
    /// canvas, and the HUD lands at negative coordinates. The result is a completely black
    /// screen with the game running perfectly behind it — no crash, no warning, nothing in
    /// the log. Verified on the simulator before this existed.
    override func didChangeSize(_ oldSize: CGSize) {
        super.didChangeSize(oldSize)
        guard size.width > 0, size.height > 0 else { return }
        recomputeScale()
        layoutHUD()
        field.position = fieldOrigin
        rebuildAttractor()
    }

    /// The ring's radius is baked into its path at construction, so a scene that was 0x0 at
    /// didMove leaves a zero-radius circle behind. Rebuilt on every scale change rather than
    /// scaled, because scaling a stroked shape scales its line width with it.
    private func rebuildAttractor() {
        guard fieldScale > 0 else { return }
        let pos = attractorNode?.position
        attractorNode?.removeFromParent()
        let n = SKShapeNode(circleOfRadius: sim.playerClass.captureRange * fieldScale)
        n.strokeColor = UIColor(red: 0.91, green: 0.56, blue: 0.31, alpha: 0.55)
        n.lineWidth = 1.5
        n.fillColor = .clear
        n.glowWidth = 3
        if let pos { n.position = pos }
        addChild(n)
        attractorNode = n
    }

    /// HUD positions depend on `size`, so they are set here rather than at construction and
    /// re-applied on every resize — rotation included.
    private func layoutHUD() {
        scoreLabel?.position = CGPoint(x: 22, y: size.height - 58)
        comboLabel?.position = CGPoint(x: 22, y: size.height - 82)
        timerLabel?.position = CGPoint(x: size.width - 22, y: size.height - 58)
        boardLabel?.position = CGPoint(x: size.width - 22, y: size.height - 118)
    }

    // ── input ────────────────────────────────────────────────────────────────
    private func setAttractor(_ p: CGPoint) {
        // Screen back to field space. Clamped, so a touch in the letterbox bar does not
        // park the attractor outside the world where nothing can be captured.
        let fx = min(max((p.x - fieldOrigin.x) / fieldScale, 0), FieldSize.width)
        let fy = min(max((p.y - fieldOrigin.y) / fieldScale, 0), FieldSize.height)
        sim.attractor = CGPoint(x: fx, y: fy)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with e: UIEvent?) {
        if let t = touches.first { setAttractor(t.location(in: self)) }
    }
    override func touchesMoved(_ touches: Set<UITouch>, with e: UIEvent?) {
        if let t = touches.first { setAttractor(t.location(in: self)) }
    }

    // ── frame ────────────────────────────────────────────────────────────────
    override func update(_ currentTime: TimeInterval) {
        if last == 0 { last = currentTime }
        let dt = currentTime - last
        last = currentTime

        let wasOver = sim.isOver
        sim.step(dt: dt)

        field.render(particles: sim.particles,
                     in: CGSize(width: FieldSize.width * fieldScale,
                                height: FieldSize.height * fieldScale),
                     scale: fieldScale,
                     tint: UIColor(red: 0.42, green: 0.92, blue: 0.62, alpha: 0.9))

        attractorNode?.position = CGPoint(x: fieldOrigin.x + sim.attractor.x * fieldScale,
                                         y: fieldOrigin.y + sim.attractor.y * fieldScale)

        // Haptics on capture, and only when a burst is big enough to feel deliberate —
        // a tap on every single particle would buzz continuously and mean nothing.
        if sim.captures.count >= 3 { Haptics.shared.tap(intensity: min(1, Double(sim.captures.count) / 20)) }

        syncNetwork(dt: dt)

        scoreLabel?.text = "\(sim.score)"
        comboLabel?.text = sim.combo > 1.05 ? String(format: "×%.1f", sim.combo) : ""
        timerLabel?.text = String(format: "%.0fs", max(0, sim.roundLength - sim.elapsed))

        if sim.isOver && !wasOver { onRoundEnd(sim.score) }
    }

    // ── multiplayer ──────────────────────────────────────────────────────────
    private func syncNetwork(dt: TimeInterval) {
        guard let net, net.connected else { return }

        net.sendInput(sim.attractor, dt: dt)

        // Claims are batched to one per frame rather than one per particle. The server
        // checks each claim for proximity and recency, so a hundred messages a second would
        // be rejected wholesale AND cost the battery — the count is the value.
        if !sim.captures.isEmpty {
            let mid = sim.captures.reduce(CGPoint.zero) {
                CGPoint(x: $0.x + $1.x / CGFloat(sim.captures.count),
                        y: $0.y + $1.y / CGFloat(sim.captures.count))
            }
            net.claim(at: mid, value: sim.captures.count)
        }

        // Reconcile the visible set against what arrived. Nodes are reused by id and only
        // removed when an actor genuinely leaves, so a player who drops for one tick does
        // not flicker out and back.
        var seen = Set<String>()
        for a in net.others {
            seen.insert(a.id)
            let node = remoteNodes[a.id] ?? {
                let n = RemoteNode(name: a.name, isBot: a.isBot, hue: a.hue)
                addChild(n)
                remoteNodes[a.id] = n
                return n
            }()
            // Interpolated, because the server ticks at 15Hz and we draw at 60. Snapping
            // would make every other player look like they were teleporting.
            let target = CGPoint(x: fieldOrigin.x + a.x * fieldScale,
                                 y: fieldOrigin.y + a.y * fieldScale)
            node.position = node.position == .zero ? target : CGPoint(
                x: node.position.x + (target.x - node.position.x) * 0.25,
                y: node.position.y + (target.y - node.position.y) * 0.25)
        }
        for (id, node) in remoteNodes where !seen.contains(id) {
            node.removeFromParent()
            remoteNodes.removeValue(forKey: id)
        }

        // The live board. Shown only online, since solo already has the score top-left.
        if boardLabel == nil {
            let l = hud(size: 11, weight: .regular)
            l.horizontalAlignmentMode = .right
            l.numberOfLines = 0
            l.position = CGPoint(x: size.width - 22, y: size.height - 118)
            addChild(l)
            boardLabel = l
        }
        boardLabel?.text = net.board(limit: 5)
            .map { "\($0.name)\($0.isBot ? " ·bot" : "")  \($0.score)" }
            .joined(separator: "\n")
    }
}

/// Another participant's attractor. A bot is drawn and labelled as a bot — passing them off
/// as people would make a room look busier and is a claim the player can never check.
final class RemoteNode: SKNode {
    init(name: String, isBot: Bool, hue: String) {
        super.init()
        let ring = SKShapeNode(circleOfRadius: isBot ? 7 : 10)
        ring.strokeColor = isBot ? UIColor(white: 0.68, alpha: 0.75) : UIColor(hex: hue)
        ring.lineWidth = isBot ? 1.5 : 2.5
        ring.fillColor = .clear
        addChild(ring)

        let label = SKLabelNode(fontNamed: "Menlo")
        label.text = isBot ? "\(name) ·bot" : name
        label.fontSize = 10
        label.fontColor = UIColor(white: 0.8, alpha: isBot ? 0.45 : 0.8)
        label.position = CGPoint(x: 0, y: 15)
        addChild(label)
    }
    required init?(coder: NSCoder) { fatalError("not from a storyboard") }
}

extension UIColor {
    /// The server sends CSS hex. Falls back to a readable blue rather than failing, because
    /// a wrong colour must never cost the player sight of another player.
    convenience init(hex: String) {
        var s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else {
            self.init(red: 0.23, green: 0.44, blue: 0.75, alpha: 1); return
        }
        self.init(red: CGFloat((v >> 16) & 0xFF) / 255,
                  green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}
