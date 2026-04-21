# Third-Party Licenses

TrackSplitter is distributed under the MIT License (see `LICENSE`). However, it depends on the following third-party tools/libraries, each with their own licenses.

## FFmpeg

**License:** LGPL v2.1 or later by default; builds with optional GPL components are GPL v2+.

FFmpeg is used for audio transcoding, chapter metadata handling, and format conversion. The official FFmpeg build is LGPL v2.1+ by default, but enabling optional components (e.g., libx264, libx265, libmp3lame, and other non-free/GPL-coded filters) changes the resulting binary to GPL v2+. You must comply with the applicable license terms for your FFmpeg build if you redistribute binaries.

Website: https://ffmpeg.org

## mutagen

**License:** [GPL v2 or later](https://github.com/quodlibet/mutagen/blob/master/COPYING)

Mutagen is a Python library used by TrackSplitter's metadata embedding script (`Library/Resources/embed_metadata.py`) to write audio tags in various formats.

Website: https://github.com/quodlibet/mutagen
