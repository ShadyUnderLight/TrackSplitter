#!/usr/bin/env python3
"""Embed metadata into audio files.

Supported formats:
  FLAC          — Vorbis comments via mutagen
  MP3           — ID3v2 via mutagen
  M4A/AAC/MP4   — iTunes atoms via mutagen
  WAV           — INFO chunk via ffmpeg -metadata (no cover art)
  AIFF          — ID3 chunk via mutagen (no cover art)
  OGG / Opus    — Vorbis comments via mutagen (no cover art)

Cover art is supported for FLAC, MP3, and M4A only.
"""
import sys, os, json, base64, subprocess

from mutagen.flac import FLAC, Picture as FLACPicture
from mutagen.mp3 import MP3
from mutagen.mp4 import MP4
from mutagen.aiff import AIFF
from mutagen.id3 import (
    TIT2, TPE1, TALB, TDRC, TCON, TRCK, TPOS, TCOM,
    TPE2, COMM, APIC
)
from mutagen.oggvorbis import OggVorbis
from mutagen.oggopus import OggOpus


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

        if ext == ".flac":
            ok = embed_flac(fpath, item, cover_bytes)
        elif ext == ".mp3":
            ok = embed_mp3(fpath, item, cover_bytes)
        elif ext in (".m4a", ".aac", ".mp4"):
            ok = embed_mp4(fpath, item, cover_bytes)
        elif ext in (".aiff", ".aif"):
            ok = embed_aiff(fpath, item, cover_bytes)
        elif ext in (".ogg", ".opus"):
            ok = embed_ogg(fpath, item, cover_bytes)
        elif ext == ".wav":
            ok = embed_wav(fpath, item, cover_bytes)
        else:
            ok = embed_ffmpeg(fpath, item, cover_bytes)

        if ok:
            print("DONE: %s" % os.path.basename(fpath))
        else:
            print("ERROR: %s: embedding failed" % os.path.basename(fpath))


# ─── FLAC ────────────────────────────────────────────────────────────────────

def embed_flac(fpath: str, item: dict, cover_bytes: bytes) -> bool:
    """Write Vorbis comments + embedded picture to FLAC via mutagen."""
    try:
        audio = FLAC(fpath)
        audio.clear()
        _set_vorbis(audio, "TITLE", item.get("title"))
        _set_vorbis(audio, "ARTIST", item.get("artist"))
        _set_vorbis(audio, "ALBUM", item.get("album"))
        # DATE is the canonical year field in Vorbis; YEAR is omitted.
        _set_vorbis(audio, "DATE", item.get("year"))
        _set_vorbis(audio, "GENRE", item.get("genre"))
        _set_vorbis(audio, "TRACKNUMBER", item.get("tracknum"))
        _set_vorbis(audio, "TOTALTRACKS", item.get("total"))
        _set_vorbis(audio, "ALBUMARTIST", item.get("albumArtist"))
        _set_vorbis(audio, "COMPOSER", item.get("composer"))
        _set_vorbis(audio, "DISCNUMBER", item.get("discNumber"))
        _set_vorbis(audio, "COMMENT", item.get("comment"))
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


# ─── MP3 / ID3v2 ─────────────────────────────────────────────────────────────

def embed_mp3(fpath: str, item: dict, cover_bytes: bytes) -> bool:
    """Write ID3v2 tags to MP3 via mutagen (mutagen >= 1.47 API)."""
    try:
        audio = MP3(fpath)
        if audio.tags is None:
            audio.add_tags()
        id3 = audio.tags

        _id3_text(id3, TIT2, item.get("title"))
        _id3_text(id3, TPE1, item.get("artist"))
        _id3_text(id3, TALB, item.get("album"))
        _id3_text(id3, TDRC, item.get("year"))
        _id3_text(id3, TCON, item.get("genre"))
        _id3_text(id3, TRCK, item.get("tracknum"))
        _id3_text(id3, TPOS, item.get("discNumber"))
        _id3_text(id3, TPE2, item.get("albumArtist"))
        _id3_text(id3, TCOM, item.get("composer"))
        _id3_comm(id3, item.get("comment"))
        if cover_bytes:
            id3[APIC] = APIC(
                encoding=3, mime="image/jpeg", type=3, desc="Album cover",
                data=cover_bytes
            )
        audio.save()
        return True
    except Exception as e:
        print("ERROR: %s: %s" % (os.path.basename(fpath), e))
        return False


# ─── M4A / AAC / MP4 ────────────────────────────────────────────────────────

def embed_mp4(fpath: str, item: dict, cover_bytes: bytes) -> bool:
    """Write iTunes-style atoms to M4A/AAC/MP4 via mutagen."""
    try:
        audio = MP4(fpath)
        _set_mp4_text(audio, "\xa9nam", item.get("title"))
        _set_mp4_text(audio, "\xa9ART", item.get("artist"))
        _set_mp4_text(audio, "\xa9alb", item.get("album"))
        _set_mp4_text(audio, "\xa9day", item.get("year"))
        _set_mp4_text(audio, "\xa9gen", item.get("genre"))
        _set_mp4_trkn(audio, item.get("tracknum"), item.get("total"))
        _set_mp4_text(audio, "\xa9aART", item.get("albumArtist"))
        _set_mp4_text(audio, "\xa9wrt", item.get("composer"))
        _set_mp4_text(audio, "\xa9cmt", item.get("comment"))
        # Disc number: no standard iTunes atom exists; silently skipped.
        if cover_bytes:
            audio["covr"] = [cover_bytes]
        audio.save()
        return True
    except Exception as e:
        print("ERROR: %s: %s" % (os.path.basename(fpath), e))
        return False


# ─── AIFF ───────────────────────────────────────────────────────────────────

