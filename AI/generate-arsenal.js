#!/usr/bin/env node
// Regenerates the SKILLS data array in .scratch/skills-arsenal.html from
// SKILL.md frontmatter across AI/skills and plugins/*/skills. Source of
// truth is always the SKILL.md files — never hand-edit the array directly.

const fs = require("fs");
const path = require("path");

const ROOT = path.join(__dirname, "..");
const HTML_PATH = path.join(ROOT, ".scratch", "skills-arsenal.html");
const START_MARKER = "// AUTO-GENERATED:SKILLS:START — do not hand-edit; run node AI/generate-arsenal.js";
const END_MARKER = "// AUTO-GENERATED:SKILLS:END";

const SOURCES = [
  { key: "standalone", label: "Standalone", dir: path.join(ROOT, "AI/skills") },
  { key: "workstream", label: "Workstream", dir: path.join(ROOT, "plugins/workstream/skills") },
  { key: "sdd", label: "Spec-Driven Development", dir: path.join(ROOT, "plugins/spec-driven-development/skills") },
];

// Pipeline position isn't derivable from workstream's directory names (unlike
// SDD's numeric prefixes) — this is hand-maintained design knowledge, not data.
const WORKSTREAM_ORDER = {
  init: 0,
  grill: 1,
  "to-epic": 2,
  "to-task": 2,
  "to-subissues": 3,
  ship: 4,
  "to-pr": 5,
};

function parseFrontmatter(content) {
  const lines = content.split("\n");
  if (lines[0].trim() !== "---") return {};
  let end = -1;
  for (let i = 1; i < lines.length; i++) {
    if (lines[i].trim() === "---") { end = i; break; }
  }
  if (end === -1) return {};

  const fm = lines.slice(1, end);
  const obj = {};
  let i = 0;
  while (i < fm.length) {
    const m = fm[i].match(/^([A-Za-z0-9_-]+):\s*(.*)$/);
    if (!m) { i++; continue; }
    const key = m[1];
    let val = m[2].trim();

    if (val === ">" || val === "|") {
      const folded = val === ">";
      const collected = [];
      i++;
      while (i < fm.length && (fm[i].trim() === "" || /^\s/.test(fm[i]))) {
        collected.push(fm[i].trim());
        i++;
      }
      obj[key] = folded ? collected.filter(Boolean).join(" ") : collected.join("\n");
      continue;
    }

    if ((val.startsWith('"') && val.endsWith('"')) || (val.startsWith("'") && val.endsWith("'"))) {
      val = val.slice(1, -1);
    }
    obj[key] = val;
    i++;
  }
  return obj;
}

function deriveBlurb(description) {
  const clean = description.replace(/\s+/g, " ").trim();
  const firstSentence = clean.match(/^(.*?[.!?])(\s|$)/);
  if (firstSentence && firstSentence[1].length <= 140) return firstSentence[1];
  if (clean.length <= 110) return clean;
  const cut = clean.slice(0, 110);
  const lastSpace = cut.lastIndexOf(" ");
  return (lastSpace > 60 ? cut.slice(0, lastSpace) : cut) + "…";
}

function collectSkills(source) {
  if (!fs.existsSync(source.dir)) return [];
  const dirs = fs.readdirSync(source.dir, { withFileTypes: true })
    .filter(d => d.isDirectory())
    .map(d => d.name)
    .sort();

  const skills = [];
  for (const dirName of dirs) {
    const skillPath = path.join(source.dir, dirName, "SKILL.md");
    if (!fs.existsSync(skillPath)) continue;

    const fm = parseFrontmatter(fs.readFileSync(skillPath, "utf8"));
    if (!fm.description) continue;

    const id = fm.name || dirName;
    const invocation = String(fm["disable-model-invocation"]).toLowerCase() === "true" ? "manual" : "auto";

    let order;
    if (source.key === "sdd") {
      const numMatch = dirName.match(/^(\d+)-/);
      if (numMatch) order = parseInt(numMatch[1], 10);
      else if (dirName === "init") order = 0;
    } else if (source.key === "workstream" && Object.prototype.hasOwnProperty.call(WORKSTREAM_ORDER, id)) {
      order = WORKSTREAM_ORDER[id];
    }

    const skill = {
      id,
      source: source.key,
      blurb: deriveBlurb(fm.description),
      detail: fm.description.replace(/\s+/g, " ").trim(),
      invocation,
    };
    if (order !== undefined) skill.order = order;
    skills.push(skill);
  }

  skills.sort((a, b) => {
    if (a.order !== undefined && b.order !== undefined) return a.order - b.order || a.id.localeCompare(b.id);
    if (a.order !== undefined) return -1;
    if (b.order !== undefined) return 1;
    return a.id.localeCompare(b.id);
  });
  return skills;
}

function skillLiteral(s) {
  const parts = [
    `id:${JSON.stringify(s.id)}`,
    `source:${JSON.stringify(s.source)}`,
    `blurb:${JSON.stringify(s.blurb)}`,
    `detail:${JSON.stringify(s.detail)}`,
    `invocation:${JSON.stringify(s.invocation)}`,
  ];
  if (s.order !== undefined) parts.push(`order:${s.order}`);
  return `    { ${parts.join(", ")} },`;
}

function main() {
  const allBySource = SOURCES.map(source => ({ source, skills: collectSkills(source) }));

  const body = allBySource.map(({ source, skills }) =>
    [`    // ${source.label}`, ...skills.map(skillLiteral)].join("\n")
  ).join("\n\n");

  const html = fs.readFileSync(HTML_PATH, "utf8");
  const startIdx = html.indexOf(START_MARKER);
  const endIdx = html.indexOf(END_MARKER);
  if (startIdx === -1 || endIdx === -1) {
    throw new Error(`Markers not found in ${HTML_PATH} — did the file structure change?`);
  }

  const before = html.slice(0, startIdx + START_MARKER.length);
  const after = html.slice(endIdx);
  const newHtml = `${before}\n  const SKILLS = [\n${body}\n  ];\n  ${after}`;

  if (newHtml === html) {
    console.log("arsenal: no change");
    return;
  }
  fs.writeFileSync(HTML_PATH, newHtml);

  const total = allBySource.reduce((n, g) => n + g.skills.length, 0);
  const auto = allBySource.reduce((n, g) => n + g.skills.filter(s => s.invocation === "auto").length, 0);
  console.log(`arsenal: regenerated (${total} skills, ${auto} auto-invoked, ${total - auto} manual)`);
}

main();
