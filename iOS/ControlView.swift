import SwiftUI

struct ControlView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Which side is yours?").font(.title2.bold())
                        Text("Choose the side your phone and watch control.")
                            .foregroundStyle(Theme.muted)
                    }
                    HStack(spacing: 12) {
                        ForEach(model.sides) { option in sideCard(option) }
                    }
                    levelControl
                    if let error = model.errorMessage {
                        Text(error).font(.footnote).foregroundStyle(Theme.warm)
                    }
                    Text("Unofficial — uses Eight Sleep’s private cloud API.")
                        .font(.caption).foregroundStyle(Theme.muted)
                }
                .padding(20)
            }
            .background(Theme.background)
            .refreshable { await model.loadAll(force: true) }
            .navigationTitle("Eight Sleep Remote")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.background, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { Task { await model.loadAll(force: true) } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Refresh")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Sign out") { Task { await model.signOut() } }
                }
            }
            .overlay {
                if model.isBusy && model.status == nil { ProgressView() }
            }
        }
        .tint(.white)
        .foregroundStyle(.white)
    }

    private func sideCard(_ option: AppModel.SideOption) -> some View {
        let selected = model.selectedSide == option.id
        return Button { model.select(option.id) } label: {
            VStack(alignment: .leading, spacing: 14) {
                Text(option.id.title.uppercased()).font(.caption.bold()).tracking(2)
                    .foregroundStyle(selected ? Theme.cool : Theme.muted)
                Text(option.firstName ?? "\(option.id.title) side")
                    .font(.title3.bold()).lineLimit(1).minimumScaleFactor(0.7)
                Label("Yours", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.cool)
                    .opacity(selected ? 1 : 0)
            }
            .frame(maxWidth: .infinity, minHeight: 125, alignment: .leading)
            .padding(16)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(selected ? Theme.cool : .white.opacity(0.06), lineWidth: selected ? 2 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.pickerLabel)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var levelControl: some View {
        let level = model.displayLevel
        let state = model.status?.isOn
        return VStack(alignment: .leading, spacing: 12) {
            Text(model.selectedOption?.watchLabel ?? "Your bed")
                .foregroundStyle(Theme.muted)
            HStack(alignment: .center, spacing: 16) {
                Text(level.map(TemperatureFormat.levelText(raw:)) ?? "–")
                    .font(.system(size: 92, weight: .bold, design: .rounded))
                    .monospacedDigit().foregroundStyle(Theme.levelColor(level))
                    .contentTransition(.numericText()).animation(.snappy, value: level)
                if model.isSending { ProgressView().accessibilityLabel("Sending") }
            }
            HStack(spacing: 8) {
                Text(state.map { $0 ? "On" : "Off" } ?? "State unknown")
                if let level { Text("·  \(TemperatureFormat.fahrenheitText(raw: level))") }
            }
            .font(.title3).foregroundStyle(Theme.muted)
            HStack(spacing: 28) {
                RoundButton(symbol: "minus", color: Theme.cool) { model.step(-1) }
                    .disabled(level == nil || level == -100)
                RoundButton(symbol: "plus", color: Theme.warm) { model.step(1) }
                    .disabled(level == nil || level == 100)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 12)
            Toggle("Power", isOn: Binding(get: { state == true }, set: { on in
                Task { await model.setPower(on) }
            }))
            .tint(Theme.cool)
            .disabled(state == nil || model.isSending || model.pendingLevel != nil)
        }
    }
}

private struct RoundButton: View {
    let symbol: String
    let color: Color
    let action: () -> Void
    var body: some View {
        Button {
            UISelectionFeedbackGenerator().selectionChanged()
            action()
        } label: {
            Image(systemName: symbol).font(.system(size: 32, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 86, height: 86)
                .background(color.opacity(0.2), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(symbol == "minus" ? "Cooler" : "Warmer")
    }
}
