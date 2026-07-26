// DriftCore.swift — DRIFT's simulation, natively.
//
// Diego, 2026-07-25: "let's make it as native as we can / can even start again from
// scratch." This is the start-again: the game's physics, ported off the canvas.
//
// WHY THIS FILE HAS NO SPRITEKIT IN IT. The simulation is deliberately pure Swift with no
// import of any rendering framework, and that is the whole design decision. It means:
//
//   · it runs in a unit test, on a Mac, with no simulator and no Xcode scheme
//   · the renderer (SpriteKit today, Metal if particle counts demand it) can be replaced
//     without touching a line of game logic
//   · the same code can be checked against the web version's numbers, which is the only
//     way to know the port is faithful rather than merely similar
//
// The web game mixes simulation and drawing in one 1490-line file, which is why nothing in
// it can be tested. Keeping that seam is the main thing the rewrite buys.
//
// COORDINATES. The field is a fixed 1600x900 space, identical to the multiplayer server's,
// so a native client and a browser client are in the same world and no conversion layer
// can drift between them. The renderer letterboxes; the simulation never knows the screen.

import Foundation
import CoreGraphics

public struct FieldSize {
    public static let width: CGFloat = 1600
    public static let height: CGFloat = 900
}

// ── classes ──────────────────────────────────────────────────────────────────
// Values lifted from the web game's CLASSES table so the port is checkable against it.
public struct PlayerClass: Equatable {
    public let name: String
    public let pullMult: CGFloat
    public let captureRange: CGFloat
    public let ability: String
    public let cooldown: TimeInterval

    public static let void  = PlayerClass(name: "VOID",  pullMult: 1.7, captureRange: 95,
                                          ability: "SINGULARITY", cooldown: 6)
    public static let surge = PlayerClass(name: "SURGE", pullMult: 1.0, captureRange: 75,
                                          ability: "CHAIN GATE", cooldown: 8)
    public static let phase = PlayerClass(name: "PHASE", pullMult: 1.1, captureRange: 115,
                                          ability: "FREEZE", cooldown: 9)

    public static let all: [PlayerClass] = [.void, .surge, .phase]
}

// ── deterministic randomness ─────────────────────────────────────────────────
// mulberry32, mirrored bit-for-bit from mp.js and the Durable Object. A native player and
// a browser player seeded alike MUST compute the same field, or multiplayer shows two
// different games and nobody can tell whose cluster was whose.
public struct Mulberry {
    private var a: UInt32
    public init(seed: UInt32) { a = seed }

    public mutating func next() -> CGFloat {
        a = a &+ 0x6D2B79F5
        var t = a
        t = (t ^ (t >> 15)) &* (1 | t)
        t = t &+ ((t ^ (t >> 7)) &* (61 | t)) ^ t
        // 4294967296 is 2^32, NOT UInt32.max. The JS divides by 2^32; dividing by 2^32-1
        // here would put every value a hair high and the two fields would slowly disagree —
        // the exact failure this mirroring exists to prevent, and invisible until two
        // players compare screens.
        return CGFloat(t ^ (t >> 14)) / 4294967296.0
    }

    public mutating func next(_ upper: CGFloat) -> CGFloat { next() * upper }
}

// ── particles ────────────────────────────────────────────────────────────────
public struct Particle {
    public var x: CGFloat, y: CGFloat
    public var vx: CGFloat, vy: CGFloat
    public var r: CGFloat
    public var captured = false

    mutating func spawn(_ rng: inout Mulberry) {
        x = rng.next(FieldSize.width)
        y = rng.next(FieldSize.height)
        vx = (rng.next() - 0.5) * 0.5
        vy = (rng.next() - 0.5) * 0.5
        r = 0.8 + rng.next() * 1.4
        captured = false
    }
}

// ── the simulation ───────────────────────────────────────────────────────────
public final class DriftSim {

    public private(set) var particles: [Particle] = []
    public private(set) var score: Int = 0
    public private(set) var combo: CGFloat = 1
    public private(set) var elapsed: TimeInterval = 0

    /// Where the player's warm attractor is. The renderer sets this from touch.
    public var attractor = CGPoint(x: FieldSize.width / 2, y: FieldSize.height / 2)
    public let playerClass: PlayerClass
    public let roundLength: TimeInterval

    private var rng: Mulberry
    private var comboDecay: TimeInterval = 0

    /// Capture events since the last drain — the renderer turns these into bursts and the
    /// multiplayer client turns them into claims. Returned rather than fired as callbacks
    /// so the simulation stays free of anything it has to know about.
    public private(set) var captures: [CGPoint] = []

    public init(seed: UInt32, playerClass: PlayerClass = .void,
                count: Int = 900, roundLength: TimeInterval = 90) {
        self.rng = Mulberry(seed: seed)
        self.playerClass = playerClass
        self.roundLength = roundLength
        particles = (0..<count).map { _ in
            var p = Particle(x: 0, y: 0, vx: 0, vy: 0, r: 1)
            p.spawn(&rng)
            return p
        }
    }

    public var isOver: Bool { elapsed >= roundLength }

    /// One step. dt is clamped because a backgrounded app returns with a huge delta, and an
    /// unclamped step would teleport every particle across the field in one frame.
    public func step(dt: TimeInterval) {
        let dt = min(dt, 0.05)
        elapsed += dt
        captures.removeAll(keepingCapacity: true)

        let pull = playerClass.pullMult
        let range = playerClass.captureRange
        let range2 = range * range
        let ax = attractor.x, ay = attractor.y

        for i in particles.indices {
            var p = particles[i]
            if p.captured { continue }

            // Inverse-distance attraction, softened near the centre. Without the +400 the
            // force goes to infinity at zero distance and particles slingshot off the field.
            let dx = ax - p.x, dy = ay - p.y
            let d2 = dx * dx + dy * dy
            let f = pull * 26_000 / (d2 + 400)
            let inv = 1 / max(sqrt(d2), 0.0001)
            p.vx += dx * inv * f * CGFloat(dt)
            p.vy += dy * inv * f * CGFloat(dt)

            // Drag, so the field settles instead of accumulating energy forever.
            p.vx *= 0.985
            p.vy *= 0.985

            p.x += p.vx
            p.y += p.vy

            // Wrap rather than bounce: the field should feel unbounded, and a bounce puts a
            // visible wall where the design says there is none.
            if p.x < 0 { p.x += FieldSize.width } else if p.x > FieldSize.width { p.x -= FieldSize.width }
            if p.y < 0 { p.y += FieldSize.height } else if p.y > FieldSize.height { p.y -= FieldSize.height }

            if d2 < range2 {
                p.captured = true
                captures.append(CGPoint(x: p.x, y: p.y))
            }
            particles[i] = p
        }

        if !captures.isEmpty {
            score += Int((CGFloat(captures.count) * combo).rounded())
            combo = min(8, combo + CGFloat(captures.count) * 0.05)
            comboDecay = 0
        } else {
            // The combo is a reward for continuous capture, so it has to bleed when the
            // player stops. Without decay a single good sweep holds an 8x for the round.
            comboDecay += dt
            if comboDecay > 1.2 { combo = max(1, combo - CGFloat(dt) * 1.5) }
        }

        // Respawn what was taken, so the field stays populated and the round has a rhythm
        // rather than thinning to nothing.
        for i in particles.indices where particles[i].captured {
            particles[i].spawn(&rng)
        }
    }
}
