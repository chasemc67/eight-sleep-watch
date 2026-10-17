import SwiftUI

struct WatchContentView: View {
    @EnvironmentObject private var model: WatchModel

    var body: some View {
        Group {
            if model.isConfigured {
                control
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "iphone")
                        .font(.title)
                        .foregroundStyle(Theme.cool)
                    Text("Set up on iPhone")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                    Text("Sign in and choose your side in Eight Sleep Remote.")
                        .font(.footnote)
                        .foregroundStyle(Theme.muted)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 4)
        .containerBackground(Theme.background, for: .navigation)
        .background(Theme.background.ignoresSafeArea())
        .task { await model.refresh() }
    }

    private var control: some View {
        let level = model.displayLevel
        return VStack(spacing: 6) {
            Text(model.sideLabel)
                .font(.caption2)
                .foregroundStyle(Theme.muted)
                .lineLimit(1)

            Text(level.map(TemperatureFormat.levelText(raw:)) ?? "–")
                .font(.system(size: 52, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.snappy, value: level)
                .foregroundStyle(Theme.levelColor(level))
                .minimumScaleFactor(0.6)
                .overlay(alignment: .trailing) { sendIndicator.frame(width: 12).offset(x: 16) }

            Text(subtitle(level))
                .font(.footnote)
                .foregroundStyle(Theme.muted)

            if let error = model.errorMessage {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.warm)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }

            Spacer(minLength: 2)

            HStack(spacing: 14) {
                Button { model.tap(-1) } label: { Image(systemName: "minus") }
                    .buttonStyle(BigRoundButtonStyle(color: Theme.cool))
                    .accessibilityLabel("Cooler")
                Button { model.tap(1) } label: { Image(systemName: "plus") }
                    .buttonStyle(BigRoundButtonStyle(color: Theme.warm))
                    .accessibilityLabel("Warmer")
            }
            .disabled(level == nil)
        }
        .padding(.horizontal, 4)
        .focusable()
        .digitalCrownRotation($model.crownValue, from: -10, through: 10, by: 1,
                              sensitivity: .low, isContinuous: false, isHapticFeedbackEnabled: true)
        .onChange(of: model.crownValue) { _, value in model.crownChanged(to: value) }
    }

    private func subtitle(_ level: Int?) -> String {
        guard let level else { return " " }
        let f = TemperatureFormat.fahrenheitText(raw: level)
        return model.isOn == false ? "\(f) · Off" : f
    }

    @ViewBuilder
    private var sendIndicator: some View {
        switch model.sendState {
        case .sending: ProgressView().controlSize(.mini)
        case .sent: Image(systemName: "checkmark").font(.caption2.bold()).foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark").font(.caption2.bold()).foregroundStyle(Theme.warm)
        case .idle: Color.clear
        }
    }
}

private struct BigRoundButtonStyle: ButtonStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 26, weight: .bold))
            .foregroundStyle(color)
            .frame(width: 62, height: 62)
            .background(color.opacity(0.2), in: Circle())
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}
