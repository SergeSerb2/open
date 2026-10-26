import Foundation
import Observation

public struct ProfileRowData: Identifiable, Sendable {
    public var id: ProfileID
    public var name: String
    public var icon: SpaceIcon?
    public var spaceCount: Int
    public var favoriteCount: Int
    public var isDefault: Bool
    public var deleteBlock: ProfileDeleteBlock?
    public var settings: ProfileSettings
}

/// Settings data only. The App refreshes after model changes and owns saving and disk wipes.
@MainActor @Observable
public final class ProfilesSettingsModel {
    public private(set) var rows: [ProfileRowData] = []
    public var pendingDiskWipe: (name: String, directoryName: String)?
    public static let diskWipeWarning = "Deleting Profile data is permanent. Cookies, history, logins, and extensions for this Profile will be removed. Undo can restore the sidebar Profile, but cannot restore its browsing data."
    @ObservationIgnored private var profiles: [Profile] = []

    public init() {}
    public convenience init(model: BrowserModel) { self.init(); refresh(from: model) }

    public func refresh(from model: BrowserModel) {
        profiles = model.profiles
        rows = model.profiles.map { profile in
            ProfileRowData(id: profile.id, name: profile.name, icon: profile.icon,
                spaceCount: model.spaces(using: profile.id).count, favoriteCount: profile.favorites.count,
                isDefault: profile.id == model.defaultProfile?.id, deleteBlock: model.deleteBlockReason(for: profile.id), settings: profile.settings)
        }
    }
    public func nameIssue(for name: String, excluding id: ProfileID? = nil) -> ProfileNameIssue? {
        BrowserModel.profileNameIssue(name, in: profiles, excluding: id)
    }
    @discardableResult
    public func createProfile(in model: BrowserModel, name: String, icon: SpaceIcon? = nil) -> Profile? {
        let profile = model.createProfile(name: name, icon: icon); refresh(from: model); return profile
    }
    @discardableResult
    public func renameProfile(in model: BrowserModel, id: ProfileID, to name: String) -> Bool {
        let changed = model.renameProfile(id: id, to: name); refresh(from: model); return changed
    }
    public func setIcon(in model: BrowserModel, id: ProfileID, icon: SpaceIcon?) {
        model.setProfileIcon(id: id, icon: icon); refresh(from: model)
    }
    public func updateSettings(in model: BrowserModel, id: ProfileID, settings: ProfileSettings) {
        model.updateProfileSettings(id: id, settings: settings); refresh(from: model)
    }
    @discardableResult
    public func deleteProfile(in model: BrowserModel, id: ProfileID) -> Bool {
        let deleted = model.deleteProfile(id: id); refresh(from: model); return deleted
    }
    public func indicator(for spaceID: SpaceID, in model: BrowserModel) -> (name: String, icon: SpaceIcon?)? {
        guard model.profiles.count > 1, let space = model.space(id: spaceID), let profile = model.profile(id: space.profileID) else { return nil }
        return (profile.name, profile.icon)
    }
}

public extension ProfileNameIssue {
    var message: String {
        switch self {
        case .empty: return "Enter a name."
        case .tooLong: return "Use 64 characters or fewer."
        case .invalidCharacters: return "That name cannot be used."
        case .duplicate: return "A Profile with that name already exists."
        }
    }
}

public extension ProfileDeleteBlock {
    var message: String {
        switch self {
        case .isDefault: return "The default Profile cannot be deleted."
        case .spacesAssigned(let count): return "Move or delete its Spaces first. This Profile is used by \(count) Space(s)."
        }
    }
}

public struct SpaceProfileChoice: Identifiable, Sendable {
    public var id: ProfileID
    public var name: String
    public var icon: SpaceIcon?
    public var isDefault: Bool
}

@MainActor
public func spaceProfileChoices(in model: BrowserModel) -> [SpaceProfileChoice] {
    model.profiles.map { SpaceProfileChoice(id: $0.id, name: $0.name, icon: $0.icon, isDefault: $0.id == model.defaultProfile?.id) }
}

/// Sheet-local state: creating a Profile is a mode, never a sentinel ProfileID.
@MainActor @Observable
public final class SpaceCreationProfilePickerModel {
    public private(set) var choices: [SpaceProfileChoice]
    public var selectedProfileID: ProfileID?
    public var isCreatingProfile = false
    public var newProfileName = ""
    public var newProfileIcon: SpaceIcon?
    public private(set) var nameIssue: ProfileNameIssue?

    public init(model: BrowserModel, windowID: WindowID? = nil) {
        choices = spaceProfileChoices(in: model)
        let window = windowID.map { id in model.windows.first { $0.id == id } } ?? model.windows.first
        selectedProfileID = window.flatMap { model.space(id: $0.focusedSpaceID) }.flatMap { model.profile(id: $0.profileID)?.id } ?? model.defaultProfile?.id
    }
    public func refresh(from model: BrowserModel) {
        choices = spaceProfileChoices(in: model)
        if !choices.contains(where: { $0.id == selectedProfileID }) { selectedProfileID = model.defaultProfile?.id }
    }
    @discardableResult
    public func createSpace(in model: BrowserModel, title: String, icon: SpaceIcon? = nil, theme: SpaceTheme = SpaceTheme()) -> Space? {
        let profileID: ProfileID
        if isCreatingProfile {
            nameIssue = BrowserModel.profileNameIssue(newProfileName, in: model.profiles)
            guard nameIssue == nil, let profile = model.createProfile(name: newProfileName, icon: newProfileIcon) else { return nil }
            profileID = profile.id; selectedProfileID = profileID
            isCreatingProfile = false; refresh(from: model)
        } else {
            guard let selectedProfileID, model.profile(id: selectedProfileID) != nil else { return nil }
            profileID = selectedProfileID
        }
        nameIssue = nil
        return model.createSpace(title: title, profileID: profileID, icon: icon, theme: theme)
    }
}

public struct ChangeProfileRequest: Sendable {
    public var spaceID: SpaceID
    public var spaceTitle: String
    public var fromProfileID: ProfileID
    public var toProfileID: ProfileID
    public var toProfileName: String
    public var warning: String
    public var dontShowAgainKey: String

    @MainActor
    public init?(spaceID: SpaceID, toProfile profileID: ProfileID, in model: BrowserModel) {
        guard let space = model.space(id: spaceID), let target = model.profile(id: profileID), space.profileID != profileID else { return nil }
        self.spaceID = space.id; spaceTitle = space.title; fromProfileID = space.profileID
        toProfileID = target.id; toProfileName = target.name
        warning = "Each Profile has different browser data, so you might get logged out or lose your progress in \(space.title). Its tabs will reopen with \(target.name) data."
        dontShowAgainKey = "open.profiles.confirmInterProfileMove"
    }

}
