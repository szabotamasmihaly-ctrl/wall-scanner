import UIKit

/// Draws the image that is projected onto the wall in AR (and shown in the editor):
/// the straightened photo, a measuring grid, and the marked features.
enum OverlayRenderer {

    struct Options {
        var showPhoto = true
        var showFeatures = true
        var showGrid = true
    }

    static func render(wall: WallRecord, photo: UIImage?, options: Options) -> UIImage {
        let w = CGFloat(wall.width), h = CGFloat(wall.height)
        let size: CGSize
        if let photo {
            size = CGSize(width: photo.size.width * photo.scale, height: photo.size.height * photo.scale)
        } else {
            let ppm: CGFloat = min(400, 4096 / max(w, h))
            size = CGSize(width: (w * ppm).rounded(), height: (h * ppm).rounded())
        }
        let ppmX = size.width / w
        let ppmY = size.height / h
        func px(_ p: WallPoint) -> CGPoint {
            CGPoint(x: CGFloat(p.x) * ppmX, y: (h - CGFloat(p.y)) * ppmY)
        }
        let ppm = (ppmX + ppmY) / 2

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let cg = ctx.cgContext

            if options.showPhoto, let photo {
                photo.draw(in: CGRect(origin: .zero, size: size))
            }

            if options.showGrid {
                // Thin line every 10 cm, thicker every 50 cm.
                var x: CGFloat = 0
                var i = 0
                while x <= w + 0.001 {
                    let major = i % 5 == 0
                    cg.setStrokeColor(UIColor.white.withAlphaComponent(major ? 0.55 : 0.2).cgColor)
                    cg.setLineWidth(major ? max(2, ppm * 0.004) : max(1, ppm * 0.002))
                    cg.move(to: CGPoint(x: x * ppmX, y: 0))
                    cg.addLine(to: CGPoint(x: x * ppmX, y: size.height))
                    cg.strokePath()
                    x += 0.1; i += 1
                }
                var y: CGFloat = 0
                i = 0
                while y <= h + 0.001 {
                    let major = i % 5 == 0
                    cg.setStrokeColor(UIColor.white.withAlphaComponent(major ? 0.55 : 0.2).cgColor)
                    cg.setLineWidth(major ? max(2, ppm * 0.004) : max(1, ppm * 0.002))
                    let yy = (h - y) * ppmY
                    cg.move(to: CGPoint(x: 0, y: yy))
                    cg.addLine(to: CGPoint(x: size.width, y: yy))
                    cg.strokePath()
                    y += 0.1; i += 1
                }
                // Outline
                cg.setStrokeColor(UIColor.cyan.cgColor)
                cg.setLineWidth(max(3, ppm * 0.01))
                cg.stroke(CGRect(origin: .zero, size: size).insetBy(dx: 2, dy: 2))
            }

            if options.showFeatures {
                for f in wall.features {
                    let color = f.kind.uiColor
                    if f.points.count == 1 {
                        let c = px(f.points[0])
                        let r = ppm * 0.04
                        cg.setFillColor(color.withAlphaComponent(0.85).cgColor)
                        cg.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
                        cg.setStrokeColor(UIColor.white.cgColor)
                        cg.setLineWidth(max(2, ppm * 0.006))
                        cg.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
                    } else if f.points.count > 1 {
                        // White halo under the coloured line keeps it readable on any photo.
                        for (lineColor, widthM) in [(UIColor.white, 0.035), (color, 0.025)] {
                            cg.setStrokeColor(lineColor.cgColor)
                            cg.setLineWidth(ppm * CGFloat(widthM))
                            cg.setLineCap(.round)
                            cg.setLineJoin(.round)
                            cg.move(to: px(f.points[0]))
                            for p in f.points.dropFirst() { cg.addLine(to: px(p)) }
                            cg.strokePath()
                        }
                    }
                }
                for r in wall.referencePoints {
                    let c = px(r.wallPosition)
                    let s = ppm * 0.05
                    cg.setStrokeColor(UIColor.green.cgColor)
                    cg.setLineWidth(max(3, ppm * 0.008))
                    cg.move(to: CGPoint(x: c.x - s, y: c.y)); cg.addLine(to: CGPoint(x: c.x + s, y: c.y))
                    cg.move(to: CGPoint(x: c.x, y: c.y - s)); cg.addLine(to: CGPoint(x: c.x, y: c.y + s))
                    cg.strokePath()
                }
            }
        }
    }
}
