// DriftApp.swift — the native shell: menu, class select, server browser, game.
//
// This replaces the WKWebView build entirely. The web game is still the canonical version
// on phronesis.world; this is a second implementation of the same game against the same
// multiplayer server, not a wrapper around the first.
//
// The menu is SwiftUI rather than drawn into the canvas, and that is not decoration. On the
// web the class cards and mode grid are hit-tested rectangles the game draws itself — they
// are invisible to VoiceOver, ignore Dynamic Type, and cannot be reached by a keyboard or a
// switch control. Real controls get all of that for free, and it is the single clearest
// difference between this and the site.

import SwiftUI
import SpriteKit

// ── app ──────────────────────────────────────────────────────────────────────
@main
struct DriftApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
                .statusBarHidden()
        }
    }
}

enum Route: Equatable {
    case menu
    case modes
    case servers
    case playing(seed: UInt32, cls: PlayerClass, mode: Mode, server: String?)
    case over(score: Int, cls: PlayerClass, mode: Mode, team: Int, foe: Int)
}

// ── root ─────────────────────────────────────────────────────────────────────
struct RootView: View {
    @State private var route: Route = .menu
    @State private var cls: PlayerClass = .void
    @AppStorage("drift_name") private var playerName = ""
    // v2: the scoring model changed by a factor of ~18, so a best carried over from the
    // old one is unbeatable and reads as a bug. A new key retires it without deleting it.
    @AppStorage("drift_best_v2") private var best = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch route {
            case .menu:
                MenuView(cls: $cls, best: best,
                         onPlay: { route = .modes },
                         onOnline: { route = .servers })
            case .modes:
                ModeView(onBack: { route = .menu },
                         onPick: { m in
                             if m == .online { route = .servers }
                             else { route = .playing(seed: UInt32.random(in: 1...4_000_000_000),
                                                     cls: cls, mode: m, server: nil) }
                         })
            case .servers:
                ServerBrowser(name: $playerName,
                              onBack: { route = .menu },
                              onJoin: { s in
                                  route = .playing(seed: UInt32.random(in: 1...4_000_000_000),
                                                   cls: cls, mode: .online, server: s)
                              })
            case let .playing(seed, c, m, server):
                GameView(seed: seed, cls: c, mode: m, server: server, name: playerName) { score, team, foe in
                    // Only SOLO feeds the personal best. A 180-second ZEN round and a
                    // 45-second BLITZ round are not comparable, and one "best" across all
                    // of them would just record which mode is longest.
                    if m == .solo && score > best { best = score }
                    // Online scores go to their own board: a shared field with other players
                    // pulling the same particles is not the same contest as a solo run, and
                    // one leaderboard for both would make neither number mean anything.
                    GameCenterBridge.shared.submit(
                        score: score,
                        leaderboard: server == nil ? GC.leaderboardBest : GC.leaderboardOnline)
                    if server != nil { GameCenterBridge.shared.award(.online) }
                    Haptics.shared.roundEnd()
                    route = .over(score: score, cls: c, mode: m, team: team, foe: foe)
                }
                .ignoresSafeArea()
            case let .over(score, c, m, team, foe):
                GameOverView(score: score, best: best, mode: m, team: team, foe: foe,
                             onAgain: { route = .playing(seed: UInt32.random(in: 1...4_000_000_000),
                                                         cls: c, mode: m, server: nil) },
                             onMenu: { route = .menu })
            }
        }
        .onAppear {
            // Presenting from the key window's root, because Game Center can ask to show
            // sign-in long after launch and SwiftUI has no view controller to hand it.
            if let root = UIApplication.shared.connectedScenes
                .compactMap({ ($0 as? UIWindowScene)?.keyWindow?.rootViewController }).first {
                GameCenterBridge.shared.authenticate(presenter: root)
            }
        }
    }
}

// ── menu ─────────────────────────────────────────────────────────────────────
struct MenuView: View {
    @Binding var cls: PlayerClass
    let best: Int
    let onPlay: () -> Void
    let onOnline: () -> Void

