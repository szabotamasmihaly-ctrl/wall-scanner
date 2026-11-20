import SwiftUI

struct BuildingListView: View {
    @EnvironmentObject private var store: BuildingStore
    @State private var newName = ""
    @State private var askName = false

    var body: some View {
        NavigationStack {
            Group {
                if store.buildings.isEmpty {
                    ContentUnavailableView {
                        Label("No buildings yet", systemImage: "building.2")
                    } description: {
                        Text("Measure the outside corners, windows and doors with LiDAR, scan the rooms, and get a blueprint tied to fixed known points.")
                    } actions: {
                        Button("New building") { askName = true }.buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        ForEach(store.buildings) { b in
                            NavigationLink(value: b.id) {
                                VStack(alignment: .leading) {
                                    Text(b.name).font(.headline)
                                    Text("\(b.controlPoints.count) known points · \(b.sessions.count) scans")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onDelete { idx in for i in idx { store.delete(store.buildings[i].id) } }
                    }
                }
            }
            .navigationTitle("Buildings")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { askName = true } label: { Label("New building", systemImage: "plus") }
                }
            }
            .navigationDestination(for: UUID.self) { BuildingDetailView(buildingID: $0) }
            .alert("New building", isPresented: $askName) {
                TextField("Name or address", text: $newName)
                Button("Create") {
                    store.save(Building(name: newName.isEmpty ? "Building \(store.buildings.count + 1)" : newName))
                    newName = ""
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
}

struct BuildingDetailView: View {
    @EnvironmentObject private var store: BuildingStore
    @EnvironmentObject private var wallStore: WallStore
    let buildingID: UUID
    @State private var measuring = false
    @State private var scanningRooms = false
    @State private var editing: ControlPoint?

    var body: some View {
        if let b = store.building(buildingID) {
            let solved = BuildingSolver.solve(b)
            List {
                Section {
                    Button { measuring = true } label: {
                        Label("Measure outside with LiDAR", systemImage: "ruler")
                    }
                    Button { scanningRooms = true } label: {
                        Label("Scan rooms (RoomPlan)", systemImage: "cube.transparent")
                    }
                    .disabled(!RoomScanController.isSupported)
                    NavigationLink { BlueprintView(buildingID: buildingID) } label: {
                        Label("Blueprint", systemImage: "map")
                    }
                } footer: {
                    if !RoomScanController.isSupported {
                        Text("Room scanning needs an iPhone or iPad with LiDAR.")
                    } else {
                        Text("Start outside: measure 2 or more building corners, then windows and doors. Inside, mark at least 2 points that were also measured outside (e.g. both sides of the entrance door frame) so the rooms line up with the outside.")
                    }
                }

                Section {
                    let surveyed = b.controlPoints.filter { $0.surveyed != nil }.count
                    HStack {
                        Image(systemName: surveyed >= 4 ? "checkmark.seal.fill" : "mappin.and.ellipse")
                            .foregroundStyle(surveyed >= 4 ? .green : .orange)
                        Text("\(surveyed) of 4 surveyor points entered")
                    }
                    Button {
                        editing = ControlPoint(name: "Survey point \(surveyed + 1)", isBuildingCorner: false,
                                               surveyed: SurveyedCoordinate(easting: 0, northing: 0, elevation: 0,
                                                                            system: b.controlPoints.compactMap { $0.surveyed?.system }.first ?? "EOV (EPSG:23700)"))
                    } label: {
                        Label("Add surveyed point", systemImage: "plus.circle")
                    }
                } header: {
                    Text("Site reference points")
                } footer: {
                    Text("Enter the coordinates the surveyor gave you for 4 fixed points (corner pegs, building corners, nails). Then measure each of them with the phone: everything you scan is placed on that grid, and the fit shows how well each point agrees. With 3 or more, a bad point stands out in red.")
                }

                Section {
                    ForEach(b.controlPoints) { cp in
                        Button { editing = cp } label: {
                            HStack {
                                Image(systemName: cp.isBuildingCorner ? "square.dashed" : "scope").foregroundStyle(.green)
                                VStack(alignment: .leading) {
                                    Text(cp.name).foregroundStyle(.primary)
                                    if let p = solved.coordinates[cp.id] {
                                        Text(String(format: "E %.3f  N %.3f  H %.3f", p.e, p.n, p.h))
                                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                        if let err = solved.pointResiduals[cp.id] {
                                            Text(String(format: "Fit %.1f cm", err * 100))
                                                .font(.caption2.monospacedDigit())
                                                .foregroundStyle(err < 0.03 ? .green : (err < 0.10 ? .orange : .red))
                                        }
                                    } else {
                                        Text("No coordinates yet").font(.caption).foregroundStyle(.orange)
                                    }
                                }
                                Spacer()
                                if cp.surveyed != nil { Image(systemName: "globe").foregroundStyle(.blue) }
                            }
                        }
                    }
                    .onMove { from, to in update { $0.controlPoints.move(fromOffsets: from, toOffset: to) } }
                    .onDelete { idx in update { $0.controlPoints.remove(atOffsets: idx) } }
                } header: {
                    HStack { Text("Known points"); Spacer(); EditButton().font(.caption) }
                } footer: {
                    Text("Frame: \(solved.frameDescription). Building corners are joined in this order to draw the outline; drag to reorder. Enter surveyed coordinates for 2+ points to place the building on the national/site grid.")
                }

                Section("Scans") {
                    if b.sessions.isEmpty { Text("No scans yet").foregroundStyle(.secondary) }
                    ForEach(b.sessions) { s in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Image(systemName: s.kind == .exterior ? "ruler" : "cube.transparent")
                                Text(s.name)
                                Spacer()
                                if solved.transforms[s.id] != nil {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                } else {
                                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                }
                            }
                            Text(summary(s, residual: solved.residuals[s.id]))
                                .font(.caption).foregroundStyle(.secondary)
                            if s.hasModel {
                                ShareLink(item: store.modelURL(building: b.id, session: s.id)) {
                                    Label("Share 3D model (USDZ)", systemImage: "square.and.arrow.up").font(.caption)
                                }
                            }
                        }
                    }
                    .onDelete { idx in update { $0.sessions.remove(atOffsets: idx) } }
                }

                Section {
                    let linked = wallStore.walls.filter { $0.buildingID == b.id }
                    if linked.isEmpty {
                        Text("No walls linked yet. When scanning a wall, pick this building and measure 2 known points.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(linked) { w in
                        HStack {
                            Image(systemName: "square.split.bottomrightquarter").foregroundStyle(.pink)
                            Text(w.name)
                            Spacer()
                            Text("\(w.features.count) marks").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Scanned walls")
                }

                Section {
                    ShareLink(item: store.jsonURL(b.id)) {
                        Label("Export building data (JSON)", systemImage: "square.and.arrow.up")
                    }
                }
            }
            .navigationTitle(b.name)
            .fullScreenCover(isPresented: $measuring) {
                ExteriorMeasureView(buildingID: buildingID, name: "Outside \(b.sessions.filter { $0.kind == .exterior }.count + 1)")
                    .environmentObject(store)
            }
            .fullScreenCover(isPresented: $scanningRooms) {
                RoomScanView(buildingID: buildingID).environmentObject(store)
            }
            .sheet(item: $editing) { cp in
                ControlPointEditor(point: cp) { updated in
                    update { b in
                        if let i = b.controlPoints.firstIndex(where: { $0.id == updated.id }) { b.controlPoints[i] = updated }
                        else { b.controlPoints.append(updated) }
                    }
                }
            }
        } else {
            Text("Building not found")
        }
    }

    private func update(_ change: (inout Building) -> Void) {
        guard var b = store.building(buildingID) else { return }
        change(&b)
        store.save(b)
    }

    private func summary(_ s: MeasureSession, residual: Double?) -> String {
        var parts: [String] = []
        if s.kind == .interior { parts.append("\(s.roomCount) room(s), \(s.surfaces.count) surfaces") }
        if !s.features.isEmpty { parts.append("\(s.features.count) windows/doors/points") }
        parts.append("\(s.observations.count) known-point sightings")
        if let r = residual { parts.append(String(format: "fit ±%.1f cm", r * 100)) } else { parts.append("not placed: needs 2 known points") }
        return parts.joined(separator: " · ")
    }
}

struct ControlPointEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var point: ControlPoint
    @State private var hasSurvey: Bool
    @State private var survey: SurveyedCoordinate
    var onSave: (ControlPoint) -> Void

    init(point: ControlPoint, onSave: @escaping (ControlPoint) -> Void) {
        _point = State(initialValue: point)
        _hasSurvey = State(initialValue: point.surveyed != nil)
        _survey = State(initialValue: point.surveyed ?? SurveyedCoordinate(easting: 0, northing: 0, elevation: 0, system: "EOV (EPSG:23700)"))
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $point.name)
                    Toggle("Outside building corner", isOn: $point.isBuildingCorner)
                }
                Section {
                    Toggle("Has surveyed coordinates", isOn: $hasSurvey)
                    if hasSurvey {
                        TextField("Coordinate system", text: $survey.system)
                        numberRow("Easting / Y", $survey.easting)
                        numberRow("Northing / X", $survey.northing)
                        numberRow("Elevation", $survey.elevation)
                    }
                } footer: {
                    Text("With 2 or more surveyed points the whole building, all rooms and walls are placed on that grid.")
                }
            }
            .navigationTitle("Known point")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var p = point
                        p.surveyed = hasSurvey ? survey : nil
                        onSave(p)
                        dismiss()
                    }
                }
            }
        }
    }

    private func numberRow(_ title: String, _ value: Binding<Double>) -> some View {
        LabeledContent(title) {
            TextField(title, value: value, format: .number.precision(.fractionLength(3)))
                .keyboardType(.numbersAndPunctuation)
                .multilineTextAlignment(.trailing)
        }
    }
}
