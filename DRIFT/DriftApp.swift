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
    case servers
    case playing(seed: UInt32, cls: PlayerClass, server: String?)
    case over(score: Int, cls: PlayerClass)
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
                         onSolo: { route = .playing(seed: UInt32.random(in: 1...4_000_000_000),
                                                    cls: cls, server: nil) },
                         onOnline: { route = .servers })
            case .servers:
                ServerBrowser(name: $playerName,
                              onBack: { route = .menu },
                              onJoin: { s in
                                  route = .playing(seed: UInt32.random(in: 1...4_000_000_000),
                                                   cls: cls, server: s)
                              })
            case let .playing(seed, c, server):
                GameView(seed: seed, cls: c, server: server, name: playerName) { score in
                    if score > best { best = score }
                    // Online scores go to their own board: a shared field with other players
                    // pulling the same particles is not the same contest as a solo run, and
                    // one leaderboard for both would make neither number mean anything.
                    GameCenterBridge.shared.submit(
                        score: score,
                        leaderboard: server == nil ? GC.leaderboardBest : GC.leaderboardOnline)
                    if server != nil { GameCenterBridge.shared.award(.online) }
                    Haptics.shared.roundEnd()
                    route = .over(score: score, cls: c)
                }
                .ignoresSafeArea()
            case let .over(score, c):
                GameOverView(score: score, best: best,
                             onAgain: { route = .playing(seed: UInt32.random(in: 1...4_000_000_000),
                                                         cls: c, server: nil) },
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
    let onSolo: () -> Void
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
                Button(action: onSolo) { Label("PLAY", systemImage: "play.fill").frame(maxWidth: .infinity) }
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
    let server: String?
    let name: String
    let onEnd: (Int) -> Void

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
                               playerClass: cls, onRoundEnd: onEnd)
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
    let onAgain: () -> Void, onMenu: () -> Void
    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Text("\(score)").font(.system(size: 64, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(red: 0.91, green: 0.56, blue: 0.31))
            Text(score >= best ? "new best" : "best \(best)")
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
