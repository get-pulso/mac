import SwiftUI

struct ProfileAboutField: View {
    // MARK: Internal

    @Binding var text: String
    var focusedField: FocusState<ProfileDraft.Field?>.Binding

    var body: some View {
        NativeFormRow("About") {
            TextField("What are you working on? What interests you?", text: $text, axis: .vertical)
                .lineLimit(4 ... 8)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.leading)
                .focused(focusedField, equals: .bio)
                .accessibilityLabel("About you")
                .nativeFormField(focused: focusedField.wrappedValue == .bio)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if overLimit {
                    NativeFormFieldError(
                        message: "Use \(ProfileDraft.bioLimit) characters or fewer. Your text hasn't been shortened."
                    )
                } else {
                    NativeFormHint(text: "A few sentences for people viewing your profile.")
                }
                Spacer(minLength: 0)
                Text("\(text.count) / \(ProfileDraft.bioLimit)")
                    .font(.caption).monospacedDigit()
                    .foregroundStyle(overLimit ? Color.red : Color.secondary)
                    .accessibilityLabel("\(text.count) of \(ProfileDraft.bioLimit) characters")
            }
        }
    }

    // MARK: Private

    private var overLimit: Bool { self.text.count > ProfileDraft.bioLimit }
}
