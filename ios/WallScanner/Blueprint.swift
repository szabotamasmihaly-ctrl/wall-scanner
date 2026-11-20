import SwiftUI

/// Everything of a building expressed in plan coordinates (east / north, metres).
struct BlueprintModel {
    struct Corner: Identifiable { let id: UUID; let name: String; let p: PlanPoint; let isCorner: Bool }
    struct Feature: Identifiable { let id = UUID(); let kind: BuildingFeatureKind; let points: [PlanPoint] }
    struct Surface: Identifiable { let id = UUID(); let kind: SurfaceKind; let a: PlanPoint; let b: PlanPoint; let height: Double }
    struct Dimension: Identifiable { let id = UUID(); let a: PlanPoint; let b: PlanPoint; let offset: Double }
    struct WallLine: Identifiable { let id: UUID; let name: String; let a: PlanPoint; let b: PlanPoint; let features: Int }

    var corners: [Corner] = []
    var outline: [PlanPoint] = []
    var features: [Feature] = []
    var surfaces: [Surface] = []
    var dimensions: [Dimension] = []
    var walls: [WallLine] = []
    var unplacedWalls: [String] = []
    var unplacedSessions: [String] = []
    var frame = ""
    var residualNote = ""

    init(building b: Building, walls wallRecords: [WallRecord] = []) {
        let r = BuildingSolver.solve(b)
        frame = r.frameDescription
        for cp in b.controlPoints {
            if let p = r.coordinates[cp.id] { corners.append(Corner(id: cp.id, name: cp.name, p: p, isCorner: cp.isBuildingCorner)) }
        }
        outline = corners.filter(\.isCorner).map(\.p)
        for s in b.sessions {
            guard let t = r.transforms[s.id] else { unplacedSessions.append(s.name); continue }
            for f in s.features { features.append(Feature(kind: f.kind, points: f.points.map(t.apply))) }
            for sf in s.surfaces { surfaces.append(Surface(kind: sf.kind, a: t.apply(sf.start), b: t.apply(sf.end), height: sf.height)) }
        }
        // Scanned walls (pipes, cables, rebar) linked to this building.
        for w in wallRecords where w.buildingID == b.id {
            guard let obs = w.controlObservations, let o = w.frameOrigin, let ax = w.frameAxisX else { continue }
            let pairs = obs.compactMap { ob in r.coordinates[ob.controlPointID].map { (ob.position, $0) } }
            guard Set(obs.filter { r.coordinates[$0.controlPointID] != nil }.map(\.controlPointID)).count >= 2,
                  let (t, _) = BuildingSolver.fit(pairs) else { unplacedWalls.append(w.name); continue }
            let end = Vec3(x: o.x + ax.x * w.width, y: o.y + ax.y * w.width, z: o.z + ax.z * w.width)
            walls.append(WallLine(id: w.id, name: w.name, a: t.apply(o), b: t.apply(end), features: w.features.count))
        }
        let worst = r.residuals.values.max() ?? 0
        if worst > 0 { residualNote = String(format: "Largest misfit between scans: %.1f cm", worst * 100) }
        buildChainDimensions()
    }

    /// Along each outline edge: corner → window edge → window edge → … → corner.
    private mutating func buildChainDimensions() {
        guard outline.count >= 2 else { return }
        let closed = outline.count >= 3
        let edgeCount = closed ? outline.count : outline.count - 1
        let featurePoints = features.flatMap(\.points) + surfaces.filter { $0.kind != .wall }.flatMap { [$0.a, $0.b] }
        for i in 0..<edgeCount {
            let a = outline[i], b = outline[(i + 1) % outline.count]
            let dx = b.e - a.e, dy = b.n - a.n
            let L = hypot(dx, dy)
            guard L > 0.1 else { continue }
            let ux = dx / L, uy = dy / L
            var stations: [Double] = [0, L]
            for p in featurePoints {
                let t = (p.e - a.e) * ux + (p.n - a.n) * uy
                let d = abs((p.e - a.e) * uy - (p.n - a.n) * ux)
                if d < 0.6, t > 0.02, t < L - 0.02 { stations.append(t) }
            }
            stations.sort()
            var unique: [Double] = []
            for s in stations where unique.last.map({ s - $0 > 0.02 }) ?? true { unique.append(s) }
            for k in 0..<(unique.count - 1) {
                let p1 = PlanPoint(e: a.e + ux * unique[k], n: a.n + uy * unique[k])
                let p2 = PlanPoint(e: a.e + ux * unique[k + 1], n: a.n + uy * unique[k + 1])
                dimensions.append(Dimension(a: p1, b: p2, offset: 0.6))
            }
            if unique.count > 2 { dimensions.append(Dimension(a: a, b: b, offset: 1.2)) }
        }
    }

