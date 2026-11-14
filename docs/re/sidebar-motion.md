# Sidebar motion capture, session 14

The Cmd+S show uses an equivalent curve fitted to images from Arc1.172.2 on the M1. This is a fit to visible motion, not a claim about Arc's internal animation class or parameters.

Evidence: `.re/capture/s14/m1/arc/v8/analysis/020-sidebar/sidebar-show/{per-frame.csv,summary.json}` and `.re/handoff/plans/C-report-s14.md`, C14-2. The native2560x1600 movie and source sample counts agree. Seven intermediate samples per left marker give a show-duration bracket61.667–90.000ms. The top-marker equivalent Bezier fit has duration75.834ms, controls(0.01055,0.50742,0.55930,0.98516), RMS0.477pt. Bottom-marker RMS is0.416pt with nearby controls. Marker size stays36x36pt; inferred panel width changes by353pt. This supports moving and cropping native-size content rather than scaling its glyphs.

Open applies the top-marker fit to the show translation, crop and shadow. Hide retains the prior spring: its new onset bracket is381.666ms with only4–5 intermediate samples, so the new hide curve is unresolved. The hover-card and Space displacement/opacity fits are unresolved; those tokens retain their earlier evidence. Whole-movie rates38–71fps and large static gaps do not prove120Hz scanout. Required Open pacing proof uses the unchanged120Hz detector independently.
