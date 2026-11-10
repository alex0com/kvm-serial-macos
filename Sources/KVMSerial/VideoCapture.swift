@preconcurrency import AVFoundation
import CoreMedia
import os

/// One selectable capture format.
struct VideoFormatChoice: @unchecked Sendable {
    let format: AVCaptureDevice.Format
    let width: Int32
    let height: Int32
    let maxFrameRate: Double
    let subtype: FourCharCode
    /// False when macOS decodes this format from MJPEG behind the scenes,
    /// which adds a decode step and latency.
    let isNative: Bool

    init(_ format: AVCaptureDevice.Format) {
        self.format = format
        let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        width = dims.width
        height = dims.height
        maxFrameRate = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
        subtype = CMFormatDescriptionGetMediaSubType(format.formatDescription)
        let extensions = CMFormatDescriptionGetExtensions(format.formatDescription) as? [String: Any]
        isNative = extensions?["com.apple.cmio.format_extension.decompressed_from_format_type"] == nil
    }

    var key: String { "\(width)x\(height)@\(Int(maxFrameRate.rounded()))/\(fourCC)" }

    var fourCC: String {
        let bytes = [24, 16, 8, 0].map { UInt8((subtype >> $0) & 0xFF) }
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }

    var label: String {
        let fps = maxFrameRate.rounded() == maxFrameRate
            ? "\(Int(maxFrameRate))" : String(format: "%.2f", maxFrameRate)
        return "\(width)×\(height) \(fps) fps \(fourCC)" + (isNative ? "" : " (decoded)")
    }

    /// Pixel formats the renderer can draw directly.
    static let renderable: Set<FourCharCode> = [
        kCVPixelFormatType_422YpCbCr8_yuvs,  // 'yuvs' YUY2
        kCVPixelFormatType_422YpCbCr8,  // '2vuy' UYVY
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,  // '420v'
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,  // '420f'
    ]

    /// Formats worth offering, best first: native before decoded, then by
    /// pixel count, then frame rate.
    static func choices(for device: AVCaptureDevice) -> [VideoFormatChoice] {
        device.formats.map(VideoFormatChoice.init)
            .filter { $0.maxFrameRate > 0 }
            .sorted {
                if $0.isNative != $1.isNative { return $0.isNative }
                let a = Int($0.width) * Int($0.height), b = Int($1.width) * Int($1.height)
                if a != b { return a > b }
                return $0.maxFrameRate > $1.maxFrameRate
            }
    }

    /// The format to use when none is saved. Frame rate comes before size:
    /// 4K cards often list 3840×2160 at under 20 fps, which adds a frame
    /// interval of 50+ ms. Portrait modes such as 1920×2160 are skipped.
    static func automatic(for device: AVCaptureDevice) -> VideoFormatChoice? {
        let usable = choices(for: device).filter { renderable.contains($0.subtype) }
        let landscape = usable.filter { $0.width >= $0.height }
        return (landscape.isEmpty ? usable : landscape).min {
            if $0.isNative != $1.isNative { return $0.isNative }
            let fa = $0.maxFrameRate.rounded(), fb = $1.maxFrameRate.rounded()
            if fa != fb { return fa > fb }
            return Int($0.width) * Int($0.height) > Int($1.width) * Int($1.height)
        }
    }
}

/// AVFoundation capture into a frame callback, tuned for latency: the
/// device's native pixel format (no conversion), the highest frame rate
/// locked, and late frames dropped rather than queued.
final class VideoCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
    @unchecked Sendable
{
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "video session")
    private let frameQueue = DispatchQueue(label: "video frames", qos: .userInteractive)
    private let onFrame: @Sendable (CVPixelBuffer, CMTime) -> Void

    init(onFrame: @escaping @Sendable (CVPixelBuffer, CMTime) -> Void) {
        self.onFrame = onFrame
    }

    static func devices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external], mediaType: .video, position: .unspecified
        ).devices
    }

    /// Reconfigure the session for `device` in `choice` and start it.
    func start(device: AVCaptureDevice, choice: VideoFormatChoice,
               completion: @escaping @Sendable (Error?) -> Void) {
        sessionQueue.async { [self] in
            do {
                // Hold the configuration lock until the session is running;
                // otherwise startRunning() replaces activeFormat with the
                // session preset's choice (on this card, MJPEG-decoded 420v).
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                try configure(device: device, choice: choice)
                if !session.isRunning { session.startRunning() }
                Logger(subsystem: "com.alex0com.kvm-serial-macos", category: "video").info(
                    "Capture running, active format \(VideoFormatChoice(device.activeFormat).label, privacy: .public)")
                completion(nil)
            } catch {
                completion(error)
            }
        }
    }

    func stop() {
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    /// Call with the device locked for configuration.
    private func configure(device: AVCaptureDevice, choice: VideoFormatChoice) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.inputs.forEach(session.removeInput)
        session.outputs.forEach(session.removeOutput)

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw CocoaError(.featureUnsupported, userInfo: [
                NSLocalizedDescriptionKey: "Cannot use \(device.localizedName) for capture."
            ])
        }
        session.addInput(input)

        device.activeFormat = choice.format
        if let range = choice.format.videoSupportedFrameRateRanges
            .max(by: { $0.maxFrameRate < $1.maxFrameRate })
        {
            device.activeVideoMinFrameDuration = range.minFrameDuration
            device.activeVideoMaxFrameDuration = range.minFrameDuration
        }

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        // Ask for the device's own pixel format so nothing is converted.
        // Formats the renderer can't draw (e.g. MJPEG) are decoded to 420v.
        let pixelFormat = VideoFormatChoice.renderable.contains(choice.subtype)
            ? choice.subtype : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        output.setSampleBufferDelegate(self, queue: frameQueue)
        guard session.canAddOutput(output) else {
            throw CocoaError(.featureUnsupported, userInfo: [
                NSLocalizedDescriptionKey: "Cannot capture \(choice.label)."
            ])
        }
        session.addOutput(output)
    }

    func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame(pixelBuffer, CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }
}
