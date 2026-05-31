import SwiftUI

struct WebviewSessionConfigView: View {
    @StateObject private var vm = WebviewSessionConfigViewModel()
    @State private var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            field("Idle → suspend", value: $vm.idleSuspendSec, range: 30...7200, step: 30, suffix: "sec")
            field("Idle → hard close", value: $vm.hardCloseSec, range: 60...86400, step: 60, suffix: "sec")
            field("Max live sessions", value: $vm.maxLiveSessions, range: 1...64, step: 1, suffix: "live")
            Divider()
            HStack {
                if saved { Label("Saved", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green) }
                if let e = vm.error { Label(e, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red).lineLimit(1) }
                Spacer()
                Button("Save") { Task { saved = await vm.save() } }
                    .buttonStyle(.borderedProminent).disabled(vm.isSaving)
            }
        }
        .padding()
        .task { await vm.fetch() }
    }

    @ViewBuilder private func field(_ label: String, value: Binding<Int>, range: ClosedRange<Int>, step: Int, suffix: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).frame(width: 150, alignment: .leading)
            Stepper(value: value, in: range, step: step) {
                Text("\(value.wrappedValue) \(suffix)").font(.body.monospacedDigit()).frame(width: 110, alignment: .leading)
            }
            Spacer()
        }
    }
}
