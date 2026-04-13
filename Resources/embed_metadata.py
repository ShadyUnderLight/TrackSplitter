#!/usr/bin/env python3
"""Embed metadata into FLAC files. Called from Swift via Process."""
import sys, os, json, base64
from mutagen.flac import FLAC, Picture

def main():
    if len(sys.argv) < 2:
        print("ERROR: Usage: embed_metadata.py <json_file>", file=sys.stderr)
        sys.exit(1)

    json_path = sys.argv[1]
    if not os.path.exists(json_path):
        print("ERROR: JSON file not found: %s" % json_path)
        sys.exit(1)

    try:
        payload = json.load(open(json_path))
    except Exception as e:
        print("ERROR: JSON load error: %s" % e)
        sys.exit(1)

    cover_bytes = None
    if payload.get("coverData"):
        try:
            cover_bytes = base64.b64decode(payload["coverData"])
        except Exception:
            pass

    for item in payload.get("files", []):
        fpath = item.get("path", "")
        if not os.path.exists(fpath):
            print("ERROR: %s: file not found" % os.path.basename(fpath))
            continue

        try:
            audio = FLAC(fpath)
            audio.clear()
            audio["TITLE"]       = item.get("title", "")
            audio["ARTIST"]      = item.get("artist", "")
            audio["ALBUM"]       = item.get("album", "")
            audio["DATE"]        = item.get("year", "")
            audio["YEAR"]        = item.get("year", "")
            audio["GENRE"]       = item.get("genre", "")
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
            print("DONE: %s" % os.path.basename(fpath))
        except Exception as e:
            print("ERROR: %s: %s" % (os.path.basename(fpath), e))

if __name__ == "__main__":
    main()
