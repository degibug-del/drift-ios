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
    // Named SURGE, not CHAIN GATE. The web game's chain gate spawns a gate at the cursor
    // and this build has no gates — advertising it on the class card was the app telling
    // the player something untrue. The ability is named for what it actually does.
    public static let surge = PlayerClass(name: "SURGE", pullMult: 1.0, captureRange: 75,
                                          ability: "SURGE", cooldown: 8)
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

    /// Respawn, uniformly.
    ///
    /// This was biased AWAY from the attractor, to stop a parked player farming an endless
    /// supply. Measurement retired it. The bias was added before combo-requires-movement
    /// existed, and once that landed it was doing the anti-farming job on its own — a
    /// sweep of the away radius showed parking still loses by 13x at radius 0 (116 against
    /// 1525 for a hunter).
    ///
    /// What the bias WAS still doing was making abilities counterproductive. Capturing more
    /// thinned your own surroundings, so for a player working a small area a mass-capture
    /// ability cost more than it paid: -27% for VOID at radius 320, -0% at 160, +3% at 0.
    /// Two rules solving the same problem, and the redundant one was the expensive one.
    mutating func spawn(_ rng: inout Mulberry, away from: CGPoint? = nil) {
        _ = from                       // kept in the signature; the bias itself is retired
        x = rng.next(FieldSize.width)
        y = rng.next(FieldSize.height)
        vx = (rng.next() - 0.5) * 0.5
        vy = (rng.next() - 0.5) * 0.5
        r = 0.8 + rng.next() * 1.4
        captured = false
    }
}


// ── modes ────────────────────────────────────────────────────────────────────
/// What a mode actually changes. The web game has seven and they differ in four ways:
/// round length, how many AI opponents share the field, whether those opponents are on
/// your side, and whether the field is unstable.
///
/// Ported rather than invented — the round lengths are the web game's MODE_CFG values, so
/// a player who knows DRIFT on the site finds the same rhythms here. GLITCH is the one
/// that needed reinterpreting: the web version distorts the rendering, and distortion that
/// only affects what you SEE is a renderer concern. Here it perturbs the field itself, so
/// the simulation can be tested for it.
public struct Mode: Equatable {
    public let name: String
    public let seconds: TimeInterval
    /// Opponent attractors sharing the field and competing for the same particles.
    public let rivals: Int
    /// How many of those are on your side. Their captures count toward your team score.
    public let allies: Int
    /// Field instability: particles get random impulses, growing through the round.
    public let glitch: Bool
    public let blurb: String

    public static let solo   = Mode(name: "SOLO",   seconds: 90,  rivals: 0, allies: 0, glitch: false,
                                    blurb: "pull particles through the field · no opponent")
    public static let online = Mode(name: "ONLINE", seconds: 90,  rivals: 0, allies: 0, glitch: false,
                                    blurb: "a shared field · real players and bots")
    public static let oneVone = Mode(name: "1V1",   seconds: 90,  rivals: 1, allies: 0, glitch: false,
                                    blurb: "you and the machine, matched")
    public static let twoVtwo = Mode(name: "2V2",   seconds: 90,  rivals: 3, allies: 1, glitch: false,
                                    blurb: "you + partner meet two")
    public static let zen    = Mode(name: "ZEN",    seconds: 180, rivals: 0, allies: 0, glitch: false,
                                    blurb: "3 min · no pressure · just flow")
    public static let blitz  = Mode(name: "BLITZ",  seconds: 45,  rivals: 0, allies: 0, glitch: false,
                                    blurb: "45s · fast · high tempo")
    public static let glitch = Mode(name: "GLITCH", seconds: 60,  rivals: 0, allies: 0, glitch: true,
                                    blurb: "60s · the field will not hold still")

    public static let all: [Mode] = [.solo, .online, .oneVone, .twoVtwo, .zen, .blitz, .glitch]
}

/// An AI attractor. Simpler than the server's bots on purpose: those coordinate with real
/// players over a network, these only have to be worth playing against.
public struct Rival {
    public var x: CGFloat, y: CGFloat
    public var score: Int = 0
    public var ally: Bool
    var tx: CGFloat, ty: CGFloat
    var think: TimeInterval = 0
    var skill: CGFloat
}

