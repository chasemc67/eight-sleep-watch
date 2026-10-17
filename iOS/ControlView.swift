import SwiftUI

struct ControlView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    sidePicker
                    levelCard
                    if let error = model.errorMessage {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }
                    Text("Unofficial — uses Eight Sleep's private cloud API.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                }
                .padding()
            }
            .refreshable { await model.loadAll() }
            .navigationTitle("Bed Temperature")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Sign out") { Task { await model.signOut() } }
                }
            }
            .overlay {
                if model.isBusy && model.status == nil { ProgressView() }
            }
        }
    }

    @ViewBuilder
    private var sidePicker: some View {
        if !model.sides.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Your side").font(.headline)
                Picker("Your side", selection: Binding(
                    get: { model.selectedSide ?? model.sides[0].id },
                    set: { model.select($0) }
                )) {
                    ForEach(model.sides) { option in
                        Text(option.pickerLabel).tag(option.id)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
    }

    private var levelCard: some View {
        let level = model.displayLevel
        let isOn = model.status?.isOn ?? false
        return VStack(spacing: 12) {
            HStack(spacing: 6) {
                Circle().fill(isOn ? Color.green : Color.secondary).frame(width: 8, height: 8)
                Text(model.status == nil ? "—" : (isOn ? "On" : "Off"))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                if model.isSending { ProgressView().controlSize(.mini) }
            }

            Text(level.map(TemperatureFormat.levelText(raw:)) ?? "–")
                .font(.system(size: 104, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.snappy, value: level)
                .foregroundStyle(isOn ? .primary : .secondary)

            if let level {
                Text(TemperatureFormat.fahrenheitText(raw: level))
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            if let actual = model.status?.currentDeviceLevel {
                Text("Bed is at \(TemperatureFormat.levelText(raw: actual)) now")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 40) {
                RoundButton(systemImage: "minus", color: .blue) { model.step(-1) }
                    .disabled(level == nil || level! <= TemperatureFormat.rawRange.lowerBound)
                RoundButton(systemImage: "plus", color: .orange) { model.step(1) }
                    .disabled(level == nil || level! >= TemperatureFormat.rawRange.upperBound)
            }
            .padding(.top, 8)

            Toggle("Power", isOn: Binding(
                get: { isOn },
                set: { on in Task { await model.setPower(on) } }
            ))
            .disabled(model.status == nil)
            .padding(.top, 8)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }
}

private struct RoundButton: View {
    let systemImage: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button {
            UISelectionFeedbackGenerator().selectionChanged()
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 80, height: 80)
                .background(color.gradient, in: Circle())
        }
        .buttonStyle(.plain)
    }
}
