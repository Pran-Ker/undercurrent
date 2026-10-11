import SwiftUI

@main
struct UndercurrentApp: App {
    @State private var board = Board.live()
    @State private var live = LiveSession()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(board)
                .environment(live)
                .tint(Theme.ink)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await board.refresh() } }
                }
        }
    }
}