    var body: some View {
        VStack(spacing: 26) {
            VStack(spacing: 6) {
                Text("DRIFT")
                    .font(.system(size: 52, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color(red: 0.91, green: 0.56, blue: 0.31))
                Text("PHRONESIS · FIELD SPORT")
                    .font(.system(size: 10, design: .monospaced))
                    .tracking(2)
                    .foregroundStyle(.secondary)
                if best > 0 {
                    Text("best \(best)")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 40)

            VStack(spacing: 10) {
                Text("SELECT CLASS")
                    .font(.system(size: 10, design: .monospaced)).tracking(2)
                    .foregroundStyle(.secondary)
                ForEach(PlayerClass.all, id: \.name) { c in
                    Button { cls = c; Haptics.shared.tap(intensity: 0.4) } label: {
                        ClassCard(c: c, selected: c == cls)
                    }
                    .buttonStyle(.plain)
                    // Real accessibility, which drawn rectangles on a canvas cannot have.
                    .accessibilityLabel("\(c.name). \(AbilityCopy.blurb(for: c)).")
                    .accessibilityAddTraits(c == cls ? [.isSelected, .isButton] : .isButton)
                }
            }

            VStack(spacing: 10) {
                Button(action: onPlay) { Label("PLAY", systemImage: "play.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(PrimaryButton())
                Button(action: onOnline) { Label("ONLINE", systemImage: "person.2.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(SecondaryButton())
                Button {
                    if let root = UIApplication.shared.connectedScenes
                        .compactMap({ ($0 as? UIWindowScene)?.keyWindow?.rootViewController }).first {
                        GameCenterBridge.shared.showDashboard(from: root, leaderboard: GC.leaderboardBest)
                    }
                } label: {
                    Label("LEADERBOARD", systemImage: "trophy.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryButton())
            }
            .padding(.horizontal, 28)

            Spacer()
        }
    }
}

/// One place for what each ability actually does, so the card, the accessibility label and
/// the in-game readout cannot drift apart from each other or from the simulation.
enum AbilityCopy {
    static func blurb(for c: PlayerClass) -> String {
        switch c.name {
        case "VOID":  return "singularity · harvest everything near you"
        case "SURGE": return "surge · capture reach x2.6, 3s"
        case "PHASE": return "freeze · combo held + boosted, 4s"
        default:      return c.ability.lowercased()
        }
    }
}

/// The mode grid. Two columns on a phone, adaptive above — a seven-item list in one column
/// runs off the bottom of a small screen, and a fixed two-column grid wastes an iPad.
struct ModeView: View {
    let onBack: () -> Void
    let onPick: (Mode) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onBack) { Label("back", systemImage: "chevron.left") }
                    .font(.system(size: 13, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 20).padding(.top, 12)

            Text("SELECT MODE").font(.system(size: 10, design: .monospaced)).tracking(2)
                .foregroundStyle(.secondary).padding(.top, 18).padding(.bottom, 14)

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                    ForEach(Mode.all, id: \.name) { m in
                        Button { Haptics.shared.tap(intensity: 0.4); onPick(m) } label: {
                            VStack(spacing: 4) {
                                Text(m.name).font(.system(size: 15, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(ModeColour.of(m))
                                Text(m.blurb).font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, minHeight: 74)
                            .padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.03)))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(m.name). \(m.blurb). \(Int(m.seconds)) seconds.")
                    }
                }
                .padding(.horizontal, 20)
            }
            Spacer(minLength: 20)
        }
    }
}

/// One colour per mode, taken from the site's twelve wedges so the app and the web version
/// name the same things the same way.
enum ModeColour {
    static func of(_ m: Mode) -> Color {
        switch m.name {
        case "SOLO":   return Color(red: 0.91, green: 0.56, blue: 0.31)
        case "ONLINE": return Color(red: 0.27, green: 0.69, blue: 0.54)
        case "1V1":    return Color(red: 0.23, green: 0.58, blue: 0.79)
        case "2V2":    return Color(red: 0.43, green: 0.85, blue: 0.60)
        case "ZEN":    return Color(red: 0.38, green: 0.65, blue: 0.98)
        case "BLITZ":  return Color(red: 0.98, green: 0.58, blue: 0.24)
        default:       return Color(red: 0.91, green: 0.30, blue: 0.61)
        }
    }
}

struct ClassCard: View {
    let c: PlayerClass
    let selected: Bool
    var body: some View {
        VStack(spacing: 3) {
            Text(c.name).font(.system(size: 15, weight: .semibold, design: .monospaced))
            Text(AbilityCopy.blurb(for: c)).font(.system(size: 11, design: .monospaced))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(selected ? 0.07 : 0.03)))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(selected ? Color(red: 0.91, green: 0.56, blue: 0.31) : Color.white.opacity(0.12),
                    lineWidth: selected ? 1.5 : 1))
        .padding(.horizontal, 28)
    }
}

struct PrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold, design: .monospaced))
            .padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color(red: 0.91, green: 0.56, blue: 0.31)))
            .foregroundStyle(.black)
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

