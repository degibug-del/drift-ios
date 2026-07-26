// ServerBrowser.swift — the native lobby, against the same Durable Objects the web plays on.
//
// Same endpoint, same rooms, same bots. A native player and a browser player join the same
// Durable Object and see each other; this is a second client, not a second game.
//
// The web lobby is a DOM overlay the game injects. This is a real list: it gets pull-to-
// refresh, Dynamic Type, VoiceOver and keyboard focus without any of it being written, and
// a name field that uses the system keyboard rather than a canvas text box.

import SwiftUI

struct DriftServer: Identifiable, Decodable {
    let id: String
    let name: String
    let hue: String
    let blurb: String
    let players: Int
    let bots: Int
    let round: Int

    /// The server sends a CSS hex; SwiftUI needs a Color. Falls back to white rather than
    /// failing, because a wrong colour must never cost the player a server.
    var color: Color {
        var s = hue.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return .white }
        return Color(red: Double((v >> 16) & 0xFF) / 255,
                     green: Double((v >> 8) & 0xFF) / 255,
                     blue: Double(v & 0xFF) / 255)
    }
}

private struct LobbyResponse: Decodable { let servers: [DriftServer] }

@MainActor
final class LobbyModel: ObservableObject {
    @Published var servers: [DriftServer] = []
    @Published var error: String?
    @Published var loading = false

    static let endpoint = URL(string: "https://phronesis-drift-mp.degibug.workers.dev")!

    func load() async {
        loading = true
        defer { loading = false }
        do {
            var req = URLRequest(url: Self.endpoint.appendingPathComponent("servers"))
            // The lobby is live population data; a cached copy would show an empty server as
            // busy and send the player somewhere nobody is.
            req.cachePolicy = .reloadIgnoringLocalCacheData
            req.timeoutInterval = 12
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            servers = try JSONDecoder().decode(LobbyResponse.self, from: data).servers
            error = nil
        } catch {
            // Named plainly, with solo still available. "Could not load" beside a dead list
            // reads as "nobody is playing", which is a different and discouraging claim.
            self.error = "Could not reach the lobby. You can still play solo."
        }
    }
}

struct ServerBrowser: View {
    let onBack: () -> Void
    let onJoin: (String) -> Void

    @StateObject private var model = LobbyModel()

    // There was a name field here. It is gone because a name one player types is content
    // another player reads, and that single text box would have made this an app with
    // user-generated content — owing filtering, reporting and blocking under Guideline 1.2
    // for a game that otherwise offers no way at all to send another person anything.
    //
    // The server assigns a name and tells you what it picked. What the field was FOR is
    // preserved: names still have to be DISTINCT, or you cannot tell who took the cluster
    // you were going for. Typing them was only ever one way to get that.

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button(action: onBack) { Label("back", systemImage: "chevron.left") }
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 20).padding(.top, 12)

            Text("ONLINE").font(.system(size: 26, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(red: 0.27, green: 0.69, blue: 0.54))
                .padding(.horizontal, 20).padding(.top, 6)
            Text("Each server runs its own field, round timer and bots.")
                .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                .padding(.horizontal, 20).padding(.bottom, 14)

            Text("the field will name you when you arrive")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20).padding(.bottom, 4)

            if let e = model.error {
                Text(e).font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color(red: 0.91, green: 0.45, blue: 0.18))
                    .padding(.horizontal, 20).padding(.top, 12)
            }

            List(model.servers) { s in
                Button { onJoin(s.id) } label: {
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 2).fill(s.color).frame(width: 3, height: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.name).font(.system(size: 15, weight: .semibold, design: .monospaced))
                                .foregroundStyle(s.color)
                            Text(s.blurb).font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 1) {
                            Text("\(s.players)").font(.system(size: 15, design: .monospaced))
                            Text(s.players == 1 ? "player" : "players")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .listRowBackground(Color.white.opacity(0.03))
                .accessibilityLabel("\(s.name). \(s.players) players, \(s.bots) bots. \(s.blurb)")
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .refreshable { await model.load() }        // free, because this is a real List
            .overlay {
                if model.loading && model.servers.isEmpty { ProgressView().tint(.white) }
            }
        }
        .task { await model.load() }
    }
}
