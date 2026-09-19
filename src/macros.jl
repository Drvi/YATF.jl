"""
    @testitem "name" [kwargs...] begin
        # tests
    end

Declare an independently runnable group of tests.

A test item is never expanded by the Julia compiler: `YATF` reads test files by
parsing them, and evaluates the body inside a fresh module on a worker process.
Expanding this macro therefore means a test file was `include`d directly, which
is an error — run the tests with `YATF.runtests()` instead.

Keyword arguments must be literals, with the single exception of `skip`, which
may be any expression and is evaluated on the worker.

| Keyword | Meaning |
|:--------|:--------|
| `tags=[:a, :b]` | tags used for filtering |
| `timeout=N` | seconds before the item is killed; overrides the run default |
| `retries=N` | overrides the run default; a chain retries from its first item |
| `skip=expr` | `Bool`, or an expression evaluated on the worker before the body |
| `failfast=true` | stop this item at its first failure |
| `chain=:sym` | items sharing a chain run in sequence on one worker |
| `sandbox=true` | run alone in a process that is torn down afterwards |
| `sandbox=:profile` | run in the pool for `[profiles.profile]` of `TestItems.toml` |
"""
# Expanding this macro means the item was evaluated rather than scanned: pasted
# into a REPL, or in a file somebody `include`d. Both want the same thing — run
# this one item, here, with as much of a run around it as one process can provide.
# The whole call is handed to `run_interactive`, which reads it with the scanner's
# own parser, so a pasted item means exactly what the same item means in a file.
macro testitem(args...)
    call = Expr(:macrocall, Symbol("@testitem"), __source__, args...)
    return :($(run_interactive)($(QuoteNode(call)), $(QuoteNode(__source__))))
end
