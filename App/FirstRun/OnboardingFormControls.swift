import AppKit
import OpenDesign
import OpenModel
import OpenOnboarding
import OpenSpaceEditor

/// Form-only treatments. The real editor still owns knob input and theme math.
@MainActor final class OnboardingNameField: NSTextField {
  override init(frame: NSRect) {
    super.init(frame: frame)
    cell = OnboardingNameCell(); isBordered = false; drawsBackground = false; focusRingType = .none
    wantsLayer = true
  }
  required init?(coder: NSCoder) { nil }
  override func draw(_ dirtyRect: NSRect) {
    let rect = bounds.insetBy(dx: 0.5,dy: 0.5)
    let path = NSBezierPath(roundedRect: rect,xRadius: 10,yRadius: 10)
    NSColor.controlBackgroundColor.setFill(); path.fill()
    NSColor.separatorColor.setStroke(); path.lineWidth = 1; path.stroke()
    super.draw(dirtyRect)
    if currentEditor() != nil {
      OnboardingTokens.Room.space.withAlphaComponent(0.35).setStroke()
      let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5,dy: 1.5),xRadius: 9,yRadius: 9)
      ring.lineWidth = 3; ring.stroke()
    }
  }
  override func becomeFirstResponder() -> Bool { let result = super.becomeFirstResponder(); needsDisplay = true; return result }
  override func textDidEndEditing(_ notification: Notification) { super.textDidEndEditing(notification); needsDisplay = true }
}
@MainActor private final class OnboardingNameCell: NSTextFieldCell {
  override func drawingRect(forBounds rect: NSRect) -> NSRect {
    let height = min(22,rect.height)
    return NSRect(x: rect.minX+12,y: rect.midY-height/2,width: max(0,rect.width-24),height: height)
  }
}

@MainActor final class OnboardingFormCard: OnboardingSurface {
  override func draw(_ dirtyRect: NSRect) {
    let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5,dy: 0.5),xRadius: 12,yRadius: 12)
    NSColor.controlBackgroundColor.setFill(); path.fill()
    NSColor.separatorColor.setStroke(); path.lineWidth = 1; path.stroke()
  }
  override func layout() {
    super.layout()
    for child in subviews {
      if child is OnboardingAccentSwitch { child.frame.origin.x = bounds.width-68 }
      else { child.frame.size.width = max(0,bounds.width-32-(child.frame.minY < 44 ? 60:0)) }
    }
  }
  override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

/// AppKit owns switch input, keyboard handling and the AXSwitch value. The
/// bezel is drawn here because NSSwitch has no public accent-color override.
@MainActor final class OnboardingAccentSwitch: NSButton {
  override init(frame: NSRect) {
    super.init(frame: frame)
    setButtonType(.switch); title = ""; isBordered = false
    setAccessibilityRole(.checkBox); setAccessibilitySubrole(.switch)
  }
  required init?(coder: NSCoder) { nil }
  override var state: NSControl.StateValue { didSet { needsDisplay = true } }
  override func draw(_ dirtyRect: NSRect) {
    let track = NSRect(x: bounds.midX-20,y: bounds.midY-11,width: 40,height: 22)
    let outline = NSBezierPath(roundedRect: track,xRadius: 11,yRadius: 11)
    (state == .on ? OnboardingTokens.Room.space:NSColor.quaternaryLabelColor).withAlphaComponent(isEnabled ? 1:0.4).setFill()
    outline.fill()
    let knob = NSRect(x: state == .on ? track.maxX-20:track.minX+2,y: track.minY+2,width: 18,height: 18)
    NSColor.white.withAlphaComponent(isEnabled ? 1:0.6).setFill(); NSBezierPath(ovalIn: knob).fill()
    if window?.firstResponder === self { NSFocusRingPlacement.only.set(); outline.fill() }
  }
  override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

@MainActor final class OnboardingChoiceRadio: NSButton {
  override func draw(_ dirtyRect: NSRect) {
    let circle = NSRect(x: 16,y: bounds.midY-8,width: 16,height: 16)
    let ring = NSBezierPath(ovalIn: circle)
    (state == .on ? OnboardingTokens.Room.space:NSColor.tertiaryLabelColor).setStroke(); ring.lineWidth = 1.5; ring.stroke()
    if state == .on { OnboardingTokens.Room.space.setFill(); NSBezierPath(ovalIn: circle.insetBy(dx: 4,dy: 4)).fill() }
    (title as NSString).draw(in: NSRect(x: 44,y: bounds.midY-9,width: bounds.width-60,height: 20),withAttributes: [.font:NSFont.systemFont(ofSize: 13),.foregroundColor:NSColor.labelColor])
    if window?.firstResponder === self { NSFocusRingPlacement.only.set(); NSBezierPath(roundedRect: bounds.insetBy(dx: 2,dy: 2),xRadius: 11,yRadius: 11).fill() }
  }
}

@MainActor final class OnboardingPresetStrip: OnboardingSurface {
  var onAction: (@MainActor (ThemeEditorAction) -> Void)?
  private var page = 0
  private let swatches: [OnboardingSwatch]
  private let previous: NSButton
  private let next: NSButton
  override init(frame: NSRect) {
    swatches = SpaceStylePresets.all.enumerated().map { OnboardingSwatch(index: $0.offset,preset: $0.element) }
    previous = NSButton(title: "Previous color presets",target: nil,action: nil)
    next = NSButton(title: "Next color presets",target: nil,action: nil)
    super.init(frame: frame)
    // Target/actions keep the two page buttons in AppKit's normal key loop.
    for (button,symbol,tag) in [(previous,"chevron.left",-1),(next,"chevron.right",1)] {
      button.image = NSImage(systemSymbolName: symbol,accessibilityDescription: button.title); button.imagePosition = .imageOnly
      button.setAccessibilityElement(true); button.setAccessibilityRole(.button); button.setAccessibilityLabel(button.title)
      button.isBordered = false; button.target = self; button.action = #selector(changePage(_:)); button.tag = tag; addSubview(button)
    }
    for swatch in swatches { swatch.target = self; swatch.action = #selector(selectColor(_:)); addSubview(swatch) }
  }
  convenience init() { self.init(frame: .zero) }
  required init?(coder: NSCoder) { nil }
  @objc private func changePage(_ sender: NSButton) { onAction?(.setPresetPage(page+sender.tag)) }
  @objc private func selectColor(_ sender: NSButton) { onAction?(.selectPreset(index: sender.tag)) }
  func apply(_ state: ThemeEditorState) {
    page = state.presetPage; previous.isEnabled = page > 0; next.isEnabled = page < 4
    for swatch in swatches {
      swatch.isHidden = swatch.tag/9 != page
      swatch.selected = state.style.map { $0.keyColor == SpaceStylePresets.all[swatch.tag].style.keyColor } ?? false
    }
    needsLayout = true
  }
  override func layout() {
    super.layout(); previous.frame = NSRect(x: 0,y: 2,width: 28,height: 28)
    next.frame = NSRect(x: bounds.width-28,y: 2,width: 28,height: 28)
    let origin = floor((bounds.width-252)/2)
    for swatch in swatches { swatch.frame = NSRect(x: origin+CGFloat(swatch.tag%9)*28,y: 2,width: 28,height: 28) }
  }
}
@MainActor private final class OnboardingSwatch: NSButton {
  let colors: [NSColor]
  var selected = false { didSet { needsDisplay = true } }
  init(index: Int,preset: SpaceStylePreset) {
    colors = ThemeColorMath.harmony(key: ThemeColorMath.toP3(preset.style.keyColor),count: preset.style.colorCount,wheel: preset.style.wheel).map { NSColor(displayP3Red: $0.r,green: $0.g,blue: $0.b,alpha: 1) }
    super.init(frame: .zero); tag = index; isBordered = false; title = ""; setButtonType(.momentaryPushIn)
    setAccessibilityElement(true); setAccessibilityRole(.button)
    setAccessibilityLabel("Set Space color to \(preset.name)"); toolTip = preset.name
  }
  required init?(coder: NSCoder) { nil }
  override var acceptsFirstResponder: Bool { true }
  override func draw(_ dirtyRect: NSRect) {
    NSGraphicsContext.saveGraphicsState()
    let disc = bounds.insetBy(dx: 4,dy: 4); NSBezierPath(ovalIn: disc).addClip()
    NSGradient(colors: colors.count > 1 ? colors:[colors[0],colors[0]])?.draw(in: disc,angle: 35)
    NSGraphicsContext.restoreGraphicsState()
    if selected {
      OnboardingTokens.Room.space.setStroke(); let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1,dy: 1)); ring.lineWidth = 2; ring.stroke()
    }
    if window?.firstResponder === self { NSFocusRingPlacement.only.set(); NSBezierPath(ovalIn: bounds).fill() }
  }
}

