import SwiftUI
import ARKit
import RealityKit

/// Measures points with LiDAR by aiming the crosshair: building corners (control points),
/// window / door edges, single points. Everything in one session shares one coordinate frame.
final class ExteriorMeasureController: NSObject, ObservableObject, ARSessionDelegate {
    enum Mode: Hashable { case known, feature(BuildingFeatureKind) }

    @Published private(set) var trackingText = "Starting…"
    @Published private(set) var livePoint: SIMD3<Float>?
    @Published private(set) var liveDistance: Float?
    @Published private(set) var fromLast: Float?
    @Published var mode: Mode = .known { didSet { pending = [] } }
    @Published private(set) var pending: [SIMD3<Float>] = []
    @Published var session: MeasureSession
    @Published var message: String?

    let arView = ARSupport.makeARView()
    private var lastAdded: SIMD3<Float>?
    private let markers = AnchorEntity(world: matrix_identity_float4x4)
    private var lastRay: TimeInterval = 0

    init(kind: SessionKind = .exterior, name: String) {
        session = MeasureSession(kind: kind, name: name)
        super.init()
        arView.session.delegate = self
        arView.scene.addAnchor(markers)
        arView.debugOptions.insert(.showSceneUnderstanding)
    }

    func start() { arView.session.run(ARSupport.makeConfiguration(), options: [.resetTracking, .removeExistingAnchors]) }
    func pause() { arView.session.pause() }

    var pointCount: Int { session.observations.count + session.features.reduce(0) { $0 + $1.points.count } }

    func addObservation(controlPointID: UUID) {
        guard let p = livePoint else { message = "Aim the crosshair at a surface first."; return }
        session.observations.append(ControlObservation(controlPointID: controlPointID, position: Vec3(p)))
        history.append(true)
        addMarker(p, color: .systemGreen)
    }

    func addFeaturePoint() {
        guard case .feature(let kind) = mode else { return }
        guard let p = livePoint else { message = "Aim the crosshair at a surface first."; return }
        pending.append(p)
        addMarker(p, color: .systemBlue)
        if pending.count >= kind.pointsNeeded {
            session.features.append(MeasuredFeature(kind: kind, points: pending.map { Vec3($0) }))
            history.append(false)
            pending = []
        }
    }

    /// Order in which observations (true) and features (false) were added, for Undo.
    private var history: [Bool] = []

    func undo() {
        if !pending.isEmpty {
            pending.removeLast()
        } else if let last = history.popLast() {
            if last { if !session.observations.isEmpty { session.observations.removeLast() } }
            else { if !session.features.isEmpty { session.features.removeLast() } }
        }
        rebuildMarkers()
    }

    private func addMarker(_ p: SIMD3<Float>, color: UIColor) {
        let m = ARSupport.marker(color: color)
        m.position = p
        markers.addChild(m)
        lastAdded = p
    }

    private func rebuildMarkers() {
        markers.children.removeAll()
        for o in session.observations { addMarker(o.position.simd, color: .systemGreen) }
        for f in session.features { for p in f.points { addMarker(p.simd, color: .systemBlue) } }
        for p in pending { addMarker(p, color: .systemBlue) }
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard frame.timestamp - lastRay > 0.1 else { return }
        lastRay = frame.timestamp
        let text = frame.camera.trackingState.userText
        if text != trackingText { trackingText = text }
        let center = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
        if let p = ARSupport.worldPoint(at: center, in: arView) {
            livePoint = p
            let c = frame.camera.transform.columns.3
            liveDistance = simd_distance(p, SIMD3<Float>(c.x, c.y, c.z))
            fromLast = lastAdded.map { simd_distance($0, p) }
        } else {
            livePoint = nil
            liveDistance = nil
            fromLast = nil
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        message = "AR session failed: \(error.localizedDescription)"
    }
}

struct ExteriorMeasureView: View {
    @EnvironmentObject private var store: BuildingStore
    @Environment(\.dismiss) private var dismiss
    let buildingID: UUID
    @StateObject private var c: ExteriorMeasureController
    @State private var choosingPoint = false

    init(buildingID: UUID, name: String) {
        self.buildingID = buildingID
        _c = StateObject(wrappedValue: ExteriorMeasureController(name: name))
    }

