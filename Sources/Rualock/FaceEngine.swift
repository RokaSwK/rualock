import CoreML
import CoreVideo
import Foundation
import Vision

/// Finds faces with Apple's Vision framework and turns each into a 128-number SFace embedding.
///
/// Faces are aligned like OpenCV's `FaceRecognizerSF.alignCrop`: five landmarks (eye centres,
/// nose tip, mouth corners) are mapped onto a fixed 112x112 template by a similarity transform.
final class FaceEngine {
    static let dimensions = 128
    private static let size = 112
    private static let template: [(Double, Double)] = [
        (38.2946, 51.6963), (73.5318, 51.5014), (56.0252, 71.7366), (41.5493, 92.3655), (70.7299, 92.2041),
    ]

    private let model: MLModel

    init() throws {
        guard let url = Bundle.main.url(forResource: "SFace", withExtension: "mlmodelc") else {
            throw NSError(domain: "Rualock", code: 1, userInfo: [NSLocalizedDescriptionKey: "SFace.mlmodelc missing from the app bundle"])
        }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        model = try MLModel(contentsOf: url, configuration: config)
    }

    struct Face {
        /// Normalised Vision coordinates (0-1, bottom-left origin).
        var box: CGRect
        /// Eye height over width, averaged over both eyes; drops sharply during a blink.
        var openness: Double?
        /// Unit-length SFace embedding, when requested.
        var embedding: [Float]?
        /// Inner-lip height over width: near 0 closed, larger when talking.
        var mouthOpen: Double? = nil
        /// Mouth width over the distance between the eyes: grows when smiling.
        var mouthWidth: Double? = nil
    }

    /// Faces found by the last full detection; frames in between only refit landmarks inside them.
    private var known: [VNFaceObservation] = []

    private static let neuralEngine: MLComputeDevice? = {
        guard let devices = try? VNDetectFaceLandmarksRequest().supportedComputeStageDevices[.main] else { return nil }
        return devices.first { if case .neuralEngine = $0 { return true } else { return false } }
    }()