def embed_aiff(fpath: str, item: dict, cover_bytes: bytes) -> bool:
    """Write ID3 chunk to AIFF via mutagen. No cover art support."""
    try:
        audio = AIFF(fpath)
        if audio.tags is None:
            audio.add_tags()
        id3 = audio.tags

        _id3_text(id3, TIT2, item.get("title"))
        _id3_text(id3, TPE1, item.get("artist"))
        _id3_text(id3, TALB, item.get("album"))
        _id3_text(id3, TDRC, item.get("year"))
        _id3_text(id3, TCON, item.get("genre"))
        _id3_text(id3, TRCK, item.get("tracknum"))
        _id3_text(id3, TPOS, item.get("discNumber"))
        _id3_text(id3, TPE2, item.get("albumArtist"))
        _id3_text(id3, TCOM, item.get("composer"))
        _id3_comm(id3, item.get("comment"))
        if cover_bytes:
            print("SKIP: %s: cover art skipped (AIFF cover art support is unreliable)" %
                  os.path.basename(fpath))
        audio.save()
        return True
    except Exception as e:
        print("ERROR: %s: %s" % (os.path.basename(fpath), e))
        return False


# ─── OGG (Vorbis) ─────────────────────────────────────────────────────────────

def embed_ogg(fpath: str, item: dict, cover_bytes: bytes) -> bool:
    """Write Vorbis comments to OGG/Opus via mutagen. No cover art support."""
    try:
        if fpath.endswith(".opus"):
            audio = OggOpus(fpath)
        else:
            audio = OggVorbis(fpath)
        _set_vorbis(audio, "TITLE", item.get("title"))
        _set_vorbis(audio, "ARTIST", item.get("artist"))
        _set_vorbis(audio, "ALBUM", item.get("album"))
        _set_vorbis(audio, "DATE", item.get("year"))
        _set_vorbis(audio, "GENRE", item.get("genre"))
        _set_vorbis(audio, "TRACKNUMBER", item.get("tracknum"))
        _set_vorbis(audio, "TOTALTRACKS", item.get("total"))
        _set_vorbis(audio, "ALBUMARTIST", item.get("albumArtist"))
        _set_vorbis(audio, "COMPOSER", item.get("composer"))
        _set_vorbis(audio, "DISCNUMBER", item.get("discNumber"))
        _set_vorbis(audio, "COMMENT", item.get("comment"))
        if cover_bytes:
            print("SKIP: %s: cover art skipped (OGG/Opus cover art support is unreliable)" %
                  os.path.basename(fpath))
        audio.save()
        return True
    except Exception as e:
        print("ERROR: %s: %s" % (os.path.basename(fpath), e))
        return False


# ─── WAV ─────────────────────────────────────────────────────────────────────

def embed_wav(fpath: str, item: dict, cover_bytes: bytes) -> bool:
    """Write INFO chunk metadata to WAV via ffmpeg. No cover art support."""
    return _ffmpeg_metadata(fpath, item, cover_bytes,
                            extra_note="WAV format does not support embedded images")


# ─── Generic fallback ────────────────────────────────────────────────────────

def embed_ffmpeg(fpath: str, item: dict, cover_bytes: bytes) -> bool:
    """Generic fallback: ffmpeg -metadata for any unrecognized format."""
    return _ffmpeg_metadata(fpath, item, cover_bytes)


# ─── Helpers ──────────────────────────────────────────────────────────────────

def _ffmpeg_cmd():
    """Return the full path to ffmpeg."""
    import shutil
    for path in ("/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg",
                 "/usr/bin/ffmpeg", "ffmpeg"):
        if shutil.which(path) or path == "ffmpeg":
            return path
    return "ffmpeg"


def _ffmpeg_metadata(fpath: str, item: dict, cover_bytes: bytes,
                     extra_note: str = None) -> bool:
    """Write metadata via ffmpeg -metadata -codec copy."""
    ffmpeg = _ffmpeg_cmd()
    tmp = fpath + "_meta_tmp"
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
        tmp
    ]
    try:
        proc = subprocess.run(cmd, capture_output=True, timeout=30)
        if proc.returncode == 0:
            os.replace(tmp, fpath)
            if cover_bytes and extra_note:
                print("SKIP: %s: %s" % (os.path.basename(fpath), extra_note))
            return True
        else:
            err = proc.stderr.decode()[:200] if proc.stderr else "unknown"
            print("ERROR: %s: ffmpeg failed: %s" % (os.path.basename(fpath), err))
            if os.path.exists(tmp):
                os.remove(tmp)
            return False
    except Exception as e:
        print("ERROR: %s: %s" % (os.path.basename(fpath), e))
        return False


def _set_vorbis(audio, key: str, value):
    """Set a Vorbis comment key, skipping None/empty values."""
    if value:
        audio[key] = value


def _id3_text(id3, frame_cls, value):
    """Set a text ID3 frame (mutagen >= 1.47: must use Frame instance as value)."""
    if value:
        id3[frame_cls] = frame_cls(encoding=3, text=[value])


def _id3_comm(id3, value):
    """Set a COMM (comment) ID3 frame."""
    if value:
        id3[COMM] = COMM(encoding=3, lang="eng", desc="", text=[value])


def _set_mp4_text(audio, key: str, value):
    """Set an MP4 text atom, skipping None/empty values."""
    if value:
        audio[key] = value


def _set_mp4_trkn(audio, track: str, total: str):
    """Set the MP4 trkn atom from track number and total tracks."""
    try:
        t = int(track) if track else 0
        n = int(total) if total else 0
        audio["trkn"] = [(t, n)]
    except (ValueError, TypeError):
        pass


if __name__ == "__main__":
    main()
