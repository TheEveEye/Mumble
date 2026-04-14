import SwiftUI
import SwiftData

@main
struct MumbleApp: App {
    private let dependencies = AppDependencies.live()

    var body: some Scene {
        WindowGroup {
            RootNavigationShell(dependencies: dependencies)
        }
        .modelContainer(dependencies.persistence.container)
    }
}