    /// Up to `limit` faces, largest first, with eye openness and (if `embed`) embeddings,
    /// plus how many faces were seen in total. With `embed` it also re-detects faces; without, it only
    /// refits landmarks inside the faces found last time, which is much cheaper (for blink tracking).
    func analyze(_ buffer: CVPixelBuffer, embed wantEmbeddings: Bool, limit: Int = 3) -> (count: Int, faces: [Face]) {
        let request = VNDetectFaceLandmarksRequest()
        if let ne = Self.neuralEngine { request.setComputeDevice(ne, for: .main) }
        if !wantEmbeddings && known.isEmpty { return (0, []) }  // nobody at the last detection: wait for the next
        let refit = !wantEmbeddings
        if refit { request.inputFaceObservations = known }
        do {
            try VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up).perform([request])
        } catch {
            return (0, [])
        }
        let observations = (request.results ?? []).filter { $0.landmarks != nil }.sorted {
            $0.boundingBox.width * $0.boundingBox.height > $1.boundingBox.width * $1.boundingBox.height
        }
        if !refit { known = Array(observations.prefix(limit)) }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        if wantEmbeddings { CVPixelBufferLockBaseAddress(buffer, .readOnly) }
        defer { if wantEmbeddings { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) } }
        var out: [Face] = []
        for o in observations.prefix(limit) {
            var face = Face(box: o.boundingBox, openness: Self.openness(o, width: w, height: h), embedding: nil)
            (face.mouthOpen, face.mouthWidth) = Self.mouth(o, width: w, height: h)
            if wantEmbeddings, let points = Self.fivePoints(o, width: w, height: h), let input = Self.align(buffer, points: points) {
                face.embedding = embed(input)
            }
            out.append(face)
        }
        return (observations.count, out)
    }

    /// Embeddings (unit length) for up to `limit` faces, largest first, plus how many faces were seen.
    func embeddings(in buffer: CVPixelBuffer, limit: Int = 3) -> (count: Int, embeddings: [[Float]]) {
        let (count, faces) = analyze(buffer, embed: true, limit: limit)
        return (count, faces.compactMap(\.embedding))
    }

    private static func mouth(_ face: VNFaceObservation, width: Int, height: Int) -> (Double?, Double?) {
        guard let lm = face.landmarks, let inner = lm.innerLips, let outer = lm.outerLips,
              let l = lm.leftEye, let r = lm.rightEye else { return (nil, nil) }
        let size = CGSize(width: width, height: height)
        func extent(_ region: VNFaceLandmarkRegion2D) -> (w: Double, h: Double, c: CGPoint)? {
            let p = region.pointsInImage(imageSize: size)
            guard let minX = p.map(\.x).min(), let maxX = p.map(\.x).max(),
                  let minY = p.map(\.y).min(), let maxY = p.map(\.y).max() else { return nil }
            return (Double(maxX - minX), Double(maxY - minY), CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2))
        }
        guard let i = extent(inner), let o = extent(outer), let a = extent(l), let b = extent(r) else { return (nil, nil) }
        let eyeDistance = Double(hypot(a.c.x - b.c.x, a.c.y - b.c.y))
        return (i.w > 1 ? i.h / i.w : nil, eyeDistance > 1 ? o.w / eyeDistance : nil)
    }

    private static func openness(_ face: VNFaceObservation, width: Int, height: Int) -> Double? {
        guard let lm = face.landmarks, let l = lm.leftEye, let r = lm.rightEye else { return nil }
        let size = CGSize(width: width, height: height)
        func ratio(_ region: VNFaceLandmarkRegion2D) -> Double? {
            let p = region.pointsInImage(imageSize: size)
            guard let minX = p.map(\.x).min(), let maxX = p.map(\.x).max(),
                  let minY = p.map(\.y).min(), let maxY = p.map(\.y).max(), maxX - minX > 1 else { return nil }
            return Double((maxY - minY) / (maxX - minX))
        }
        guard let a = ratio(l), let b = ratio(r) else { return nil }
        return (a + b) / 2
    }

    /// Eye centres (image-left first), nose tip, mouth corners, in top-left pixel coordinates.
    private static func fivePoints(_ face: VNFaceObservation, width: Int, height: Int) -> [(Double, Double)]? {
        guard let lm = face.landmarks,
              let leftEye = lm.leftEye, let rightEye = lm.rightEye,
              let crest = lm.noseCrest, let lips = lm.outerLips else { return nil }
        let size = CGSize(width: width, height: height)
        func pts(_ r: VNFaceLandmarkRegion2D) -> [(Double, Double)] {
            r.pointsInImage(imageSize: size).map { (Double($0.x), Double(height) - Double($0.y)) }
        }
        func centre(_ p: [(Double, Double)]) -> (Double, Double) {
            (p.map(\.0).reduce(0, +) / Double(p.count), p.map(\.1).reduce(0, +) / Double(p.count))
        }
        let eyes = [centre(pts(leftEye)), centre(pts(rightEye))].sorted { $0.0 < $1.0 }
        let crestPts = pts(crest), lipPts = pts(lips)
        guard !crestPts.isEmpty, !lipPts.isEmpty,
              let tip = crestPts.max(by: { $0.1 < $1.1 }),
              let mouthL = lipPts.min(by: { $0.0 < $1.0 }),
              let mouthR = lipPts.max(by: { $0.0 < $1.0 }) else { return nil }
        return [eyes[0], eyes[1], tip, mouthL, mouthR]
    }

    /// Least-squares similarity transform from the landmarks to the template, then a bilinear warp
    /// into a 1x3x112x112 RGB tensor with values 0-255 (what SFace expects).
    private static func align(_ buffer: CVPixelBuffer, points src: [(Double, Double)]) -> MLMultiArray? {
        let n = Double(src.count)
        let ms = (src.map(\.0).reduce(0, +) / n, src.map(\.1).reduce(0, +) / n)
        let md = (template.map(\.0).reduce(0, +) / n, template.map(\.1).reduce(0, +) / n)
        var a = 0.0, b = 0.0, norm = 0.0
        for (s, d) in zip(src, template) {
            let sx = s.0 - ms.0, sy = s.1 - ms.1, dx = d.0 - md.0, dy = d.1 - md.1
            a += sx * dx + sy * dy
            b += sx * dy - sy * dx
            norm += sx * sx + sy * sy
        }
        guard norm > 1e-6 else { return nil }
        let c = a / norm, s = b / norm  // forward: dst = [c -s; s c] * (src - ms) + md
        let det = c * c + s * s
        guard det > 1e-12 else { return nil }
        // inverse: src = [c s; -s c] / det * (dst - md) + ms
        let ic = c / det, isn = s / det

        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self),
              CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              let arr = try? MLMultiArray(shape: [1, 3, NSNumber(value: size), NSNumber(value: size)], dataType: .float32)
        else { return nil }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let out = arr.dataPointer.assumingMemoryBound(to: Float.self)
        let plane = size * size

        for v in 0 ..< size {
            for u in 0 ..< size {
                let du = Double(u) - md.0, dv = Double(v) - md.1
                let x = ic * du + isn * dv + ms.0
                let y = -isn * du + ic * dv + ms.1
                var r = 0.0, g = 0.0, bl = 0.0
                let x0 = Int(floor(x)), y0 = Int(floor(y))
                let fx = x - Double(x0), fy = y - Double(y0)
                for (yy, wy) in [(y0, 1 - fy), (y0 + 1, fy)] where yy >= 0 && yy < h && wy > 0 {
                    for (xx, wx) in [(x0, 1 - fx), (x0 + 1, fx)] where xx >= 0 && xx < w && wx > 0 {
                        let p = base + yy * rowBytes + xx * 4  // BGRA
                        let k = wx * wy
                        bl += k * Double(p[0])
                        g += k * Double(p[1])
                        r += k * Double(p[2])
                    }
                }
                let i = v * size + u
                out[i] = Float(r)
                out[plane + i] = Float(g)
                out[2 * plane + i] = Float(bl)
            }
        }
        return arr
    }

    private func embed(_ input: MLMultiArray) -> [Float]? {
        guard let provider = try? MLDictionaryFeatureProvider(dictionary: ["face": input]),
              let result = try? model.prediction(from: provider),
              let e = result.featureValue(for: "embedding")?.multiArrayValue,
              e.count == Self.dimensions else { return nil }
        var v = (0 ..< e.count).map { e[$0].floatValue }
        let len = sqrt(v.reduce(0) { $0 + $1 * $1 })
        guard len > 0 else { return nil }
        for i in v.indices { v[i] /= len }
        return v
    }

    static func similarity(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }
}
