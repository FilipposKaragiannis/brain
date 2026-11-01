#!/usr/bin/env python3
"""Fold each plugin's changelog fragments into a release.

Usage: release.py [--dry-run] [plugin ...]   (default: every plugin with fragments)
For each plugin, the highest bump among its fragments raises the version in plugin.source.json,
`## <version> (<YYYY-MM-DD>)` with the bullets (fragments in filename order) goes on top of
CHANGELOG.md (created with a `# <plugin>` heading when missing), the plugin's app packages take
the new version (tools/lib/packages.py), and the fragments are deleted.
Then tools/generate.sh renders the manifests and marketplaces once. Prints `<plugin> <old> ->
<new>` per plugin; --dry-run prints the same and each section, and writes nothing.
Exit 0 with "nothing to release" when no fragment is found. Exit 2, writing nothing, on a
malformed fragment, an unknown plugin, a version that is not major.minor.patch or an app package
whose version field is not where npm writes it.
Needs python3 >= 3.9 and nothing else.
"""
import argparse
import collections
import datetime
import glob
import json
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fragments  # noqa: E402
import packages  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
VERSION = re.compile(r"^(\d+)\.(\d+)\.(\d+)$")
FIRST_SECTION = re.compile(r"^## ", re.M)

Release = collections.namedtuple("Release", "folder name source old new section fragment_paths")


def read_text(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def write_text(path, content):
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)


def rel(path):
    return os.path.relpath(path, ROOT)


def source_path(folder):
    return os.path.join(folder, "plugin.source.json")


def fragment_paths(folder):
    return sorted(glob.glob(os.path.join(folder, "changelog.d", "*.md")))


def plugin_folders(names):
    if names:
        return [os.path.join(ROOT, "plugins", name) for name in names]
    return sorted(os.path.dirname(p) for p in glob.glob(source_path(os.path.join(ROOT, "plugins", "*"))))


def problems(names, folders):
    """Every reason the release cannot go ahead, empty when it can."""
    unknown = ["no plugin named %s" % name for name in names if not os.path.isfile(source_path(os.path.join(ROOT, "plugins", name)))]
    if unknown:
        return unknown
    found = []
    for folder in (f for f in folders if fragment_paths(f)):
        for path in fragment_paths(folder):
            reason = fragments.problem(read_text(path))
            if reason:
                found.append("%s: %s" % (rel(path), reason))
        version = json.loads(read_text(source_path(folder)))["version"]
        if not VERSION.match(version):
            found.append("%s: version '%s' is not major.minor.patch" % (rel(source_path(folder)), version))
        for path in packages.files(folder):
            if packages.stamped(path, version) is None:
                found.append("%s: no version field where npm writes it" % rel(path))
    return found


def raised(version, bump):
    major, minor, patch = (int(part) for part in VERSION.match(version).groups())
    if bump == "major":
        return "%d.0.0" % (major + 1)
    if bump == "minor":
        return "%d.%d.0" % (major, minor + 1)
    return "%d.%d.%d" % (major, minor, patch + 1)


def plan(folder, today):
    source = json.loads(read_text(source_path(folder)))
    paths = fragment_paths(folder)
    texts = [read_text(path) for path in paths]
    bump = max((fragments.bump(text) for text in texts), key=fragments.BUMPS.index)
    new = raised(source["version"], bump)
    section = "## %s (%s)\n\n%s\n" % (new, today, "\n".join(fragments.bullets(text) for text in texts))
    return Release(folder, source["name"], source, source["version"], new, section, paths)


def with_section(changelog, name, section):
    if changelog is None:
        return "# %s\n\n%s" % (name, section)
    first = FIRST_SECTION.search(changelog)
    if first is None:
        return changelog.rstrip("\n") + "\n\n" + section
    return changelog[:first.start()] + section + "\n" + changelog[first.start():]


def apply(release):
    source = dict(release.source, version=release.new)
    write_text(source_path(release.folder), json.dumps(source, indent=2, ensure_ascii=False) + "\n")
    changelog_path = os.path.join(release.folder, "CHANGELOG.md")
    changelog = read_text(changelog_path) if os.path.exists(changelog_path) else None
    write_text(changelog_path, with_section(changelog, release.name, release.section))
    for path in packages.files(release.folder):
        write_text(path, packages.stamped(path, release.new))
    for path in release.fragment_paths:
        os.remove(path)
    fragments_folder = os.path.join(release.folder, "changelog.d")
    if not os.listdir(fragments_folder):
        os.rmdir(fragments_folder)


def generate():
    done = subprocess.run([os.path.join(ROOT, "tools", "generate.sh")], capture_output=True, text=True)
    if done.returncode != 0:
        sys.stderr.write(done.stdout + done.stderr)
        print("release: tools/generate.sh failed (above): the sources are released, the generated files are not", file=sys.stderr)
    return done.returncode


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("plugins", nargs="*")
    args = parser.parse_args()
    folders = plugin_folders(args.plugins)
    refusals = problems(args.plugins, folders)
    if refusals:
        for refusal in refusals:
            print("release: " + refusal, file=sys.stderr)
        return 2
    today = datetime.date.today().isoformat()
    releases = [plan(folder, today) for folder in folders if fragment_paths(folder)]
    if not releases:
        print("release: nothing to release")
        return 0
    for release in releases:
        print("%s %s -> %s" % (release.name, release.old, release.new))
        if args.dry_run:
            print("\n" + release.section)
    if args.dry_run:
        return 0
    for release in releases:
        apply(release)
    return 1 if generate() else 0


if __name__ == "__main__":
    sys.exit(main())
