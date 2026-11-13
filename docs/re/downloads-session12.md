# Downloads: session 12 capture facts

Arc 1.172.2 on the M1 built-in 2x display, 2026-11-12. These are filename probes with synthetic bytes and `application/octet-stream`, not content-type inference.

| Filename extension | Completed subtitle |
| --- | --- |
| zip | Zip Archive |
| dmg | Disk Image |
| png, jpg | Image |
| mp4 | Movie |
| mp3 | Audio |
| docx, csv, json, txt, no extension | Download |

Evidence: `.re/capture/s12/m1/arc/v4/10-kind-a/10-kind-a-rows.{png,ax.json}` and `v4/11-kind-b/11-kind-b-rows.{png,ax.json}`. More-menu words were not captured; these findings apply to subtitles only.

A truncated transfer shows **Failed to Download** by 30 seconds and at 60/90 seconds. Its row is absent after relaunch. Evidence: `.re/capture/s12/m1/arc/v9/34-failure-verified-90/failure-at-{5,30,60,90}.{png,ax.json}` and `v11/36-failure-relaunch/failed-after-relaunch.{png,ax.json}`. The attachment 404 had no visible row (`v9/35-404-verified/`).

The running mark is a down arrow inside a roughly 20 pt blue circle, centred approximately 34 pt from the window's left and 37 pt above its bottom. It overlaps the Library icon's top-right area. No filename text or separate dot appears at rest. At completion a roughly 32 pt file thumbnail replaces it. The blue is the same in both appearances (stored Color LCD screenshot dominant RGB #212AFB; not an sRGB measurement). Evidence: `.re/capture/s12/m1/arc/v10/43-chip-full-{light,dark}/`, and the native decoded crops in `s12-chip-decode/`.

Clicking the running mark opens Downloads in the same window. Evidence: `v12/44-chip-click/chip-click.{png,ax.json}`; its block retained exit 1 for a missed screenshot deadline and cleanup, while the frame and AX qualify this transition. Both appearances keep the completed thumbnail at least five seconds and through a Library visit: `v14/47-badge-{light,dark}/badge-{running,five-after,library,after-library}-*.{png,ax.json}`. The final dismissal time is not established; Open retains its existing 60-second expiry. The cancelled glyph and More-menu behavior were not captured in this session.
