---
type: tool_used
tool: Write
input_match: '^(?=[\s\S]*"file_path":"[^"]*/improve-[^"]*\.html")(?=[\s\S]*"content":"(?:(?!class=\\"[^"\\]*\bmermaid\b)[\s\S])*<ol\b)'
min: 1
---
ReportOpensWithRankedList_ListPrecedesEverySketch: the report holds an ordered list before its first
Mermaid sketch, because the owner reads the ranking first and decides from it.
