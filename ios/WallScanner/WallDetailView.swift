import SwiftUI

struct WallDetailView: View {
    @EnvironmentObject private var store: WallStore
    let wallID: UUID

    enum Tool: String, CaseIterable, Identifiable {
        case view = "View", spot = "Spot", run = "Run", reference = "Ref. point"
        var id: String { rawValue }
    }

    @State private var wall: WallRecord?
    @State private var photo: UIImage?
    @State private var tool: Tool = .spot
    @State private var kind: FeatureKind = .pipe
    @State private var pending: [WallPoint] = []
    @State private var showOverlay = false
    @State private var editingRef: ReferencePoint?

    var body: some View {
        Group {
            if let wall {
                content(wall)
            } else {
                ProgressView()
            }
        }
        .navigationTitle(wall?.name ?? "Wall")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            wall = store.wall(wallID)
            photo = store.photo(for: wallID)
        }
        .fullScreenCover(isPresented: $showOverlay, onDismiss: { wall = store.wall(wallID) }) {
            if let wall { OverlayView(wall: wall, store: store) }
        }
        .sheet(item: $editingRef) { ref in
            ReferencePointEditor(point: ref) { updated in
                update { w in
                    if let i = w.referencePoints.firstIndex(where: { $0.id == updated.id }) {
                        w.referencePoints[i] = updated
                    } else {
                        w.referencePoints.append(updated)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func content(_ wall: WallRecord) -> some View {
        List {
            Section {
                Button {
                    showOverlay = true
                } label: {
                    Label("Show on the wall (AR)", systemImage: "arkit")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            Section {
                WallCanvas(wall: wall, photo: photo, pending: pending) { p in handleTap(p) }
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                Picker("Tool", selection: $tool) {
                    ForEach(Tool.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: tool) { pending = [] }
                if tool == .spot || tool == .run {
                    Picker("Type", selection: $kind) {
                        ForEach(FeatureKind.allCases) { k in
                            Label(k.label, systemImage: k.symbol).tag(k)
                        }
                    }
                }
                if tool == .run {
                    HStack {
                        Text(pending.isEmpty ? "Tap points along the pipe/cable" : "\(pending.count) point(s)")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Undo") { _ = pending.popLast() }.disabled(pending.isEmpty)
                        Button("Finish") { finishRun() }.disabled(pending.count < 2)
                            .buttonStyle(.borderedProminent)
                    }
                }
            } header: {
                Text(String(format: "%.2f m × %.2f m – tap the photo to mark", wall.width, wall.height))
            }

            Section("Marked features") {
                if wall.features.isEmpty {
                    Text("Nothing marked yet").foregroundStyle(.secondary)
                }
                ForEach(wall.features) { f in
                    HStack {
                        Image(systemName: f.kind.symbol).foregroundStyle(f.kind.color)
                        Text(f.kind.label)
                        Spacer()
                        Text(describe(f)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                .onDelete { idx in update { $0.features.remove(atOffsets: idx) } }
            }

            Section {
                ForEach(wall.referencePoints) { r in
                    Button {
                        editingRef = r
                    } label: {
                        HStack {
                            Image(systemName: "scope").foregroundStyle(.green)
                            VStack(alignment: .leading) {
                                Text(r.name)
                                Text(String(format: "x %.2f m, y %.2f m", r.wallPosition.x, r.wallPosition.y))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if r.surveyed != nil {
                                Image(systemName: "globe").foregroundStyle(.blue)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                }
                .onDelete { idx in update { $0.referencePoints.remove(atOffsets: idx) } }
            } header: {
                Text("Reference points")
            } footer: {
                let n = wall.referencePoints.filter { $0.surveyed != nil }.count
                Text("Add surveyed coordinates (e.g. from the site survey) to reference points. With 2 or more, this wall can be placed in the building's coordinate system. \(n) of \(wall.referencePoints.count) have coordinates.")
            }

            Section("Details") {
                TextField("Name", text: Binding(
                    get: { wall.name },
                    set: { new in update { $0.name = new } }))
                LabeledContent("Scanned", value: wall.createdAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Room map saved", value: wall.hasWorldMap ? "Yes" : "No (align manually)")
                ShareLink(item: store.jsonURL(for: wall.id)) {
                    Label("Export wall data (JSON)", systemImage: "square.and.arrow.up")
                }
            }
        }
    }

    // MARK: - Editing

    private func update(_ change: (inout WallRecord) -> Void) {
        guard var w = wall else { return }
        change(&w)
        wall = w
        store.save(w)
    }

    private func handleTap(_ p: WallPoint) {
        switch tool {
        case .view:
            break
        case .spot:
            update { $0.features.append(WallFeature(kind: kind, points: [p])) }
        case .run:
            pending.append(p)
        case .reference:
            let n = (wall?.referencePoints.count ?? 0) + 1
            editingRef = ReferencePoint(name: "Point \(n)", wallPosition: p)
        }
    }

    private func finishRun() {
        guard pending.count >= 2 else { return }
        let pts = pending
        update { $0.features.append(WallFeature(kind: kind, points: pts)) }
        pending = []
    }

    private func describe(_ f: WallFeature) -> String {
        guard let first = f.points.first else { return "" }
        if f.points.count == 1 {
            return String(format: "%.0f cm, %.0f cm high", first.x * 100, first.y * 100)
        }
        var length = 0.0
        for i in 1..<f.points.count {
            length += hypot(f.points[i].x - f.points[i - 1].x, f.points[i].y - f.points[i - 1].y)
        }
        return String(format: "run, %.2f m long", length)
    }
}

/// The straightened wall photo with the marks drawn on top. Taps report wall coordinates in meters.
struct WallCanvas: View {
    let wall: WallRecord
    let photo: UIImage?
    let pending: [WallPoint]
    var onTap: (WallPoint) -> Void

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                if let photo {
                    Image(uiImage: photo).resizable()
                } else {
                    Color.gray.opacity(0.3)
                }
                Canvas { ctx, size in
                    draw(in: &ctx, size: size)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { loc in
                let x = Double(loc.x / size.width) * wall.width
                let y = (1 - Double(loc.y / size.height)) * wall.height
                onTap(WallPoint(x: x, y: y))
            }
        }
        .aspectRatio(CGFloat(wall.width / wall.height), contentMode: .fit)
    }

    private func draw(in ctx: inout GraphicsContext, size: CGSize) {
        func pt(_ p: WallPoint) -> CGPoint {
            CGPoint(x: p.x / wall.width * size.width, y: (1 - p.y / wall.height) * size.height)
        }
        let ppm = size.width / wall.width

        // 50 cm grid
        var grid = Path()
        var x = 0.0
        while x <= wall.width { grid.move(to: pt(.init(x: x, y: 0))); grid.addLine(to: pt(.init(x: x, y: wall.height))); x += 0.5 }
        var y = 0.0
        while y <= wall.height { grid.move(to: pt(.init(x: 0, y: y))); grid.addLine(to: pt(.init(x: wall.width, y: y))); y += 0.5 }
        ctx.stroke(grid, with: .color(.white.opacity(0.35)), lineWidth: 0.5)

        for f in wall.features {
            if f.points.count == 1 {
                let c = pt(f.points[0])
                let r = max(5, ppm * 0.04)
                let rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
                ctx.fill(Path(ellipseIn: rect), with: .color(f.kind.color))
                ctx.stroke(Path(ellipseIn: rect), with: .color(.white), lineWidth: 1.5)
            } else {
                var path = Path()
                path.addLines(f.points.map(pt))
                ctx.stroke(path, with: .color(.white), style: StrokeStyle(lineWidth: max(4, ppm * 0.035), lineCap: .round, lineJoin: .round))
                ctx.stroke(path, with: .color(f.kind.color), style: StrokeStyle(lineWidth: max(3, ppm * 0.025), lineCap: .round, lineJoin: .round))
            }
        }

        for r in wall.referencePoints {
            let c = pt(r.wallPosition)
            var cross = Path()
            cross.move(to: CGPoint(x: c.x - 8, y: c.y)); cross.addLine(to: CGPoint(x: c.x + 8, y: c.y))
            cross.move(to: CGPoint(x: c.x, y: c.y - 8)); cross.addLine(to: CGPoint(x: c.x, y: c.y + 8))
            ctx.stroke(cross, with: .color(.green), lineWidth: 2)
        }

        if !pending.isEmpty {
            var path = Path()
            path.addLines(pending.map(pt))
            ctx.stroke(path, with: .color(.yellow), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            for p in pending {
                let c = pt(p)
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)), with: .color(.yellow))
            }
        }
    }
}

struct ReferencePointEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var point: ReferencePoint
    @State private var hasSurvey: Bool
    @State private var survey: SurveyedCoordinate
    var onSave: (ReferencePoint) -> Void

    init(point: ReferencePoint, onSave: @escaping (ReferencePoint) -> Void) {
        _point = State(initialValue: point)
        _hasSurvey = State(initialValue: point.surveyed != nil)
        _survey = State(initialValue: point.surveyed ?? SurveyedCoordinate(easting: 0, northing: 0, elevation: 0, system: "EOV (EPSG:23700)"))
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Point on wall") {
                    TextField("Name", text: $point.name)
                    LabeledContent("From left (m)") {
                        TextField("x", value: $point.wallPosition.x, format: .number.precision(.fractionLength(3)))
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Above floor (m)") {
                        TextField("y", value: $point.wallPosition.y, format: .number.precision(.fractionLength(3)))
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                }
                Section {
                    Toggle("Has surveyed coordinate", isOn: $hasSurvey)
                    if hasSurvey {
                        TextField("Coordinate system", text: $survey.system)
                        LabeledContent("Easting / Y") {
                            TextField("E", value: $survey.easting, format: .number.precision(.fractionLength(3)))
                                .keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing)
                        }
                        LabeledContent("Northing / X") {
                            TextField("N", value: $survey.northing, format: .number.precision(.fractionLength(3)))
                                .keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing)
                        }
                        LabeledContent("Elevation") {
                            TextField("H", value: $survey.elevation, format: .number.precision(.fractionLength(3)))
                                .keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing)
                        }
                    }
                } header: {
                    Text("Georeference")
                } footer: {
                    Text("Enter the surveyed coordinates of this point if you have them (e.g. from the building's site survey).")
                }
            }
            .navigationTitle("Reference point")
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
}
