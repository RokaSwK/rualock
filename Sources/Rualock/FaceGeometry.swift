import CoreGraphics
import Foundation

/// Eye and mouth measurements in the face's own frame, so that moving a photo can't fake a blink or
/// a word:
/// - Points are rotated onto the line between the eyes, so tilting a photo sideways changes nothing.
/// - Eye height is divided by the distance from the eyes down to the mouth. Tipping a photo back
///   squashes both by the same amount, so the ratio holds; only closing the eyes changes it.
/// - Mouth opening is the inner lips' height over their width, both along the face's own axes.
enum FaceGeometry {
    /// Eye height (both eyes averaged) over the eyes-to-mouth distance; drops sharply in a blink.
    static func eyeOpenness(leftEye: [CGPoint], rightEye: [CGPoint], mouth: [CGPoint]) -> Double? {
        guard let frame = Frame(leftEye: leftEye, rightEye: rightEye), !mouth.isEmpty else { return nil }
        let l = frame.extent(leftEye), r = frame.extent(rightEye)
        let down = abs(frame.place(centre(mouth)).y)  // eye line is y = 0 in the face's frame
        guard down > 1 else { return nil }
        return Double((l.height + r.height) / 2 / down)
    }

    /// Inner-lip height over width: near 0 when closed, larger when talking.
    static func mouthOpening(innerLips: [CGPoint], leftEye: [CGPoint], rightEye: [CGPoint]) -> Double? {
        guard let frame = Frame(leftEye: leftEye, rightEye: rightEye), innerLips.count >= 3 else { return nil }
        let e = frame.extent(innerLips)
        return e.width > 1 ? Double(e.height / e.width) : nil
    }

    static func centre(_ p: [CGPoint]) -> CGPoint {
        CGPoint(x: p.map(\.x).reduce(0, +) / CGFloat(p.count), y: p.map(\.y).reduce(0, +) / CGFloat(p.count))
    }

    /// Coordinates with the origin between the eyes and the x axis along the eye line.
    private struct Frame {
        let origin: CGPoint, cos: CGFloat, sin: CGFloat

        init?(leftEye: [CGPoint], rightEye: [CGPoint]) {
            guard !leftEye.isEmpty, !rightEye.isEmpty else { return nil }
            var a = FaceGeometry.centre(leftEye), b = FaceGeometry.centre(rightEye)
            if a.x > b.x { swap(&a, &b) }
            let angle = atan2(b.y - a.y, b.x - a.x)
            guard hypot(b.x - a.x, b.y - a.y) > 1 else { return nil }
            origin = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            cos = Foundation.cos(-angle)
            sin = Foundation.sin(-angle)
        }

        func place(_ p: CGPoint) -> CGPoint {
            let x = p.x - origin.x, y = p.y - origin.y
            return CGPoint(x: x * cos - y * sin, y: x * sin + y * cos)
        }

        func extent(_ points: [CGPoint]) -> CGSize {
            let p = points.map(place)
            guard let minX = p.map(\.x).min(), let maxX = p.map(\.x).max(),
                  let minY = p.map(\.y).min(), let maxY = p.map(\.y).max() else { return .zero }
            return CGSize(width: maxX - minX, height: maxY - minY)
        }
    }
}
