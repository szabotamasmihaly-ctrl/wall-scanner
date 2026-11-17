import SwiftUI

struct WallListView: View {
    @EnvironmentObject private var store: WallStore
    @State private var path: [UUID] = []
    @State private var scanning = false

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if store.walls.isEmpty {
                    ContentUnavailableView {
                        Label("No walls yet", systemImage: "square.dashed")
                    } description: {
                        Text("Scan a wall while pipes, cables and rebar are still visible. Later, point the phone at the finished wall to see what is inside.")
                    } actions: {
                        Button("Scan a wall") { scanning = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        ForEach(store.walls) { wall in
                            NavigationLink(value: wall.id) {
                                WallRow(wall: wall)
                            }
                        }
                        .onDelete { idx in
                            for i in idx { store.delete(store.walls[i].id) }
                        }
                    }
                }
            }
            .navigationTitle("Walls")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { scanning = true } label: { Label("Scan wall", systemImage: "plus") }
                }
            }
            .navigationDestination(for: UUID.self) { id in
                WallDetailView(wallID: id)
            }
            .fullScreenCover(isPresented: $scanning) {
                ScanView { id in path = [id] }
                    .environmentObject(store)
            }
        }
    }
}

private struct WallRow: View {
    @EnvironmentObject private var store: WallStore
    let wall: WallRecord

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let img = store.photo(for: wall.id) {
                    Image(uiImage: img).resizable().scaledToFill()
                } else {
                    Color.gray.opacity(0.3)
                }
            }
            .frame(width: 64, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading) {
                Text(wall.name).font(.headline)
                Text(String(format: "%.2f × %.2f m · %d marks", wall.width, wall.height, wall.features.count))
                    .font(.caption).foregroundStyle(.secondary)
                Text(wall.createdAt, style: .date).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
