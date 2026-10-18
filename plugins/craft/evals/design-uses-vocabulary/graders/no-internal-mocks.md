---
type: llm
---
The answer does not propose testing by mocking the module's own internals; tests go through the module's interface, with a fake only for the remote rate service.
