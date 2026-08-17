import AVFoundation
import Combine
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Ties the camera to the scene, and is the only thing SwiftUI observes.
///
/// Nothing here is published per frame: the grid goes straight from the capture
/// queue to the scene, and SwiftUI only hears about the things on screen that
/// are not the overlay — the start card, the error, which camera is live.
final class CamController: ObservableObject {

    let scene = TrackerScene(size: CGSize(width: 390, height: 844))
    let feed = CameraFeed()

    @Published private(set) var live = false
    @Published private(set) var opening = false
    @Published private(set) var errorText: String?
    @Published private(set) var position: AVCaptureDevice.Position = .front
    /// Bumped on every switch, so the preview view re-reads its connection.
    @Published private(set) var generation = 0

    let canFlip = CameraFeed.canFlip()

    private var wasLive = false

    init() {
        scene.onResize = { [weak self] gridHeight in
            self?.feed.setGridHeight(gridHeight)
        }
        feed.onGrid = { [weak self] grid in
            DispatchQueue.main.async { self?.scene.ingest(grid: grid) }
        }
    }

    // MARK: - Opening the camera

    func open() {
        guard !live, !opening else { return }
        opening = true
        errorText = nil
        Task { [weak self] in
            guard let self else { return }
            let allowed = await self.feed.requestAccess()
            await MainActor.run {
                self.opening = false
                guard allowed else {
                    self.fail(CameraFeed.FeedError.denied)
                    return
                }
                do {
                    try self.feed.start(position: self.position)
                    self.feed.apply(orientation: Self.currentOrientation())
                    self.live = true
                    self.wasLive = true
                } catch {
                    self.fail(error)
                }
            }
        }
    }

    func flip() {
        guard live, canFlip else { return }
        let next: AVCaptureDevice.Position = position == .front ? .back : .front
        do {
            try feed.start(position: next)
            feed.apply(orientation: Self.currentOrientation())
            position = feed.position
            generation += 1
            scene.cameraSwitched()
        } catch {
            fail(error)
        }
    }

    private func fail(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        errorText = "CAMERA FAILED: " + message.uppercased()
        live = false
    }

    // MARK: - Coming and going

    func onAppear() {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(orientationChanged),
            name: UIDevice.orientationDidChangeNotification, object: nil)
        #endif
    }

    func onDisappear() {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = false
        NotificationCenter.default.removeObserver(
            self, name: UIDevice.orientationDidChangeNotification, object: nil)
        #endif
        feed.stop()
    }

    /// The camera has to be given up in the background and picked up again after.
    func setActive(_ active: Bool) {
        guard wasLive else { return }
        if active {
            feed.resume()
            feed.apply(orientation: Self.currentOrientation())
        } else {
            feed.stop()
        }
    }

    @objc private func orientationChanged() {
        guard live else { return }
        feed.apply(orientation: Self.currentOrientation())
    }

    /// `AVCaptureVideoOrientation`'s raw values line up with
    /// `UIInterfaceOrientation`'s, even though the two landscape cases are named
    /// the other way round. This is the mapping Apple's own camera samples use.
    static func currentOrientation() -> AVCaptureVideoOrientation {
        #if os(iOS)
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive } ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first
        if let raw = scene?.interfaceOrientation.rawValue,
           let orientation = AVCaptureVideoOrientation(rawValue: raw) {
            return orientation
        }
        return .portrait
        #else
        return .portrait
        #endif
    }
}
