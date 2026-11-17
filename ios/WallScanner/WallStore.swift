import Foundation
import UIKit
import ARKit

/// Saves each wall in its own folder: Documents/Walls/<id>/
///   wall.json   – the WallRecord (size, features, reference points)
///   photo.jpg   – the rectified (straightened) photo of the open wall
///   map.arworldmap – ARKit world map used to find the wall again later
final class WallStore: ObservableObject {
    @Published private(set) var walls: [WallRecord] = []

    private let root: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = docs.appendingPathComponent("Walls", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        reload()
    }

    func folder(for id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }
    func photoURL(for id: UUID) -> URL { folder(for: id).appendingPathComponent("photo.jpg") }
    func mapURL(for id: UUID) -> URL { folder(for: id).appendingPathComponent("map.arworldmap") }
    func jsonURL(for id: UUID) -> URL { folder(for: id).appendingPathComponent("wall.json") }

    func reload() {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        walls = dirs.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("wall.json")) else { return nil }
            return try? decoder.decode(WallRecord.self, from: data)
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    func wall(_ id: UUID) -> WallRecord? { walls.first { $0.id == id } }

    func save(_ wall: WallRecord) {
        let dir = folder(for: wall.id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(wall) {
            try? data.write(to: jsonURL(for: wall.id), options: .atomic)
        }
        if let i = walls.firstIndex(where: { $0.id == wall.id }) {
            walls[i] = wall
        } else {
            walls.insert(wall, at: 0)
        }
    }

    func savePhoto(_ image: UIImage, for id: UUID) {
        try? FileManager.default.createDirectory(at: folder(for: id), withIntermediateDirectories: true)
        if let data = image.jpegData(compressionQuality: 0.9) {
            try? data.write(to: photoURL(for: id), options: .atomic)
        }
    }

    func photo(for id: UUID) -> UIImage? {
        UIImage(contentsOfFile: photoURL(for: id).path)
    }

    func saveWorldMap(_ map: ARWorldMap, for id: UUID) throws {
        try FileManager.default.createDirectory(at: folder(for: id), withIntermediateDirectories: true)
        let data = try NSKeyedArchiver.archivedData(withRootObject: map, requiringSecureCoding: true)
        try data.write(to: mapURL(for: id), options: .atomic)
    }

    func worldMap(for id: UUID) -> ARWorldMap? {
        guard let data = try? Data(contentsOf: mapURL(for: id)) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data)
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: folder(for: id))
        walls.removeAll { $0.id == id }
    }
}
