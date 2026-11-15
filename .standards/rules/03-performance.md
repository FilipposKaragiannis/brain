# 1c. Performance

- **P-01 Measure before optimising.** [judgement] *Why:* a guess at the hot spot is usually wrong.
- **P-02 Hot paths are declared, and zero-allocation there.** [hard] A project names its hot paths (by folder or marker). Inside them no allocation per step, no LINQ, no interface enumeration, no closures. Outside them readability wins. *Why:* the rule is strict only where it pays; everywhere else it would cost clarity for nothing.
