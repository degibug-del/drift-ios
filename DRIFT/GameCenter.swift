// GameCenter.swift — DRIFT's native scoreboard.
//
// This is the piece that makes the iOS build an app rather than a bundled web page, and it
// is worth being precise about why. Guideline 4.2 does not ask "is there native code" — a
// WKWebView is native code. It asks whether the app does something the website cannot.
// Game Center is exactly that: a system-level identity, a leaderboard the player already
// has friends on, and achievements that persist outside the app. None of it is reachable
// from a browser.
//
// It also replaces something worse. The web game posts scores to a KV board keyed by class,
// with no identity behind them — anyone can submit any number, and the guard that checks
// them only bounds the value. Game Center scores are attributed to a real Apple account.
//
// The web layer stays the renderer and calls in through window.webkit.messageHandlers.
// Score submission is one-way and fire-and-forget: a failed submit must never interrupt a
// run, because the run is the product and the leaderboard is not.

import Foundation
import GameKit
import UIKit

/// Leaderboard and achievement ids. These must match App Store Connect exactly — a typo
/// here fails silently at submit time, which is the worst way for this to break.
enum GC {
    /// Leaderboard ids live on `Mode.board`, one per mode — see the note there for why a
    /// single shared board would have ranked the mode instead of the player. Nothing should
    /// name a board here: routing through the mode is what keeps a new mode from silently
    /// submitting into an existing board.
    static var allLeaderboards: [String] { Mode.all.map(\.board) }

    /// Every one of these is awarded somewhere. That is not a given — three of the four
    /// were declared here and granted nowhere, and `combo_10` could never have been earned
    /// at all: the combo caps at x6, so a player chasing it would have been chasing a
    /// number the simulation cannot produce. Renamed to what is actually reachable.
    ///
    /// Checked before creating the App Store Connect records, because an achievement that
    /// exists in the store and never unlocks is the same lie as an ability card describing
    /// something the game does not do.
    enum Achievement: String, CaseIterable {
        /// Finish a round. Anyone who plays once earns it.
        case firstRun    = "world.phronesis.drift.first_run"
        /// Reach the maximum multiplier, x6.
        case maxCombo    = "world.phronesis.drift.max_combo"
        /// Finish a round online.
        case online      = "world.phronesis.drift.first_online"
        /// Finish a round with each of VOID, SURGE and PHASE.
        case allClasses  = "world.phronesis.drift.all_classes"

        var title: String {
            switch self {
            case .firstRun:   return "First Drift"
            case .maxCombo:   return "Six Times Over"
            case .online:     return "Not Alone"
            case .allClasses: return "All Three"
            }
        }
        var detail: String {
            switch self {
            case .firstRun:   return "Finish a round."
            case .maxCombo:   return "Reach a x6 multiplier."
            case .online:     return "Finish a round on a shared field."
            case .allClasses: return "Finish a round as VOID, SURGE and PHASE."
            }
        }
    }
}

final class GameCenterBridge: NSObject {

    static let shared = GameCenterBridge()
    private(set) var authenticated = false

    /// Authenticate. Called once at launch.
    ///
    /// GameKit hands back a view controller when it wants to present sign-in, and it can do
    /// so LATER as well as immediately — the handler is not one-shot. Presenting from a
    /// stored reference rather than assuming the root controller is what keeps this working
    /// when the prompt arrives mid-session.
    func authenticate(presenter: UIViewController) {
        GKLocalPlayer.local.authenticateHandler = { [weak presenter] vc, error in
            if let vc {
                presenter?.present(vc, animated: true)
                return
            }
            self.authenticated = GKLocalPlayer.local.isAuthenticated
            if let error {
                // Not fatal and not worth a dialog: a player with Game Center switched off
                // should still get the whole game. Logged so it is diagnosable.
                NSLog("[drift] Game Center unavailable: \(error.localizedDescription)")
            }
        }
    }

    /// Submit a score. Silent on failure by design — see the file comment.
    func submit(score: Int, leaderboard: String) {
        guard authenticated, score > 0 else { return }
        GKLeaderboard.submitScore(score, context: 0, player: GKLocalPlayer.local,
                                  leaderboardIDs: [leaderboard]) { error in
            if let error { NSLog("[drift] score submit failed: \(error.localizedDescription)") }
        }
    }

    /// Report an achievement as fully earned. Repeat reports are harmless — GameKit keeps
    /// the maximum — so callers do not have to track what has already been sent.
    func award(_ a: GC.Achievement) {
        guard authenticated else { return }
        let ach = GKAchievement(identifier: a.rawValue)
        ach.percentComplete = 100
        ach.showsCompletionBanner = true
        GKAchievement.report([ach]) { error in
            if let error { NSLog("[drift] achievement failed: \(error.localizedDescription)") }
        }
    }

    /// The system leaderboard UI, presented natively over the game.
    func showDashboard(from presenter: UIViewController, leaderboard: String? = nil) {
        guard authenticated else {
            let a = UIAlertController(title: "Game Center",
                                      message: "Sign in to Game Center in Settings to use leaderboards.",
                                      preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "OK", style: .default))
            presenter.present(a, animated: true)
            return
        }
        let vc = leaderboard.map { GKGameCenterViewController(leaderboardID: $0, playerScope: .global,
                                                             timeScope: .allTime) }
            ?? GKGameCenterViewController(state: .leaderboards)
        vc.gameCenterDelegate = self
        presenter.present(vc, animated: true)
    }
}

extension GameCenterBridge: GKGameCenterControllerDelegate {
    func gameCenterViewControllerDidFinish(_ vc: GKGameCenterViewController) {
        vc.dismiss(animated: true)
    }
}

/// Decodes what the web layer sends. Kept as a separate type so a malformed message from
/// the page cannot crash the app — every field is optional and validated.
struct GameEvent {
    let kind: String
    let score: Int
    let mode: String
    let combo: Int

    init?(_ body: Any) {
        guard let d = body as? [String: Any], let kind = d["kind"] as? String else { return nil }
        self.kind = kind
        // JS numbers arrive as NSNumber or String depending on how they were built; accept
        // both rather than silently dropping a score because of a type mismatch.
        self.score = (d["score"] as? NSNumber)?.intValue ?? Int((d["score"] as? String) ?? "") ?? 0
        self.combo = (d["combo"] as? NSNumber)?.intValue ?? 0
        self.mode = (d["mode"] as? String) ?? "SOLO"
    }
}
