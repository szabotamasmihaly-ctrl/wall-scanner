import SwiftUI
import ARKit
import RoomPlan

/// Scans one or more rooms with Apple RoomPlan (LiDAR), all in one AR session so the rooms
/// share one coordinate frame, then merges them into one structure. Known points can be
/// marked during the scan to tie the rooms to the building (e.g. the entrance door frame,
/// also measured from outside).
final class RoomScanController: NSObject, ObservableObject, RoomCaptureViewDelegate {
    enum Phase { case scanning, reviewing, merging }

    @Published var phase: Phase = .scanning
    @Published private(set) var rooms: [CapturedRoom] = []
    @Published var observations: [ControlObservation] = []
    @Published var message: String?

    let arSession = ARSession()
    private(set) var captureView: RoomCaptureView!

    override init() {
        super.init()
        captureView = RoomCaptureView(frame: .zero, arSession: arSession)
        captureView.delegate = self
    }

    // RoomCaptureViewDelegate inherits NSCoding; this controller is never archived.
    required init?(coder: NSCoder) { nil }
    func encode(with coder: NSCoder) {}

    static var isSupported: Bool { RoomCaptureSession.isSupported }

    func startRoom() {
        phase = .scanning
        captureView.captureSession.run(configuration: RoomCaptureSession.Configuration())
    }

    /// Ends this room but keeps the AR session running, so the next room lines up with it.
    func finishRoom() {
        captureView.captureSession.stop(pauseARSession: false)
        phase = .reviewing
    }

    func stopAll() {
        captureView.captureSession.stop()
        arSession.pause()
    }

    /// Raycast from the centre of the camera image using LiDAR depth.
    func markKnownPoint(_ id: UUID) {
        guard let frame = arSession.currentFrame else { message = "Camera not ready."; return }
        let q = frame.raycastQuery(from: CGPoint(x: 0.5, y: 0.5), allowing: .estimatedPlane, alignment: .any)
        guard let hit = arSession.raycast(q).first else {
            message = "No surface under the crosshair. Aim at the point and try again."
            return
        }
        let c = hit.worldTransform.columns.3
        observations.append(ControlObservation(controlPointID: id, position: Vec3(SIMD3<Float>(c.x, c.y, c.z))))
    }

    // MARK: RoomCaptureViewDelegate

    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool { true }

    func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        DispatchQueue.main.async {
            if let error { self.message = "Room processing failed: \(error.localizedDescription)"; return }
            self.rooms.append(processedResult)
        }
    }

    // MARK: Saving

    func buildSession(name: String, modelURL: URL) async -> MeasureSession? {
        guard !rooms.isEmpty else { return nil }
        await MainActor.run { phase = .merging }
        var s = MeasureSession(kind: .interior, name: name)
        s.observations = observations
        s.roomCount = rooms.count
        do {
            if rooms.count == 1 {
                let r = rooms[0]
                s.surfaces = Self.surfaces(walls: r.walls, doors: r.doors, windows: r.windows, openings: r.openings)
                try r.export(to: modelURL)
            } else {
                let structure = try await StructureBuilder(options: [.beautifyObjects]).capturedStructure(from: rooms)
                s.surfaces = Self.surfaces(walls: structure.walls, doors: structure.doors, windows: structure.windows, openings: structure.openings)
                try structure.export(to: modelURL)
            }
            s.hasModel = true
        } catch {
            await MainActor.run { message = "Saved the floor plan, but the 3D model could not be built: \(error.localizedDescription)" }
            if s.surfaces.isEmpty {
                for r in rooms {
                    s.surfaces += Self.surfaces(walls: r.walls, doors: r.doors, windows: r.windows, openings: r.openings)
                }
            }
        }
        return s
    }

    static func surfaces(walls: [CapturedRoom.Surface], doors: [CapturedRoom.Surface],
                         windows: [CapturedRoom.Surface], openings: [CapturedRoom.Surface]) -> [PlanSurface] {
        func convert(_ s: CapturedRoom.Surface, _ kind: SurfaceKind) -> PlanSurface {
            let t = s.transform
            let center = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
            let along = simd_normalize(SIMD3<Float>(t.columns.0.x, t.columns.0.y, t.columns.0.z))
            let half = s.dimensions.x / 2
            return PlanSurface(kind: kind,
                               start: Vec3(center - along * half),
                               end: Vec3(center + along * half),
                               bottom: Double(center.y - s.dimensions.y / 2),
                               height: Double(s.dimensions.y))
        }
        return walls.map { convert($0, .wall) } + doors.map { convert($0, .door) }
            + windows.map { convert($0, .window) } + openings.map { convert($0, .opening) }
    }
}

