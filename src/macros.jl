"""
    @testitem "name" [kwargs...] begin
        # tests
    end

Declare an independently runnable group of tests.

`YATF.runtests()` finds test items by parsing test files and runs each body in a
fresh module on a worker process. Evaluating the macro itself — pasting an item
into the REPL, or `include`ing its file — runs that one item the same way in this
session, or on a worker of its own when it is sandboxed.

Keyword arguments must be literals, except `skip`, which may be any expression and
is evaluated on the worker.

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
macro testitem(args...)
    # The call goes to `run_interactive` whole, to be read by the scanner's own
    # parser: a pasted item means exactly what the same item means in a file.
    call = Expr(:macrocall, Symbol("@testitem"), __source__, args...)
    return :($(run_interactive)($(QuoteNode(call)), $(QuoteNode(__source__))))
end
