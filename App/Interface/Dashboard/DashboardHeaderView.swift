import SwiftUI

struct DashboardHeaderView: View {
    @Binding var groups: [UserGroup]
    @Binding var selectedGroup: String?
    @Binding var timeFilter: TimeFilter

    let onSettings: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    GroupPickerButton(
                        label: "All Friends",
                        isSelected: self.selectedGroup == nil,
                        action: { self.selectedGroup = nil }
                    )
                    ForEach(Array(self.groups.enumerated()), id: \ .element.id) { _, group in
                        GroupPickerButton(
                            label: group.name,
                            isSelected: self.selectedGroup == group.id,
                            action: { self.selectedGroup = group.id }
                        )
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .frame(height: 44)

            Divider()
                .padding(.vertical, 8)

            // Custom Time filter picker
            TimeFilterPicker(selection: self.$timeFilter)
                .padding(.horizontal, 8)

            Divider()
                .padding(.vertical, 8)

            Button(action: self.onSettings) {
                Image(systemName: "gearshape")
                    .imageScale(.medium)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
        }
        .frame(height: 44)

        Divider()
    }
}

private struct GroupPickerButton: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: self.action) {
            ZStack {
                // Reserve space for bold font
                Text(self.label)
                    .font(.system(size: 11, weight: .semibold))
                    .opacity(0)
                Text(self.label)
                    .font(.system(size: 11, weight: self.isSelected ? .semibold : .regular))
                    .foregroundColor(self.isSelected ? .white : .primary)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(self.isSelected ? Color.accentColor : Color.clear)
            .cornerRadius(8)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

private struct TimeFilterPicker: View {
    // MARK: Internal

    @Binding var selection: TimeFilter

    var body: some View {
        Button(action: {
            let currentIndex = self.filters.firstIndex(of: self.selection) ?? 0
            let nextIndex = (currentIndex + 1) % self.filters.count
            // Set direction: if going forward (24h -> 7d), slide up; if backward (7d -> 24h), slide down
            self.transitionEdge = nextIndex > currentIndex ? .top : .bottom
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                self.selection = self.filters[nextIndex]
            }
        }) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.accentColor.opacity(0.13))
                    .frame(width: 44, height: 22)
                Text(self.selection.rawValue)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(.accentColor)
                    .id(self.selection)
                    .transition(.asymmetric(
                        insertion: .move(edge: self.transitionEdge).combined(with: .opacity),
                        removal: .move(edge: self.transitionEdge == .top ? .bottom : .top).combined(with: .opacity)
                    ))
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: self.selection)
            }
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel("Time Filter")
    }

    // MARK: Private

    @State private var transitionEdge: Edge = .top

    private let filters: [TimeFilter] = [.last24h, .last7d]
}
