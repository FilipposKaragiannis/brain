"""The image and video evidence a pull request carries, shared by scripts/_pr_report.py and
scripts/_pr_publish.py.

A media file is a regular file under <reports>/evidence/, nested or not, whose extension is in
MEDIA_EXTENSIONS. The walk follows no link, because an attached file goes public. Its reference is
`![<name>](./evidence/<name>)`, the name percent-encoded in the destination, so gh resolves it
against the body file in <reports> and swaps in the asset URL it uploads the file to.
"""
import os
import posixpath
import stat
from typing import List
from urllib.parse import quote

from _verify_proofs import EVIDENCE_FOLDER

MEDIA_EXTENSIONS = frozenset((".png", ".jpg", ".jpeg", ".gif", ".webp", ".mp4", ".mov", ".webm"))
MEDIA_REFERENCE = "![%s](./%s/%s)"
PATH_SEPARATOR = "/"
ALT_TEXT_SPECIAL_CHARACTERS = ("\\", "[", "]")
MARKDOWN_ESCAPE = "\\"


def is_media(name: str) -> bool:
    return os.path.splitext(name)[1].lower() in MEDIA_EXTENSIONS


def is_regular_file(path: str) -> bool:
    try:
        return stat.S_ISREG(os.lstat(path).st_mode)
    except OSError:
        return False


def evidence_names(folder: str) -> List[str]:
    if os.path.islink(folder) or not os.path.isdir(folder):
        return []
    paths = [os.path.join(directory, file_name)
             for directory, _subfolders, file_names in os.walk(folder) for file_name in file_names]
    return sorted(os.path.relpath(path, folder).replace(os.sep, posixpath.sep) for path in paths if is_regular_file(path))


def media_names(reports: str) -> List[str]:
    return [name for name in evidence_names(os.path.join(reports, EVIDENCE_FOLDER)) if is_media(name)]


def alt_text(name: str) -> str:
    escaped = name
    for special_character in ALT_TEXT_SPECIAL_CHARACTERS:
        escaped = escaped.replace(special_character, MARKDOWN_ESCAPE + special_character)
    return escaped


def media_reference(name: str) -> str:
    return MEDIA_REFERENCE % (alt_text(name), EVIDENCE_FOLDER, quote(name, safe=PATH_SEPARATOR))