// ── the simulation ───────────────────────────────────────────────────────────
public final class DriftSim {

    public private(set) var particles: [Particle] = []
    public private(set) var score: Int = 0
    public private(set) var combo: CGFloat = 1
    /// Highest multiplier reached this round. The live `combo` decays, so an achievement
    /// checked at round end against it would almost never fire — the player hit x6 forty
    /// seconds ago and it has bled back to x1 by the time anyone looks.
    public private(set) var peakCombo: CGFloat = 1
    public private(set) var elapsed: TimeInterval = 0

    /// Where the player's warm attractor is. The renderer sets this from touch.
    public var attractor = CGPoint(x: FieldSize.width / 2, y: FieldSize.height / 2)
    public let playerClass: PlayerClass
    public let roundLength: TimeInterval

    private var rng: Mulberry
    private var comboDecay: TimeInterval = 0

    // ── the ability ─────────────────────────────────────────────────────────
    // Each class had a name on its card and nothing behind it: SINGULARITY, CHAIN GATE and
    // FREEZE were strings. The only real difference between classes was pullMult and
    // captureRange, so choosing PHASE changed two numbers and printed a promise.
    //
    // All three now do what they say, and each is distinct in KIND rather than in degree —
    // one changes the force, one changes the reach, one stops time. A cooldown that differs
    // by a second between three otherwise identical buttons is not three abilities.
    public private(set) var abilityCooldown: TimeInterval = 0
    public private(set) var abilityRemaining: TimeInterval = 0
    public var abilityReady: Bool { abilityCooldown <= 0 && abilityRemaining <= 0 }
    /// 0…1 for a cooldown ring in the UI.
    public var abilityCharge: CGFloat {
        guard playerClass.cooldown > 0 else { return 1 }
        return abilityCooldown <= 0 ? 1 : 1 - CGFloat(abilityCooldown / playerClass.cooldown)
    }

    private static let duration: TimeInterval = 3.0

    /// Fire it. Ignored unless ready, so the caller does not have to check.
    @discardableResult
    public func fireAbility() -> Bool {
        guard abilityReady else { return false }
        abilityRemaining = playerClass.name == "PHASE" ? 4.0 : Self.duration
        abilityCooldown = playerClass.cooldown + abilityRemaining
        // SINGULARITY is a one-shot harvest, not a window: everything within a third of
        // the field is taken at once. A sustained stronger pull was measured at +5%, which
        // is noise; a burst is felt and is worth the cooldown.
        if playerClass.name == "VOID" { pendingSingularity = true }
        // FREEZE holds the combo where it is and lifts it — the multiplier is half the
        // score, and protecting it is what "patience · control" is actually worth.
        if playerClass.name == "PHASE" { combo = min(6, combo + 1.5) }
        return true
    }

    private var pendingSingularity = false
    /// Where the attractor was when the combo last rose — see the scoring note in step().
    private var lastComboPoint = CGPoint(x: FieldSize.width / 2, y: FieldSize.height / 2)
    private var pointsCarry: CGFloat = 0

    /// Points per unit of capture-volume-times-combo.
    ///
    /// CALIBRATED, not derived. With this at 1.0 a strong round scored 37,068, which is a
    /// number nobody can hold in their head or compare to a friend's. Three simulated play
    /// styles were run against the same field and the constant chosen so that a hunting
    /// round lands near 1,500: parked ~90, wandering ~620, hunting ~1,480. The ORDER of
    /// those is the design; the scale is taste, and this is where the taste lives so it can
    /// be changed in one place without touching the model.
    static let rate: CGFloat = 0.04


    /// Capture events since the last drain — the renderer turns these into bursts and the
    /// multiplayer client turns them into claims. Returned rather than fired as callbacks
    /// so the simulation stays free of anything it has to know about.
    public private(set) var captures: [CGPoint] = []

