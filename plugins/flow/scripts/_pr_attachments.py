"""The image and video files scripts/_pr_publish.py hands to gh with --attach, and the ones gh did
not upload.

gh refuses an empty file, an image over 10 MiB and a video over 100 MiB before it uploads
anything, so one such file would stop every upload: those are left out of --attach and counted as
not uploaded (attachments). gh uploads in order and stops at the first failure, naming that file
by the path it was given after `could not upload ` or `failed to upload `, so the files not
uploaded are that one and every file after it (not_uploaded). The paths are absolute, so a known
path is matched by prefix, the longest first, and the path itself is never parsed.
"""
import os
import stat
from dataclasses import dataclass
from typing import Optional, Sequence, Tuple

VIDEO_EXTENSIONS = frozenset((".mp4", ".mov", ".webm"))
BYTES_PER_MEBIBYTE = 1024 * 1024
IMAGE_LIMIT_MEBIBYTES = 10
VIDEO_LIMIT_MEBIBYTES = 100
UPLOAD_ERROR_PREFIXES = ("could not upload ", "failed to upload ")
PATH_END = ":"
LINE_BREAK = "\n"


@dataclass(frozen=True)
class Attachment:
    name: str
    path: str


@dataclass(frozen=True)
class Attachments:
    uploadable: Tuple[Attachment, ...]
    refused: Tuple[Attachment, ...]


def size_limit_bytes(name: str) -> int:
    is_video = os.path.splitext(name)[1].lower() in VIDEO_EXTENSIONS
    return (VIDEO_LIMIT_MEBIBYTES if is_video else IMAGE_LIMIT_MEBIBYTES) * BYTES_PER_MEBIBYTE


def is_uploadable(attachment: Attachment) -> bool:
    try:
        status = os.lstat(attachment.path)
    except OSError:
        return False
    return stat.S_ISREG(status.st_mode) and 0 < status.st_size <= size_limit_bytes(attachment.name)


def attachments(candidates: Sequence[Attachment]) -> Attachments:
    uploadable = tuple(attachment for attachment in candidates if is_uploadable(attachment))
    return Attachments(uploadable, tuple(attachment for attachment in candidates if attachment not in uploadable))


def named_path(line: str, paths: Sequence[str]) -> Optional[str]:
    for prefix in UPLOAD_ERROR_PREFIXES:
        if not line.startswith(prefix):
            continue
        rest = line[len(prefix):]
        named = [path for path in paths if rest == path or rest.startswith(path + PATH_END)]
        return max(named, key=len) if named else None
    return None


def not_uploaded(attached: Tuple[Attachment, ...], stderr: str) -> Tuple[Attachment, ...]:
    paths = [attachment.path for attachment in attached]
    named = {named_path(line, paths) for line in stderr.split(LINE_BREAK)} - {None}
    positions = [position for position, path in enumerate(paths) if path in named]
    return attached[min(positions):] if positions else ()
