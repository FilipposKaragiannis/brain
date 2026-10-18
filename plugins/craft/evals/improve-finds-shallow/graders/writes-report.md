---
type: tool_used
tool: Write
input_match: '^(?=.*"file_path":"[^"]*/improve-[^"]*\.html")(?=.*order_)(?=.*[Tt]op [Rr]ecommendation)(?=.*(?:D-0[1-9]|S-0[1-9]|T-12))'
min: 1
---
The skill writes its HTML report: a Write call to an improve-*.html file whose content covers the
order_* modules, cites the rules served and ends with the top recommendation. The report goes to
$TMPDIR, outside the run directory a file_exists grader sees, so the trace is graded instead.
