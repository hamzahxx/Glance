import AVFoundation
import Foundation
import Vision

/// Built-in webcam → Vision face angles. Runs entirely off the main thread.
///
/// Uses `VNDetectFaceRectanglesRequest` revision 3, which is the revision that
/// reports pitch in addition to yaw and roll.
public final class PoseCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.glance.capture")
    private let request: VNDetectFaceRectanglesRequest = {
        let r = VNDetectFaceRectanglesRequest()
        r.revision = VNDetectFaceRectanglesRequestRevision3
        return r
    }()

    /// Called on the capture queue. `nil` means a frame arrived with no usable face.
    public var onPose: (@Sendable (HeadPose?) -> Void)?

    /// Camera vanished or the session blew up mid-run. FR-03.
    public var onFailure: (@Sendable (String) -> Void)?

    public private(set) var deviceName = "unknown"

    public enum StartError: Error, CustomStringConvertible {
        case permissionDenied
        case noBuiltInCamera
        case cannotConfigure(String)

        public var description: String {
            switch self {
            case .permissionDenied:
                "Camera permission denied. Grant it in System Settings › Privacy & Security › Camera."
            case .noBuiltInCamera:
                "No built-in camera found."
            case .cannotConfigure(let why):
                "Could not configure capture: \(why)"
            }
        }
    }

    public func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    public func start() throws {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            throw StartError.permissionDenied
        }

        // Explicitly the built-in camera: a Continuity Camera sits at a totally
        // different angle and would invalidate the whole measurement.
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: .front
        )
        guard let device = discovery.devices.first(where: { !$0.isContinuityCamera })
                ?? discovery.devices.first
        else { throw StartError.noBuiltInCamera }
        deviceName = device.localizedName

        session.beginConfiguration()
        session.sessionPreset = .vga640x480  // Face rectangles do not need more.

        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            throw StartError.cannotConfigure("input rejected")
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else {
            throw StartError.cannotConfigure("output rejected")
        }
        session.addOutput(output)
        session.commitConfiguration()

        for name in [AVCaptureSession.runtimeErrorNotification, .AVCaptureDeviceWasDisconnected] {
            NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: nil
            ) { [weak self] note in
                let detail = (note.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription
                self?.onFailure?(detail ?? "camera disconnected")
            }
        }

        session.startRunning()
    }

    public func stop() {
        session.stopRunning()
    }

    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let handler = VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .up)
        do {
            try handler.perform([request])
        } catch {
            onPose?(nil)
            return
        }

        // Largest face wins if someone walks behind you.
        guard let face = (request.results ?? []).max(by: {
            $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height
        }),
            let yaw = face.yaw?.doubleValue,
            let pitch = face.pitch?.doubleValue,
            let roll = face.roll?.doubleValue
        else {
            onPose?(nil)
            return
        }

        let degrees = 180.0 / .pi
        onPose?(HeadPose(
            yaw: yaw * degrees,
            pitch: pitch * degrees,
            roll: roll * degrees,
            faceArea: Double(face.boundingBox.width * face.boundingBox.height),
            confidence: Double(face.confidence)
        ))
    }
}