    var body: some View {
        ZStack {
            ARViewContainer(arView: c.arView).ignoresSafeArea()
            Crosshair(color: c.livePoint == nil ? .red : .white)
            VStack(spacing: 10) {
                HStack(alignment: .top) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.headline).padding(10).background(.ultraThinMaterial, in: Circle())
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.trackingText)
                        Text("\(c.pointCount) points measured")
                        if (c.liveDistance ?? 0) > 5 {
                            Text("Over 5 m away: LiDAR range exceeded, accuracy drops. Move closer.").foregroundStyle(.yellow)
                        }
                    }
                    .font(.caption).padding(8).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                    Spacer()
                }
                Spacer()
                panel
            }
            .padding()
        }
        .onAppear { c.start() }
        .onDisappear { c.pause() }
        .sheet(isPresented: $choosingPoint) {
            ControlPointPicker(buildingID: buildingID) { id in c.addObservation(controlPointID: id) }
                .environmentObject(store)
                .presentationDetents([.medium, .large])
        }
        .alert("Note", isPresented: Binding(get: { c.message != nil }, set: { if !$0 { c.message = nil } })) {
            Button("OK") { c.message = nil }
        } message: { Text(c.message ?? "") }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(c.liveDistance.map { String(format: "Aim point %.2f m away", $0) } ?? "No surface under crosshair")
                Spacer()
                if let d = c.fromLast { Text(String(format: "%.2f m from last", d)).bold() }
            }
            .font(.callout.monospacedDigit())
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    modeButton("Known point", symbol: "scope", mode: .known)
                    ForEach(BuildingFeatureKind.allCases) { k in
                        modeButton(k.label, symbol: k.symbol, mode: .feature(k))
                    }
                }
            }
            Text(hint).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Undo") { c.undo() }.buttonStyle(.bordered).disabled(c.pointCount == 0 && c.pending.isEmpty)
                Spacer()
                Button {
                    if c.mode == .known { choosingPoint = true } else { c.addFeaturePoint() }
                } label: { Label("Add point", systemImage: "plus.circle.fill") }
                .buttonStyle(.borderedProminent)
                .disabled(c.livePoint == nil)
                Button("Save") { save() }
                    .buttonStyle(.bordered)
                    .disabled(c.pointCount == 0)
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var hint: String {
        switch c.mode {
        case .known: return "Aim at a fixed point (outside building corner at ground level, survey mark, door frame corner) and add it. Measure at least 2 known points in every session."
        case .feature(let k) where k.pointsNeeded == 2:
            return c.pending.isEmpty ? "Aim at the LEFT edge of the \(k.label.lowercased()) and add." : "Now aim at the RIGHT edge and add."
        case .feature: return "Aim at the point and add."
        }
    }

    private func modeButton(_ title: String, symbol: String, mode: ExteriorMeasureController.Mode) -> some View {
        Button { c.mode = mode } label: { Label(title, systemImage: symbol).font(.caption) }
            .buttonStyle(.bordered)
            .tint(c.mode == mode ? .accentColor : .gray)
    }

    private func save() {
        store.addSession(c.session, to: buildingID)
        dismiss()
    }
}

/// Pick an existing control point of the building or create a new one.
struct ControlPointPicker: View {
    @EnvironmentObject private var store: BuildingStore
    @Environment(\.dismiss) private var dismiss
    let buildingID: UUID
    var onPick: (UUID) -> Void
    @State private var newName = ""
    @State private var isCorner = true

    var body: some View {
        NavigationStack {
            List {
                Section("New known point") {
                    TextField("Name, e.g. Corner NE", text: $newName)
                    Toggle("Outside building corner", isOn: $isCorner)
                    Button("Add new point") {
                        guard var b = store.building(buildingID) else { return }
                        let cp = ControlPoint(name: newName.isEmpty ? "Point \(b.controlPoints.count + 1)" : newName, isBuildingCorner: isCorner)
                        b.controlPoints.append(cp)
                        store.save(b)
                        onPick(cp.id)
                        dismiss()
                    }
                }
                if let b = store.building(buildingID), !b.controlPoints.isEmpty {
                    Section("Existing points") {
                        ForEach(b.controlPoints) { cp in
                            Button {
                                onPick(cp.id)
                                dismiss()
                            } label: {
                                HStack {
                                    Image(systemName: cp.isBuildingCorner ? "square.dashed" : "scope")
                                    Text(cp.name)
                                    Spacer()
                                    if cp.surveyed != nil { Image(systemName: "globe").foregroundStyle(.blue) }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Which known point?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
