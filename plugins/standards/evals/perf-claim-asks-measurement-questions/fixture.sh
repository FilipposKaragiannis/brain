#!/bin/sh
# Builds a repo whose feature branch drops the LINQ from a declared hot path, committed with the
# message given as $1, so the claim cases differ only in what the commit claims.
set -e
commit_message="${1:?the feature commit message}"
git init -q -b main .
git config user.email eval@example.com
git config user.name eval
mkdir -p src/Simulation
cat > AGENTS.md <<'BLOCK'
# Project

Hot paths: everything under `src/Simulation/` runs once per tick.

<!-- standards:begin v0.1.0 -->
# Coding standards (standards plugin v0.1.0)
Cite rules by id.

## Hard rules (a breach blocks)
- P-02 Hot paths are declared, and zero-allocation there.
- N-06 No magic numbers.

## Judgement rules
- P-01 Measure before optimising.

## Code Review Rules
Review the touched code only. Cite every finding by rule id, file and line. A broken hard
rule is P0 and blocks. A crossed signal with no explanation is P1 and blocks. A judgement
disagreement is P2, a comment.
<!-- standards:end -->
BLOCK
cat > src/Simulation/Swarm.cs <<'CS'
using System.Linq;

public sealed class Swarm
{
    private readonly double[] _speeds;

    public Swarm(double[] speeds) { _speeds = speeds; }

    public double Step() => _speeds.Where(speed => speed > 0d).Sum();
}
CS
git add -A
git commit -qm "chore: initial"
git switch -q -c feature
cat > src/Simulation/Swarm.cs <<'CS'
public sealed class Swarm
{
    private readonly double[] _speeds;

    public Swarm(double[] speeds) { _speeds = speeds; }

    public double Step()
    {
        var total = 0d;
        foreach (var speed in _speeds)
        {
            if (speed > 0d) total += speed;
        }
        return total;
    }
}
CS
git add -A
git commit -qm "$commit_message"
