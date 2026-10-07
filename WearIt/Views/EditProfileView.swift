import SwiftUI
import SwiftData

/// "Edit profile": name, @username and bio (the public part, once sharing exists) plus
/// private details (email, phone, birthday). Edits stay local until Save, so typing
/// doesn't trigger a CloudKit push per keystroke.
struct EditProfileView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let profile: UserProfile

    @State private var name = ""
    @State private var username = ""
    @State private var bio = ""
    @State private var email = ""
    @State private var phone = ""
    @State private var hasBirthday = false
    @State private var birthday = Calendar.current.date(byAdding: .year, value: -25, to: Date()) ?? Date()
    @State private var didLoad = false

    private var normalizedUsername: String { UsernameRules.normalize(username) }
    private var usernameProblem: String? { UsernameRules.problem(with: normalizedUsername) }
    private var emailProblem: String? {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: "@")
        let looksValid = parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".") && !trimmed.contains(" ")
        return looksValid ? nil : String(localized: "edit_profile_email_error")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(String(localized: "profile_display_name_placeholder"), text: $name)
                        .textContentType(.name)
                        .textInputAutocapitalization(.words)

                    HStack(spacing: 2) {
                        Text("@")
                            .foregroundStyle(.secondary)
                        TextField(String(localized: "edit_profile_username_placeholder"), text: $username)
                            .textContentType(.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.asciiCapable)
                    }
                    .environment(\.layoutDirection, .leftToRight)

                    if let usernameProblem {
                        Text(usernameProblem)
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else if username.isEmpty, let suggestion = UsernameRules.suggestion(from: name) {
                        Button {
                            username = suggestion
                        } label: {
                            Text(String(format: String(localized: "edit_profile_username_suggestion_format"), suggestion))
                                .font(.caption)
                        }
                    }

                    TextField(String(localized: "profile_bio_placeholder"), text: $bio, axis: .vertical)
                        .lineLimit(1...4)
                } header: {
                    Text(String(localized: "edit_profile_public_section"))
                } footer: {
                    Text(String(localized: "edit_profile_public_footer"))
                }

                Section {
                    TextField(String(localized: "edit_profile_email_placeholder"), text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if let emailProblem {
                        Text(emailProblem)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    TextField(String(localized: "edit_profile_phone_placeholder"), text: $phone)
                        .textContentType(.telephoneNumber)
                        .keyboardType(.phonePad)

                    Toggle(String(localized: "edit_profile_birthday_toggle"), isOn: $hasBirthday.animation())
                    if hasBirthday {
                        DatePicker(
                            String(localized: "edit_profile_birthday"),
                            selection: $birthday,
                            in: ...Date(),
                            displayedComponents: .date
                        )
                    }
                } header: {
                    Text(String(localized: "edit_profile_private_section"))
                } footer: {
                    Text(String(localized: "edit_profile_private_footer"))
                }
            }
            .navigationTitle(String(localized: "edit_profile_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "action_cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "action_save")) { save() }
                        .disabled(usernameProblem != nil || emailProblem != nil)
                }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        let defaultNames: Set<String> = ["", "Me", String(localized: "profile_default_name")]
        name = defaultNames.contains(profile.displayName) ? "" : profile.displayName
        username = profile.username ?? ""
        bio = profile.bio ?? ""
        email = profile.email ?? ""
        phone = profile.phone ?? ""
        if let saved = profile.birthday {
            hasBirthday = true
            birthday = saved
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.displayName = trimmedName.isEmpty ? String(localized: "profile_default_name") : trimmedName
        profile.username = normalizedUsername.isEmpty ? nil : normalizedUsername
        profile.bio = nilIfEmpty(bio)
        profile.email = nilIfEmpty(email)
        profile.phone = nilIfEmpty(phone)
        profile.birthday = hasBirthday ? Calendar.current.startOfDay(for: birthday) : nil
        try? context.save()
        DS.haptic(0.4)
        dismiss()
    }

    private func nilIfEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
