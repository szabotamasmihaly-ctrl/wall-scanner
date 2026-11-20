import SwiftUI
import ARKit
import RealityKit

/// Drives the "Scan a new wall" screen:
/// 1. tap the bottom-left corner, 2. tap the bottom-right corner,
/// 3. set the height, 4. save (photo + world map + record).
final class ScanController: NSObject, ObservableObject, ARSessionDelegate {
    enum Step { case tapFirstCorner, tapSecondCorner, adjust }

    @Published var step: Step = .tapFirstCorner
    @Published var height: Float = 2.6 { didSet { rebuildPreview(); mosaic = nil; mosaicPreview = nil; coverage = 0 } }
    /// Live video scanning: the wall picture is built up from the camera feed.
    @Published private(set) var isRecording = false
    @Published private(set) var mosaicPreview: UIImage?
    @Published private(set) var coverage: Double = 0
    @Published private(set) var videoHint: String?
    private var mosaic: WallMosaic?

    /// Marking pipes / cables / rebar directly in AR while they are visible.
    enum MarkTool: String, CaseIterable, Identifiable { case off = "Off", spot = "Spot", run = "Run"; var id: String { rawValue } }
    @Published var markTool: MarkTool = .off { didSet { pendingRun = []; redrawMarks() } }
    @Published var markKind: FeatureKind = .pipe
    @Published private(set) var features: [WallFeature] = []
    @Published private(set) var pendingRun: [WallPoint] = []
    private let markAnchor = AnchorEntity(world: matrix_identity_float4x4)

    /// Optional link to a building: measure 2+ of its known points in this same session.
    @Published var linkedBuildingID: UUID? { didSet { if oldValue != linkedBuildingID { observations = [] } } }
    @Published private(set) var observations: [ControlObservation] = []

    func markKnownPoint(_ id: UUID) {
        let center = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
        guard let p = ARSupport.worldPoint(at: center, in: arView) else {
            message = "No surface under the crosshair. Aim at the known point and try again."
            return
        }
        observations.append(ControlObservation(controlPointID: id, position: Vec3(p)))
        let m = ARSupport.marker(color: .systemGreen)
        m.position = p
        markAnchor.addChild(m)
    }
    @Published private(set) var width: Float = 0
    @Published private(set) var trackingText = "Starting…"
    @Published private(set) var mappingStatus: ARFrame.WorldMappingStatus = .notAvailable
    @Published var showMesh = true { didSet { applyMeshOption() } }
    @Published var isSaving = false
    @Published var message: String?

    let arView = ARSupport.makeARView()

    private var cornerA: SIMD3<Float>?
    private var wallTransform: simd_float4x4?
    private let previewAnchor = AnchorEntity(world: matrix_identity_float4x4)
    private var lastStatusUpdate: TimeInterval = 0

