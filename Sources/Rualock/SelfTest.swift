import AppKit
import CoreVideo

enum SelfTest {
    static func embed(path: String) -> Int32 {
        guard let image = NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            FileHandle.standardError.write(Data("cannot read \(path)\n".utf8))
            return 1
        }
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, image.width, image.height, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferCGImageCompatibilityKey: true] as CFDictionary, &buffer)
        guard let buffer else { return 1 }
        CVPixelBufferLockBaseAddress(buffer, [])
        let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
        ctx?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        do {
            let (count, found) = try FaceEngine().embeddings(in: buffer)
            print("faces: \(count)")
            if let e = found.first { print(e.map { String(format: "%.6f", $0) }.joined(separator: " ")) }
            return found.isEmpty ? 2 : 0
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            return 1
        }
    }
}