    var allPoints: [PlanPoint] {
        corners.map(\.p) + features.flatMap(\.points) + surfaces.flatMap { [$0.a, $0.b] } + walls.flatMap { [$0.a, $0.b] }
    }

    var bounds: (minE: Double, minN: Double, maxE: Double, maxN: Double)? {
        let pts = allPoints
        guard let f = pts.first else { return nil }
        var r = (minE: f.e, minN: f.n, maxE: f.e, maxN: f.n)
        for p in pts { r.minE = min(r.minE, p.e); r.maxE = max(r.maxE, p.e); r.minN = min(r.minN, p.n); r.maxN = max(r.maxN, p.n) }
        return r
    }
}

/// Maps plan metres to screen points.
struct PlanViewport {
    var scale: CGFloat
    var center: (Double, Double)
    var size: CGSize
    var pan: CGSize = .zero

    func screen(_ p: PlanPoint) -> CGPoint {
        CGPoint(x: CGFloat(p.e - center.0) * scale + size.width / 2 + pan.width,
                y: -CGFloat(p.n - center.1) * scale + size.height / 2 + pan.height)
    }

    static func fit(_ m: BlueprintModel, size: CGSize, zoom: CGFloat = 1, pan: CGSize = .zero) -> PlanViewport {
        guard let b = m.bounds else { return PlanViewport(scale: 40 * zoom, center: (0, 0), size: size, pan: pan) }
        let w = max(b.maxE - b.minE, 1) + 3, h = max(b.maxN - b.minN, 1) + 3
        let s = min(size.width / CGFloat(w), size.height / CGFloat(h))
        return PlanViewport(scale: s * zoom, center: ((b.minE + b.maxE) / 2, (b.minN + b.maxN) / 2), size: size, pan: pan)
    }
}

/// Draws the blueprint. Used on screen and for the exported image.
struct BlueprintCanvas: View {
    let model: BlueprintModel
    var zoom: CGFloat = 1
    var pan: CGSize = .zero
    var selection: [PlanPoint] = []
    var ink: Color = .primary
    var paper: Color = Color(.systemBackground)

