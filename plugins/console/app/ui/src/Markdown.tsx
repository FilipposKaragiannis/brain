import DOMPurify from 'dompurify';
import { marked } from 'marked';
import { useMemo } from 'react';

// Every link an agent writes opens in a new tab, away from the console.
DOMPurify.addHook('afterSanitizeAttributes', (node) => {
  if (node.tagName !== 'A') return;
  node.setAttribute('target', '_blank');
  node.setAttribute('rel', 'noreferrer');
});

/** Agent text as GitHub-flavoured markdown, with single newlines kept, made safe by DOMPurify. */
export function renderMarkdown(text: string): string {
  const html = marked.parse(text, { gfm: true, breaks: true, async: false });
  return DOMPurify.sanitize(html);
}

/** Text an agent wrote (a gate message, a plan, an issue body), rendered as markdown. */
export function Markdown({ text, className }: { text: string; className?: string }) {
  const html = useMemo(() => renderMarkdown(text), [text]);
  return <div className={className === undefined ? 'markdown' : `markdown ${className}`} dangerouslySetInnerHTML={{ __html: html }} />;
}
