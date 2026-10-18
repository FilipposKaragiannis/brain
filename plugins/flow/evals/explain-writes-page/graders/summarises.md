---
type: regex
pattern: "<(?:html|head|body|div|section|svg|h[1-6])\\b|```html"
flags: "i"
match: not_contains
target: last_message
---
The final message does not paste the explain page: no HTML from it.
