# 4. Files and naming

- **N-01 Files over 300 lines smell.** [signal] Explore decomposition.
- **N-02 More than 4 parameters smell.** [signal] Group the inputs in a record. *Why:* long parameter lists hide a missing type.
- **N-03 Long methods smell.** [signal] A method that needs scrolling is doing several things. *Why:* same signal as complexity, read from a different angle.
- **N-04 Names state the role.** [hard] A name says what the value is in domain terms (`ballSweep`, `resolvedState`), never `tmp`, `data`, `flag`, `mgr`, `helper`, `util`. If a name needs a comment to be understood, rename until it does not. *Why:* the code carries no explanatory comments, so the name is the documentation.
- **N-05 No abbreviations.** [hard] Names are spelt in full, units included (`degreesPerSecond`, not `degPerSec`). An acronym is allowed only after review, only when it shrinks a very long name, and only once it is on the project's allowed list. *Why:* an abbreviation saves the writer seconds and costs every reader a guess.
- **N-06 No magic numbers.** [hard] Every literal with meaning gets a named constant or a setting. *Why:* a bare `0.35` says nothing about what it tunes.
- **N-07 Say it once (DRY).** [judgement] When the same logic appears twice, extract a shared pure helper.
- **N-08 Keep it simple (KISS).** [judgement]
