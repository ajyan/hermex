import SwiftUI

/// Settings › Agent › Active Profile: switches the server's active profile.
/// Rows and states match the old sidebar disclosure it replaces.
struct ActiveProfilePickerView: View {
    let viewModel: SessionListViewModel
    let onSwitch: (ProfileSummary) -> Void

    var body: some View {
        List {
            if viewModel.isLoadingActiveProfile && viewModel.profileOptions.isEmpty {
                CompactStatusRow(title: String(localized: "Loading profiles..."), systemImage: "person.crop.circle")
            } else if viewModel.profileOptions.isEmpty {
                CompactStatusRow(
                    title: viewModel.activeProfileErrorMessage == nil
                        ? String(localized: "No profiles")
                        : String(localized: "Could not load profiles"),
                    systemImage: "exclamationmark.triangle"
                )
            } else {
                ForEach(viewModel.profileOptions) { profile in
                    let profileIsActive = isActive(profile)
                    ActiveProfilePickerRow(
                        profile: profile,
                        isSelected: profileIsActive,
                        isSwitching: viewModel.isSwitchingActiveProfile
                            && viewModel.switchingActiveProfileName == profile.normalizedName
                    ) {
                        guard !profileIsActive else { return }
                        onSwitch(profile)
                    }
                    .disabled(
                        viewModel.isViewingCachedData
                            || viewModel.isSwitchingActiveProfile
                            || profile.normalizedName == nil
                    )
                }
            }
        }
        .navigationTitle("Active Profile")
        .task { await viewModel.loadActiveProfile() }
    }

    private func isActive(_ profile: ProfileSummary) -> Bool {
        guard let profileName = profile.normalizedName else { return false }
        if let activeProfileName = viewModel.activeProfileName {
            return profileName == activeProfileName
        }
        return profile.isActive == true
    }
}
