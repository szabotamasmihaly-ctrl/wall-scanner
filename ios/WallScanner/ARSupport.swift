import SwiftUI
import ARKit
import RealityKit

/// Hosts a RealityKit ARView owned by a controller object.
struct ARViewContainer: UIViewRepresentable {
    let arView: ARView
    func makeUIView(context: Context) -> ARView { arView }
    func updateUIView(_ uiView: ARView, context: Context) {}
}

enum ARSupport {
    static var hasLiDAR: Bool {
        ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
    }

    static func makeConfiguration(worldMap: ARWorldMap? = nil) -> ARWorldTrackingConfiguration {
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        if hasLiDAR {
            config.sceneReconstruction = .mesh
        }
        config.environmentTexturing = .none
        config.initialWorldMap = worldMap
        return config
    }

    static func makeARView() -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        view.renderOptions.insert(.disableMotionBlur)
        return view
    }

    /// Raycasts from a screen point onto real surfaces (LiDAR depth / planes / mesh).
    static func worldPoint(at screenPoint: CGPoint, in view: ARView) -> SIMD3<Float>? {
        let targets: [ARRaycastQuery.Target] = [.existingPlaneGeometry, .estimatedPlane]
        for target in targets {
            if let hit = view.raycast(from: screenPoint, allowing: target, alignment: .any).first {
                let c = hit.worldTransform.columns.3
                return SIMD3<Float>(c.x, c.y, c.z)
            }
        }
        return nil
    }

    static func cameraPosition(_ view: ARView) -> SIMD3<Float>? {
        guard let c = view.session.currentFrame?.camera.transform.columns.3 else { return nil }
        return SIMD3<Float>(c.x, c.y, c.z)
    }

    // MARK: - Entities

    static func marker(color: UIColor) -> ModelEntity {
        ModelEntity(mesh: .generateSphere(radius: 0.02), materials: [UnlitMaterial(color: color)])
    }

    /// Cyan rectangle (edges + faint fill) showing the wall area, in wall-frame coordinates.
    static func wallOutline(width: Float, height: Float) -> Entity {
        let root = Entity()
        let t: Float = 0.01
        let edge = UnlitMaterial(color: .cyan)
        let edges: [(SIMD3<Float>, SIMD3<Float>)] = [
            ([width / 2, 0, 0], [width, t, t]),
            ([width / 2, height, 0], [width, t, t]),
            ([0, height / 2, 0], [t, height, t]),
            ([width, height / 2, 0], [t, height, t])
        ]
        for (pos, size) in edges {
            let e = ModelEntity(mesh: .generateBox(size: size), materials: [edge])
            e.position = pos
            root.addChild(e)
        }
        var fill = UnlitMaterial(color: .cyan)
        fill.blending = .transparent(opacity: .init(floatLiteral: 0.15))
        let plane = ModelEntity(mesh: .generatePlane(width: width, height: height), materials: [fill])
        plane.position = [width / 2, height / 2, 0.002]
        root.addChild(plane)
        return root
    }

    static func texture(from image: UIImage) -> TextureResource? {
        guard let cg = image.cgImage else { return nil }
        return try? TextureResource.generate(from: cg, options: .init(semantic: .color))
    }

    static func overlayMaterial(texture: TextureResource, opacity: Float) -> UnlitMaterial {
        var m = UnlitMaterial()
        m.color = .init(tint: .white, texture: .init(texture))
        m.blending = .transparent(opacity: .init(floatLiteral: opacity))
        return m
    }
}

extension ARCamera.TrackingState {
    var userText: String {
        switch self {
        case .normal: return "Tracking OK"
        case .notAvailable: return "Tracking not available"
        case .limited(.initializing): return "Starting… move the phone slowly"
        case .limited(.relocalizing): return "Recognising the room… look around slowly"
        case .limited(.excessiveMotion): return "Slow down"
        case .limited(.insufficientFeatures): return "Not enough detail – add light or aim at textured areas"
        case .limited: return "Tracking limited"
        }
    }
}

extension ARFrame.WorldMappingStatus {
    var userText: String {
        switch self {
        case .notAvailable: return "Map: not ready – look around the room"
        case .limited: return "Map: limited – keep moving around"
        case .extending: return "Map: good"
        case .mapped: return "Map: excellent"
        @unknown default: return "Map: unknown"
        }
    }
    var isGoodEnough: Bool { self == .extending || self == .mapped }
}
