import Foundation
import CoreGraphics
func play(_ m: Mode) -> (you: Int, team: Int, foe: Int, secs: Double) {
    let sim = DriftSim(seed: 962021266, playerClass: .void, mode: m)
    var t = 0.0
    while !sim.isOver {
        t += 1.0/60.0
        sim.attractor = CGPoint(x: 800 + cos(t*1.3)*640, y: 450 + sin(t*1.7)*380)
        if sim.abilityReady { sim.fireAbility() }
        sim.step(dt: 1.0/60.0)
    }
    return (sim.score, sim.teamScore, sim.enemyScore, sim.elapsed)
}
print("  mode      secs   you   team   foe   rivals")
for m in Mode.all where m.name != "ONLINE" {
    let r = play(m)
    print(String(format: "  %-8s %4.0f  %5d  %5d %5d   %d(%d ally)",
          (m.name as NSString).utf8String!, r.secs, r.you, r.team, r.foe, m.rivals, m.allies))
}