struct SecondaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, design: .monospaced))
            .padding(.vertical, 13)
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.white.opacity(0.18)))
            .foregroundStyle(.white.opacity(0.9))
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

// ── game ─────────────────────────────────────────────────────────────────────
struct GameView: UIViewRepresentable {
    let seed: UInt32
    let cls: PlayerClass
    let mode: Mode
    let server: String?
    let name: String
    /// (your score, your team's score, the opposing score) — the last two matter only in
    /// 1V1 and 2V2, and equal the first and zero elsewhere.
    let onEnd: (Int, Int, Int) -> Void

    /// Holds the socket for the lifetime of the view. Without a coordinator the DriftNet
    /// would be released the moment makeUIView returned and the connection would die
    /// somewhere between "joined" and the first frame.
    final class Coordinator {
        var net: DriftNet?
        deinit { net?.disconnect() }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SKView {
        let v = SKView()
        v.preferredFramesPerSecond = 60
        // Both off in release: they cost frames and are the first thing a reviewer notices
        // as unfinished if left on.
        v.showsFPS = false
        v.showsNodeCount = false
        v.ignoresSiblingOrder = true

        let scene = DriftScene(size: UIScreen.main.bounds.size, seed: seed,
                               playerClass: cls, mode: mode, onRoundEnd: onEnd)
        v.presentScene(scene)

        if let server {
            let net = DriftNet()
            context.coordinator.net = net
            scene.net = net
            // The server's seed is authoritative. Presenting first and re-seeding on welcome
            // means the player sees a field immediately instead of a black screen while the
            // socket opens — and once welcome lands they are on everyone else's field.
            net.onWelcome = { [weak scene] s in scene?.restart(seed: s) }
            net.onRoundReset = { [weak scene] s in scene?.restart(seed: s) }
            net.connect(server: server, name: name)
        }
        return v
    }

    func updateUIView(_ v: SKView, context: Context) {}

    static func dismantleUIView(_ v: SKView, coordinator: Coordinator) {
        coordinator.net?.disconnect()
    }
}

struct GameOverView: View {
    let score: Int, best: Int
    let mode: Mode, team: Int, foe: Int
    let onAgain: () -> Void, onMenu: () -> Void

    /// In a contested mode the score alone does not say what happened — you can score well
    /// and lose. The result line is the point of playing 1V1.
    private var verdict: String? {
        guard mode.rivals > 0 else { return nil }
        if team > foe { return "you win  \(team) – \(foe)" }
        if team < foe { return "you lose  \(team) – \(foe)" }
        return "drawn  \(team) – \(foe)"
    }

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Text("\(score)").font(.system(size: 64, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(red: 0.91, green: 0.56, blue: 0.31))
            if let verdict {
                Text(verdict).font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundStyle(team >= foe ? Color(red: 0.43, green: 0.85, blue: 0.60)
                                                 : Color(red: 0.91, green: 0.45, blue: 0.35))
            }
            Text(mode == .solo ? (score >= best ? "new best" : "best \(best)") : mode.name)
                .font(.system(size: 13, design: .monospaced)).foregroundStyle(.secondary)
            Spacer()
            VStack(spacing: 10) {
                Button(action: onAgain) { Text("AGAIN").frame(maxWidth: .infinity) }
                    .buttonStyle(PrimaryButton())
                Button(action: onMenu) { Text("MENU").frame(maxWidth: .infinity) }
                    .buttonStyle(SecondaryButton())
            }
            .padding(.horizontal, 28).padding(.bottom, 40)
        }
    }
}
