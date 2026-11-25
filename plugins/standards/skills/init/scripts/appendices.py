#!/usr/bin/env python3
"""Which language appendices `standards init` installs, and the file globs each one loads for.

    python3 -I appendices.py <plugin>/rules/appendices.json .standards/config.json <project|machine> [<block.md>]

Prints one line per appendix of the plugin, in the plugin's order: "<file>\\t<globs>", the globs it
installs with separated by spaces, and no globs when it is left out. At project scope an appendix
installs when a configured language shares a file extension with it, and loads for the extensions
of those languages. At machine scope, shared by every project, each appendix installs and loads for its own
extensions. A missing config configures no language. With a block file, prints that block instead,
its language sentence naming the files of the appendices installed, in the plugin's order, and no
sentence when none is. Exit 1 with the reason on stderr when a file does not parse, names an
extension that is not a dot and a name, or is a block whose first paragraph does not name every
appendix of the plugin.
"""
import dataclasses
import json
import re
import sys
import textwrap
from typing import Iterator, List, Tuple

SCOPES = ("project", "machine")
MACHINE_SCOPE = "machine"
EXTENSION = re.compile(r"^\.[A-Za-z0-9_+-]+$")
GLOB_PREFIX = "**/*"
GLOB_SEPARATOR = " "
ARGUMENT_COUNT = 4
BLOCK_ARGUMENT_COUNT = 5
SCOPE_POSITION = 3
USAGE_EXIT = 2
USAGE = "usage: appendices.py <appendices.json> <config.json> <project|machine> [<block.md>]"
BLOCK_WIDTH = 100
SENTENCE_LEAD = "Language conventions, one file per configured language: "
NAMED_APPENDIX = "`.standards/rules/%s` (%s)"


@dataclasses.dataclass(frozen=True)
class Appendix:
    file: str
    language: str
    extensions: Tuple[str, ...]


@dataclasses.dataclass(frozen=True)
class Selection:
    appendices: Tuple[Appendix, ...]
    configured: Tuple[Tuple[str, ...], ...]
    problem: str


@dataclasses.dataclass(frozen=True)
class Output:
    text: str
    problem: str


def read_json(path: str) -> object:
    with open(path, encoding="utf-8") as source:
        return json.load(source)


def extensions_problem(value: object, where: str) -> str:
    """Why a JSON value is not a list of extensions like ".sh", or empty when it is one."""
    if isinstance(value, list) and all(isinstance(entry, str) and EXTENSION.match(entry) for entry in value):
        return ""
    return "%s: extensions must be a list like [\".sh\"], not %s" % (where, json.dumps(value))


def appendices_problem(appendix_entries: object, path: str) -> str:
    if not isinstance(appendix_entries, list):
        return "%s: not a list of appendices" % path
    problems = (_entry_problem(entry, "%s[%d]" % (path, position)) for position, entry in enumerate(appendix_entries))
    return next((problem for problem in problems if problem), "")


def _entry_problem(entry: object, where: str) -> str:
    if not isinstance(entry, dict) or not isinstance(entry.get("file"), str):
        return "%s: an appendix needs a file name" % where
    if not isinstance(entry.get("language"), str):
        return "%s: an appendix needs a language name" % where
    return extensions_problem(entry.get("extensions"), where)


def configured_languages(project_config: object) -> list:
    languages = project_config.get("languages") if isinstance(project_config, dict) else None
    return languages if isinstance(languages, list) else []


def language_extensions(language: dict) -> list:
    """A configured language's extensions; one that names none has an empty list."""
    extensions = language.get("extensions")
    return [] if extensions is None else extensions


def languages_problem(project_config: object, path: str) -> str:
    if isinstance(project_config, dict) and "languages" in project_config and not isinstance(project_config["languages"], list):
        return "%s: languages is not a list" % path
    for position, language in enumerate(configured_languages(project_config)):
        where = "%s: languages[%d]" % (path, position)
        if not isinstance(language, dict):
            return "%s: a language must be an object, not %s" % (where, json.dumps(language))
        problem = extensions_problem(language_extensions(language), where)
        if problem:
            return problem
    return ""


def failed(problem: str) -> Selection:
    return Selection(appendices=(), configured=(), problem=problem)


