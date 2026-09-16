import SwiftUI

struct ProfileAboutField: View {
    // MARK: Internal

    @Binding var text: String
    var focusedField: FocusState<ProfileDraft.Field?>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("About you").fontWeight(.medium)
                Spacer()
                Text("\(text.count) / \(ProfileDraft.bioLimit)")
                    .font(.caption).monospacedDigit()
                    .foregroundStyle(overLimit ? Color.red : Color.secondary)
                    .accessibilityLabel("\(text.count) of \(ProfileDraft.bioLimit) characters")
            }
            TextField("What are you working on? What interests you?", text: $text, axis: .vertical)
                .lineLimit(4 ... 8)
                .multilineTextAlignment(.leading)
                .textFieldStyle(.roundedBorder)
                .focused(focusedField, equals: .bio)
                .accessibilityLabel("About you")
            if overLimit {
                Label(
                    "Use \(ProfileDraft.bioLimit) characters or fewer. Your text hasn't been shortened.",
                    systemImage: "exclamationmark.circle"
                )
                .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("A few sentences for people viewing your profile.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Private

    private var overLimit: Bool { self.text.count > ProfileDraft.bioLimit }
}