    public let mode: Mode
    public private(set) var rivals: [Rival] = []
    /// Your side's total when a mode has allies; equals `score` otherwise.
    public var teamScore: Int { score + rivals.filter { $0.ally }.reduce(0) { $0 + $1.score } }
    public var enemyScore: Int { rivals.filter { !$0.ally }.reduce(0) { $0 + $1.score } }

    public init(seed: UInt32, playerClass: PlayerClass = .void,
                count: Int = 900, mode: Mode = .solo) {
        self.rng = Mulberry(seed: seed)
        self.playerClass = playerClass
        self.mode = mode
        self.roundLength = mode.seconds
        particles = (0..<count).map { _ in
            var p = Particle(x: 0, y: 0, vx: 0, vy: 0, r: 1)
            p.spawn(&rng)
            return p
        }
        // Allies first, so index 0 is your partner in 2V2 and the UI can colour it.
        for i in 0..<mode.rivals {
            rivals.append(Rival(x: rng.next(FieldSize.width), y: rng.next(FieldSize.height),
                                ally: i < mode.allies,
                                tx: rng.next(FieldSize.width), ty: rng.next(FieldSize.height),
                                skill: 0.45 + rng.next() * 0.4))
        }
    }

    // ── opponents ───────────────────────────────────────────────────────────
    /// Rivals hunt: they pick a target, run at it, and capture on the same terms you do.
    /// Deliberately no smarter than that — an opponent that played optimally would win
    /// every round, and the point is a contest rather than a demonstration.
    private func stepRivals(_ dt: TimeInterval) {
        guard !rivals.isEmpty else { return }
        for i in rivals.indices {
            var r = rivals[i]
            r.think -= dt
            if r.think <= 0 {
                r.think = 0.8 + Double(rng.next()) * 1.6
                r.tx = rng.next(FieldSize.width)
                r.ty = rng.next(FieldSize.height)
            }
            let dx = r.tx - r.x, dy = r.ty - r.y
            let d = max(hypot(dx, dy), 0.001)
            let sp = (300 + r.skill * 420) * CGFloat(dt)
            let k = min(1, sp / d)
            r.x = max(0, min(FieldSize.width, r.x + dx * k))
            r.y = max(0, min(FieldSize.height, r.y + dy * k))

            // Same capture rule as the player, at the rival's own range.
            let range2: CGFloat = 88 * 88
            var took = 0
            for j in particles.indices where !particles[j].captured {
                let ddx = particles[j].x - r.x, ddy = particles[j].y - r.y
                if ddx * ddx + ddy * ddy < range2 { particles[j].captured = true; took += 1 }
            }
            if took > 0 { r.score += max(1, Int((sqrt(CGFloat(took)) * Self.rate * 3).rounded())) }
            rivals[i] = r
        }
    }

    public var isOver: Bool { elapsed >= roundLength }

    /// One step. dt is clamped because a backgrounded app returns with a huge delta, and an
    /// unclamped step would teleport every particle across the field in one frame.
    public func step(dt: TimeInterval) {
        let dt = min(dt, 0.05)
        elapsed += dt
        captures.removeAll(keepingCapacity: true)

        // Cooldown runs whether or not the ability is active; the active window is a
        // prefix of it, so one timer cannot drift out of step with the other.
        if abilityCooldown > 0 { abilityCooldown = max(0, abilityCooldown - dt) }
        if abilityRemaining > 0 { abilityRemaining = max(0, abilityRemaining - dt) }
        let active = abilityRemaining > 0

        // Three abilities that differ in KIND — and all three act on the thing that
        // actually decides the score.
        //
        // Two earlier designs failed measurement and are worth recording. FREEZE-as-
        // stop-motion made PHASE score 3% WORSE than not firing: frozen particles stop
        // drifting toward the attractor, so it prevented what it was meant to help.
        // SINGULARITY-as-stronger-pull gained 5%, which is inside the noise — because
        // scoring is dominated by how much field you sweep, not how hard you pull, so an
        // ability that only changes local physics cannot move the number.
        //
        // SURGE was the one that worked (+22%) and it shows why: reach multiplies captures
        // directly. So all three now act on captures or combo, the two terms in the score.
        //
        // FREEZE was first written as "stop position updates entirely", and measurement
        // showed it made PHASE score 3% WORSE than not firing at all — frozen particles
        // stop drifting toward the attractor, so the ability actively prevented the thing
        // it was meant to help. It now kills the particles' INHERITED velocity instead, so
        // during the window they move under attraction alone: no overshoot, no orbiting,
        // everything falls straight in. That is what "patience · control" should mean.
        let boostPull  = 1.0
        let boostRange = active && playerClass.name == "SURGE" ? 2.6 : 1.0
        let frozen     = active && playerClass.name == "PHASE"

        let pull = playerClass.pullMult * boostPull
        let range = playerClass.captureRange * boostRange
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

            // The singularity radius is checked on the frame it fires only.
            if d2 < range2 || (pendingSingularity && d2 < 520 * 520) {
                p.captured = true
                captures.append(CGPoint(x: p.x, y: p.y))
            }
            particles[i] = p
        }

