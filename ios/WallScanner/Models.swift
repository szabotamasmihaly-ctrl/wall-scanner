import Foundation
import SwiftUI

/// A 2D point on a wall, in meters.
/// Origin = bottom-left corner of the wall (where wall meets floor, on the left
/// as seen when facing the wall). x grows to the right, y grows upward.
struct WallPoint: Codable, Hashable {
    var x: Double
    var y: Double
}

enum FeatureKind: String, Codable, CaseIterable, Identifiable {
    case pipe, electrical, rebar, void, other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pipe: return "Pipe"
        case .electrical: return "Electrical"
        case .rebar: return "Rebar / steel"
        case .void: return "Hole / void"
        case .other: return "Other"
        }
    }

    var symbol: String {
        switch self {
        case .pipe: return "drop.fill"
        case .electrical: return "bolt.fill"
        case .rebar: return "square.grid.3x3.fill"
        case .void: return "circle.dashed"
        case .other: return "mappin"
        }
    }

    var uiColor: UIColor {
        switch self {
        case .pipe: return .systemBlue
        case .electrical: return .systemRed
        case .rebar: return .systemOrange
        case .void: return .systemPurple
        case .other: return .systemYellow
        }
    }

    var color: Color { Color(uiColor) }
}

/// Something hidden inside the wall. One point = a spot (socket, box, hole),
/// two or more points = a run (pipe, cable, rebar).
struct WallFeature: Codable, Identifiable, Hashable {
    var id = UUID()
    var kind: FeatureKind
    var points: [WallPoint]
    var note: String = ""
}

/// A surveyed coordinate in a building / national grid system (e.g. EOV, UTM, a site grid).
struct SurveyedCoordinate: Codable, Hashable {
    var easting: Double
    var northing: Double
    var elevation: Double
    /// Free text naming the coordinate system, e.g. "EOV (EPSG:23700)" or "Site grid A".
    var system: String
}

/// A physical reference point on the wall (a corner, a surveyor's mark, a column edge).
/// Its position on the wall is always known; the surveyed coordinate is optional and
/// lets the wall be georeferenced later once 2+ points have surveyed values.
struct ReferencePoint: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var wallPosition: WallPoint
    var surveyed: SurveyedCoordinate?
}

struct WallRecord: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var createdAt = Date()
    /// Wall size in meters.
    var width: Double
    var height: Double
    var features: [WallFeature] = []
    /// Bottom-left and bottom-right corners are added automatically on scan.
    var referencePoints: [ReferencePoint] = []
    var hasPhoto = false
    var hasWorldMap = false

    // Link to a building (all optional so older saved walls still load).
    /// The building whose known points were measured during this wall scan.
    var buildingID: UUID?
    /// Known points measured in the same AR session as the wall.
    var controlObservations: [ControlObservation]?
    /// Wall frame in that session: bottom-left corner and the direction along the wall.
    var frameOrigin: Vec3?
    var frameAxisX: Vec3?

    /// Distance in meters from a wall point to the nearest feature, and which feature.
    func nearestFeature(to p: WallPoint) -> (WallFeature, Double)? {
        var best: (WallFeature, Double)?
        for f in features {
            let d = WallGeometry.distance(from: p, to: f.points)
            if best == nil || d < best!.1 { best = (f, d) }
        }
        return best
    }
}