struct RoomCaptureContainer: UIViewRepresentable {
    let view: RoomCaptureView
    func makeUIView(context: Context) -> RoomCaptureView { view }
    func updateUIView(_ uiView: RoomCaptureView, context: Context) {}
}

struct RoomScanView: View {
    @EnvironmentObject private var store: BuildingStore
    @Environment(\.dismiss) private var dismiss
    let buildingID: UUID
    @StateObject private var c = RoomScanController()
    @State private var choosingPoint = false
    @State private var name = ""

    var body: some View {
        ZStack {
            RoomCaptureContainer(view: c.captureView).ignoresSafeArea()
            if c.phase == .scanning { Crosshair(color: .white) }
            VStack {
                HStack(alignment: .top) {
                    Button { c.stopAll(); dismiss() } label: {
                        Image(systemName: "xmark").font(.headline).padding(10).background(.ultraThinMaterial, in: Circle())
                    }
                    Text("\(c.rooms.count) room(s) scanned · \(c.observations.count) known point(s)")
                        .font(.caption).padding(8).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                    Spacer()
                }
                Spacer()
                VStack(alignment: .leading, spacing: 10) {
                    switch c.phase {
                    case .scanning:
                        Text("Walk slowly around the room, pointing at walls, windows and doors. To tie this scan to the building, aim the crosshair at a known point (e.g. the entrance door frame) and mark it.")
                            .font(.caption)
                        HStack {
                            Button { choosingPoint = true } label: { Label("Mark known point", systemImage: "scope") }
                                .buttonStyle(.bordered)
                            Spacer()
                            Button("Room done") { c.finishRoom() }.buttonStyle(.borderedProminent)
                        }
                    case .reviewing:
                        Text("Check the room model. Walk into the next room without stopping and scan it, or finish to save the floor plan.")
                            .font(.caption)
                        TextField("Name, e.g. Ground floor", text: $name).textFieldStyle(.roundedBorder)
                        HStack {
                            Button("Scan next room") { c.startRoom() }.buttonStyle(.bordered)
                            Spacer()
                            Button("Finish & save") { save() }.buttonStyle(.borderedProminent).disabled(c.rooms.isEmpty)
                        }
                    case .merging:
                        ProgressView("Merging rooms into one plan…")
                    }
                }
                .padding()
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
            .padding()
        }
        .onAppear { c.startRoom() }
        .sheet(isPresented: $choosingPoint) {
            ControlPointPicker(buildingID: buildingID) { id in c.markKnownPoint(id) }
                .environmentObject(store)
                .presentationDetents([.medium, .large])
        }
        .alert("Note", isPresented: Binding(get: { c.message != nil }, set: { if !$0 { c.message = nil } })) {
            Button("OK") { c.message = nil }
        } message: { Text(c.message ?? "") }
    }

    private func save() {
        Task {
            let sessionName = name.isEmpty ? "Rooms \(Date().formatted(date: .abbreviated, time: .shortened))" : name
            var placeholder = MeasureSession(kind: .interior, name: sessionName)
            let url = store.modelURL(building: buildingID, session: placeholder.id)
            try? FileManager.default.createDirectory(at: store.folder(buildingID), withIntermediateDirectories: true)
            if let s = await c.buildSession(name: sessionName, modelURL: url) {
                placeholder = s
                // Keep the file name matching the saved session id.
                let finalURL = store.modelURL(building: buildingID, session: s.id)
                try? FileManager.default.moveItem(at: url, to: finalURL)
                await MainActor.run {
                    store.addSession(placeholder, to: buildingID)
                    c.stopAll()
                    dismiss()
                }
            }
        }
    }
}
