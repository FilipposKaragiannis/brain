"""The command line of _state.py: its commands and their options.
Pure: it reads only the words it is given.

A command, then each of its options as `--name value`, every one required but the --item of list
(given twice, the last counts), then `--` and the command's words: the pairs of set, the one key of
get, the pool entries of import, none for the others. --seed is stdin or none, --kind runs or
gates, --effect plan or write. --item, where a command
takes one, is an id whose slug holds only letters, digits, _ and -, as the slug of every adapter's
id shape does, so no item names a path. A line outside this grammar is refused with the command's
usage, exit 2. Hand-written rather than argparse, whose import was a large share of every write's
start.
"""
from collections import namedtuple
from types import MappingProxyType

import _state_join as join
import _state_schema as schema

PROGRAM = "_state.py"
OPTION_PREFIX = "--"
END_OF_OPTIONS = "--"
WORDS_PER_OPTION = 2
SEED_OPTION = "seed"
ITEM_OPTION = "item"
KIND_OPTION = "kind"
EFFECT_OPTION = "effect"
SEED_SOURCES = ("stdin", "none")
PLAN_EFFECT, WRITE_EFFECT = "plan", "write"
OPTION_CHOICES = MappingProxyType({SEED_OPTION: SEED_SOURCES, KIND_OPTION: join.ROW_KINDS,
                                   EFFECT_OPTION: (PLAN_EFFECT, WRITE_EFFECT)})
COMMAND_OPTIONS = MappingProxyType({
    "set": ("state-dir", "flow-home", "item", "now", "machine", "host", "claim-file", "seed"),
    "take": ("state-dir", "flow-home", "item", "now", "machine", "host", "seed"),
    "get": ("state-dir", "flow-home", "item"),
    "show": ("state-dir", "flow-home", "item"),
    "status": ("state-dir", "flow-home", "item"),
    "archive": ("state-dir", "flow-home", "item", "machine"),
    "join": ("state-dir", "flow-home"),
    "list": ("state-dir", "flow-home", "kind"),
    "row": ("state-dir", "flow-home", "kind", "item"),
    "import": ("state-dir", "flow-home", "now", "machine", "effect"),
})
OPTIONAL_OPTIONS = MappingProxyType({"list": (ITEM_OPTION,)})
PAIRS_COMMAND = "set"
KEY_COMMAND = "get"
POOL_COMMAND = "import"
WORDS_USAGE = MappingProxyType({PAIRS_COMMAND: "-- <pair>...", KEY_COMMAND: "-- <key>",
                                POOL_COMMAND: "-- <pool entry>..."})
WORD_COUNTS = MappingProxyType({KEY_COMMAND: 1, "take": 0, "show": 0, "status": 0, "archive": 0, "join": 0, "list": 0,
                                 "row": 0})
OPTION_FIELDS = ("state_dir", "flow_home", "item", "now", "machine", "host", "claim_file", "seed", "kind", "effect")
UNSET_OPTIONS = MappingProxyType(dict.fromkeys(OPTION_FIELDS, ""))
Options = namedtuple("Options", ("command",) + OPTION_FIELDS + ("pairs", "key", "pool"))
NO_OPTIONS = Options(command="", pairs=(), key="", pool=(), **UNSET_OPTIONS)
CommandLine = namedtuple("CommandLine", ("options", "outcome"))


def option_word(option):
    return OPTION_PREFIX + option


def option_field(word):
    return word[len(OPTION_PREFIX):].replace("-", "_")


def option_usage(option):
    value = "|".join(OPTION_CHOICES[option]) if option in OPTION_CHOICES else "<%s>" % option
    return "%s %s" % (option_word(option), value)


def usage_line(command):
    required = [option_usage(option) for option in COMMAND_OPTIONS[command]]
    optional = ["[%s]" % option_usage(option) for option in OPTIONAL_OPTIONS.get(command, ())]
    options = " ".join(required + optional)
    return " ".join(part for part in ("usage:", PROGRAM, command, options, WORDS_USAGE.get(command, "")) if part)


def refused(command, problem):
    commands = (command,) if command in COMMAND_OPTIONS else tuple(COMMAND_OPTIONS)
    usage = "\n".join(usage_line(each) for each in commands)
    return CommandLine(NO_OPTIONS, schema.Outcome(schema.EXIT_USAGE, "%s\n%s" % (problem, usage)))


def given_options(option_words):
    return dict(zip(option_words[::WORDS_PER_OPTION], option_words[1::WORDS_PER_OPTION]))


def choice_problem(given):
    for option, choices in OPTION_CHOICES.items():
        value = given.get(option_word(option), choices[0])
        if value not in choices:
            return "%s is %s, not %s" % (option_word(option), " or ".join(choices), value)
    return ""


def item_problem(given):
    item = given.get(option_word(ITEM_OPTION))
    if item is None or schema.item_slug_shaped(item):
        return ""
    return "--item takes an id whose slug is letters, digits, _ and -, not %r" % item


def options_problem(command, option_words):
    names, values = option_words[::WORDS_PER_OPTION], option_words[1::WORDS_PER_OPTION]
    given = given_options(option_words)
    required = tuple(option_word(option) for option in COMMAND_OPTIONS[command])
    known = required + tuple(option_word(option) for option in OPTIONAL_OPTIONS.get(command, ()))
    unknown = [name for name in names if name not in known]
    missing = [name for name in required if name not in given]
    checks = (
        (len(names) != len(values), "every option takes one value: %s" % " ".join(option_words)),
        (unknown, "unrecognized options: %s" % " ".join(unknown)),
        (missing, "the following options are required: %s" % " ".join(missing)),
    )
    problem = next((message for failed, message in checks if failed), "")
    return problem or choice_problem(given) or item_problem(given)


def words_problem(command, words):
    wanted = WORD_COUNTS.get(command, len(words))
    return "" if len(words) == wanted else "the words after -- for %s number %d, not %d" % (command, wanted, len(words))


def command_word(arguments):
    return arguments[0] if arguments else ""


def end_of_options_index(rest):
    return rest.index(END_OF_OPTIONS) if END_OF_OPTIONS in rest else len(rest)


def assembled_options(command, option_words, words):
    fields = dict(UNSET_OPTIONS, **{option_field(name): value for name, value in given_options(option_words).items()})
    pairs = words if command == PAIRS_COMMAND else ()
    key = words[0] if command == KEY_COMMAND else ""
    pool = words if command == POOL_COMMAND else ()
    return Options(command=command, pairs=pairs, key=key, pool=pool, **fields)


def parsed(arguments):
    command = command_word(arguments)
    if command not in COMMAND_OPTIONS:
        return refused(command, "the command is one of %s, not %r" % (", ".join(COMMAND_OPTIONS), command))
    rest = list(arguments[1:])
    marker = end_of_options_index(rest)
    option_words, words = rest[:marker], tuple(rest[marker + 1:])
    problem = options_problem(command, option_words) or words_problem(command, words)
    if problem:
        return refused(command, problem)
    return CommandLine(assembled_options(command, option_words, words), schema.DONE)
