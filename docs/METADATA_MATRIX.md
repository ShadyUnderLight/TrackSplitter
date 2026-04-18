# Metadata Support Matrix

This document describes the **actual implemented behavior** of `Library/Resources/embed_metadata.py`
and the Swift `embedBatch` API in `Library/MetadataEmbedder.swift`.

Tested combinations are in `Tests/MetadataEmbeddingTests.swift`.

---

## Output Format Support

| Field | FLAC | MP3 (ID3v2) | M4A/AAC/MP4 | WAV | AIFF | OGG | Opus |
|-------|------|-------------|-------------|-----|------|-----|------|
| title | ✅ | ✅ | ✅ ©nam | ✅ | ✅ | ✅ | ✅ |
| artist | ✅ | ✅ | ✅ ©ART | ✅ | ✅ | ✅ | ✅ |
| album | ✅ | ✅ | ✅ ©alb | ✅ | ✅ | ✅ | ✅ |
| year | ✅ DATE | ✅ TDRC | ✅ ©day | ✅ | ✅ | ✅ | ✅ |
| genre | ✅ | ✅ TCON | ✅ ©gen | ✅ | ✅ | ✅ | ✅ |
| track number | ✅ TRACKNUMBER | ✅ TRCK | ✅ trkn | ❌ | ❌ | ❌ | ❌ |
| total tracks | ✅ TOTALTRACKS | ❌ | ✅ trkn | ❌ | ❌ | ❌ | ❌ |
| disc number | ✅ DISCNUMBER | ✅ TPOS | ❌ | ❌ | ❌ | ❌ | ❌ |
| composer | ✅ COMPOSER | ✅ TCOM | ✅ ©wrt | ❌ | ✅ | ✅ | ✅ |
| comment | ✅ COMMENT | ✅ COMM | ✅ ©cmt | ❌ | ✅ | ✅ | ✅ |
| cover art | ✅ | ✅ APIC | ✅ covr | ❌ | ❌ | ❌ | ❌ |

**Legend:**
- ✅ = implemented in Python layer (`embed_metadata.py`)
- ❌ = not supported
- Numbers in parentheses (`TRCK`) = actual ID3v2 frame / Vorbis key used

---

## Swift API Coverage

The Swift `embedBatch(…)` method in `MetadataEmbedder.swift` currently exposes:

```
files: [(url: URL, title: String, trackNumber: Int)]
artist: String
album: String
year: String
genre: String
comment: String?
composer: String?
discNumber: String?
totalTracks: Int
coverData: Data?
```

The following fields are **implemented in Python** but **not yet reachable** through the Swift API:

| Field | Python support | Swift API reachable |
|-------|--------------|-------------------|
| album artist (`ALBUMARTIST` / `TPE2` / `©aART`) | ✅ | ❌ not plumbed |
| TOTALTRACKS (MP3) | ❌ not representable in ID3v2 | n/a |

---

## Implementation Notes

### FLAC — mutagen Vorbis comments
- `DATE` is the only year field written. `YEAR` is **not written** (confirmed by `testEmbedFLAC_duplicateYearNotWritten`).
- `ALBUMARTIST` is present in the Python implementation but is never passed from Swift — the CUE parser does not distinguish track-level from album-level performer.

### MP3 — mutagen ID3v2
- `TIT2 / TPE1 / TALB / TDRC / TCON / TRCK / TPOS / TCOM / COMM` via frame class instances (required by mutagen ≥ 1.47).
- `COMM` frame key serializes as `COMM::eng` (language suffix is part of the key).
- TOTALTRACKS has no standard ID3v2 representation; only `TRCK` is written.

### M4A — mutagen iTunes atoms
- `©nam / ©ART / ©alb / ©day / ©gen / ©wrt / ©cmt` as free-form text atoms.
- `trkn` carries `(track, total)` as a tuple; mutagen serializes it as `(N, M)` string.
- `©aART` (album artist) is present in Python but not passed from Swift.
- **No disc number atom** exists in the iTunes tag schema.

### AIFF — mutagen ID3 chunk
- Uses `AIFF(fpath)` + `add_tags()` + ID3 frame classes — not ffmpeg.
- No cover art (mutagen AIFF + APIC combination is unreliable across players; silently skipped with `SKIP:`).

### OGG / Opus — mutagen Vorbis comments
- `OggVorbis` / `OggOpus` used directly with `_set_vorbis` helper.
- No cover art (OGG/Vorbis embedded pictures are format-dependent and not universally readable; silently skipped with `SKIP:`).

### WAV — ffmpeg `-metadata`
- `ffmpeg -codec copy -metadata key=value` only; no re-encoding.
- Cover art not supported by the WAV INFO chunk spec; silently skipped with `SKIP:`.

---

## Format Coverage in Tests

| Format | End-to-end test | Notes |
|--------|----------------|-------|
| FLAC | ✅ `testEmbedFLAC_allFields`, `testEmbedFLAC_duplicateYearNotWritten` | Full field validation |
| MP3 | ✅ `testEmbedMP3_allFields`, `testEmbedMP3_discNumberWrittenAsTPOS` | Full field validation |
| M4A | ✅ `testEmbedM4A_allFields` | Full field validation |
| AIFF | ❌ | Implementation exists; no E2E test yet |
| OGG | ❌ | Implementation exists; no E2E test yet |
| Opus | ❌ | Implementation exists; no E2E test yet |
| WAV | ❌ | No E2E test yet |

---

## Known Limitations

- **MP3 TOTALTRACKS**: not representable in ID3v2. `TRCK` carries only the track number.
- **M4A disc number**: no standard iTunes atom exists in the schema.
- **Album artist**: implemented in Python (`ALBUMARTIST`/`TPE2`/`©aART`) but the Swift `embedBatch` API does not currently accept or forward this field from CUE data.
- **WAV / AIFF / OGG / Opus**: cover art is not supported and is silently skipped.
- **AIFF / OGG / Opus**: have explicit mutagen implementations but lack end-to-end test coverage.
