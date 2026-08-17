import AVFoundation
import CoreVideo

/// The camera, and the only file that touches AVFoundation.
///
/// Two things are worth knowing.
///
/// **The rotation and the mirroring are done by the capture connections, not by
/// this code.** The preview connection and the data-output connection are always
/// set to the same orientation and the same mirroring, so a frame arrives here
/// already the way up it is on screen. That is the only reason the overlay
/// cannot drift out of register with the picture: there is no second copy of the
/// geometry to get wrong.
///
/// **All a frame is used for is the motion grid.** The luma plane is box-averaged
/// down to roughly 176 cells across — the part of it that is on screen, since the
/// preview fills the view and crops the overflow — and thrown away. Nothing is
/// recorded and nothing leaves the device.
final class CameraFeed: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    let session = AVCaptureSession()

    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "dev.vaibhavkumar.simulationcam.capture")
    private var input: AVCaptureDeviceInput?
    private var configured = false

    private(set) var position: AVCaptureDevice.Position = .front

    /// Handed a fresh grid on the capture queue.
    var onGrid: (([UInt8]) -> Void)?

    /// Grid shape. Written from the main thread, read on the capture queue, so
    /// both go through `queue`.
    private var gridHeight = 24
    /// Only used when a connection refuses to mirror for us.
    private var mirrorInSoftware = false

    /// True on a phone, false on the average Mac: flipping only means anything
    /// when there is both a front and a back camera.
    static func canFlip() -> Bool {
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .unspecified).devices
        return devices.contains { $0.position == .front } && devices.contains { $0.position == .back }
    }

    static func camera(at position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
            ?? AVCaptureDevice.default(for: .video)
    }

    enum FeedError: LocalizedError {
        case noCamera
        case denied

        var errorDescription: String? {
            switch self {
            case .noCamera: return "no camera on this device"
            case .denied: return "permission refused — turn the camera back on in Settings"
            }
        }
    }

    // MARK: - Lifecycle

    func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    func start(position p: AVCaptureDevice.Position) throws {
        guard let device = Self.camera(at: p) else { throw FeedError.noCamera }
        position = device.position == .unspecified ? p : device.position

        session.beginConfiguration()
        if !configured {
            session.sessionPreset = .hd1280x720
            output.alwaysDiscardsLateVideoFrames = true
            output.videoSettings = Self.preferredVideoSettings()
            output.setSampleBufferDelegate(self, queue: queue)
            if session.canAddOutput(output) { session.addOutput(output) }
            configured = true
        }
        if let old = input { session.removeInput(old) }
        let fresh = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(fresh) else {
            session.commitConfiguration()
            throw FeedError.noCamera
        }
        session.addInput(fresh)
        input = fresh
        session.commitConfiguration()

        apply(orientation: orientation)
        // starting blocks for a moment, so it goes on the capture queue rather
        // than stalling the tap that asked for it
        queue.async { [session] in
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        queue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    func resume() {
        guard configured else { return }
        queue.async { [session] in
            if !session.isRunning { session.startRunning() }
        }
    }

    // MARK: - Orientation and mirroring

    private(set) var orientation: AVCaptureVideoOrientation = .portrait

    /// Sets the same orientation and mirroring on every video connection there
    /// is, the preview included, and tells the sampler what it can rely on.
    func apply(orientation o: AVCaptureVideoOrientation) {
        orientation = o
        let mirror = position == .front
        var dataConnectionMirrors = false
        for (connection, isDataOutput) in videoConnections() {
            // Only on the phone. A Mac camera already delivers frames the right
            // way up, and rotating them there would tip the picture over.
            #if os(iOS)
            if connection.isVideoOrientationSupported { connection.videoOrientation = o }
            #endif
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = mirror
                if isDataOutput { dataConnectionMirrors = true }
            }
        }
        let software = mirror && !dataConnectionMirrors
        queue.async { self.mirrorInSoftware = software }
    }

    /// The preview layer's connection joins the list once the layer exists.
    var previewConnection: AVCaptureConnection? {
        didSet { apply(orientation: orientation) }
    }

    private func videoConnections() -> [(AVCaptureConnection, Bool)] {
        var list: [(AVCaptureConnection, Bool)] = []
        if let data = output.connection(with: .video) { list.append((data, true)) }
        if let preview = previewConnection { list.append((preview, false)) }
        return list
    }

    func setGridHeight(_ h: Int) {
        queue.async { self.gridHeight = max(2, h) }
    }

    // MARK: - Frames

    /// On the phone, full-range biplanar: the luma plane is 0...255, which is
    /// exactly what the web build reads back off its canvas, and it comes for
    /// free. On the Mac, BGRA, which every camera there can be converted to;
    /// `grid` computes luminance from the pixels instead.
    private static func preferredVideoSettings() -> [String: Any] {
        #if os(iOS)
        let format = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        #else
        let format = kCVPixelFormatType_32BGRA
        #endif
        return [kCVPixelBufferPixelFormatTypeKey as String: format]
    }

    func captureOutput(_ out: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let gw = TrackerSim.gridWidth
        let gh = gridHeight
        guard let grid = Self.grid(from: buffer, width: gw, height: gh, mirrored: mirrorInSoftware)
        else { return }
        onGrid?(grid)
    }

    /// Box-averages the frame's luminance down to a `width` x `height` grid,
    /// over the centre crop the preview layer actually shows.
    static func grid(from buffer: CVPixelBuffer, width gw: Int, height gh: Int,
                     mirrored: Bool) -> [UInt8]? {
        guard gw > 1, gh > 1 else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        let planar = CVPixelBufferGetPlaneCount(buffer) > 0
        let base = planar ? CVPixelBufferGetBaseAddressOfPlane(buffer, 0)
                          : CVPixelBufferGetBaseAddress(buffer)
        guard let base else { return nil }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let vw = planar ? CVPixelBufferGetWidthOfPlane(buffer, 0) : CVPixelBufferGetWidth(buffer)
        let vh = planar ? CVPixelBufferGetHeightOfPlane(buffer, 0) : CVPixelBufferGetHeight(buffer)
        let rowBytes = planar ? CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
                              : CVPixelBufferGetBytesPerRow(buffer)
        guard vw > 1, vh > 1 else { return nil }
        // BGRA in memory order, so blue is first
        let pixelBytes = planar ? 1 : 4

        // cover crop: the preview fills the view and throws the overflow away,
        // so the grid has to cover the same rectangle and nothing more
        let viewAspect = Double(gw) / Double(gh)
        var cropW = Double(vw), cropH = Double(vh)
        if Double(vw) / Double(vh) > viewAspect {
            cropW = Double(vh) * viewAspect
        } else {
            cropH = Double(vw) / viewAspect
        }
        let x0 = (Double(vw) - cropW) / 2, y0 = (Double(vh) - cropH) / 2
        let cellW = cropW / Double(gw), cellH = cropH / Double(gh)
        // a few taps per cell, so downsampling behaves like the canvas the web
        // build reads back rather than a single noisy pixel
        let taps = max(1, min(3, Int(min(cellW, cellH))))
        let step = 1.0 / Double(taps)

        var grid = [UInt8](repeating: 0, count: gw * gh)
        grid.withUnsafeMutableBufferPointer { out in
            for gy in 0..<gh {
                for gx in 0..<gw {
                    let sx = mirrored ? gw - 1 - gx : gx
                    var sum = 0
                    for ty in 0..<taps {
                        let py = min(vh - 1, Int(y0 + (Double(gy) + (Double(ty) + 0.5) * step) * cellH))
                        let row = bytes + py * rowBytes
                        for tx in 0..<taps {
                            let px = min(vw - 1, Int(x0 + (Double(sx) + (Double(tx) + 0.5) * step) * cellW))
                            if planar {
                                sum += Int(row[px])
                            } else {
                                let p = row + px * pixelBytes
                                sum += (Int(p[2]) * 3 + Int(p[1]) * 4 + Int(p[0])) >> 3
                            }
                        }
                    }
                    out[gy * gw + gx] = UInt8(sum / (taps * taps))
                }
            }
        }
        return grid
    }
}
