# HTML Report Format

The architectural review is rendered as a single self-contained HTML file in the OS temp directory. Tailwind and Mermaid both come from CDNs. Mermaid draws the sketches. The owner reads the page top to bottom in a few minutes: a ranked list first, then one card per candidate, each with one sketch.

## Scaffold

```html
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <title>Architecture review — {{repo name}}</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <script type="module">
      import mermaid from "https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs";
      mermaid.initialize({ startOnLoad: true, theme: "neutral", securityLevel: "loose" });
    </script>
  </head>
  <body class="bg-stone-50 text-slate-900 font-sans">
    <main class="max-w-5xl mx-auto px-6 py-12 space-y-12">
      <header>...</header>
      <section id="ranking">...</section>
      <section id="candidates" class="space-y-10">...</section>
    </main>
  </body>
</html>
```

## Header

Repo name, date, and a compact legend: box = module, dashed line = seam, red arrow = leakage, thick dark box = deep module. No introduction paragraph — straight into the ranked list.

## Ranked list

The page opens with the candidates ranked, before any sketch: an `<ol>`, one line per candidate, best first. Each line holds the candidate's name as an anchor link to its card, its strength and the rules it serves. Under the list, one line: **Top recommendation:** the first candidate and why it goes first.

## Candidate card

The sketch carries the weight. Prose is sparse, plain, and uses the glossary terms ([codebase-design](../codebase-design/SKILL.md)) without ceremony.

Each candidate is one `<article>` that holds these fields, in this order, and nothing else:

- **Verdict** — one line: the strength badge (`Strong` = emerald, `Worth exploring` = amber, `Speculative` = slate), the candidate's name (e.g. "Collapse the Order intake pipeline") and why it is worth doing, in a clause.
- **Sketch** — one before and after, side by side. See below.
- **Problem** — one sentence. What hurts.
- **Solution** — one sentence. What changes.
- **Gain** — one line: the locality and leverage won, and how the tests improve.
- **Rules** — the standards ids this deepening serves, and any it strains.
- **Files** — the modules involved, monospaced, `font-mono text-sm`.
- **ADR conflict** — only when the friction is real enough to reopen an ADR: one line in an amber-tinted box naming it.

No paragraphs of explanation. If the sketch needs a paragraph to be understood, redraw the sketch.

## Sketch

One sketch per candidate: the before and the after side by side, in the simplest form that makes the point.

The default is a Mermaid `flowchart` per side: modules as boxes, calls as arrows, the leaking edges red and the deep module in the after drawn as one thick dark box. Wrap each side in a Tailwind-styled card.

```html
<div class="rounded-lg border border-slate-200 bg-white p-4">
  <pre class="mermaid">
    flowchart LR
      A[Order intake] --> B[Validation]
      B --> C[Order storage]
      C -.leak.-> D[Pricing]
      classDef leak stroke:#dc2626,stroke-width:2px;
      class C,D leak
  </pre>
</div>
```

Another form is allowed only when a flowchart cannot make the point. A Mermaid `sequenceDiagram` fits when the friction is the number of round trips ("before: 6 calls; after: 1").

Every sketch keeps these rules:

- A box is labelled with what the reader knows it as: the module or concept in plain words. Variable, field, function and class names stay out; the file names go in **Files**.
- About 20 arrows at most across the before and the after. Past that, merge boxes or drop the minor calls.
- One line under the sketch says what it leaves out (e.g. "Left out: logging and the config read").

## Style guidance

- Lean editorial, not corporate-dashboard. Generous whitespace. Serif optional for headings (`font-serif` works well with stone/slate).
- Colour sparingly: one accent (emerald or indigo) plus red for leakage and amber for warnings.
- Keep sketches ~320px tall so before/after sits comfortably side by side without scrolling.
- The only scripts are the Tailwind CDN and the Mermaid ESM import. The report is otherwise static — no app code, no interactivity beyond Mermaid's own rendering.

## Tone

Plain English, concise — but the architectural nouns and verbs come straight from [codebase-design](../codebase-design/SKILL.md). Concision is not an excuse to drift.

**Use exactly:** module, interface, implementation, depth, deep, shallow, seam, adapter, leverage, locality.

**Never substitute:** component, service, unit (for module) · API, signature (for interface) · boundary (for seam) · layer, wrapper (for module, when you mean module).

**Phrasings that fit the style:**

- "Order intake module is shallow — interface nearly matches the implementation."
- "Pricing leaks across the seam."
- "Deepen: one interface, one place to test."
- "Two adapters justify the seam: HTTP in prod, in-memory in tests."

**The gain line** names the gain in glossary terms: *"locality: bugs concentrate in one module"*, *"leverage: one interface, N call sites"*, *"interface shrinks; implementation absorbs the wrappers"*. Don't write *"easier to maintain"* or *"cleaner code"* — those terms aren't in the glossary and don't earn their place.

No hedging, no throat-clearing, no "it's worth noting that…". If a sentence could be a bullet, make it a bullet. If a bullet could be cut, cut it. If a term isn't in [codebase-design](../codebase-design/SKILL.md), reach for one that is before inventing a new one.
