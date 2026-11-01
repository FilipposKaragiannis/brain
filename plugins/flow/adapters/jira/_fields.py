"""Jira's field values for _jira.py: custom fields named in jira.fields.* by id or by name, and the
Atlassian Document Format of descriptions and comments, to and from plain text."""
import os

from _http import call, expect, fail


def setting(name, default=""):
    return os.environ.get("FLOW_JIRA_" + name) or default


def custom_fields():
    wanted = {role: setting(role.upper() + "_FIELD") for role in ("size", "area")}
    if not any(wanted.values()):
        return {}
    status, known = call("GET", "/rest/api/3/field")
    expect(status, known, "read the Jira fields")
    found = {}
    for role, name in wanted.items():
        match = next((f for f in known if name and name in (f.get("id"), f.get("name"))), None)
        if name and not match:
            fail("no Jira field named %s (jira.fields.%s)" % (name, role))
        if match:
            found[role] = {"id": match["id"], "type": (match.get("schema") or {}).get("type", "string")}
    return found


def field_text(value):
    if isinstance(value, dict):
        return str(value.get("value") or value.get("name") or "")
    if isinstance(value, list):
        return field_text(value[0]) if value else ""
    if isinstance(value, float) and value.is_integer():
        return str(int(value))
    return "" if value is None else str(value)


def field_input(field, text):
    return {"value": text} if field["type"] == "option" else text


# --- descriptions and comments are Atlassian Document Format


def to_document(text):
    paragraphs = []
    for block in text.strip("\n").split("\n\n"):
        content = []
        for line in block.split("\n"):
            if content:
                content.append({"type": "hardBreak"})
            if line:
                content.append({"type": "text", "text": line})
        paragraphs.append({"type": "paragraph", "content": content})
    return {"type": "doc", "version": 1, "content": paragraphs}


def from_document(node):
    if not isinstance(node, dict):
        return node or ""
    kind, children = node.get("type"), node.get("content") or []
    if kind == "text":
        return linked_text(node)
    if kind in ("inlineCard", "blockCard", "embedCard"):
        return (node.get("attrs") or {}).get("url", "")
    if kind == "hardBreak":
        return "\n"
    if kind in ("paragraph", "heading", "codeBlock"):
        text = "".join(from_document(c) for c in children)
        if kind == "heading":
            return "#" * (node.get("attrs") or {}).get("level", 1) + " " + text
        return "```\n%s\n```" % text if kind == "codeBlock" else text
    if kind in ("bulletList", "orderedList"):
        return "\n".join("- " + from_document(c) for c in children)
    if kind == "listItem":
        return "\n".join(from_document(c) for c in children)
    return "\n\n".join(from_document(c) for c in children)


def linked_text(node):
    text = node.get("text", "")
    href = next(((m.get("attrs") or {}).get("href", "") for m in node.get("marks") or [] if m.get("type") == "link"), "")
    return "[%s](%s)" % (text, href) if href and href != text else text
