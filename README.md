# TrackSplitter

> Split FLAC+CUE albums into individual tracks — with metadata and album art.

## What it does

1. Reads a `.flac` file and its companion `.cue` sheet
2. Parses track titles and timestamps from the CUE
3. Splits the FLAC into separate `.flac` files using `ffmpeg`
4. Fetches and embeds album artwork
5. Writes full metadata: title, artist, album, year, genre, track number, total tracks, cover art

## Requirements

- **macOS 13+**
- **ffmpeg** — `brew install ffmpeg`
- **Python 3 + mutagen** — `pip3 install mutagen --break-system-packages`

## Build from source

```bash
git clone https://github.com/ShadyUnderLight/TrackSplitter.git
cd TrackSplitter
swift build --configuration release
```

The binary is at `.build/arm64-apple-macosx/release/tracksplitter`.

## Install to PATH

```bash
ln -s ~/.swift/projects/TrackSplitter/.build/arm64-apple-macosx/release/tracksplitter /usr/local/bin/tracksplitter
```

Or with Swift Package Manager:

```bash
swift install tracksplitter  # coming soon
```

## Usage

```bash
tracksplitter "/path/to/陈升-别让我哭.flac"
```

The tool looks for a `.cue` file with the same base name in the same directory. Output is written to a subfolder named after the album title in the same directory as the source FLAC.

```
📂 /path/to/陈升-别让我哭/陈升-别让我哭/
  ├── 01. 別讓我哭.flac
  ├── 02. 嘿！我要走了.flac
  ├── 03. Vivien.flac
  └── ...
```

## Architecture

```
TrackSplitter/
├── Package.swift              # Swift Package Manager manifest
├── CLI/
│   └── main.swift             # Entry point + argument parsing
├── Library/
│   ├── CueParser.swift        # CUE sheet parser (Big5/UTF-8)
│   ├── AlbumArtFetcher.swift  # Album art fetcher (leftfm.com)
│   ├── FLACSplitter.swift     # ffmpeg orchestration
│   ├── MetadataEmbedder.swift # Python/mutagen bridge
│   └── TrackSplitterEngine.swift  # Main orchestrator
└── Resources/
    └── embed_metadata.py      # Metadata writing helper
```

## How it works

### CUE parsing
The CUE sheet is read with multi-encoding detection (Big5 → CP950 → UTF-8) so traditional Chinese filenames in CUE files are handled correctly. Track times are converted from `MM:SS:FF` (75 frames/second) to decimal seconds.

### Splitting
`ffmpeg` is invoked per-track with `-ss` / `-t` flags. The last track's duration is derived from the file's total duration (queried via `ffprobe`).

### Metadata embedding
A Python helper script (`embed_metadata.py`) is called via `Process`. It uses `mutagen` to write FLAC Vorbis comments and embed the JPEG cover art into each file's Picture block.

## Known limitations

- Only FLAC output is supported (MP3/AAC conversion planned)
- `ffmpeg` and `python3` must be in `PATH`
- Album art fetching currently targets `leftfm.com` only (extensible to other sources)

## License

MIT
