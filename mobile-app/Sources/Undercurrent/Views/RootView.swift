import SwiftUI

// One screen: the board. Everything else is a push or a sheet off it.
struct RootView: View {
    @Environment(Board.self) private var board
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            HomeView(path: $path)
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .task(let id): TaskDetailView(taskID: id, path: $path)
                    case .run(let id): RunView(runID: id)
                    case .insights: InsightsView()
                    case .settings: SettingsView()
                    case .time: TimeTravelView()
                    }
                }
        }
        .task { await board.refresh() }
    }
}

enum Route: Hashable {
    case task(String)
    case run(String)
    case insights
    case settings
    case time
}
