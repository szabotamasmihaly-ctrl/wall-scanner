import Foundation
import ARKit
import CoreImage
import UIKit
import simd

/// Math shared by scanning and overlay.
///
/// A wall is described by a transform ("wall frame") in AR world space:
///   origin  = bottom-left corner of the wall (on the floor line)
///   +X      = along the wall to the right (horizontal)
///   +Y      = world up
///   +Z      = out of the wall, toward the person looking at it
enum WallGeometry {

    /// Builds the wall frame from two taps on the floor line (left and right corner).
    /// The order of taps does not matter: the corners are swapped if needed so that
    /// +Z points toward the camera.
    static func wallFrame(cornerA: SIMD3<Float>, cornerB: SIMD3<Float>, cameraPosition: SIMD3<Float>) -> (transform: simd_float4x4, width: Float)? {
        var left = cornerA
        var right = cornerB
        var along = right - left
        along.y = 0
        guard simd_length(along) > 0.05 else { return nil }
        var x = simd_normalize(along)
        let up = SIMD3<Float>(0, 1, 0)
        var z = simd_cross(x, up)
        if simd_dot(z, cameraPosition - left) < 0 {
            swap(&left, &right)
            x = -x
            z = -z
        }
        let width = simd_length(along)
        let origin = SIMD3<Float>(left.x, min(left.y, right.y), left.z)
        let t = simd_float4x4(columns: (
            SIMD4<Float>(x, 0),
            SIMD4<Float>(up, 0),
            SIMD4<Float>(z, 0),
            SIMD4<Float>(origin, 1)
        ))
        return (t, width)
    }

    static func worldPoint(_ p: WallPoint, in frame: simd_float4x4) -> SIMD3<Float> {
        let v = frame * SIMD4<Float>(Float(p.x), Float(p.y), 0, 1)
        return SIMD3<Float>(v.x, v.y, v.z)
    }

    static func wallPoint(fromWorld w: SIMD3<Float>, in frame: simd_float4x4) -> WallPoint {
        let v = frame.inverse * SIMD4<Float>(w, 1)
        return WallPoint(x: Double(v.x), y: Double(v.y))
    }

    /// Intersects a world-space ray with the wall plane (z = 0 in wall frame).
    static func intersect(rayOrigin o: SIMD3<Float>, direction d: SIMD3<Float>, frame: simd_float4x4) -> SIMD3<Float>? {
        let n = SIMD3<Float>(frame.columns.2.x, frame.columns.2.y, frame.columns.2.z)
        let p0 = SIMD3<Float>(frame.columns.3.x, frame.columns.3.y, frame.columns.3.z)
        let denom = simd_dot(n, d)
        guard abs(denom) > 1e-5 else { return nil }
        let t = simd_dot(p0 - o, n) / denom
        guard t > 0 else { return nil }
        return o + d * t
    }

    // MARK: - Distances

    static func distance(from p: WallPoint, to points: [WallPoint]) -> Double {
        guard let first = points.first else { return .infinity }
        if points.count == 1 { return hypot(p.x - first.x, p.y - first.y) }
        var best = Double.infinity
        for i in 0..<(points.count - 1) {
            best = min(best, segmentDistance(p, points[i], points[i + 1]))
        }
        return best
    }

    private static func segmentDistance(_ p: WallPoint, _ a: WallPoint, _ b: WallPoint) -> Double {
        let abx = b.x - a.x, aby = b.y - a.y
        let len2 = abx * abx + aby * aby
        guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        var t = ((p.x - a.x) * abx + (p.y - a.y) * aby) / len2
        t = max(0, min(1, t))
        return hypot(p.x - (a.x + t * abx), p.y - (a.y + t * aby))
    }

    // MARK: - Photo straightening

    private static let ciContext = CIContext()

    enum RectifyError: LocalizedError {
        case cornerBehindCamera
        case filterFailed
        var errorDescription: String? {
            switch self {
            case .cornerBehindCamera: return "Step back so the whole wall is in front of the camera."
            case .filterFailed: return "Could not process the photo. Try again."
            }
        }
    }

    /// Takes the current camera image and warps it so the wall rectangle becomes a
    /// straight-on, to-scale image (as if photographed perfectly square to the wall).
    /// Returns the image and whether every corner was inside the camera view.
    static func rectifiedPhoto(frame: ARFrame, wallTransform: simd_float4x4, width: Float, height: Float, pixelsPerMeter: Float = 600) throws -> (UIImage, Bool) {
        let camera = frame.camera
        let res = camera.imageResolution
        let viewToCamera = camera.transform.inverse

        let local: [WallPoint] = [
            WallPoint(x: 0, y: Double(height)),             // top-left
            WallPoint(x: Double(width), y: Double(height)), // top-right
            WallPoint(x: Double(width), y: 0),              // bottom-right
            WallPoint(x: 0, y: 0)                           // bottom-left
        ]
        var imagePoints: [CGPoint] = []
        var allVisible = true
        for lp in local {
            let w = worldPoint(lp, in: wallTransform)
            let c = viewToCamera * SIMD4<Float>(w, 1)
            if c.z >= -0.01 { throw RectifyError.cornerBehindCamera } // camera looks down -Z
            // Pixel coordinates in the captured (sensor, landscape) image, origin top-left.
            let p = camera.projectPoint(w, orientation: .landscapeRight, viewportSize: res)
            if p.x < 0 || p.y < 0 || p.x > res.width || p.y > res.height { allVisible = false }
            // Core Image uses a bottom-left origin.
            imagePoints.append(CGPoint(x: p.x, y: res.height - p.y))
        }

        let input = CIImage(cvPixelBuffer: frame.capturedImage)
        guard let filter = CIFilter(name: "CIPerspectiveCorrection") else { throw RectifyError.filterFailed }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgPoint: imagePoints[0]), forKey: "inputTopLeft")
        filter.setValue(CIVector(cgPoint: imagePoints[1]), forKey: "inputTopRight")
        filter.setValue(CIVector(cgPoint: imagePoints[2]), forKey: "inputBottomRight")
        filter.setValue(CIVector(cgPoint: imagePoints[3]), forKey: "inputBottomLeft")
        guard let corrected = filter.outputImage, corrected.extent.width > 1, corrected.extent.height > 1 else {
            throw RectifyError.filterFailed
        }

        // Scale to true wall proportions (meters -> pixels), capped for texture limits.
        var targetW = CGFloat(width * pixelsPerMeter)
        var targetH = CGFloat(height * pixelsPerMeter)
        let maxSide: CGFloat = 4096
        let scaleDown = min(1, maxSide / max(targetW, targetH))
        targetW = (targetW * scaleDown).rounded()
        targetH = (targetH * scaleDown).rounded()

        let e = corrected.extent
        let scaled = corrected
            .transformed(by: CGAffineTransform(translationX: -e.origin.x, y: -e.origin.y))
            .transformed(by: CGAffineTransform(scaleX: targetW / e.width, y: targetH / e.height))
        let outRect = CGRect(x: 0, y: 0, width: targetW, height: targetH)
        // Fill anything outside the camera view with dark grey instead of transparency.
        let background = CIImage(color: CIColor(red: 0.15, green: 0.15, blue: 0.15)).cropped(to: outRect)
        guard let cg = ciContext.createCGImage(scaled.composited(over: background), from: outRect) else {
            throw RectifyError.filterFailed
        }
        return (UIImage(cgImage: cg), allVisible)
    }
}
