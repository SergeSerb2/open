# Display ICC identity after restart

The M5 restart on 2026-11-11 changed the AW2726DM ICC creation date. It did
not change its colour content. The display stayed at 2560×1440 points/pixels,
scale 1, 240 Hz. The gate now uses `icc-header-v1`: SHA-256 of the complete
profile with only bytes 24–35 (creation date) and 84–99 (profile ID) zeroed.
Offsets in this document are zero-based. No tag is excluded.

## Retained evidence

The capture helper retained the full ICC as `screens[0].iccBase64` in its
private metadata. Decoding these fields recovered the exact recorded profiles:

- M5: `.re/capture/s1-library/arc/02-library-sections/s1-library-closing-before.meta.json`,
  3,364 bytes, raw SHA-256
  `b1e0db75fbfcbecd866fb49106037ef7f806728e9a9f2f797d3deb8d4503fc43`.
- M1: `.re/capture/s1-library/m1/arc/13-light/s1-boosts-light-narrow.meta.json`,
  4,076 bytes, raw SHA-256
  `b33d3996c56e94d25097d38213687e26e0e8224ed0c215634a8c350ed44f6856`.
- M5 after restart: the installed AW2726DM ColorSync profile, copied without
  modification; 3,364 bytes, raw SHA-256
  `fc516285268a359fa7a22e8213839fc146a58ead5330af434323d824336b0885`.

The private byte/tag receipt and the three profiles are retained under
Step 4 `.re/icc-restart-20261111/`. The receipt is `byte-tag-diff.json`.
No extracted ICC or capture image is added to the repository.

## Byte and tag comparison

The creation date changed from 2026-11-05 16:41:26 to 2026-11-11 10:08:32.
These are the only changed bytes in the whole file:

| Offset | Before (decimal) | After (decimal) | Field |
|---:|---:|---:|---|
| 29 | 5 | 11 | Day |
| 31 | 16 | 10 | Hour |
| 33 | 41 | 8 | Minute |
| 35 | 26 | 32 | Second |

The profile ID, bytes 84–99, is zero in both files. All other header bytes,
the complete tag table and every tag payload match byte for byte. Parsing the
big-endian count at 128 and the 12-byte entries starting at 132 gives:

| Tags | Payload offset | Length | Result |
|---|---:|---:|---|
| `desc` | 336 | 98 | Identical |
| `dscm` | 436 | 512 | Identical |
| `cprt` | 948 | 35 | Identical |
| `wtpt` | 984 | 20 | Identical |
| `rXYZ` | 1004 | 20 | Identical |
| `gXYZ` | 1024 | 20 | Identical |
| `bXYZ` | 1044 | 20 | Identical |
| `rTRC`, `gTRC`, `bTRC` | 1064 | 2060 | Identical |
| `aarg`, `aabg`, `aagg` | 3124 | 32 | Identical |
| `vcgt` | 3156 | 48 | Identical |
| `ndin` | 3204 | 62 | Identical |
| `mmod` | 3268 | 40 | Identical |
| `vcgp` | 3308 | 56 | Identical |

The 17 entries include shared payloads. In particular, primaries, white point,
TRCs and `vcgt` are unchanged. No date or serial tag needs an exception.

## Exact key migration

`swift tools/verification/display-environment.swift --icc-digest FILE` reads
at most 4 MiB plus one refusal byte and computes both digests through the same
normalization used by the live display reader. The two native renderers use
the same two zeroed ranges and still check their actual host screen.

| Profile | `icc-header-v1` SHA-256 |
|---|---|
| M5 before and after | `f8e4893d0898030a891e0594ed435f2dd174c90d3ccad5d0d09f40db23b15d56` |
| M1 retained | `ced527b7482d75a039b583d3a6b856fb4e3f0c26010e4258ba770e17b142e844` |

Schema 3 names the scheme in every key and records each exact previous key
and both digests. Existing PNG bytes, hashes, colour limits, measured samples,
scales and modes are unchanged. The retained M1 asset directory keeps its old
name; that directory name has no role in display selection.

For a paired comparison with older main, the parent requires the exact
previous manifest entry and identical colour limits. The older baseline
renderer receives the live raw key and checks its actual screen. The candidate
receives the normalized key. Both digests and the mode are checked before and
after every pair. There is no unknown-key fallback or new reference recording.
