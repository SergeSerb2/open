import AppKit
import OpenDesign
import OpenModel

public struct SpaceCreationOptions: Sendable {
    public var insertionIndex: Int?
    public var moving: [ItemID]
    public var prefillTitle: String?
    public var placement: BrowserModel.SpaceCreationPlacement
    public var removingEmptyFolder: ItemID?
    public init(insertionIndex: Int? = nil, moving: [ItemID] = [], prefillTitle: String? = nil,
                placement: BrowserModel.SpaceCreationPlacement = .preserveSection, removingEmptyFolder: ItemID? = nil) {
        self.insertionIndex = insertionIndex; self.moving = moving; self.prefillTitle = prefillTitle
        self.placement = placement; self.removingEmptyFolder = removingEmptyFolder
    }
}

@MainActor
public final class SpaceCreationController {
    public let creationView = SpaceCreationView(frame: .zero)
    public var view: NSView { creationView }
    public let localUndoManager = UndoManager()
    public let profilePicker: SpaceCreationProfilePickerModel
    public let options: SpaceCreationOptions
    public private(set) var draftStyle: SpaceStyle?
    public private(set) var draftIcon: SpaceIcon?
    public private(set) var themeEditor: ThemeEditorController?
    public private(set) var isFinished = false
    public var onFinish: (@MainActor (Space?) -> Void)?
    public var onDraftStyle: (@MainActor (SpaceThemeStyle) -> Void)?
    /// The window owns the shared picker; picks edit only this local draft.
    public var onPickIcon: (@MainActor (SpaceIcon?, CGRect, @escaping @MainActor (SpaceIcon?) -> Void) -> Void)?
    private let model: BrowserModel
    private let windowID: WindowID

