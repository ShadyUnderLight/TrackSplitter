#!/usr/bin/env python3
"""Embed metadata into FLAC files."""
import sys, os, json, base64
from mutagen.flac import FLAC, Picture

def main():
    # Debug marker - write immediately
    try:
        with open("/tmp/script_ran.txt", "w") as f:
            f.write("START: argv=%r cwd=%s\n" % (sys.argv, os.getcwd()))
    except:
        pass

    if len(sys.argv) < 2:
        print("Usage: embed_metadata.py <json_file>", file=sys.stderr)
        sys.exit(1)

    json_path = sys.argv[1]
    if not os.path.exists(json_path):
        print("FILE_NOT_FOUND: %s" % json_path, file=sys.stderr)
        sys.exit(1)

    try:
        payload = json.load(open(json_path))
    except Exception as e:
        print("JSON load error: %s" % e, file=sys.stderr)
        sys.exit(1)

    # Debug: log what we received
    try:
        with open("/tmp/script_ran.txt", "a") as f:
            n_files = len(payload.get("files", []))
            f.write("payload keys=%s n_files=%d\n" % (list(payload.keys()), n_files))
            for item in payload.get("files", []):
                f.write("  file: path=%r exists=%s\n" % (item.get("path", ""), os.path.exists(item.get("path", ""))))
    except Exception as e:
        pass

    cover_bytes = None
    if payload.get("coverData"):
        try:
            cover_bytes = base64.b64decode(payload["coverData"])
        except Exception:
            pass

    for item in payload.get("files", []):
        fpath = item.get("path", "")
        if not os.path.exists(fpath):
            print("FILE_NOT_FOUND: %s" % fpath, file=sys.stderr)
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
            print("ERROR: %s: %s" % (os.path.basename(fpath), e), file=sys.stderr)

if __name__ == "__main__":
    main()