    override init() {
        super.init()
        arView.session.delegate = self
        arView.scene.addAnchor(previewAnchor)
        arView.scene.addAnchor(markAnchor)
        arView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap(_:))))
        applyMeshOption()
    }

    func start() {
        arView.session.run(ARSupport.makeConfiguration(), options: [.resetTracking, .removeExistingAnchors])
    }

    func pause() { arView.session.pause() }

    func startVideo() {
        guard let t = wallTransform, width > 0 else { return }
        if mosaic == nil {
            let m = WallMosaic(wallTransform: t, width: width, height: height)
            m.onUpdate = { [weak self] image, cov in
                self?.mosaicPreview = image
                self?.coverage = cov
            }
            mosaic = m
        }
        isRecording = true
    }

    func stopVideo() {
        isRecording = false
        videoHint = nil
    }

    func reset() {
        stopVideo()
        mosaic = nil
        mosaicPreview = nil
        coverage = 0
        cornerA = nil
        wallTransform = nil
        features = []
        pendingRun = []
        observations = []
        markTool = .off
        width = 0
        step = .tapFirstCorner
        previewAnchor.children.removeAll()
    }

    private func applyMeshOption() {
        if showMesh {
            arView.debugOptions.insert(.showSceneUnderstanding)
        } else {
            arView.debugOptions.remove(.showSceneUnderstanding)
        }
    }

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        let point = g.location(in: arView)
        if step == .adjust {
            markAt(point)
            return
        }
        guard let hit = ARSupport.worldPoint(at: point, in: arView) else {
            message = "Couldn't find a surface there. Aim at the corner where the wall meets the floor."
            return
        }
        switch step {
        case .tapFirstCorner:
            cornerA = hit
            let m = ARSupport.marker(color: .systemGreen)
            m.position = hit
            previewAnchor.addChild(m)
            step = .tapSecondCorner
        case .tapSecondCorner:
            guard let a = cornerA, let cam = ARSupport.cameraPosition(arView),
                  let frame = WallGeometry.wallFrame(cornerA: a, cornerB: hit, cameraPosition: cam) else {
                message = "The corners are too close together. Tap the other end of the wall."
                return
            }
            wallTransform = frame.transform
            width = frame.width
            step = .adjust
            rebuildPreview()
        case .adjust:
            break
        }
    }

    // MARK: - AR marking

    private func markAt(_ screenPoint: CGPoint) {
        guard markTool != .off, let t = wallTransform,
              let ray = arView.ray(through: screenPoint),
              let hit = WallGeometry.intersect(rayOrigin: ray.origin, direction: ray.direction, frame: t) else { return }
        let p = WallGeometry.wallPoint(fromWorld: hit, in: t)
        guard p.x >= -0.05, p.y >= -0.05, p.x <= Double(width) + 0.05, p.y <= Double(height) + 0.05 else {
            message = "That point is outside the wall frame."
            return
        }
        switch markTool {
        case .spot: features.append(WallFeature(kind: markKind, points: [p]))
        case .run: pendingRun.append(p)
        case .off: break
        }
        redrawMarks()
    }

    func finishRun() {
        guard pendingRun.count >= 2 else { return }
        features.append(WallFeature(kind: markKind, points: pendingRun))
        pendingRun = []
        redrawMarks()
    }

    func undoMark() {
        if !pendingRun.isEmpty { pendingRun.removeLast() } else if !features.isEmpty { features.removeLast() }
        redrawMarks()
    }

    private func redrawMarks() {
        markAnchor.children.removeAll()
        guard let t = wallTransform else { return }
        func dot(_ p: WallPoint, _ color: UIColor) {
            let m = ARSupport.marker(color: color)
            m.scale = SIMD3<Float>(repeating: 0.7)
            m.position = WallGeometry.worldPoint(p, in: t) + SIMD3<Float>(t.columns.2.x, t.columns.2.y, t.columns.2.z) * 0.01
            markAnchor.addChild(m)
        }
        for f in features {
            // Dots every ~5 cm along runs, so the line is visible in AR.
            if f.points.count == 1 { dot(f.points[0], f.kind.uiColor); continue }
            for i in 0..<(f.points.count - 1) {
                let a = f.points[i], b = f.points[i + 1]
                let n = max(1, Int(hypot(b.x - a.x, b.y - a.y) / 0.05))
                for k in 0...n {
                    let u = Double(k) / Double(n)
                    dot(WallPoint(x: a.x + (b.x - a.x) * u, y: a.y + (b.y - a.y) * u), f.kind.uiColor)
                }
            }
        }
        for p in pendingRun { dot(p, .systemYellow) }
        for o in observations {
            let m = ARSupport.marker(color: .systemGreen)
            m.position = o.position.simd
            markAnchor.addChild(m)
        }
    }

    private func rebuildPreview() {
        guard let t = wallTransform, width > 0 else { return }
        previewAnchor.children.removeAll()
        let outline = ARSupport.wallOutline(width: width, height: height)
        outline.transform = Transform(matrix: t)
        previewAnchor.addChild(outline)
    }

    // MARK: - Saving

    func save(name: String, store: WallStore, completion: @escaping (UUID?) -> Void) {
        guard let t = wallTransform, let frame = arView.session.currentFrame else { return }
        isSaving = true

        // 1. Straightened photo of the wall from the current camera view.
        stopVideo()
        let result: (UIImage, Bool)
        do {
            if let m = mosaic, coverage > 0, let img = m.finalImage() {
                result = (img, coverage > 0.97)
            } else {
                result = try WallGeometry.rectifiedPhoto(frame: frame, wallTransform: t, width: width, height: height)
            }
        } catch {
            isSaving = false
            message = error.localizedDescription
            completion(nil)
            return
        }

        let (photo, allVisible) = result
        var record = WallRecord(name: name.isEmpty ? "Wall \(store.walls.count + 1)" : name,
                                width: Double(width), height: Double(height))
        record.referencePoints = [
            ReferencePoint(name: "Bottom-left corner", wallPosition: WallPoint(x: 0, y: 0)),
            ReferencePoint(name: "Bottom-right corner", wallPosition: WallPoint(x: Double(width), y: 0))
        ]
        record.hasPhoto = true
        record.features = features
        if let b = linkedBuildingID, !observations.isEmpty {
            record.buildingID = b
            record.controlObservations = observations
            record.frameOrigin = Vec3(SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z))
            record.frameAxisX = Vec3(SIMD3<Float>(t.columns.0.x, t.columns.0.y, t.columns.0.z))
        }
        store.savePhoto(photo, for: record.id)

        // 2. Anchor the wall in the session so it is stored inside the world map.
        for a in arView.session.currentFrame?.anchors ?? [] where a.name == "wall" {
            arView.session.remove(anchor: a)
        }
        arView.session.add(anchor: ARAnchor(name: "wall", transform: t))

        // 3. World map, so the wall can be found again later.
        arView.session.getCurrentWorldMap { [weak self] map, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let map {
                    do {
                        try store.saveWorldMap(map, for: record.id)
                        record.hasWorldMap = true
                    } catch {
                        self.message = "Photo saved, but the room map could not be saved: \(error.localizedDescription)"
                    }
                } else {
                    self.message = "Photo saved, but the room map was not ready (\(error?.localizedDescription ?? "unknown")). You can align manually later."
                }
                store.save(record)
                self.isSaving = false
                if !allVisible && self.message == nil {
                    self.message = "Saved. Part of the wall was never in view and shows grey in the picture."
                }
                completion(record.id)
            }
        }
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        if isRecording, let m = mosaic {
            m.add(frame)
        }
        guard frame.timestamp - lastStatusUpdate > 0.3 else { return }
        if isRecording, let m = mosaic {
            let hint = m.rejectionReason(for: frame)
            if hint != videoHint { videoHint = hint }
        }
        lastStatusUpdate = frame.timestamp
        if mappingStatus != frame.worldMappingStatus { mappingStatus = frame.worldMappingStatus }
        let text = frame.camera.trackingState.userText
        if trackingText != text { trackingText = text }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        message = "AR session failed: \(error.localizedDescription)"
    }
}
