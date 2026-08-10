import SwiftUI

struct ControlView: View {
    @ObservedObject var c: Controller

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.02, green: 0.02, blue: 0.05),
                                    Color(red: 0.08, green: 0.03, blue: 0.11)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 18) {
                holeIcon
                    .padding(.top, 8)

                Text("SINGULARITY")
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .tracking(5)
                    .foregroundStyle(.white.opacity(0.92))

                VStack(spacing: 5) {
                    HStack {
                        Text("APPETITE")
                        Spacer()
                        Text(String(format: "%.2f×", c.intensity))
                    }
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.orange)

                    Slider(value: $c.intensity, in: 0.25...4)
                        .tint(.orange)

                    HStack {
                        Text("gentle nibble")
                        Spacer()
                        Text("ravenous")
                    }
                    .font(.system(size: 9))
                    .foregroundStyle(.gray)
                }

                HStack(spacing: 10) {
                    Button(action: { c.start() }) {
                        Label(c.isRunning ? "Feeding…" : "Unleash",
                              systemImage: "circle.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(c.isRunning)

                    Button(action: { c.reset() }) {
                        Label("Reset", systemImage: "arrow.counterclockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!c.isRunning)
                }
                .controlSize(.large)

                Text(c.status)
                    .font(.system(size: 10))
                    .foregroundStyle(.gray)
                    .multilineTextAlignment(.center)
                    .frame(height: 28)

                Spacer(minLength: 0)
            }
            .padding(20)
        }
        .frame(width: 300, height: 340)
        .preferredColorScheme(.dark)
    }

    private var holeIcon: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [.orange.opacity(0.75), .clear],
                                     center: .center, startRadius: 15, endRadius: 34))
                .frame(width: 68, height: 68)
            Circle()
                .fill(.black)
                .frame(width: 32, height: 32)
                .overlay(Circle().stroke(Color.orange.opacity(0.9), lineWidth: 1.5))
                .shadow(color: .orange.opacity(0.8), radius: 9)
        }
    }
}
