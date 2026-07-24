import SwiftUI

struct SplashScreenView: View {
    @Binding var isFinished: Bool

    // Animation states
    @State private var logoScale: CGFloat = 1.0
    @State private var bgScale: CGFloat = 1.0
    @State private var logoOpacity: Double = 1.0
    @State private var bgOpacity: Double = 1.0
    @State private var phase: SplashPhase = .idle

    enum SplashPhase {
        case idle, expanding, done
    }

    var body: some View {
        ZStack {
            // Background that expands to cover the screen (the "burst" effect)
            Color(hex: "#1a1a2e")
                .scaleEffect(bgScale)
                .opacity(bgOpacity)
                .ignoresSafeArea()

            // Logo
            Image("logo")
                .resizable()
                .scaledToFit()
                .frame(width: 80, height: 80)
                .scaleEffect(logoScale)
                .opacity(logoOpacity)
        }
        .onAppear {
            startAnimation()
        }
    }

    private func startAnimation() {
        // Phase 1: Hold for a moment, then expand logo + bg
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            phase = .expanding

            // Logo scales up dramatically (like Twitter/X)
            withAnimation(.easeIn(duration: 0.35)) {
                logoScale = 35.0   // Logo grows huge to cover screen
                logoOpacity = 0.0
            }

            // Background simultaneously scales and fades out, revealing the app
            withAnimation(.easeIn(duration: 0.35).delay(0.25)) {
                bgOpacity = 0.0
                bgScale = 1.0
            }

            // Mark finished slightly after animation completes
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
                isFinished = true
            }
        }
    }
}
