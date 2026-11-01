#!/usr/bin/env python3
"""The npm package versions of a plugin's app follow the plugin's version.

A plugin with an app (plugins/<plugin>/app/package.json, console today) runs the version its
package.json names, while the hosts cache the plugin by the version in plugin.source.json. Both
must agree: tools/release.sh stamps the plugin's version into app/package.json,
app/*/package.json and the package-lock.json beside each (the top-level `version` and that of
`packages[""]`), and lint fails when one differs.

Usage: packages.py [ROOT]
  lint every plugin under ROOT (default: this repo): each package version equals the plugin's.
  Prints one line per finding, exits 1 on any.
Needs python3 >= 3.9 and nothing else.
"""
import glob
import json
import os
import re
import sys

# The text is edited in place so npm's own formatting stays: the top-level key sits at two spaces,
# and packages[""] at four with its keys at six.
TOP_VERSION = re.compile(r'^(  "version": ")[^"\n]*(")', re.M)
ROOT_PACKAGE_VERSION = re.compile(r'^(    "": \{\n(?:      .*\n)*?      "version": ")[^"\n]*(")', re.M)


def read_text(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def files(folder):
    """The package.json and package-lock.json files of the plugin's app, in a stable order."""
    manifests = glob.glob(os.path.join(folder, "app", "package.json")) + glob.glob(os.path.join(folder, "app", "*", "package.json"))
    found = []
    for manifest in sorted(m for m in manifests if "node_modules" not in m):
        found.append(manifest)
        lock = os.path.join(os.path.dirname(manifest), "package-lock.json")
        if os.path.exists(lock):
            found.append(lock)
    return found


def versions(path):
    """Every version in the file that must equal the plugin's."""
    data = json.loads(read_text(path))
    if path.endswith("package-lock.json"):
        return [data.get("version"), data.get("packages", {}).get("", {}).get("version")]
    return [data.get("version")]


def stamped(path, version):
    """The file's text with the plugin's version in place, or None when its shape is unknown."""
    text = read_text(path)
    text, count = TOP_VERSION.subn(r"\g<1>%s\g<2>" % version, text, count=1)
    if path.endswith("package-lock.json"):
        text, root_count = ROOT_PACKAGE_VERSION.subn(r"\g<1>%s\g<2>" % version, text, count=1)
        count += root_count
    expected = 2 if path.endswith("package-lock.json") else 1
    if count != expected:
        return None
    return text


def lint(root):
    findings = []
    for source in sorted(glob.glob(os.path.join(root, "plugins", "*", "plugin.source.json"))):
        version = json.loads(read_text(source))["version"]
        for path in files(os.path.dirname(source)):
            if any(found != version for found in versions(path)):
                findings.append("%s: version %s, the plugin is %s" % (
                    os.path.relpath(path, root), " and ".join(str(v) for v in versions(path)), version))
    return findings


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    findings = lint(root)
    for finding in findings:
        print("lint: " + finding)
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
