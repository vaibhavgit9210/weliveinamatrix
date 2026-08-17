import AVFoundation
import SwiftUI

#if os(iOS)
import UIKit
typealias PlatformViewRepresentable = UIViewRepresentable
#elseif os(macOS)
import AppKit
typealias PlatformViewRepresentable = NSViewRepresentable
#endif

/// A view that is nothing but an `AVCaptureVideoPreviewLayer`, filling itself and
/// cropping the overflow — the same cover-crop the web build does by hand with
/// `drawImage`. The overlay is a transparent SpriteKit view sitting on top.
#if os(iOS)
final class PreviewHost: UIView {
    let preview = AVCaptureVideoPreviewLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        preview.videoGravity = .resizeAspectFill
        layer.addSublayer(preview)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        preview.frame = bounds
    }
}
#elseif os(macOS)
final class PreviewHost: NSView {
    let preview = AVCaptureVideoPreviewLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        preview.videoGravity = .resizeAspectFill
        layer?.addSublayer(preview)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        preview.frame = bounds
    }
}
#endif

struct CameraPreview: PlatformViewRepresentable {
    let feed: CameraFeed
    /// Bumped when the camera is switched, so the connection is handed over again.
    let generation: Int

    private func make() -> PreviewHost {
        let host = PreviewHost(frame: .zero)
        host.preview.session = feed.session
        feed.previewConnection = host.preview.connection
        return host
    }

    private func update(_ host: PreviewHost) {
        if host.preview.session !== feed.session { host.preview.session = feed.session }
        if feed.previewConnection !== host.preview.connection {
            feed.previewConnection = host.preview.connection
        }
    }

    #if os(iOS)
    func makeUIView(context: Context) -> PreviewHost { make() }
    func updateUIView(_ host: PreviewHost, context: Context) { update(host) }
    #elseif os(macOS)
    func makeNSView(context: Context) -> PreviewHost { make() }
    func updateNSView(_ host: PreviewHost, context: Context) { update(host) }
    #endif
}
