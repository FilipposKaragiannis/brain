---
type: llm
---
The answer proposes a small interface for the shipping cost module with the pricing logic as a pure core that takes the rate table as data, puts the remote rate service behind a seam (a port with a production adapter and a test adapter or fake), and cites at least one standards rule id for the shape. It does not propose a large interface or mock the module's own internals.
