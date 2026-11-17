import SwiftUI

@main
struct WallScannerApp: App {
    @StateObject private var store = WallStore()
    @StateObject private var buildings = BuildingStore()

    var body: some Scene {
        WindowGroup {
            TabView {
                WallListView()
                    .tabItem { Label("Walls", systemImage: "square.split.bottomrightquarter") }
                BuildingListView()
                    .tabItem { Label("Buildings", systemImage: "building.2") }
            }
            .environmentObject(store)
            .environmentObject(buildings)
        }
    }
}