    var body: some View {
        Canvas { ctx, size in
            let vp = PlanViewport.fit(model, size: size, zoom: zoom, pan: pan)
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(paper))
            drawGrid(&ctx, vp, size)

            // Interior walls and openings from RoomPlan.
            for s in model.surfaces {
                var p = Path(); p.move(to: vp.screen(s.a)); p.addLine(to: vp.screen(s.b))
                switch s.kind {
                case .wall: ctx.stroke(p, with: .color(ink.opacity(0.85)), lineWidth: max(2, 0.12 * vp.scale))
                case .window: ctx.stroke(p, with: .color(.cyan), lineWidth: max(2, 0.08 * vp.scale))
                case .door: ctx.stroke(p, with: .color(.orange), lineWidth: max(2, 0.08 * vp.scale))
                case .opening: ctx.stroke(p, with: .color(.gray), style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
                }
            }

            // Building outline through the outside corners.
            if model.outline.count >= 2 {
                var p = Path()
                p.addLines(model.outline.map(vp.screen))
                if model.outline.count >= 3 { p.closeSubpath() }
                ctx.stroke(p, with: .color(ink), lineWidth: max(3, 0.3 * vp.scale))
            }

            // Measured windows / doors (outside).
            for f in model.features {
                let color: Color = f.kind == .window ? .cyan : (f.kind == .door ? .orange : .purple)
                if f.points.count >= 2 {
                    var p = Path(); p.addLines(f.points.map(vp.screen))
                    ctx.stroke(p, with: .color(color), lineWidth: max(4, 0.15 * vp.scale))
                } else if let q = f.points.first {
                    let c = vp.screen(q)
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)), with: .color(color))
                }
            }

            // Scanned walls with what is inside them.
            for w in model.walls {
                let a = vp.screen(w.a), b = vp.screen(w.b)
                var p = Path(); p.move(to: a); p.addLine(to: b)
                ctx.stroke(p, with: .color(.pink.opacity(0.8)), style: StrokeStyle(lineWidth: max(5, 0.2 * vp.scale), lineCap: .round))
                let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                ctx.draw(Text("\(w.name) · \(w.features) marks").font(.caption2).foregroundColor(.pink), at: CGPoint(x: mid.x, y: mid.y + 12))
            }

            // Chain dimensions.
            for d in model.dimensions { drawDimension(&ctx, vp, d) }

            // Control points.
            for c in model.corners {
                let s = vp.screen(c.p)
                var cross = Path()
                cross.move(to: CGPoint(x: s.x - 7, y: s.y)); cross.addLine(to: CGPoint(x: s.x + 7, y: s.y))
                cross.move(to: CGPoint(x: s.x, y: s.y - 7)); cross.addLine(to: CGPoint(x: s.x, y: s.y + 7))
                ctx.stroke(cross, with: .color(.green), lineWidth: 2)
                ctx.draw(Text(c.name).font(.caption2.bold()).foregroundColor(.green), at: CGPoint(x: s.x + 8, y: s.y - 10), anchor: .leading)
            }

            // Tap-to-measure selection.
            if !selection.isEmpty {
                let pts = selection.map(vp.screen)
                for p in pts { ctx.stroke(Path(ellipseIn: CGRect(x: p.x - 8, y: p.y - 8, width: 16, height: 16)), with: .color(.red), lineWidth: 2) }
                if pts.count == 2 {
                    var l = Path(); l.move(to: pts[0]); l.addLine(to: pts[1])
                    ctx.stroke(l, with: .color(.red), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                }
            }

            // North arrow and scale bar.
            let na = CGPoint(x: size.width - 28, y: 40)
            var arrow = Path()
            arrow.move(to: CGPoint(x: na.x, y: na.y - 18)); arrow.addLine(to: CGPoint(x: na.x - 7, y: na.y + 6))
            arrow.addLine(to: CGPoint(x: na.x, y: na.y + 1)); arrow.addLine(to: CGPoint(x: na.x + 7, y: na.y + 6)); arrow.closeSubpath()
            ctx.fill(arrow, with: .color(ink))
            ctx.draw(Text("N").font(.caption.bold()).foregroundColor(ink), at: CGPoint(x: na.x, y: na.y + 18))
            let barM = niceBar(for: vp.scale)
            let bx = CGFloat(16), by = size.height - 20, bw = CGFloat(barM) * vp.scale
            var bar = Path(); bar.move(to: CGPoint(x: bx, y: by)); bar.addLine(to: CGPoint(x: bx + bw, y: by))
            ctx.stroke(bar, with: .color(ink), lineWidth: 3)
            ctx.draw(Text(barM >= 1 ? "\(Int(barM)) m" : "\(Int(barM * 100)) cm").font(.caption2).foregroundColor(ink),
                     at: CGPoint(x: bx + bw / 2, y: by - 10))
        }
    }

    private func niceBar(for scale: CGFloat) -> Double {
        let target = Double(120 / scale)
        for c in [0.1, 0.2, 0.5, 1, 2, 5, 10, 20, 50, 100] where c >= target * 0.6 { return c }
        return 100
    }

    private func drawGrid(_ ctx: inout GraphicsContext, _ vp: PlanViewport, _ size: CGSize) {
        let step = vp.scale > 25 ? 1.0 : 5.0
        let left = vp.center.0 - Double((size.width / 2 + vp.pan.width) / vp.scale)
        let right = vp.center.0 + Double((size.width / 2 - vp.pan.width) / vp.scale)
        let top = vp.center.1 + Double((size.height / 2 + vp.pan.height) / vp.scale)
        let bottom = vp.center.1 - Double((size.height / 2 - vp.pan.height) / vp.scale)
        var g = Path()
        var e = (left / step).rounded(.down) * step
        while e <= right { let a = vp.screen(PlanPoint(e: e, n: top)), b = vp.screen(PlanPoint(e: e, n: bottom)); g.move(to: a); g.addLine(to: b); e += step }
        var n = (bottom / step).rounded(.down) * step
        while n <= top { let a = vp.screen(PlanPoint(e: left, n: n)), b = vp.screen(PlanPoint(e: right, n: n)); g.move(to: a); g.addLine(to: b); n += step }
        ctx.stroke(g, with: .color(ink.opacity(0.08)), lineWidth: 0.5)
    }

    private func drawDimension(_ ctx: inout GraphicsContext, _ vp: PlanViewport, _ d: BlueprintModel.Dimension) {
        let a = vp.screen(d.a), b = vp.screen(d.b)
        let dx = b.x - a.x, dy = b.y - a.y
        let len = max(hypot(dx, dy), 0.001)
        // Offset to the right of the edge direction (outside for a counter-clockwise outline).
        let off = CGFloat(d.offset) * vp.scale * 0.6
        let nx = dy / len * off, ny = -dx / len * off
        let a2 = CGPoint(x: a.x + nx, y: a.y + ny), b2 = CGPoint(x: b.x + nx, y: b.y + ny)
        var p = Path()
        p.move(to: a2); p.addLine(to: b2)
        p.move(to: a); p.addLine(to: a2); p.move(to: b); p.addLine(to: b2)
        ctx.stroke(p, with: .color(ink.opacity(0.6)), lineWidth: 0.8)
        let meters = hypot(d.b.e - d.a.e, d.b.n - d.a.n)
        guard len > 26 else { return }
        var angle = atan2(dy, dx)
        if angle > .pi / 2 || angle < -.pi / 2 { angle += .pi }
        var c2 = ctx
        c2.translateBy(x: (a2.x + b2.x) / 2, y: (a2.y + b2.y) / 2)
        c2.rotate(by: .radians(Double(angle)))
        c2.draw(Text(String(format: "%.2f", meters)).font(.system(size: 10, design: .monospaced)).foregroundColor(ink),
                at: CGPoint(x: 0, y: -7))
    }
}

