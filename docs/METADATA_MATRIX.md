# Metadata Support Matrix

Generated from `embed_metadata.py` field mapping. Tested combinations in `Tests/MetadataEmbeddingTests.swift`.

## Output Format Support

| Field | FLAC | MP3 (ID3v2) | M4A/AAC/MP4 | WAV | AIFF | OGG | Opus |
|-------|------|-------------|-------------|-----|------|-----|------|
| title | ✅ | ✅ TIT2 | ✅ ©nam | ✅ | ✅ | ✅ | ✅ |
| artist | ✅ | ✅ TPE1 | ✅ ©ART | ✅ | ✅ | ✅ | ✅ |
| album | ✅ | ✅ TALB | ✅ ©alb | ✅ | ✅ | ✅ | ✅ |
| album artist | ✅ ALBUMARTIST | ✅ TPE2 | ✅ ©aART | ❌ | ❌ | ❌ | ❌ |
| year | ✅ DATE | ✅ TDRC (ID3v2.4) | ✅ ©day | ✅ | ✅ | ✅ | ✅ |
| genre | ✅ GENRE | ✅ TCON | ✅ ©gen | ✅ | ✅ | ✅ | ✅ |
| track number | ✅ TRACKNUMBER | ✅ TRCK | ✅ trkn[n] | ❌ | ❌ | ❌ | ❌ |
| total tracks | ✅ TOTALTRACKS | ❌ | ✅ trkn[1] | ❌ | ❌ | ❌ | ❌ |
| disc number | ✅ DISCNUMBER | ✅ TPOS | ❌ | ❌ | ❌ | ❌ | ❌ |
| composer | ✅ COMPOSER | ❌ | ✅ ©wrt | ❌ | ❌ | ❌ | ❌ |
| comment | ✅ COMMENT | ✅ COMM | ✅ ©cmt | ✅ | ✅ | ✅ | ✅ |
| cover art | ✅ (Vorbis Picture) | ✅ (APIC) | ✅ covr atom | ❌ | ❌ | ❌ | ❌ |

## Implementation Notes

### FLAC (Vorbis comments via mutagen)
- `DATE` is the canonical year field; `YEAR` is set to the same value for compatibility only.
- `ALBUMARTIST` is set independently of `ARTIST` — when a CUE provides a PERFORMER different from the track performer, both are written.
- Cover art: embedded as Vorbis Picture block (type 3, "Cover (front)").

### MP3 (ID3v2 via mutagen)
- `TIT2` / `TPE1` / `TALB` / `TDRC` / `TCON` / `TRCK` for the standard fields.
- `TPOS` for disc number (not part of TRCK; TRCK carries only track number).
- `COMM` for comment; `TPE2` for album artist / composer.
- Cover art: `APIC` frame with MIME type `image/jpeg`.
- No native support for TOTALTRACKS in ID3v2 — `TRCK` carries `track/total` in some implementations but is not universally supported.

### M4A / AAC / MP4 (iTunes-style atoms via mutagen)
- `©nam / ©ART / ©alb / ©day / ©gen` for the standard fields.
- `trkn` carries a tuple `(track, total)` as a single atom value.
- `©aART` for album artist; `©wrt` for composer.
- `covr` atom carries cover art as JPEG or PNG data.
- **No disc number atom** in the standard iTunes tag set.

### WAV (ffmpeg `-metadata`)
- Metadata written via `ffmpeg -metadata key=value -codec copy`. No re-encoding.
- WAV does not support embedded cover art — attempts are silently skipped with `SKIP:` output.
- Track number and disc number are not supported by the WAV INFO chunk specification.

### AIFF / ALAC
- Same implementation as WAV — ffmpeg `-metadata` passthrough. No cover art.

### OGG / Opus
- Same fallback as AIFF/ALAC — ffmpeg `-metadata` passthrough. Cover art via ffmpeg `-attach` is not currently implemented; unsupported formats fall through to `embed_ffmpeg`.

## Fallback Strategy

1. **Format-specific**: FLAC → mutagen FLAC; MP3 → mutagen ID3; M4A → mutagen MP4; WAV → ffmpeg.
2. **Generic fallback**: any unrecognized extension falls through to `embed_ffmpeg` (ffmpeg `-codec copy -metadata …`).
3. Fallback covers: AIFF, ALAC, OGG, Opus, and any container ffmpeg can handle.
4. Cover art in fallback: **not supported**; silently skipped with `SKIP:` line.

## Known Limitations

- **MP3 TOTALTRACKS**: not representable in ID3v2 without using the `TRCK` frame's slash syntax (`TRCK=3/12`), which is inconsistently supported across players. Track number alone is written.
- **M4A disc number**: no standard iTunes atom exists; this field cannot be written without extending to a non-standard atom.
- **WAV / AIFF / OGG / Opus**: no cover art support in the current implementation.
