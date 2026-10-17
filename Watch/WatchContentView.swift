import SwiftUI

struct WatchContentView: View {
    @EnvironmentObject private var model: WatchModel

    var body: some View {
        Group {
            if model.isConfigured {
                control
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "iphone")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text("Sign in on your iPhone")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .task { await model.refresh() }
    }

    private var control: some View {
        let level = model.displayLevel
        return VStack(spacing: 2) {
            Text(model.sideLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text(level.map(TemperatureFormat.levelText(raw:)) ?? "–")
                .font(.system(size: 54, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.snappy, value: level)
                .foregroundStyle(model.isOn ? .primary : .secondary)
                .minimumScaleFactor(0.6)
                .overlay(alignment: .trailing) { sendIndicator.frame(width: 12).offset(x: 16) }

            Text(subtitle(level))
                .font(.footnote)
                .foregroundStyle(.secondary)

            if let error = model.errorMessage {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }

            Spacer(minLength: 4)

            HStack(spacing: 14) {
                Button { model.tap(-1) } label: { Image(systemName: "minus") }
                    .buttonStyle(BigRoundButtonStyle(color: .blue))
                Button { model.tap(1) } label: { Image(systemName: "plus") }
                    .buttonStyle(BigRoundButtonStyle(color: .orange))
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
        return model.isOn ? f : "\(f) · Off"
    }

    @ViewBuilder
    private var sendIndicator: some View {
        switch model.sendState {
        case .sending: ProgressView().controlSize(.mini)
        case .sent: Image(systemName: "checkmark").font(.caption2.bold()).foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark").font(.caption2.bold()).foregroundStyle(.red)
        case .idle: Color.clear
        }
    }
}

private struct BigRoundButtonStyle: ButtonStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 26, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 62, height: 62)
            .background(color.gradient, in: Circle())
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}
