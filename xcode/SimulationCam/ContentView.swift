import SpriteKit
import SwiftUI

struct ContentView: View {
    @StateObject private var controller = CamController()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if controller.live {
                CameraPreview(feed: controller.feed, generation: controller.generation)
                    .ignoresSafeArea()

                SpriteView(scene: controller.scene,
                           preferredFramesPerSecond: 60,
                           options: [.allowsTransparency, .ignoresSiblingOrder,
                                     .shouldCullNonVisibleNodes])
                    .background(Color.clear)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                if controller.canFlip { flipButton }
            } else {
                startCard
            }
        }
        .background(Color.black)
        .onAppear { controller.onAppear() }
        .onDisappear { controller.onDisappear() }
        .onChange(of: scenePhase) { phase in controller.setActive(phase == .active) }
        #if os(iOS)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        #endif
    }

    // MARK: - The card that comes up first

    private var startCard: some View {
        VStack(spacing: 14) {
            Text("SIMULATION CAM")
                .font(.system(size: 15).width(.condensed))
                .tracking(5)
                .foregroundColor(.white.opacity(0.9))

            Text("OPENS YOUR CAMERA AND RENDERS THE TRACKING LAYER OF THE SIMULATION. NOTHING IS RECORDED OR SENT ANYWHERE.")
                .font(.system(size: 11).width(.condensed))
                .tracking(1.6)
                .lineSpacing(6)
                .multilineTextAlignment(.center)
                .foregroundColor(.white.opacity(0.45))
                .frame(maxWidth: 260)

            Button(action: controller.open) {
                Text(controller.opening ? "ASKING" : "OPEN CAMERA")
                    .font(.system(size: 12).width(.condensed))
                    .tracking(3.6)
                    .foregroundColor(.white)
                    .padding(.horizontal, 26)
                    .padding(.vertical, 10)
                    .overlay(Rectangle().stroke(Color.white.opacity(0.6), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(controller.opening)

            if let error = controller.errorText {
                Text(error)
                    .font(.system(size: 11).width(.condensed))
                    .tracking(1.1)
                    .lineSpacing(5)
                    .multilineTextAlignment(.center)
                    .foregroundColor(Color(red: 1, green: 0.4, blue: 0.4))
                    .frame(maxWidth: 280)
            }
        }
        .padding(24)
    }

    // MARK: - Front or back

    private var flipButton: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button(action: controller.flip) {
                    Image(systemName: "arrow.triangle.2.circlepath.camera")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundColor(.white.opacity(0.8))
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(Color.black.opacity(0.35)))
                        .overlay(Circle().stroke(Color.white.opacity(0.35), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(controller.position == .front
                                    ? "Switch to the back camera"
                                    : "Switch to the front camera")
                .padding(.trailing, 14)
                .padding(.bottom, 14)
            }
        }
    }
}
