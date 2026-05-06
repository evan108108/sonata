import SwiftUI

// FocusedValue used by SonataApp's Cmd-K command to focus the global search bar.
struct FocusSearchBarKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var focusSearchBar: (() -> Void)? {
        get { self[FocusSearchBarKey.self] }
        set { self[FocusSearchBarKey.self] = newValue }
    }
}

struct SearchBar: View {
    @ObservedObject var vm: SearchViewModel
    var focusBinding: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 13))

            TextField("Search Sona…", text: $vm.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused(focusBinding)
                .onChange(of: vm.query) { _, _ in
                    vm.clamp()
                }
                .onSubmit {
                    vm.submit()
                }
                .onExitCommand {
                    if vm.isShowingResults {
                        vm.dismiss()
                    } else {
                        focusBinding.wrappedValue = false
                    }
                }

            if !vm.query.isEmpty {
                Button {
                    vm.clear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}
