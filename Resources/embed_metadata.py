#!/usr/bin/env python3
"""Embed metadata into FLAC files. Called from Swift via Process."""
import json
import os
import sys

from mutagen.flac import FLAC, Picture


def main():
    argv = json.loads(sys.argv[1])
    # argv = {files: [{"path": "...", "title": "...", "artist": "...", "album": "...", "year": "...", "genre": "...", "tracknum": "...", "total": "..."}], coverData: "base64 string or null"}

    cover_bytes = None
    if argv.get("coverData"):
        import base64
        cover_bytes = base64.b64decode(argv["coverData"])

    for item in argv["files"]:
        fpath = item["path"]
        if not os.path.exists(fpath):
            print(f"FILE_NOT_FOUND: {fpath}", file=sys.stderr)
            continue

        audio = FLAC(fpath)
        audio["TITLE"] = item.get("title", "")
        audio["ARTIST"] = item.get("artist", "")
        audio["ALBUM"] = item.get("album", "")
        audio["DATE"] = item.get("year", "")
        audio["YEAR"] = item.get("year", "")
        audio["GENRE"] = item.get("genre", "")
        audio["TRACKNUMBER"] = item.get("tracknum", "")
        audio["TOTALTRACKS"] = item.get("total", "")
        audio["ALBUMARTIST"] = item.get("artist", "")

        if cover_bytes:
            audio.clear_pictures()
            pic = Picture()
            pic.type = 3
            pic.desc = "Album cover"
            pic.mime = "image/jpeg"
            pic.data = cover_bytes
            audio.add_picture(pic)

        audio.save()
        print(f"DONE: {os.path.basename(fpath)}")


if __name__ == "__main__":
    main()
