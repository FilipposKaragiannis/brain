# Appendix A. C#

- **CS-01** `sealed` and `internal` by default. `public` only across an assembly boundary.
- **CS-02** `var` preferred. Private fields `_camelCase`, constants `PascalCase`, interfaces `IPascalCase`.
- **CS-03** Nullable reference types enabled everywhere.
- **CS-04** Expression bodies only for single-line returns; everything else is a block body.
- **CS-05** Max line length 200.
- **CS-06** No `#region`.
- **CS-07** `readonly record struct` / `readonly struct` for values, `sealed record` for immutable data and configuration, `with` for copies.
- **CS-08** Hot-path values are `readonly struct` passed `in`; storage is `T[]`, surface is `ReadOnlySpan<T>`, iteration is an index `for`.
- **CS-09** Never `.Result`, `.Wait()`, `.GetAwaiter().GetResult()`.
- **CS-10** Tests: NUnit or xUnit with FluentAssertions; because-strings on every assertion; `[TestCase]` for genuine data variants.
- **CS-11** Doc comments are `///`, on public APIs and boundaries only: above `public` declarations and on `interface` and `enum` members.
- **CS-12** `.editorconfig` severities drive the Roslyn style and usage analyzers; `dotnet format` is the formatter.
