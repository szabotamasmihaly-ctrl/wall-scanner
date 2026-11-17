import SwiftUI
import ARKit
import RealityKit

/// Drives the "Show on wall" screen: finds the saved wall again (automatically via the
/// saved world map, or manually by tapping the two bottom corners) and projects the
/// saved photo + markings onto it.
final class OverlayController: NSObject, ObservableObject, ARSessionDelegate {
    enum AlignStep { case none, tapFirstCorner, tapSecondCorner }

    struct Readout: Equatable {
        var x: Double
        var y: Double
        var onWall: Bool
        var nearestKind: FeatureKind?
        var distance: Double?
    }

    @Published private(set) var trackingText = "Starting…"
    @Published private(set) var isPlaced = false
    @Published private(set) var placedManually = false
    @Published var alignStep: AlignStep = .none
    @Published var opacity: Float = 0.75 { didSet { applyMaterial() } }
    @Published var options = OverlayRenderer.Options() { didSet { rebuildTexture() } }
    @Published private(set) var readout: Readout?
    @Published var message: String?

    let arView = ARSupport.makeARView()
    private(set) var wall: WallRecord
    private let store: WallStore
    private let photo: UIImage?

    private let overlayAnchor = AnchorEntity(world: matrix_identity_float4x4)
    private var overlayModel: ModelEntity?
    private var texture: TextureResource?
    private var wallTransform: simd_float4x4?
    private var firstCorner: SIMD3<Float>?
    private var lastReadout: TimeInterval = 0

    init(wall: WallRecord, store: WallStore) {
        self.wall = wall
        self.store = store
        self.photo = store.photo(for: wall.id)
        super.init()
        arView.session.delegate = self
        arView.scene.addAnchor(overlayAnchor)
        overlayAnchor.isEnabled = false
        arView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap(_:))))
        rebuildTexture()
    }

    func start() {
        let map = wall.hasWorldMap ? store.worldMap(for: wall.id) : nil
        if map == nil {
            alignStep = .tapFirstCorner
        }
        arView.session.run(ARSupport.makeConfiguration(worldMap: map), options: [.resetTracking, .removeExistingAnchors])
    }

    func pause() { arView.session.pause() }

    func beginManualAlign() {
        firstCorner = nil
        alignStep = .tapFirstCorner
    }

    // MARK: - Overlay content

    private func rebuildTexture() {
        let image = OverlayRenderer.render(wall: wall, photo: photo, options: options)
        texture = ARSupport.texture(from: image)
        if overlayModel == nil {
            let w = Float(wall.width), h = Float(wall.height)
            let model = ModelEntity(mesh: .generatePlane(width: w, height: h))
            // Slightly in front of the stored plane: finished walls have plaster/board on top.
            model.position = [w / 2, h / 2, 0.01]
            overlayAnchor.addChild(model)
            overlayModel = model
        }
        applyMaterial()
    }

    private func applyMaterial() {
        guard let texture, let model = overlayModel else { return }
        model.model?.materials = [ARSupport.overlayMaterial(texture: texture, opacity: opacity)]
    }

    private func place(transform: simd_float4x4, manual: Bool) {
        wallTransform = transform
        overlayAnchor.transform = Transform(matrix: transform)
        overlayAnchor.isEnabled = true
        isPlaced = true
        placedManually = manual
    }

    // MARK: - Manual alignment

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        guard alignStep != .none else { return }
        let point = g.location(in: arView)
        guard let hit = ARSupport.worldPoint(at: point, in: arView) else {
            message = "Couldn't find a surface there. Aim at the corner where the wall meets the floor."
            return
        }
        switch alignStep {
        case .tapFirstCorner:
            firstCorner = hit
            alignStep = .tapSecondCorner
        case .tapSecondCorner:
            guard let a = firstCorner, let cam = ARSupport.cameraPosition(arView),
                  let frame = WallGeometry.wallFrame(cornerA: a, cornerB: hit, cameraPosition: cam) else {
                message = "Corners too close together. Tap the other end of the wall."
                return
            }
            alignStep = .none
            place(transform: frame.transform, manual: true)
            let diff = abs(Double(frame.width) - wall.width)
            if diff > 0.05 {
                message = String(format: "The measured width (%.2f m) differs from the saved width (%.2f m) by %.0f cm. Check that you tapped the same corners.", frame.width, wall.width, diff * 100)
            }
        case .none:
            break
        }
    }

    /// Stores a new world map of the finished room, so next time the wall is found automatically.
    func saveAlignment() {
        guard let t = wallTransform else { return }
        for a in arView.session.currentFrame?.anchors ?? [] where a.name == "wall" {
            arView.session.remove(anchor: a)
        }
        arView.session.add(anchor: ARAnchor(name: "wall", transform: t))
        arView.session.getCurrentWorldMap { [weak self] map, error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let map else {
                    self.message = "Map not ready yet (\(error?.localizedDescription ?? "unknown")). Look around the room a bit more and try again."
                    return
                }
                do {
                    try self.store.saveWorldMap(map, for: self.wall.id)
                    self.wall.hasWorldMap = true
                    self.store.save(self.wall)
                    self.placedManually = false
                    self.message = "Saved. Next time this wall will be found automatically."
                } catch {
                    self.message = "Could not save map: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        guard !placedManually else { return }
        if let a = anchors.first(where: { $0.name == "wall" }) {
            alignStep = .none
            place(transform: a.transform, manual: false)
        }
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        guard !placedManually else { return }
        if let a = anchors.first(where: { $0.name == "wall" }) {
            place(transform: a.transform, manual: false)
        }
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        trackingText = camera.trackingState.userText
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard frame.timestamp - lastReadout > 0.1 else { return }
        lastReadout = frame.timestamp
        updateReadout()
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        message = "AR session failed: \(error.localizedDescription)"
    }

    /// What is under the crosshair in the middle of the screen.
    private func updateReadout() {
        guard isPlaced, let t = wallTransform else { readout = nil; return }
        let center = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
        guard let ray = arView.ray(through: center),
              let hit = WallGeometry.intersect(rayOrigin: ray.origin, direction: ray.direction, frame: t) else {
            readout = nil
            return
        }
        let p = WallGeometry.wallPoint(fromWorld: hit, in: t)
        let onWall = p.x >= 0 && p.y >= 0 && p.x <= wall.width && p.y <= wall.height
        let nearest = wall.nearestFeature(to: p)
        let r = Readout(x: p.x, y: p.y, onWall: onWall, nearestKind: nearest?.0.kind, distance: nearest?.1)
        if r != readout { readout = r }
    }
}
