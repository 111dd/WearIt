import SwiftUI

/// The privacy policy, in the app's languages. The same text lives in `docs/privacy-policy.md`
/// for the App Store's privacy policy URL; keep both in sync.
struct PrivacyPolicyView: View {
    private let sections: [(title: String, body: String)] = [
        (String(localized: "privacy_section_summary_title"), String(localized: "privacy_section_summary_body")),
        (String(localized: "privacy_section_stored_title"), String(localized: "privacy_section_stored_body")),
        (String(localized: "privacy_section_leaves_title"), String(localized: "privacy_section_leaves_body")),
        (String(localized: "privacy_section_permissions_title"), String(localized: "privacy_section_permissions_body")),
        (String(localized: "privacy_section_signin_title"), String(localized: "privacy_section_signin_body")),
        (String(localized: "privacy_section_choices_title"), String(localized: "privacy_section_choices_body")),
        (String(localized: "privacy_section_children_title"), String(localized: "privacy_section_children_body"))
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                Text(String(localized: "privacy_effective_date"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(sections.indices, id: \.self) { index in
                    VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                        Text(sections[index].title)
                            .font(.headline)
                        Text(sections[index].body)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .dsCard()
                }
            }
            .padding(.horizontal, DS.Spacing.md)
            .padding(.vertical, DS.Spacing.sm)
        }
        .scrollContentBackground(.hidden)
        .navigationTitle(String(localized: "privacy_title"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
