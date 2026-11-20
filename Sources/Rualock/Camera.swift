import AVFoundation
import CoreVideo

/// The webcam, delivering BGRA frames on a background queue. Prefers the built-in camera.
final class Camera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    /// Called on the video queue for every frame.
    var onFrame: ((CVPixelBuffer) -> Void)?
    private(set) var running = false
    private var configured = false
    private let sessionQueue = DispatchQueue(label: "rualock.camera.session")
    private let videoQueue = DispatchQueue(label: "rualock.camera.video")

    static var authorized: Bool { AVCaptureDevice.authorizationStatus(for: .video) == .authorized }

    @discardableResult
    func start() -> Bool {
        guard Self.authorized else { return false }
        if !configured {
            guard configure() else { return false }
            configured = true
        }
        if !running {
            running = true
            sessionQueue.async { self.session.startRunning() }
        }
        return true
    }

    func stop() {
        guard running else { return }
        running = false
        sessionQueue.async { self.session.stopRunning() }  // camera light goes off
    }

    /// Re-open the device, for example after it was unplugged or stopped sending frames.
    func reset() {
        stop()
        sessionQueue.async {
            self.session.beginConfiguration()
            self.session.inputs.forEach { self.session.removeInput($0) }
            self.session.outputs.forEach { self.session.removeOutput($0) }
            self.session.commitConfiguration()
        }
        configured = false
    }

    private func configure() -> Bool {
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external], mediaType: .video, position: .unspecified
        ).devices
        guard let device = devices.first(where: { $0.deviceType == .builtInWideAngleCamera }) ?? devices.first
            ?? AVCaptureDevice.default(for: .video),
            let input = try? AVCaptureDeviceInput(device: device) else {
            note("no camera found")
            return false
        }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = session.canSetSessionPreset(.hd1280x720) ? .hd1280x720 : .high
        guard session.canAddInput(input) else { return false }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(output) else { return false }
        session.addOutput(output)
        lowerFrameRate(device)
        note("camera: \(device.localizedName)")
        return true
    }

    /// Ask for a low frame rate when the camera supports it: enough to catch a blink (about 0.1-0.3 s),
    /// less work than 30 fps, and better low-light exposure.
    private func lowerFrameRate(_ device: AVCaptureDevice) {
        guard device.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= Watcher.watchFPS && $0.maxFrameRate >= Watcher.watchFPS }),
              (try? device.lockForConfiguration()) != nil else { return }
        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(Watcher.watchFPS))
        device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(Watcher.watchFPS))
        device.unlockForConfiguration()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(buffer)
    }
}
