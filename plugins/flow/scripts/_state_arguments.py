"""The command line of _state.py (ADR 0004). Pure: it reads only the words it is given.

A command, then each of its options as `--name value`, every one required (given twice, the last
counts), then `--` and the command's words: the pairs of set, the one key of get, none for the
others. --seed is stdin or none. --item is an id whose slug holds only letters, digits, _ and -, as
the slug of every adapter's id shape does, so no item names a path. A line outside this grammar is
refused with the command's usage, exit 2. Hand-written rather than argparse, whose import was a
large share of every write's start.
"""
from collections import namedtuple
from types import MappingProxyType

import _state_schema as schema

PROGRAM = "_state.py"
OPTION_PREFIX = "--"
END_OF_OPTIONS = "--"
WORDS_PER_OPTION = 2
SEED_OPTION = "seed"
ITEM_OPTION = "item"
SEED_SOURCES = ("stdin", "none")
COMMAND_OPTIONS = MappingProxyType({
    "set": ("state-dir", "flow-home", "item", "now", "machine", "host", "claim-file", "seed"),
    "take": ("state-dir", "flow-home", "item", "now", "machine", "host", "seed"),
    "get": ("state-dir", "flow-home", "item"),
    "show": ("state-dir", "flow-home", "item"),
    "archive": ("state-dir", "flow-home", "item", "machine"),
})
PAIRS_COMMAND = "set"
KEY_COMMAND = "get"
WORDS_USAGE = MappingProxyType({PAIRS_COMMAND: "-- <pair>...", KEY_COMMAND: "-- <key>"})
WORD_COUNTS = MappingProxyType({KEY_COMMAND: 1, "take": 0, "show": 0, "archive": 0})
OPTION_FIELDS = ("state_dir", "flow_home", "item", "now", "machine", "host", "claim_file", "seed")
UNSET_OPTIONS = MappingProxyType(dict.fromkeys(OPTION_FIELDS, ""))
Options = namedtuple("Options", ("command",) + OPTION_FIELDS + ("pairs", "key"))
NO_OPTIONS = Options(command="", pairs=(), key="", **UNSET_OPTIONS)
CommandLine = namedtuple("CommandLine", ("options", "outcome"))


def option_word(option):
    return OPTION_PREFIX + option


def option_field(word):
    return word[len(OPTION_PREFIX):].replace("-", "_")


def usage_line(command):
    options = " ".join("%s %s" % (option_word(option), "|".join(SEED_SOURCES) if option == SEED_OPTION
                                  else "<%s>" % option) for option in COMMAND_OPTIONS[command])
    return " ".join(part for part in ("usage:", PROGRAM, command, options, WORDS_USAGE.get(command, "")) if part)


def refused(command, problem):
    commands = (command,) if command in COMMAND_OPTIONS else tuple(COMMAND_OPTIONS)
    usage = "\n".join(usage_line(each) for each in commands)
    return CommandLine(NO_OPTIONS, schema.Outcome(schema.EXIT_USAGE, "%s\n%s" % (problem, usage)))


def given_options(option_words):
    return dict(zip(option_words[::WORDS_PER_OPTION], option_words[1::WORDS_PER_OPTION]))


def options_problem(command, option_words):
    names, values = option_words[::WORDS_PER_OPTION], option_words[1::WORDS_PER_OPTION]
    given = given_options(option_words)
    known = tuple(option_word(option) for option in COMMAND_OPTIONS[command])
    unknown = [name for name in names if name not in known]
    missing = [name for name in known if name not in given]
    seed = given.get(option_word(SEED_OPTION), SEED_SOURCES[0])
    item = given.get(option_word(ITEM_OPTION), "")
    checks = (
        (len(names) != len(values), "every option takes one value: %s" % " ".join(option_words)),
        (unknown, "unrecognized options: %s" % " ".join(unknown)),
        (missing, "the following options are required: %s" % " ".join(missing)),
        (seed not in SEED_SOURCES, "--seed is %s, not %s" % (" or ".join(SEED_SOURCES), seed)),
        (not schema.item_slug_shaped(item), "--item takes an id whose slug is letters, digits, _ and -, not %r" % item),
    )
    return next((message for failed, message in checks if failed), "")


def words_problem(command, words):
    wanted = WORD_COUNTS.get(command, len(words))
    return "" if len(words) == wanted else "the words after -- for %s number %d, not %d" % (command, wanted, len(words))


def parsed(arguments):
    command = arguments[0] if arguments else ""
    if command not in COMMAND_OPTIONS:
        return refused(command, "the command is one of %s, not %r" % (", ".join(COMMAND_OPTIONS), command))
    rest = list(arguments[1:])
    marker = rest.index(END_OF_OPTIONS) if END_OF_OPTIONS in rest else len(rest)
    option_words, words = rest[:marker], tuple(rest[marker + 1:])
    problem = options_problem(command, option_words) or words_problem(command, words)
    if problem:
        return refused(command, problem)
    fields = dict(UNSET_OPTIONS, **{option_field(name): value for name, value in given_options(option_words).items()})
    pairs = words if command == PAIRS_COMMAND else ()
    key = words[0] if command == KEY_COMMAND else ""
    return CommandLine(Options(command=command, pairs=pairs, key=key, **fields), schema.DONE)