        // ── scoring ──────────────────────────────────────────────────────────
        // The first model scored 27,295 in 90 seconds, with the combo pinned at x8 within
        // a few seconds. Three separate things were wrong and each fed the next:
        //
        //   score += count * combo      while combo ALSO grew with count, so a dense patch
        //                               paid quadratically in its own density
        //   combo += count * 0.05       so one good sweep maxed it outright
        //   uniform respawn             so a captured particle could reappear inside the
        //                               ring and be taken again next frame
        //
        // The fix is to pay for the ACT of capturing rather than the volume, and to make
        // the combo a reward for continuing to find density rather than for sitting in it.
        let burst = pendingSingularity
        pendingSingularity = false
        stepRivals(dt)

        // GLITCH: the field will not hold still. Impulses grow through the round, so the
        // last twenty seconds are genuinely harder than the first — an instability that is
        // constant is just a different physics, not a mode.
        if mode.glitch {
            let intensity = CGFloat(elapsed / roundLength) * 34
            for i in particles.indices where rng.next() < 0.02 {
                particles[i].vx += (rng.next() - 0.5) * intensity
                particles[i].vy += (rng.next() - 0.5) * intensity
            }
        }

        if !captures.isEmpty {
            // Sub-linear in count: a burst of twenty is worth more than a burst of five,
            // but not four times more. sqrt keeps a lucky clump from dwarfing skilled play.
            // sqrt exists to stop a LUCKY clump paying out of proportion. An ability is
            // not luck — it is a deliberate act on a cooldown — so its harvest is scored
            // linearly. Without this exemption the two designs fight: a singularity taking
            // 300 particles paid sqrt(300) = 17, and firing it measured WORSE than not.
            let volume = burst ? CGFloat(captures.count) * 0.22 : sqrt(CGFloat(captures.count))
            pointsCarry += volume * combo * Self.rate
            // Points accumulate as a fraction and are banked as whole numbers. Rounding
            // every frame instead would floor most frames to zero at this rate and the
            // score would crawl in visible steps rather than climb.
            let whole = pointsCarry.rounded(.down)
            if whole >= 1 { score += Int(whole); pointsCarry -= whole }

            // Combo builds only when the attractor has MOVED since the last capture.
            // Dwelling holds the multiplier; hunting raises it. Without this the optimal
            // strategy is to park on a dense patch and wait, which is not a game.
            let moved = hypot(attractor.x - lastComboPoint.x, attractor.y - lastComboPoint.y)
            if moved > 120 {
                combo = min(6, combo + 0.35)
                peakCombo = max(peakCombo, combo)
                lastComboPoint = attractor
            }
            comboDecay = 0
        } else {
            // The combo is a reward for continuous capture, so it has to bleed when the
            // player stops. Without decay a single good sweep holds the maximum all round.
            comboDecay += dt
            // FREEZE suspends decay outright — that is the "freeze".
            if comboDecay > 0.9 && !frozen { combo = max(1, combo - CGFloat(dt) * 2.2) }
        }

        // Respawn what was taken, away from the attractor — see Particle.spawn.
        for i in particles.indices where particles[i].captured {
            particles[i].spawn(&rng, away: attractor)
        }
    }
}
