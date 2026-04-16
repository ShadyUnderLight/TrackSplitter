#!/usr/bin/env python3
"""Embed metadata into audio files. Supports FLAC, MP3, AAC/M4A via mutagen; WAV via ffmpeg."""
import sys, os, json, base64, subprocess, shlex

# mutagen supported formats
try:
    from mutagen.flac import FLAC, Picture as FLACPicture
    HAS_FLAC = True
except ImportError:
    HAS_FLAC = False

try:
    from mutagen.mp3 import MP3
    from mutagen.id3 import ID3, TYER, TIT2, TPE1, TALB, TRCK, TCON, COMM, TPE2, TDRC
    HAS_MP3 = True
except ImportError:
    HAS_MP3 = False

try:
    from mutagen.mp4 import MP4
    HAS_MP4 = True
except ImportError:
    HAS_MP4 = False


def main():
    if len(sys.argv) < 2:
        print("ERROR: Usage: embed_metadata.py <json_file>", file=sys.stderr)
        sys.exit(1)

    json_path = sys.argv[1]
    if not os.path.exists(json_path):
        print("ERROR: JSON file not found: %s" % json_path, file=sys.stderr)
        sys.exit(1)

    try:
        payload = json.load(open(json_path))
    except Exception as e:
        print("ERROR: JSON load error: %s" % e, file=sys.stderr)
        sys.exit(1)

    cover_b64 = payload.get("coverData")
    cover_bytes = None
    if cover_b64:
        try:
            cover_bytes = base64.b64decode(cover_b64)
        except Exception:
            pass

    for item in payload.get("files", []):
        fpath = item.get("path", "")
        if not os.path.exists(fpath):
            print("ERROR: %s: file not found" % os.path.basename(fpath))
            continue

        ext = os.path.splitext(fpath)[1].lower()
        ok = False

        if ext == ".flac" and HAS_FLAC:
            ok = embed_flac(fpath, item, cover_bytes)
        elif ext == ".mp3" and HAS_MP3:
            ok = embed_mp3(fpath, item, cover_bytes)
        elif ext in (".m4a", ".aac", ".mp4") and HAS_MP4:
            ok = embed_mp4(fpath, item, cover_bytes)
        elif ext == ".wav":
            ok = embed_wav(fpath, item, cover_bytes)
        else:
            # Fallback: try ffmpeg for any format
            ok = embed_ffmpeg(fpath, item, cover_bytes)

        if ok:
            print("DONE: %s" % os.path.basename(fpath))
        else:
            print("ERROR: %s: embedding failed" % os.path.basename(fpath))


def embed_flac(fpath: str, item: dict, cover_bytes: bytes) -> bool:
    try:
        audio = FLAC(fpath)
        audio.clear()
        set_tag(audio, "TITLE", item.get("title"))
        set_tag(audio, "ARTIST", item.get("artist"))
        set_tag(audio, "ALBUM", item.get("album"))
        set_tag(audio, "DATE", item.get("year"))
        set_tag(audio, "YEAR", item.get("year"))
        set_tag(audio, "GENRE", item.get("genre"))
        set_tag(audio, "TRACKNUMBER", item.get("tracknum"))
        set_tag(audio, "TOTALTRACKS", item.get("total"))
        set_tag(audio, "ALBUMARTIST", item.get("artist"))
        if item.get("comment"):
            set_tag(audio, "COMMENT", item["comment"])
        if item.get("composer"):
            set_tag(audio, "COMPOSER", item["composer"])
        if item.get("discNumber"):
            set_tag(audio, "DISCNUMBER", item["discNumber"])
        if cover_bytes:
            audio.clear_pictures()
            pic = FLACPicture()
            pic.type = 3
            pic.desc = "Album cover"
            pic.mime = "image/jpeg"
            pic.data = cover_bytes
            audio.add_picture(pic)
        audio.save()
        return True
    except Exception as e:
        print("ERROR: %s: %s" % (os.path.basename(fpath), e))
        return False


def embed_mp3(fpath: str, item: dict, cover_bytes: bytes) -> bool:
    try:
        audio = MP3(fpath)
        if audio.tags is None:
            audio.add_tags()
        id3 = audio.tags

        set_id3(id3, "TIT2", item.get("title"))          # title
        set_id3(id3, "TPE1", item.get("artist"))         # artist
        set_id3(id3, "TALB", item.get("album"))          # album
        set_id3(id3, "TYER", item.get("year"))           # year
        set_id3(id3, "TDRC", item.get("year"))           # year (id3v2.4)
        set_id3(id3, "TCON", item.get("genre"))          # genre
        set_id3(id3, "TRCK", item.get("tracknum"))       # track
        if item.get("comment"):
            set_id3(id3, "COMM", item["comment"])         # comment
        if item.get("composer"):
            set_id3(id3, "TPE2", item["composer"])        # album artist / composer
        if item.get("discNumber"):
            pass  # MP3 doesn't have standard DISCNUMBER tag in basic set
        id3.save()
        return True
    except Exception as e:
        print("ERROR: %s: %s" % (os.path.basename(fpath), e))
        return False


