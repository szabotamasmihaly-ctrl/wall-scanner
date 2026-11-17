import Foundation

/// Documents/Buildings/<id>/building.json (+ room-<session>.usdz 3D models from RoomPlan).
final class BuildingStore: ObservableObject {
    @Published private(set) var buildings: [Building] = []
    private let root: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = docs.appendingPathComponent("Buildings", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        reload()
    }

    func folder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    func jsonURL(_ id: UUID) -> URL { folder(id).appendingPathComponent("building.json") }
    func modelURL(building: UUID, session: UUID) -> URL {
        folder(building).appendingPathComponent("rooms-\(session.uuidString).usdz")
    }

    func reload() {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        buildings = dirs.compactMap { dir in
            guard let d = try? Data(contentsOf: dir.appendingPathComponent("building.json")) else { return nil }
            return try? JSONDecoder().decode(Building.self, from: d)
        }.sorted { $0.createdAt > $1.createdAt }
    }

    func building(_ id: UUID) -> Building? { buildings.first { $0.id == id } }

    func save(_ b: Building) {
        try? FileManager.default.createDirectory(at: folder(b.id), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(b) { try? d.write(to: jsonURL(b.id), options: .atomic) }
        if let i = buildings.firstIndex(where: { $0.id == b.id }) { buildings[i] = b } else { buildings.insert(b, at: 0) }
    }

    func addSession(_ s: MeasureSession, to id: UUID) {
        guard var b = building(id) else { return }
        b.sessions.append(s)
        save(b)
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: folder(id))
        buildings.removeAll { $0.id == id }
    }
}
