import Foundation

/// Rotation about the vertical axis + translation, mapping an AR session frame into the
/// building plan frame. LiDAR measures true metres, so there is no scale.
struct PlanTransform: Hashable {
    var cosA: Double
    var sinA: Double
    var tE: Double
    var tN: Double
    var tH: Double

    /// AR world (x right, y up, z toward viewer) seen from above as (x, -z).
    static func flat(_ v: Vec3) -> (Double, Double) { (v.x, -v.z) }

    func apply(_ v: Vec3) -> PlanPoint {
        let (px, py) = PlanTransform.flat(v)
        return PlanPoint(e: cosA * px - sinA * py + tE,
                         n: sinA * px + cosA * py + tN,
                         h: v.y + tH)
    }
}

struct SolveResult {
    /// Plan transform for every session that could be placed.
    var transforms: [UUID: PlanTransform] = [:]
    /// Plan coordinates of control points (surveyed or derived from measurements).
    var coordinates: [UUID: PlanPoint] = [:]
    /// RMS misfit (metres) of each placed session against known control points.
    var residuals: [UUID: Double] = [:]
    /// Largest misfit (metres) of each known point across the sessions that saw it.
    /// Large values point to a mis-tapped point or a wrong survey coordinate.
    var pointResiduals: [UUID: Double] = [:]
    /// Human-readable description of the plan frame.
    var frameDescription = "Not defined yet"
}

/// Ties all sessions together through shared control points.
///
/// 1. Control points with surveyed coordinates are fixed.
/// 2. If none are surveyed, the first session with two control points defines a local
///    frame: the first point is the origin, the second lies on the +east axis.
/// 3. Any session that sees 2+ control points with coordinates is placed (least squares),
///    and the other control points it saw get coordinates. Repeat until nothing changes,
///    so measurements chain: outside corners -> entrance door -> rooms inside.
enum BuildingSolver {

    static func solve(_ b: Building) -> SolveResult {
        var r = SolveResult()
        var systems = Set<String>()
        for cp in b.controlPoints {
            if let s = cp.surveyed {
                r.coordinates[cp.id] = PlanPoint(e: s.easting, n: s.northing, h: s.elevation)
                systems.insert(s.system)
            }
        }
        if !r.coordinates.isEmpty {
            r.frameDescription = "Survey grid" + (systems.isEmpty ? "" : " (" + systems.sorted().joined(separator: ", ") + ")")
        } else {
            // Local frame from the first session that sees two different control points.
            for s in b.sessions {
                let distinct = uniqueObservations(s)
                if distinct.count >= 2 {
                    let a = distinct[0], c = distinct[1]
                    let (ax, ay) = PlanTransform.flat(a.position)
                    let (cx, cy) = PlanTransform.flat(c.position)
                    let d = hypot(cx - ax, cy - ay)
                    guard d > 0.05 else { continue }
                    r.coordinates[a.controlPointID] = PlanPoint(e: 0, n: 0, h: 0)
                    r.coordinates[c.controlPointID] = PlanPoint(e: d, n: 0, h: c.position.y - a.position.y)
                    let an = b.controlPoint(a.controlPointID)?.name ?? "first point"
                    let cn = b.controlPoint(c.controlPointID)?.name ?? "second point"
                    r.frameDescription = "Local: \(an) is 0/0, \(cn) lies due east"
                    break
                }
            }
        }

        var progress = true
        while progress {
            progress = false
            for s in b.sessions where r.transforms[s.id] == nil {
                let known = s.observations.filter { r.coordinates[$0.controlPointID] != nil }
                guard Set(known.map(\.controlPointID)).count >= 2 else { continue }
                guard let (t, rms) = fit(known.map { ($0.position, r.coordinates[$0.controlPointID]!) }) else { continue }
                r.transforms[s.id] = t
                r.residuals[s.id] = rms
                if Set(known.map(\.controlPointID)).count >= 3 {
                    for o in known {
                        let p = t.apply(o.position), q = r.coordinates[o.controlPointID]!
                        let err = hypot(p.e - q.e, p.n - q.n)
                        r.pointResiduals[o.controlPointID] = max(r.pointResiduals[o.controlPointID] ?? 0, err)
                    }
                }
                // Give coordinates to control points first seen in this session.
                var newOnes: [UUID: [PlanPoint]] = [:]
                for o in s.observations where r.coordinates[o.controlPointID] == nil {
                    newOnes[o.controlPointID, default: []].append(t.apply(o.position))
                }
                for (id, pts) in newOnes {
                    let n = Double(pts.count)
                    r.coordinates[id] = PlanPoint(e: pts.map(\.e).reduce(0, +) / n,
                                                  n: pts.map(\.n).reduce(0, +) / n,
                                                  h: pts.map(\.h).reduce(0, +) / n)
                }
                progress = true
            }
        }
        return r
    }

    private static func uniqueObservations(_ s: MeasureSession) -> [ControlObservation] {
        var seen = Set<UUID>()
        return s.observations.filter { seen.insert($0.controlPointID).inserted }
    }

    /// 2D rigid least-squares fit (Kabsch) plus mean height offset.
    static func fit(_ pairs: [(Vec3, PlanPoint)]) -> (PlanTransform, Double)? {
        guard pairs.count >= 2 else { return nil }
        let n = Double(pairs.count)
        let src = pairs.map { PlanTransform.flat($0.0) }
        let dst = pairs.map { ($0.1.e, $0.1.n) }
        let scx = src.map(\.0).reduce(0, +) / n, scy = src.map(\.1).reduce(0, +) / n
        let dcx = dst.map(\.0).reduce(0, +) / n, dcy = dst.map(\.1).reduce(0, +) / n
        var sxx = 0.0, sxy = 0.0
        for i in 0..<pairs.count {
            let px = src[i].0 - scx, py = src[i].1 - scy
            let qx = dst[i].0 - dcx, qy = dst[i].1 - dcy
            sxx += px * qx + py * qy
            sxy += px * qy - py * qx
        }
        guard abs(sxx) + abs(sxy) > 1e-9 else { return nil }
        let angle = atan2(sxy, sxx)
        let c = cos(angle), s = sin(angle)
        let tE = dcx - (c * scx - s * scy)
        let tN = dcy - (s * scx + c * scy)
        let tH = pairs.map { $0.1.h - $0.0.y }.reduce(0, +) / n
        let t = PlanTransform(cosA: c, sinA: s, tE: tE, tN: tN, tH: tH)
        var sq = 0.0
        for (v, q) in pairs {
            let p = t.apply(v)
            sq += (p.e - q.e) * (p.e - q.e) + (p.n - q.n) * (p.n - q.n)
        }
        return (t, sqrt(sq / n))
    }
}
