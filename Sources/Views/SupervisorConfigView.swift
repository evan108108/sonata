import SwiftUI

struct SupervisorConfigView: View {
    @StateObject private var vm = SupervisorConfigViewModel()

    // Editable state — committed on Save.
    @State private var enabled: Bool = true
    @State private var dayMinutes: Double = 3
    @State private var nightMinutes: Double = 30
    @State private var nightStart: Int = 22
    @State private var nightEnd: Int = 7
    @State private var saveStatus: SaveStatus = .idle

    enum SaveStatus: Equatable {
        case idle
        case saving
        case saved
        case failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Supervisor Schedule")
                    .font(.headline)
                Spacer()
                if let config = vm.config {
                    modeBadge(config.currentMode, intervalSec: config.currentIntervalSec)
                }
                Button {
                    Task { await vm.fetch() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh")
            }
            .padding(.horizontal)
            .padding(.vertical, 10)

            Divider()

            if vm.config == nil && vm.isLoading {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity)
                    .padding()
            } else {
                editForm
            }

            if let err = vm.error {
                Divider()
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
                    .padding(.vertical, 6)
            }
        }
        .task {
            await vm.fetch()
            if let c = vm.config {
                loadFromConfig(c)
            }
        }
        .onChange(of: vm.config) { _, newValue in
            if let c = newValue {
                loadFromConfig(c)
            }
        }
    }

    private var editForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Supervisor checks enabled", isOn: $enabled)
                .toggleStyle(.switch)

            HStack(alignment: .firstTextBaseline) {
                Text("Day interval")
                    .frame(width: 130, alignment: .leading)
                Stepper(value: $dayMinutes, in: 1...10, step: 1) {
                    Text("\(Int(dayMinutes)) min")
                        .font(.body.monospacedDigit())
                        .frame(width: 80, alignment: .leading)
                }
                .help("How often the supervisor is pinged during daytime hours")
                Spacer()
                Text(humanInterval(Int(dayMinutes) * 60))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .firstTextBaseline) {
                Text("Night interval")
                    .frame(width: 130, alignment: .leading)
                Stepper(value: $nightMinutes, in: 10...240, step: 5) {
                    Text("\(Int(nightMinutes)) min")
                        .font(.body.monospacedDigit())
                        .frame(width: 80, alignment: .leading)
                }
                .help("How often the supervisor is pinged during nighttime hours")
                Spacer()
                Text(humanInterval(Int(nightMinutes) * 60))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .firstTextBaseline) {
                Text("Night window")
                    .frame(width: 130, alignment: .leading)
                HStack(spacing: 6) {
                    Picker("", selection: $nightStart) {
                        ForEach(0..<24, id: \.self) { h in
                            Text(hourLabel(h)).tag(h)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 90)
                    Text("→")
                        .foregroundStyle(.secondary)
                    Picker("", selection: $nightEnd) {
                        ForEach(0..<24, id: \.self) { h in
                            Text(hourLabel(h)).tag(h)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 90)
                }
                Spacer()
                Text(nightWindowSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                if case .saved = saveStatus {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else if case .failed(let msg) = saveStatus {
                    Label(msg, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
                Spacer()
                Button("Save") {
                    Task { await save() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(vm.isSaving || !isDirty)
            }
        }
        .padding()
    }

    private func modeBadge(_ mode: String, intervalSec: Int) -> some View {
        let color: Color = {
            switch mode {
            case "night": return .indigo
            case "disabled": return .gray
            default: return .orange
            }
        }()
        let icon: String = {
            switch mode {
            case "night": return "moon.fill"
            case "disabled": return "pause.circle.fill"
            default: return "sun.max.fill"
            }
        }()
        return HStack(spacing: 4) {
            Image(systemName: icon)
            Text("\(mode.capitalized) · \(humanInterval(intervalSec))")
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.15), in: Capsule())
        .foregroundStyle(color)
    }

    private var isDirty: Bool {
        guard let c = vm.config else { return true }
        return enabled != c.enabled
            || Int(dayMinutes) * 60 != c.dayIntervalSec
            || Int(nightMinutes) * 60 != c.nightIntervalSec
            || nightStart != c.nightStartHour
            || nightEnd != c.nightEndHour
    }

    private var nightWindowSummary: String {
        if nightStart == nightEnd {
            return "no night window"
        }
        let wraps = nightStart > nightEnd
        let hours: Int
        if wraps {
            hours = (24 - nightStart) + nightEnd
        } else {
            hours = nightEnd - nightStart
        }
        return "\(hours) h \(wraps ? "(wraps midnight)" : "")"
    }

    private func loadFromConfig(_ c: SupervisorConfig) {
        enabled = c.enabled
        dayMinutes = max(1, Double(c.dayIntervalSec) / 60)
        nightMinutes = max(10, Double(c.nightIntervalSec) / 60)
        nightStart = c.nightStartHour
        nightEnd = c.nightEndHour
    }

    private func save() async {
        saveStatus = .saving
        let ok = await vm.save(
            dayIntervalSec: Int(dayMinutes) * 60,
            nightIntervalSec: Int(nightMinutes) * 60,
            nightStartHour: nightStart,
            nightEndHour: nightEnd,
            enabled: enabled
        )
        if ok {
            saveStatus = .saved
            Task {
                try? await Task.sleep(for: .seconds(2))
                if case .saved = saveStatus { saveStatus = .idle }
            }
        } else {
            saveStatus = .failed(vm.error ?? "Save failed")
        }
    }

    private func hourLabel(_ hour: Int) -> String {
        if hour == 0 { return "12 AM" }
        if hour == 12 { return "12 PM" }
        if hour < 12 { return "\(hour) AM" }
        return "\(hour - 12) PM"
    }

    private func humanInterval(_ sec: Int) -> String {
        if sec < 60 { return "\(sec)s" }
        let minutes = sec / 60
        if minutes < 60 { return "every \(minutes) min" }
        let hours = minutes / 60
        let remMin = minutes % 60
        if remMin == 0 { return "every \(hours) h" }
        return "every \(hours) h \(remMin) min"
    }
}
