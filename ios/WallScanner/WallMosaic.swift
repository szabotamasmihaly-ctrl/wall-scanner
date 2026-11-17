import Foundation
import ARKit
import CoreImage
import UIKit
import simd

/// Builds the wall picture from live video: while you sweep the phone over the open wall,
/// every good frame is straightened onto the wall rectangle and painted into one image.
/// Frames that are too far, too oblique or poorly tracked are skipped.
final class WallMosaic {
    let wallTransform: simd_float4x4
    let width: Float
    let height: Float
    let outSize: CGSize

    private let queue = DispatchQueue(label: "wall.mosaic", qos: .userInitiated)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var accumulated: CIImage
    private var busy = false
    private var lastAccepted: TimeInterval = 0

    // Coverage grid in wall coordinates.
    private let gridX = 32, gridY = 24
    private var covered: [Bool]

    /// Called on the main queue after each accepted frame.
    var onUpdate: ((UIImage, Double) -> Void)?

    init(wallTransform: simd_float4x4, width: Float, height: Float, pixelsPerMeter: Float = 500) {
        self.wallTransform = wallTransform
        self.width = width
        self.height = height
        var w = CGFloat(width * pixelsPerMeter), h = CGFloat(height * pixelsPerMeter)
        let s = min(1, 3072 / max(w, h))
        w = (w * s).rounded(); h = (h * s).rounded()
        outSize = CGSize(width: w, height: h)
        accumulated = CIImage(color: CIColor(red: 0.15, green: 0.15, blue: 0.15)).cropped(to: CGRect(origin: .zero, size: outSize))
        covered = Array(repeating: false, count: gridX * gridY)
    }

    var coverage: Double { Double(covered.filter { $0 }.count) / Double(covered.count) }

    /// Why the current frame is not being used, or nil if it is good.
    func rejectionReason(for frame: ARFrame) -> String? {
        guard case .normal = frame.camera.trackingState else { return "Hold steady – tracking limited" }
        let cam = frame.camera.transform
        let camPos = SIMD3<Float>(cam.columns.3.x, cam.columns.3.y, cam.columns.3.z)
        let forward = -SIMD3<Float>(cam.columns.2.x, cam.columns.2.y, cam.columns.2.z)
        let normal = SIMD3<Float>(wallTransform.columns.2.x, wallTransform.columns.2.y, wallTransform.columns.2.z)
        let origin = SIMD3<Float>(wallTransform.columns.3.x, wallTransform.columns.3.y, wallTransform.columns.3.z)
        let dist = simd_dot(camPos - origin, normal)
        if dist < 0.2 { return "Too close to the wall" }
        if dist > 3.5 { return "Move closer (under 3.5 m)" }
        let facing = simd_dot(forward, -normal)
        if facing < cos(Float.pi * 50 / 180) { return "Point the phone more squarely at the wall" }
        return nil
    }

    /// Feed a camera frame (call from the AR session delegate). Cheap when skipped.
    func add(_ frame: ARFrame) {
        guard !busy, frame.timestamp - lastAccepted > 0.25, rejectionReason(for: frame) == nil else { return }
        let camera = frame.camera
        let res = camera.imageResolution
        let toCam = camera.transform.inverse

        // Where the four corners of the camera image land on the wall plane, in wall-image
        // pixels (Core Image coordinates: origin bottom-left, which matches wall y-up).
        let x = SIMD3<Float>(wallTransform.columns.0.x, wallTransform.columns.0.y, wallTransform.columns.0.z)
        let n = SIMD3<Float>(wallTransform.columns.2.x, wallTransform.columns.2.y, wallTransform.columns.2.z)
        // unprojectPoint uses the plane's local x-z plane, so make the wall normal its y axis.
        let plane = simd_float4x4(columns: (
            wallTransform.columns.0,
            SIMD4<Float>(n, 0),
            SIMD4<Float>(simd_cross(x, n), 0),
            wallTransform.columns.3))
        let inverseWall = wallTransform.inverse
        var pts: [CGPoint] = []
        let imageCorners = [CGPoint(x: 0, y: 0), CGPoint(x: res.width, y: 0),
                            CGPoint(x: res.width, y: res.height), CGPoint(x: 0, y: res.height)] // TL, TR, BR, BL
        for ic in imageCorners {
            guard let w = camera.unprojectPoint(ic, ontoPlane: plane, orientation: .landscapeRight, viewportSize: res) else { return }
            let c = toCam * SIMD4<Float>(w, 1)
            if c.z > -0.05 { return } // intersection behind the camera
            let l = inverseWall * SIMD4<Float>(w, 1)
            guard abs(l.x) < 30, abs(l.y) < 30 else { return } // nearly parallel ray
            pts.append(CGPoint(x: CGFloat(l.x / width) * outSize.width, y: CGFloat(l.y / height) * outSize.height))
        }

        // Mark which wall cells this frame sees.
        var newCells: [Int] = []
        for j in 0..<gridY {
            for i in 0..<gridX {
                let wx = (Float(i) + 0.5) / Float(gridX) * width
                let wy = (Float(j) + 0.5) / Float(gridY) * height
                let w4 = wallTransform * SIMD4<Float>(wx, wy, 0, 1)
                let p = camera.projectPoint(SIMD3<Float>(w4.x, w4.y, w4.z), orientation: .landscapeRight, viewportSize: res)
                if p.x > 0, p.y > 0, p.x < res.width, p.y < res.height { newCells.append(j * gridX + i) }
            }
        }
        guard !newCells.isEmpty else { return }

        busy = true
        lastAccepted = frame.timestamp
        let pixelBuffer = frame.capturedImage
        queue.async { [weak self] in
            guard let self else { return }
            defer { self.busy = false }
            let image = CIImage(cvPixelBuffer: pixelBuffer)
            let white = CIImage(color: .white).cropped(to: image.extent)
            guard let warped = self.warp(image, pts), let mask = self.warp(white, pts) else { return }
            let blended = warped.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: self.accumulated,
                kCIInputMaskImageKey: mask
            ])
            let rect = CGRect(origin: .zero, size: self.outSize)
            guard let cg = self.context.createCGImage(blended, from: rect) else { return }
            self.accumulated = CIImage(cgImage: cg)
            for c in newCells { self.covered[c] = true }
            let cov = self.coverage
            let ui = UIImage(cgImage: cg)
            DispatchQueue.main.async { self.onUpdate?(ui, cov) }
        }
    }

    private func warp(_ input: CIImage, _ pts: [CGPoint]) -> CIImage? {
        let e = input.extent
        let normalized = input.transformed(by: CGAffineTransform(translationX: -e.origin.x, y: -e.origin.y))
        let out = normalized.applyingFilter("CIPerspectiveTransform", parameters: [
            "inputTopLeft": CIVector(cgPoint: pts[0]),
            "inputTopRight": CIVector(cgPoint: pts[1]),
            "inputBottomRight": CIVector(cgPoint: pts[2]),
            "inputBottomLeft": CIVector(cgPoint: pts[3])
        ])
        let rect = CGRect(origin: .zero, size: outSize)
        guard out.extent.intersects(rect) else { return nil }
        return out.cropped(to: rect)
    }

    /// The finished wall picture (waits for a frame still being processed).
    func finalImage() -> UIImage? {
        queue.sync {
            let rect = CGRect(origin: .zero, size: outSize)
            return context.createCGImage(accumulated, from: rect).map { UIImage(cgImage: $0) }
        }
    }
}