@MainActor final class OnboardingColorField: OnboardingSurface {
  let pad = OpenSpaceEditor.ColorPadView(frame: .zero)
  private let field = CALayer()
  private var fieldKey: [Double] = []
  override init(frame: NSRect) {
    super.init(frame: frame); wantsLayer = true
    pad.ringLayer = field; pad.layer?.cornerRadius = 12; pad.layer?.masksToBounds = true
    addSubview(pad)
  }
  convenience init() { self.init(frame: .zero) }
  required init?(coder: NSCoder) { nil }
  override func layout() {
    super.layout(); pad.frame = bounds
    CATransaction.begin(); CATransaction.setDisableActions(true); field.frame = pad.bounds; CATransaction.commit()
    pad.layer?.borderWidth = 1; pad.layer?.borderColor = NSColor.separatorColor.cgColor
  }
  func apply(_ state: ThemeEditorState) {
    let key = [state.range.lowerBound,state.range.upperBound,state.saturation,Double(bounds.width),Double(bounds.height)]
    guard key != fieldKey,bounds.width > 0,bounds.height > 0 else { return }; fieldKey = key
    // Fixed 400 × 280 P3 tile: at most 448,000 decoded bytes, generated only
    // while the first-run Theme form is visible. The knob uses the same law.
    let width = 400,height = 280
    var bytes = [UInt8](repeating: 0,count: width*height*4)
    for y in 0..<height { for x in 0..<width {
      let point = CGPoint(x: (Double(x)/Double(width)*bounds.width-bounds.midX)/pad.style.radius,
                          y: (Double(y)/Double(height)*bounds.height-bounds.midY)/pad.style.radius)
      let c = ThemeColorMath.color(at: point,saturation: state.saturation,range: state.range)
      let i = (y*width+x)*4
      bytes[i] = UInt8((c.r*255).rounded()); bytes[i+1] = UInt8((c.g*255).rounded()); bytes[i+2] = UInt8((c.b*255).rounded()); bytes[i+3] = 255
    }}
    guard let provider = CGDataProvider(data: Data(bytes) as CFData),let image = CGImage(width: width,height: height,bitsPerComponent: 8,bitsPerPixel: 32,bytesPerRow: width*4,space: CGColorSpace(name: CGColorSpace.displayP3)!,bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),provider: provider,decode: nil,shouldInterpolate: true,intent: .defaultIntent) else { return }
    CATransaction.begin(); CATransaction.setDisableActions(true); field.contents = image; CATransaction.commit()
  }
}