def load(appendices_path: str, config_path: str) -> Selection:
    try:
        appendix_entries = read_json(appendices_path)
    except (OSError, ValueError) as error:
        return failed("%s: %s" % (appendices_path, error))
    try:
        project_config = read_json(config_path)
    except FileNotFoundError:
        project_config = {}
    except (OSError, ValueError) as error:
        return failed("%s: %s" % (config_path, error))
    problem = appendices_problem(appendix_entries, appendices_path) or languages_problem(project_config, config_path)
    if problem:
        return failed(problem)
    return Selection(
        appendices=tuple(Appendix(file=entry["file"], language=entry["language"], extensions=tuple(entry["extensions"]))
                         for entry in appendix_entries),
        configured=tuple(tuple(language_extensions(language)) for language in configured_languages(project_config)),
        problem="",
    )


def globs_for(appendix: Appendix, configured: Tuple[Tuple[str, ...], ...], scope: str) -> Tuple[str, ...]:
    """The globs an appendix loads for, empty when it is left out."""
    if scope == MACHINE_SCOPE:
        return tuple(GLOB_PREFIX + extension for extension in appendix.extensions)
    matched = [extension for language in configured if set(language) & set(appendix.extensions) for extension in language]
    return tuple(GLOB_PREFIX + extension for extension in dict.fromkeys(matched))


def table(selection: Selection, scope: str) -> Iterator[str]:
    for appendix in selection.appendices:
        yield "%s\t%s" % (appendix.file, GLOB_SEPARATOR.join(globs_for(appendix, selection.configured, scope)))


def _named_appendices(appendices: Tuple[Appendix, ...]) -> str:
    named = [NAMED_APPENDIX % (appendix.file, appendix.language) for appendix in appendices]
    return ", ".join(named[:-1]) + " and " + named[-1] if len(named) > 1 else "".join(named)


def _language_sentence(appendices: Tuple[Appendix, ...]) -> str:
    return SENTENCE_LEAD + _named_appendices(appendices) + "." if appendices else ""


def _installed(selection: Selection, scope: str) -> Tuple[Appendix, ...]:
    return tuple(appendix for appendix in selection.appendices if globs_for(appendix, selection.configured, scope))


def _language_block(block_text: str, selection: Selection, scope: str) -> Output:
    lines = block_text.split("\n")
    paragraph_end = lines.index("") if "" in lines else 0
    paragraph = " ".join(lines[1:paragraph_end])
    shipped = _language_sentence(selection.appendices)
    if shipped not in paragraph:
        return Output(text="", problem="its first paragraph does not name every appendix of the plugin")
    scoped = " ".join(paragraph.replace(shipped, _language_sentence(_installed(selection, scope))).split())
    wrapped = textwrap.wrap(scoped, width=BLOCK_WIDTH, break_on_hyphens=False)
    return Output(text="\n".join(lines[:1] + wrapped + lines[paragraph_end:]), problem="")


def _scoped_block(block_path: str, selection: Selection, scope: str) -> Output:
    try:
        with open(block_path, encoding="utf-8") as source:
            block_text = source.read()
    except OSError as error:
        return Output(text="", problem="%s: %s" % (block_path, error))
    scoped = _language_block(block_text, selection, scope)
    return Output(text=scoped.text, problem="%s: %s" % (block_path, scoped.problem) if scoped.problem else "")


def _output(selection: Selection, scope: str, block_paths: List[str]) -> Output:
    if selection.problem:
        return Output(text="", problem=selection.problem)
    if block_paths:
        return _scoped_block(block_paths[0], selection, scope)
    return Output(text="".join(line + "\n" for line in table(selection, scope)), problem="")


def main() -> int:
    if len(sys.argv) not in (ARGUMENT_COUNT, BLOCK_ARGUMENT_COUNT) or sys.argv[SCOPE_POSITION] not in SCOPES:
        print(USAGE, file=sys.stderr)
        return USAGE_EXIT
    _, appendices_path, config_path, scope = sys.argv[:ARGUMENT_COUNT]
    output = _output(load(appendices_path, config_path), scope, sys.argv[ARGUMENT_COUNT:])
    if output.problem:
        print("appendices: %s" % output.problem, file=sys.stderr)
        return 1
    sys.stdout.buffer.write(output.text.encode("utf-8"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
