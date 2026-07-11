import SwiftUI

@main
struct SakuraApp: App {
    @StateObject private var vm = SessionViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(vm)
                .preferredColorScheme(.light)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: vm.enterBackground()
            case .active: vm.enterForeground()
            default: break
            }
        }
    }
}
