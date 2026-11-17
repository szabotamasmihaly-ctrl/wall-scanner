import Foundation
import simd

/// A 3D position in an AR session's world frame (metres, y up).
struct Vec3: Codable, Hashable {
    var x: Double
    var y: Double
    var z: Double

    init(x: Double, y: Double, z: Double) { self.x = x; self.y = y; self.z = z }
    init(_ v: SIMD3<Float>) { x = Double(v.x); y = Double(v.y); z = Double(v.z) }
    var simd: SIMD3<Float> { SIMD3<Float>(Float(x), Float(y), Float(z)) }
}

/// A position in the building's plan frame: east / north / height, in metres.
/// When any control point has surveyed coordinates this is the survey grid (e.g. EOV);
/// otherwise it is a local frame defined by the first two control points.
struct PlanPoint: Codable, Hashable {
    var e: Double
    var n: Double
    var h: Double = 0
}

/// A fixed point you can find again: an outside building corner, a survey nail,
/// a door frame corner visible from inside and outside.
struct ControlPoint: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    /// Outside corners of the building are joined in list order to draw the outline.
    var isBuildingCorner = true
    /// Known coordinates from a survey, if any.
    var surveyed: SurveyedCoordinate?
}

enum BuildingFeatureKind: String, Codable, CaseIterable, Identifiable {
    case window, door, opening, point
    var id: String { rawValue }
    var label: String {
        switch self {
        case .window: return "Window"
        case .door: return "Door"
        case .opening: return "Opening"
        case .point: return "Point"
        }
    }
    /// Windows, doors and openings are measured edge to edge (2 taps).
    var pointsNeeded: Int { self == .point ? 1 : 2 }
    var symbol: String {
        switch self {
        case .window: return "window.vertical.closed"
        case .door: return "door.left.hand.closed"
        case .opening: return "rectangle.portrait"
        case .point: return "smallcircle.filled.circle"
        }
    }
}

/// Something measured with LiDAR outside the building (a window measured edge to edge, etc.).
struct MeasuredFeature: Codable, Identifiable, Hashable {
    var id = UUID()
    var kind: BuildingFeatureKind
    var label: String = ""
    var points: [Vec3]
}

/// "Control point X is at this position in this session."
struct ControlObservation: Codable, Identifiable, Hashable {
    var id = UUID()
    var controlPointID: UUID
    var position: Vec3
}

enum SurfaceKind: String, Codable { case wall, door, window, opening }

/// A wall / door / window from a RoomPlan scan, flattened to a line on the floor plan.
struct PlanSurface: Codable, Hashable {
    var kind: SurfaceKind
    var start: Vec3
    var end: Vec3
    var bottom: Double
    var height: Double
}

enum SessionKind: String, Codable { case exterior, interior }

/// One continuous AR session. All positions inside share that session's coordinate frame;
/// two or more control points tie the session to the building.
struct MeasureSession: Codable, Identifiable, Hashable {
    var id = UUID()
    var kind: SessionKind
    var name: String
    var createdAt = Date()
    var observations: [ControlObservation] = []
    var features: [MeasuredFeature] = []
    var surfaces: [PlanSurface] = []
    var roomCount = 0
    var hasModel = false
}

struct Building: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var createdAt = Date()
    var controlPoints: [ControlPoint] = []
    var sessions: [MeasureSession] = []

    func controlPoint(_ id: UUID) -> ControlPoint? { controlPoints.first { $0.id == id } }
}