def embed_mp4(fpath: str, item: dict, cover_bytes: bytes) -> bool:
    try:
        audio = MP4(fpath)
        audio["\xa9nam"] = item.get("title", "")         # title
        audio["\xa9ART"] = item.get("artist", "")         # artist
        audio["\xa9alb"] = item.get("album", "")          # album
        audio["\xa9day"] = item.get("year", "")          # year
        audio["\xa9gen"] = item.get("genre", "")          # genre
        audio["trkn"] = [(int(item.get("tracknum", 0)), int(item.get("total", 0)))]
        if item.get("comment"):
            audio["\xa9cmt"] = item["comment"]
        # cover art: MP4 uses covr atom
        if cover_bytes:
            audio["covr"] = [cover_bytes]
        audio.save()
        return True
    except Exception as e:
        print("ERROR: %s: %s" % (os.path.basename(fpath), e))
        return False


def _ffmpeg_cmd():
    """Return full path to ffmpeg, matching MetadataEmbedder's lookup order."""
    import shutil
    for path in ("/opt/homebrew/bin/ffmpeg", "/opt/homebrew/bin/ffmpeg3",
                 "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg", "ffmpeg"):
        if shutil.which(path) or path == "ffmpeg":
            return path
    return "ffmpeg"


def embed_wav(fpath: str, item: dict, cover_bytes: bytes) -> bool:
    """Write basic metadata to WAV using ffmpeg -metadata.
    WAV does not support embedded cover art."""
    ffmpeg = _ffmpeg_cmd()
    cmd = [
        ffmpeg, "-y",
        "-i", fpath,
        "-metadata", "title=" + (item.get("title") or ""),
        "-metadata", "artist=" + (item.get("artist") or ""),
        "-metadata", "album=" + (item.get("album") or ""),
        "-metadata", "year=" + (item.get("year") or ""),
        "-metadata", "genre=" + (item.get("genre") or ""),
        "-metadata", "comment=" + (item.get("comment") or ""),
        "-codec", "copy",
        fpath + ".tmp.wav"
    ]
    try:
        proc = subprocess.run(cmd, capture_output=True, timeout=30)
        if proc.returncode == 0:
            os.replace(fpath + ".tmp.wav", fpath)
            # WAV has no cover art support
            if cover_bytes:
                print("SKIP: %s: cover art skipped (WAV format does not support embedded images)" % os.path.basename(fpath))
            return True
        else:
            err = proc.stderr.decode()[:200] if proc.stderr else "unknown"
            print("ERROR: %s: ffmpeg failed: %s" % (os.path.basename(fpath), err))
            if os.path.exists(fpath + ".tmp.wav"):
                os.remove(fpath + ".tmp.wav")
            return False
    except Exception as e:
        print("ERROR: %s: %s" % (os.path.basename(fpath), e))
        return False


def embed_ffmpeg(fpath: str, item: dict, cover_bytes: bytes) -> bool:
    """Generic fallback: ffmpeg -metadata for any format (no cover art)."""
    ffmpeg = _ffmpeg_cmd()
    cmd = [
        ffmpeg, "-y",
        "-i", fpath,
        "-metadata", "title=" + (item.get("title") or ""),
        "-metadata", "artist=" + (item.get("artist") or ""),
        "-metadata", "album=" + (item.get("album") or ""),
        "-metadata", "year=" + (item.get("year") or ""),
        "-metadata", "genre=" + (item.get("genre") or ""),
        "-metadata", "comment=" + (item.get("comment") or ""),
        "-codec", "copy",
        fpath + ".tmp"
    ]
    try:
        proc = subprocess.run(cmd, capture_output=True, timeout=30)
        if proc.returncode == 0:
            os.replace(fpath + ".tmp", fpath)
            return True
        else:
            if os.path.exists(fpath + ".tmp"):
                os.remove(fpath + ".tmp")
            return False
    except Exception as e:
        print("ERROR: %s: %s" % (os.path.basename(fpath), e))
        return False


def set_tag(audio, key: str, value: str):
    if value:
        audio[key] = value


def set_id3(id3, key: str, value: str):
    if value:
        id3[key] = value


if __name__ == "__main__":
    main()
