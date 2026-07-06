import SwiftUI

// Settings → Workers → Tool Restrictions. Per-tool toggle that updates
// the workerToolDenials table. The runtime gate lives in
// MCPToolHandlers.checkToolDenial — toggles take effect on the next
// tool call without restart.
//
// IMPORTANT — banner copy is load-bearing. See plan
// mcp-unify-worker-surface.md § Surface alignment.

struct WorkerToolRestrictionsView: View {
    @StateObject private var vm = WorkerToolDenialsViewModel()
    @State private var didLoad = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Tool Restrictions")
                    .font(Theme.Typography.displayMedium)
                Spacer()
                if !vm.denials.isEmpty {
                    Text("\(vm.denials.count) denied")
                        .font(.caption.bold())
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.orange.opacity(0.18), in: Capsule())
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            // Load-bearing banner — DO NOT change without updating the plan.
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.shield")
                    .foregroundStyle(.yellow)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Not a security boundary")
                        .font(.subheadline.bold())
                    Text("These restrictions only apply to the HTTP MCP transport (`/mcp`). The REST endpoint (`/api/mcp/call`) is not gated; do not rely on this as a security boundary.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(10)
            .background(Color.yellow.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.yellow.opacity(0.25), lineWidth: 0.5))
            .padding(.horizontal)
            .padding(.top, 6)

            // Search
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter tools by name or description", text: $vm.search)
                    .textFieldStyle(.plain)
                if !vm.search.isEmpty {
                    Button {
                        vm.search = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal)
            .padding(.top, 8)

            if let err = vm.error {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
                    .padding(.top, 4)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(vm.filteredTools) { tool in
                        toolRow(tool)
                        Divider().padding(.leading)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(minHeight: 320)
        }
        .task {
            if !didLoad {
                didLoad = true
                await vm.fetchAll()
            }
        }
    }

    @ViewBuilder
    private func toolRow(_ tool: ToolDescriptor) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(tool.name)
                        .font(.body.monospaced())
                    if let roles = vm.deniedRolesText(tool.name) {
                        Text("denied for \(roles)")
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.orange.opacity(0.18), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                }
                if !tool.description.isEmpty {
                    Text(tool.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { vm.isDenied(tool.name) },
                set: { newValue in
                    Task { await vm.setDenied(tool: tool.name, denied: newValue) }
                }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}
