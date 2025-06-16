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

            // Time filter picker
            Picker("", selection: self.$timeFilter) {
                Text("24h")
                    .tag(TimeFilter.last24h)
                Text("7d")
                    .tag(TimeFilter.last7d)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 70)
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