    public init(model: BrowserModel, windowID: WindowID, options: SpaceCreationOptions) {
        self.model = model; self.windowID = windowID; self.options = options
        profilePicker = SpaceCreationProfilePickerModel(model: model, windowID: windowID)
        // Draft edits outlive AppKit's field-editing sessions. TextKit keeps its
        // normal per-field typing history and falls back to this draft stack.
        localUndoManager.groupsByEvent = false
        creationView.localUndoManager = localUndoManager
        creationView.nameField.stringValue = options.prefillTitle ?? ""
        creationView.onCreate = { [weak self] in self?.submit() }
        creationView.onCancel = { [weak self] in self?.cancel() }
        creationView.onTheme = { [weak self] in self?.openThemeEditor() }
        creationView.onIcon = { [weak self] in
            guard let self else { return }
            self.onPickIcon?(self.draftIcon, self.creationView.iconButton.convert(self.creationView.iconButton.bounds, to: nil)) { [weak self] icon in self?.setDraftIcon(icon) }
        }
        creationView.onProfile = { [weak self] index in
            guard let self else { return }
            if self.profilePicker.choices.indices.contains(index) {
                self.profilePicker.selectedProfileID = self.profilePicker.choices[index].id
            } else { self.profilePicker.isCreatingProfile = true }
            self.refreshProfiles()
            if self.profilePicker.isCreatingProfile { self.view.window?.makeFirstResponder(self.creationView.profileNameField) }
        }
        refreshProfiles()
    }
    public func focus() { creationView.focusName(); creationView.animateEntrance() }
    public func setDraftStyle(_ style: SpaceStyle?) {
        guard !isFinished else { return }
        draftStyle = style; updatePreview()
    }
    public func setDraftIcon(_ icon: SpaceIcon?) {
        guard !isFinished, draftIcon != icon else { return }
        creationView.breakTextUndoCoalescing()
        let old = draftIcon
        localUndoManager.beginUndoGrouping()
        localUndoManager.registerUndo(withTarget: self) { target in MainActor.assumeIsolated { target.setDraftIcon(old) } }
        localUndoManager.endUndoGrouping()
        draftIcon = icon; updatePreview()
    }
    public func updatePreview() {
        creationView.apply(theme: SpaceTheme(style: draftStyle), icon: draftIcon)
        onDraftStyle?(creationView.style)
    }
    private func refreshProfiles(issue: String? = nil) {
        profilePicker.refresh(from: model)
        creationView.setProfiles(profilePicker.choices, selected: profilePicker.selectedProfileID,
                                 creating: profilePicker.isCreatingProfile, issue: issue)
    }
    public func openThemeEditor() {
        guard !isFinished, let window = view.window else { return }
        creationView.breakTextUndoCoalescing()
        if let themeEditor, !themeEditor.isClosed { themeEditor.show(); return }
        let editor = ThemeEditorController(draft: draftStyle, window: window,
            anchor: .card(creationView.themeButton.convert(creationView.themeButton.bounds, to: nil))) { [weak self] in self?.setDraftStyle($0) }
        themeEditor = editor
        editor.onClose = { [weak self] in self?.themeEditor = nil }
        editor.show()
    }
    public func cancel() {
        guard !isFinished else { return }
        themeEditor?.close(); themeEditor = nil; isFinished = true
        localUndoManager.removeAllActions(); onFinish?(nil)
    }
    public func submit() {
        guard !isFinished,
              model.canCreateSpace(at: options.insertionIndex, moving: options.moving, removingEmptyFolder: options.removingEmptyFolder),
              model.windows.contains(where: { $0.id == windowID }) else { return }
        themeEditor?.close(); themeEditor = nil
        let picker = profilePicker
        if picker.isCreatingProfile {
            picker.newProfileName = creationView.profileNameField.stringValue
            if let issue = BrowserModel.profileNameIssue(picker.newProfileName, in: model.profiles) {
                refreshProfiles(issue: issue.message); return
            }
        } else if picker.selectedProfileID.flatMap({ model.profile(id: $0) }) == nil { refreshProfiles(); return }
        let undo = model.undoManager
        let actionName: String = "New Space"
        // The model opens a group only after the failable transaction succeeds.
        // Name that group while it is open; creating an outer group here would
        // leave an empty Undo step on refusal. Never name a closed group.
        let namingObserver = undo.map { manager in
            NotificationCenter.default.addObserver(forName: .NSUndoManagerDidOpenUndoGroup,
                object: manager, queue: nil) { _ in
                MainActor.assumeIsolated {
                    if manager.groupingLevel > 0 { manager.setActionName(actionName) }
                }
            }
        }
        defer { if let namingObserver { NotificationCenter.default.removeObserver(namingObserver) } }
        // The model creates an inline Profile and Space as one atomic command.
        guard let profileID = picker.selectedProfileID, let space = model.createSpace(title: creationView.nameField.stringValue, profileID: profileID,
            icon: draftIcon, theme: SpaceTheme(style: draftStyle), at: options.insertionIndex, moving: options.moving,
            placement: options.placement, removingEmptyFolder: options.removingEmptyFolder,
            creatingProfileNamed: picker.isCreatingProfile ? picker.newProfileName : nil) else {
            return
        }
        // A caller may already have an open event group, so no open-group
        // notification was needed. A missing name is a harness FAIL, not a trap.
        if let undo, undo.groupingLevel > 0 { undo.setActionName(actionName) }
        isFinished = true; localUndoManager.removeAllActions()
        undo?.disableUndoRegistration(); model.focusSpace(windowID: windowID, spaceID: space.id); undo?.enableUndoRegistration()
        splash { [weak self] in self?.onFinish?(space) }
    }
    private func splash(completion: @escaping @MainActor () -> Void) {
        guard view.window?.isVisible == true, let host = view.layer else { completion(); return }
        let circle = CAShapeLayer()
        let button = creationView.createButton.convert(creationView.createButton.bounds, to: view)
        let radius = hypot(view.bounds.width, view.bounds.height)
        circle.path = CGPath(ellipseIn: CGRect(x: -radius, y: -radius, width: 2 * radius, height: 2 * radius), transform: nil)
        circle.position = CGPoint(x: button.midX, y: button.midY)
        if let style = draftStyle {
            let color = ThemeColorMath.toExtendedSRGB(ThemeColorMath.primaryPalette(key: ThemeColorMath.toP3(style.keyColor)).midTone)
            circle.fillColor = RGBA(color.red, color.green, color.blue, color.alpha, .extendedSRGB).cgColor
        } else { circle.fillColor = creationView.style.titleColor(creationView.systemAppearance).withAlpha(0.2).cgColor }
        host.addSublayer(circle)
        let reduced = Motion.reducesMotion, duration = reduced ? 0.2 : 0.5
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 1; fade.toValue = 0
        fade.beginTime = reduced ? 0 : 0.3; fade.duration = 0.2; fade.fillMode = .backwards
        let group = CAAnimationGroup(); group.duration = duration; group.animations = [fade]
        if !reduced {
            let grow = CABasicAnimation(keyPath: "transform.scale"); grow.fromValue = 0; grow.toValue = 1; grow.duration = duration
            grow.timingFunction = CAMediaTimingFunction(name: .easeOut); group.animations?.append(grow)
        }
        CATransaction.begin(); CATransaction.setCompletionBlock { MainActor.assumeIsolated { circle.removeFromSuperlayer(); completion() } }
        circle.opacity = 0; circle.add(group, forKey: "creation-splash"); CATransaction.commit()
    }
}
