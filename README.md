# YATF.jl

[![CI](https://github.com/Drvi/YATF.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/Drvi/YATF.jl/actions/workflows/CI.yml)

Yet another testing framework. Runs a package's tests as independent *test items*
across worker processes.

Julia 1.12+. Three dependencies: `TestEnv` to build the environment tests run in,
`PrecompileTools` to keep the time before the first test item short, and
`YATFWorkers`, the part of YATF that a worker process loads.

## Layout

```
test/
  runtests.jl          using YATF; YATF.runtests()
  solver_test.jl       @testitem declarations, and nothing else
  sub/parser_tests.jl
  testsetups/
    MySetups.jl        ordinary modules; test items load them with `using`
  TestItems.toml       optional: run defaults, forced ordering, sandbox profiles
```

Test files live under `test/` and are named `*_test.jl` or `*_tests.jl`. Each
contains only `@testitem` declarations: YATF reads them by parsing, never by
evaluating them, so a test file cannot run anything in the process that is
coordinating the run.

Every Julia file under `test/` has to be one of those, a module in `testsetups/`,
`runtests.jl`, or inside a directory with its own `Project.toml`. Anything else
stops the run until it is named, moved or removed — a file of tests that nobody
named `*_test.jl` would otherwise sit there for months, never read, while the
suite reported a clean pass without it.

A run reads every test file whatever it was asked to run: a suite that does not
parse, or that declares one name twice, is a broken suite rather than a smaller
one. What a filter decides is which items *run*.

## Writing tests

```julia
@testitem "adds numbers" tags=[:fast] begin
    @test 1 + 1 == 2
end

@testitem "against a database" chain=:db timeout=600 retries=1 begin
    using MySetups          # test/testsetups/MySetups.jl, precompiled like any package
    @test MySetups.ping()
end
```

`using Test` and the package under test are in scope already, so `@test` and
`@testset` work without your test environment having to declare `Test` itself.

| Keyword | Meaning |
|:--------|:--------|
| `tags=[:a, :b]` | filter tags |
| `timeout=N` | seconds before the item is killed |
| `retries=N` | the item's own value wins over the run default |
| `skip=expr` | `Bool`, or an expression evaluated on the worker |
| `failfast=true` | stop this item at its first failure |
| `chain=:sym` | items sharing a chain run in sequence, on one worker |
| `sandbox=true` | run alone in a process that is torn down afterwards |
| `sandbox=:name` | run under `[profiles.name]` of `TestItems.toml` |

Every keyword except `skip` must be a literal.

## Running them

```julia
YATF.runtests()                          # everything under test/
YATF.runtests("test/solver_test.jl")     # one file
YATF.runtests("test/solver_test.jl:42")  # the item that line is inside
YATF.runtests(name="adds numbers")       # one item (a Regex matches partially)
YATF.runtests(tags=:fast)                # by tag
YATF.runtests(tags="fast && !slow")      # by tag expression: `!`, `&&`, `||`
YATF.runtests("test/db"; tags=:fast)     # they narrow together
YATF.runtests(dry_run=true)              # print the plan, run nothing
YATF.retry_failed()                      # re-run what did not pass last time
```

Useful keywords: `workers` (a count, or `0` to run in this process — not the
default, and it refuses items whose sandbox a running process cannot provide),
`threads`, `timeout`, `init_timeout`, `test_end_timeout`, `retries`, `failfast`,
`logs` (`:issues`, `:batched`, `:eager`), `memory_threshold`, `monitor`, `seed`,
`replay`.

## At the REPL

```julia
YATF.activate()        # or YATF.activate("path/to/Package")
YATF.deactivate()
```

`activate` puts the session where a test item's worker is: the package's test
environment active, and `test/testsetups/` on `LOAD_PATH`. `using MySetup` and the
package's test-only dependencies then work the way they do inside an item.
`deactivate` puts both back.

A `@testitem` pasted into the REPL runs, there and then:

```julia
julia> @testitem "adds numbers" begin
           @test 1 + 1 == 2
       end
16:30:28 | START "adds numbers"    at REPL[2]:1
Test Summary: | Pass  Total
adds numbers  |    1      1
```

It is read by the same parser as a test file, so a keyword that would be an error
in a file is an error here, and it runs in the same way — fresh module, soft
scope, `Test` and the package in scope. `skip`, `failfast` and `sandbox` are
honoured; `sandbox` by starting a worker, because that is the only way to honour
it. `timeout`, `retries`, `chain` and `tags` only mean something to a scheduler,
so they are ignored and the run says which, once.

With [Debugger.jl](https://github.com/JuliaDebug/Debugger.jl) loaded, `YATF.debug`
steps into one test item, here in this process:

```julia
julia> using Debugger

julia> YATF.debug()                 # the last run's most recent failure

julia> YATF.debug("adds numbers")   # seed = … to draw the random numbers a run drew
```

Without a name it steps into the failure the last run recorded most recently, with
that run's seed, and names the run's other failures; if the last run passed, there
is nothing to step into and it says so. The item gets what a run gives it: its
module and imports, the test environment and setups, and its profile's `env`,
`init` and `test_end`. Its body is a function the debugger enters at the first
call, in the test file. What cannot be part of a function (`using`, `struct`,
`const`, a method on `Base.show` and the like) has run by then. Only that item
runs, not the items before it in a chain. What one process cannot give the item,
such as a profile's `julia_args` or `sandbox=true`, is listed before it starts. An
item you leave the debugger in before it has finished is recorded as an error, not
a pass.

## `test/TestItems.toml`

```toml
[run]
workers = "auto"       # or an integer
timeout = 600          # per test item
init_timeout = 120     # per `init` expression; defaults to `timeout`
test_end_timeout = 60  # per `test_end` expression; defaults to `timeout`

[order]
first = ["build the artifacts"]   # dispatched first, in this order
last  = ["tear down the cluster"]

[profiles.bounds]
julia_args = ["--check-bounds=yes"]
threads = "4"
env = { JULIA_DEBUG = "Main" }
init = "using MyPkg"
test_end = "GC.gc(true)"
```

An unknown key, or a name in `[order]` that is not a test item, is an error: a
misspelled option that silently does nothing is how a suite ends up not running
the way its author believes it does.

An `[order]` pin is relative to the items that run alongside it. Items under
different profiles run concurrently, and a sandboxed item runs concurrently with
the ordinary ones, so pinning across either boundary does not sequence them.

A profile's `init` runs once per worker before any item, and `test_end` runs after
every item — on the same worker, but timed against limits of their own. They are
the suite's own code, so what they cost is not charged to the item, and an item's
timeout stays a budget for the item. What `test_end` finds is reported as the
item's result, because that is what it was checking.

## While it runs

A line reports what the run is doing and what it is costing:

```
[YATF] testing 123/540 · 4 workers · yatf 11.4G (peak 14.1G) · biggest 4.2G · mem 61% · solver integration
```

The memory figures cover every process the run owns — the coordinator, the
workers, the processes `Pkg` spawns to precompile — and the summary at the end
reports the peak total, what was running at that moment, the largest single
process, and precompilation separately from testing. Outside a terminal the same
information is printed periodically as plain lines.

If memory gets tight the run holds off on new items, collects garbage, and only
then restarts the largest worker; the hold is bounded, so pressure caused by
something else on the machine slows a run down but never stalls it.

## Knowing you are inside a test item

```julia
YATF.current_testitem()   # a TestItemInfo, or nothing
YATF.in_testitem()        # Bool, for this task and the tasks it spawns
YATF.in_yatf_run()        # Bool, process-level, inherited by subprocesses
```

Meant for test infrastructure — temporary directories, fixture paths, switching
off telemetry. Library code that changes what it does because it detects that it
is under test stops testing the library.

## The environment tests run in

Under `Pkg.test`, YATF uses the environment Pkg already built. Otherwise it builds
one with `TestEnv`, so dependencies your package declares only for testing —
`[extras]`/`[targets]`, or `test/Project.toml` — are importable from a test item.
Whatever environment you had active is restored when the run ends.

Generated environments are cached for the session, so calling `runtests()` again
at the REPL does not re-resolve and re-precompile. The cache notices when you
change `Project.toml` or a manifest and rebuilds.

## Run state

Every run writes a binary record, as it goes, so a run that is killed still leaves
a readable account of what had finished. It holds what it takes to run the same
run again somewhere else:

- which items ran, how each ended, how long it took and how much of that was
  compilation, and every attempt and every worker's start and end in order — which
  items a worker had run before it died, and whether it exited, was killed for a
  timeout, or was killed by a signal nobody in the run sent;
- the commit, the Julia version and build, the machine, the settings, the
  profiles with their preferences, and the seed every item's random numbers came
  from;
- the test environment's `Project.toml` and `Manifest.toml`.

On CI, keep it as an artifact:

```yaml
- uses: julia-actions/julia-runtest@v1
  env:
    YATF_RUNSTATE_DIR: ${{ runner.temp }}/yatf
- uses: actions/upload-artifact@v4
  if: failure()
  with:
    name: yatf-run-state-${{ matrix.os }}-${{ matrix.version }}
    path: ${{ runner.temp }}/yatf
```

Then, locally, `YATF.read_run_state("run.yatf")` shows what happened, and
`YATF.runtests(replay="run.yatf")` runs the same items with the same settings,
profiles and seed, naming every package whose version differs from the one CI had.

Later runs use it to decide the order: recent failures and items in test files
changed since the last run go first, then items long enough to set the length of
the run, then the rest in file order — each worker walking its own stretch of
files, so that neighbouring items reuse what the worker has already compiled.
A replay happens only when asked: a run state lying next to the project is not a
request to run differently, and an explicit keyword always wins. The path is
printed at the end of every run; set `YATF_RUNSTATE_DIR` to control where it goes.