struct BlueprintView: View {
    @EnvironmentObject private var store: BuildingStore
    @EnvironmentObject private var wallStore: WallStore
    let buildingID: UUID
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1
    @GestureState private var drag: CGSize = .zero
    @State private var selection: [PlanPoint] = []
    @State private var exported: UIImage?

    var body: some View {
        let model = BlueprintModel(building: store.building(buildingID) ?? Building(name: ""), walls: wallStore.walls)
        VStack(spacing: 0) {
            GeometryReader { geo in
                BlueprintCanvas(model: model, zoom: zoom * pinch,
                                pan: CGSize(width: pan.width + drag.width, height: pan.height + drag.height),
                                selection: selection)
                    .contentShape(Rectangle())
                    .gesture(
                        MagnificationGesture().updating($pinch) { v, s, _ in s = v }
                            .onEnded { zoom = max(0.2, min(30, zoom * $0)) }
                            .simultaneously(with:
                                DragGesture(minimumDistance: 8).updating($drag) { v, s, _ in s = v.translation }
                                    .onEnded { pan.width += $0.translation.width; pan.height += $0.translation.height })
                    )
                    .onTapGesture(coordinateSpace: .local) { loc in
                        select(at: loc, model: model, size: geo.size)
                    }
            }
            VStack(alignment: .leading, spacing: 6) {
                if selection.count == 2 {
                    let a = selection[0], b = selection[1]
                    Text(String(format: "Distance %.3f m  (ΔE %.2f, ΔN %.2f, ΔH %.2f)", hypot(b.e - a.e, b.n - a.n), b.e - a.e, b.n - a.n, b.h - a.h))
                        .font(.callout.monospacedDigit().bold())
                } else {
                    Text(selection.isEmpty ? "Tap two points on the plan to measure between them." : "Tap a second point.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Frame: \(model.frame)").font(.caption2).foregroundStyle(.secondary)
                if !model.residualNote.isEmpty { Text(model.residualNote).font(.caption2).foregroundStyle(.secondary) }
                if !model.unplacedWalls.isEmpty {
                    Text("Walls not placed yet (need 2 known points with coordinates): " + model.unplacedWalls.joined(separator: ", "))
                        .font(.caption2).foregroundStyle(.orange)
                }
                if !model.unplacedSessions.isEmpty {
                    Text("Not placed yet (needs 2 known points): " + model.unplacedSessions.joined(separator: ", "))
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.bar)
        }
        .navigationTitle("Blueprint")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { zoom = 1; pan = .zero } label: { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass") }
                if let img = exported {
                    ShareLink(item: Image(uiImage: img), preview: SharePreview("Blueprint", image: Image(uiImage: img))) {
                        Image(systemName: "square.and.arrow.up")
                    }
                } else {
                    Button { exported = render(model) } label: { Image(systemName: "photo.badge.arrow.down") }
                }
            }
        }
        .onChange(of: store.buildings) { exported = nil }
    }

    private func select(at loc: CGPoint, model: BlueprintModel, size: CGSize) {
        let vp = PlanViewport.fit(model, size: size, zoom: zoom, pan: pan)
        var best: (PlanPoint, CGFloat)?
        for p in model.allPoints {
            let s = vp.screen(p)
            let d = hypot(s.x - loc.x, s.y - loc.y)
            if d < 30, best == nil || d < best!.1 { best = (p, d) }
        }
        guard let hit = best?.0 else { selection = []; return }
        if selection.count >= 2 { selection = [] }
        selection.append(hit)
    }

    @MainActor
    private func render(_ model: BlueprintModel) -> UIImage? {
        let renderer = ImageRenderer(content:
            BlueprintCanvas(model: model, ink: .black, paper: .white).frame(width: 1600, height: 1600))
        renderer.scale = 2
        return renderer.uiImage
    }
}
