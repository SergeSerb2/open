# Capture in Portrait Mode

Arc 1.170.0 reference binary and the shared `ArcMain` Ghidra project; capture session 9 on Arc 1.172.2
(`.re/capture/s9-queue/m1/arc/v2/43-pb2-probe/p-1-portrait*`, C-report-s6 §8). Raw output: `.re/portrait/`.

| Kind | Finding | Evidence |
|---|---|---|
| FACT | File ▸ Capture in Portrait Mode (and the Site Control and URL-field items) opens a popover of 286 × 246 pt. It points at the page from the sidebar side. Esc closes it. | Capture `p-1-portrait`, `p-2-esc`; AX `AXPopover` frame. |
| FACT | Content, top to bottom: a full-width button "Capture in Portrait Mode" (240.75 × 32.75 at 22.6, 22.6); a preview 239 × 127 at (23.5, 63.5) with the page as a card (111 × 96) on a diagonal gradient and a 32 pt tile at its bottom-left; a row with a 17 pt round swatch at (26.5, 202.5), a colour slider with a round knob, and a 17 pt swatch at (242.5, 202.5). | AX frames of `p-1-portrait-ax`. |
| FACT | The SwiftUI types are `ContentPanel.WindowScreenshotViewModel`, `WindowScreenshotPopoverContent`, `WindowScreenshotColorSlider`, `CircularSelectionButton`, `WindowScreenshotWatermarkToggle`, `WindowScreenshotPreviewImage`. | `strings -a` (reflection names). |
| FACT | Accessibility strings of the controls: "Portrait Capture Watermark Toggle" (assets `window-screenshot-watermark-on` / `-off`), "Use Website Color" ("Portrait Capture Website Tint Button"), "Use Desktop Wallpaper" ("Portrait Capture Desktop Wallpaper Button"). | `strings -a`, ContentPanel strings. |
| FACT | Settings keys: `portraitCaptureBackground`, `portraitCaptureColorPercentage`, `portraitCaptureHidesWatermark`. | `strings -a`. |
| FACT | The menu action `capturePrettyScreenshot:` (`Arc.MainWindowController`, `0x10031e1ec`) only sends a store action (`FUN_10031e1f8`). | Ghidra; `__objc_methlist`. |
| OPEN QUESTION | What the popover's button produces. Strings next to the capture code: "Screenshot Copied to Clipboard" ("Letting user know the screenshot has been copied") and "Button title to save the screenshot copied to a file." suggest a clipboard copy with a Save button in a toast. The output pixel size and any save folder were not found. A capture that presses the button settles it (not done: it may ask for folder access). | `strings -a`. |
| GUESS | The stored type of `portraitCaptureBackground` (Open's import maps a string by its words), Arc's defaults, the gradient's mix amounts, the output's proportions (Open uses the preview's), the selected-swatch ring. | Capture pending. |

## Open
- The popover is AppKit (`PortraitCaptureView`) in the measured layout. The watermark is Open's own doorway-and-sun mark.
- The button runs Open's existing capture flow: the result card with Copy, Save…, Share and Library (LEAD ruling, PB2-questions "EZ 19:40").
- Backgrounds: the colour slider (Open's own rainbow stops), the website colour (the page's top strip), or the desktop
  wallpaper. The wallpaper file is read only when the user picks that swatch (`NSWorkspace.desktopImageURL(for:)`);
  a failed read uses the website colour and logs it, with no alert. Automation builds never read the real wallpaper.
- Keys: `open.capture.portraitBackground` (`color`, `website`, `wallpaper`), `open.capture.portraitColorPercentage`,
  `open.capture.portraitHidesWatermark`. Import from Arc maps Arc's three keys.
