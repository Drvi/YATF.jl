# YATF.jl

[![CI](https://github.com/Drvi/YATF.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/Drvi/YATF.jl/actions/workflows/CI.yml)

Yet another testing framework. YATF runs a package's tests as independent *test
items* spread over worker processes, and plans each run from what the runs before
it recorded: what failed last time runs first, the longest items start early, and
the rest go in file order, so that a worker reuses the code it has already
compiled. Every run leaves a record that is enough to run it again elsewhere.

Julia 1.12+. Beyond the standard library it needs three packages: `TestEnv` to
build the environment tests run in, `PrecompileTools` to keep the wait before the
first test item short, and `YATFWorkers`, the part of YATF a worker process loads.
With [Debugger.jl](https://github.com/JuliaDebug/Debugger.jl) loaded, it can step
into a test item.

## Quick start

Add YATF to the package's test dependencies (`test/Project.toml`, or `[extras]`
and `[targets]` in `Project.toml`), and make `test/runtests.jl`:

```julia
using YATF
YATF.runtests()
```

Then write test items in files named `*_test.jl` or `*_tests.jl`:

```julia
# test/arithmetic_tests.jl
@testitem "adds numbers" begin
    @test 1 + 1 == 2
end
```

`Pkg.test()` runs them as usual. At the REPL, `YATF.runtests()` runs the suite of
the active project, building its test environment itself.

## Test files

```
test/
  runtests.jl          using YATF; YATF.runtests()
  solver_test.jl       @testitem declarations, and nothing else
  sub/parser_tests.jl
  testsetups/
    MySetups.jl        ordinary modules that test items load with `using`
  TestItems.toml       optional: run settings, forced ordering, sandbox profiles
```

A test file contains only `@testitem` declarations. YATF reads test files by
parsing them, never by evaluating them, so a test file cannot run anything in the
process that is coordinating the run.

Every Julia file under `test/` has to be a test file, a module in `testsetups/`,
or `runtests.jl`. Files inside a directory with its own `Project.toml` are left
alone, and so are hidden (dot-prefixed) files and directories. Anything else stops
the run until it is named, moved or removed: a file of tests that nobody named
`*_test.jl` would otherwise sit there for months, never read, while the suite
reported a clean pass without it.

A run reads every test file whatever it was asked to run: a suite that does not
parse, or that declares one name twice, is a broken suite rather than a smaller
one. What a filter decides is which items *run*.

## Writing test items

```julia
@testitem "adds numbers" tags=[:fast] begin
    @test 1 + 1 == 2
end

@testitem "against a database" chain=:db timeout=600 retries=1 begin
    using MySetups          # test/testsetups/MySetups.jl
    @test MySetups.ping()
end
```

`Test` and the package under test are in scope already, so `@test` and `@testset`
work without the test environment having to declare `Test` itself.

| Keyword | Meaning |
|:--------|:--------|
| `tags=[:a, :b]` | tags to filter by |
| `timeout=N` | seconds before the item is killed |
| `retries=N` | attempts after a failed one; the item's value wins over the run's |
| `skip=expr` | `true`, or an expression evaluated on the worker |
| `failfast=true` | stop this item at its first failure |
| `chain=:sym` | items sharing a chain run in sequence, on one worker |
| `sandbox=true` | run alone in a process that is torn down afterwards (not with `chain`) |
| `sandbox=:name` | run under `[profiles.name]` of `TestItems.toml` |

Every keyword except `skip` must be a literal.

An item's body runs at the top level of a fresh module, with the REPL's soft scope:
`x = 1` followed by a loop that updates `x` works as it does at the prompt. As in a
script, its variables are untyped globals, so code whose speed or allocations a
test measures belongs inside a function or a `let`. When the item ends, what its
globals refer to is let go, so a large fixture does not stay in the worker; a
`const` keeps its value for as long as the worker lives.

### Test setups

Code that items share goes in a module under `test/testsetups/`, as `Name.jl` or
`Name/src/Name.jl`:

```julia
# test/testsetups/MySetups.jl
module MySetups
export ping
ping() = true
end
```

An item loads it with `using MySetups` or `import MySetups`, which is also how
YATF knows which setups an item needs. Before any worker starts, it precompiles
each of them once, so that the workers do not all compile the same module at the
same moment. A setup is precompiled like any package: its top-level code runs when
it is compiled, and what has to happen in every process goes in its `__init__`.

A setup without a project of its own has no UUID, and Julia keeps a single cache
file for it per depot: another checkout with a setup of the same name, or a profile
with other Julia flags, compiles over it. `YATF.setups_to_packages()` makes every
setup a package, after which each checkout and each set of flags keeps its own
cache. `Name.jl` moves to `Name/src/Name.jl`, beside a `Name/Project.toml` with a
UUID and the packages the setup imports. In a moved setup, `@__DIR__` becomes
`pkgdir(MyPkg, "test", "testsetups")`, which still names that directory when the
code is pasted at the REPL. A package can import only what its project lists, so
run it again after a setup starts importing something new.

## Running tests

```julia
YATF.runtests()                          # everything under test/
YATF.runtests("test/solver_test.jl")     # one file
YATF.runtests("test/solver_test.jl:42")  # the item that line is inside
YATF.runtests(name="adds numbers")       # one item; a Regex matches part of a name
YATF.runtests(tags=:fast)                # by tag
YATF.runtests(tags="fast && !slow")      # by tag expression: `!`, `&&`, `||`
YATF.runtests("test/db"; tags=:fast)     # they narrow together
YATF.runtests(dry_run=true)              # print the plan, run nothing
YATF.runtestsf()                         # run again what did not pass last time
YATF.chores()                            # what the suite needs tidying; fix=true tidies it
```

A tag expression is names joined with `&&` and `||`, each optionally negated with
`!`; `&&` binds tighter, and there are no parentheses. `name` also takes a set of
names.

`YATF.chores()` reports what a suite needs looking after: anything a run would
refuse to start on, in the test items or in `TestItems.toml`; setups that are not
packages yet, or whose imports have outgrown their `[deps]`; and this machine's
run states older than a week, apart from the newest five, whose durations order
the next run. Another machine's run state, a downloaded CI artifact say, is never
deleted. `YATF.chores(fix = true)` makes the setups packages and deletes those run
states; the rest needs a person. It returns `true` when nothing is left to do.

A run that cannot start throws before any item runs: `YATF.ScanFailure` when test
files cannot be read as a suite, `YATF.NoTestsError` when there is nothing to run,
and `YATF.ConfigError` when a setting, profile or test setup cannot be used as
given.

| Keyword | Meaning |
|:--------|:--------|
| `workers` | how many worker processes: a number, or `"auto"` (the default: as many as the CPUs allow at `threads` each and memory allows at 4 GiB each, at most 8) |
| `threads` | each worker's `--threads`; `"2,1"` by default |
| `timeout` | seconds an item may run; 1800 by default |
| `init_timeout`, `test_end_timeout` | the same for a profile's `init` and `test_end`; `timeout` by default |
| `retries` | attempts after a failed one; 0 by default |
| `failfast` | stop the run once an item fails |
| `item_failfast` | stop an item at its first failure; `failfast` by default |
| `logs` | whose output to print: `:issues`, only items that did not pass (the default); `:batched`, every item's once it ends; `:eager`, as it is written (the default for an interactive run with one worker) |
| `verbose` | print every item's results and output, passing ones included |
| `memory_threshold` | the share of the machine's memory in use at which the run holds off on new items; 0.9 by default |
| `monitor` | watch memory and show the progress line; on by default |
| `monitor_interval` | how often the progress line is printed when there is no terminal to redraw it on; 30 seconds by default |
| `full_stacktraces` | keep YATF's own frames in a failing item's backtrace |
| `full_names` | write every item's name whole, where by default one much longer than the rest is shortened to a prefix of its own (see [The plan](#the-plan)) |
| `testset_name` | what the run's testset is called in the summary; `"YATF"` by default. Runs of several calls under one `@testset` are told apart by it |
| `coverage` | count which lines of `src/` and `ext/` the items run, into `lcov.info` at the package's root; also `YATF_COVERAGE` (see [Coverage](#coverage)) |
| `seed` | where every item's random numbers start, with its name; random unless given, and printed at the start of the run |
| `dry_run` | print the plan and run nothing |
| `replay` | run a recorded run again (see [Run state](#run-state)) |

All but `dry_run` and `replay` can also go under `[run]` in `test/TestItems.toml`;
a keyword given to `runtests` wins over the file.

With `workers = 0` the items run in this process, one after another. An item that
needs a process of its own (`sandbox=true`, or a profile) still gets one, started
and stopped around it, and the run lists which items did.

### Coverage

`coverage = true`, as a keyword, as `YATF_COVERAGE=true` in the environment, or
under `[run]` in `TestItems.toml`, has every worker count which lines of the
package's `src/` and `ext/` run. A keyword wins over the variable, and the variable
over the file; the run's opening block says which of them decided. At the end the
workers' counts are merged into `lcov.info` at the package's root, with paths
relative to it, ready for Codecov or Coveralls. Every line of a function that never
ran counts as not covered, in a file that was never loaded too, and the closing
block gives the share that ran:

<pre>
<b>│ </b>coverage: 33.3% of 6 lines in 2 files · lcov.info
</pre>

Coverage is counted by the workers, so it needs one (`workers = 0` is an error).
A worker writes what it counted as it exits, a timed-out one included, so a worker
that dies without exiting, one killed outright or one that crashed, takes its
counts with it; the closing block says how many did. On Windows a timed-out worker
is terminated outright too. A report that cannot be written is said there as well,
and the run's result stands.

Under `Pkg.test(coverage = true)`, which is what `julia-actions/julia-runtest` does,
the workers take Julia's coverage flags from the test process and write `.cov`
files beside the sources, as the test process does, for `julia-processcoverage` to
merge; nothing needs setting. To upload the merged file instead:

```yaml
- uses: julia-actions/julia-runtest@v1
  env:
    YATF_COVERAGE: true
- uses: codecov/codecov-action@v5
  with:
    files: lcov.info
```

## The plan

`YATF.runtests(dry_run=true)` prints what a run would do and runs nothing:

<pre>
<b>┌ [YATF]</b> dry run · v0.1.0 · julia 1.13.0 · 6 test items in 2 files · 2 workers · threads 2,1
<b>│ </b>startup: files 0.0s · plan 0.0s
<b>│ </b>setups: `BasicSetup`
<b>│ </b>timeout: 1800s · retries: 0 · failfast: false · logs: issues · memory_threshold: 0.9
<b>└ </b>order and workers: predicted as if every item took as long, since no durations are recorded yet

  <b>#</b> · <b>worker</b> · <b>test item   </b> · <b>at                  </b> · <b>tags      </b> · <b>why here     </b> · <b>details</b>
  1 ·     w1 · "slow thing" · test/sub/b_test.jl:9 · slow       · [order] first · timeout 120s
  2 ·     w2 · "chain one"  · test/sub/b_test.jl:1 ·            ·               · chain `seq` 1/2
  3 ·     w2 · "chain two"  · test/sub/b_test.jl:5 ·            ·               · chain `seq` 2/2
  4 ·     w1 · "add works"  · test/a_test.jl:1     · fast
  5 ·     w2 · "uses setup" · test/a_test.jl:11    ·            ·               · setup `BasicSetup`
  6 ·     w1 · "mul works"  · test/a_test.jl:6     · fast, math
</pre>

The table lists the items in the order the run is expected to start them, each
with the worker expected to run it. The prediction plays out the run's own
dispatch with the durations earlier runs recorded, so it is as good as they are.

A run hands out, in this order:
1. the items `[order] first` names;
2. sandboxed items, while every process is still fresh;
3. items that failed recently, or whose file changed since the last run;
4. items long enough to set the length of the run: at least 3 s, and over a quarter
   of a worker's share of the work;
5. everything else, in file order, each worker walking its own stretch of files so
   that neighbouring items reuse what it has compiled;
6. the items `[order] last` names.

The first four and the last go to whichever worker is free, and a worker that
finishes its own stretch takes over half of the longest one left. `why here` says
which rule placed an item, when it was not file order.

A name much longer than the rest is shortened to `r"^…"`, here and in a run's
`RUN` and `DONE` lines: a prefix that no other item's name in the suite starts
with, which picks that item out when passed as `name=`. `full_names = true` writes
every name whole.

## While it runs

Workers, test items and the run itself each get lines of one shape:

<pre>
<b>┌ [YATF]</b> v0.1.0 · julia 1.13.0 · 6 test items in 2 files · seed 0x0c15831ed3676a15 · 2 workers · threads 2,1
<b>│ </b>env: /var/folders/…/jl_vWMrc1/Project.toml
<b>└ </b>startup: files 0.0s · plan 0.1s · setup 1.4s
⚪ w0 · 12:54:36 · <b>INFO</b> · 0/6 · 0 failed · 0/2 workers · tree mem 845M (max 845M) · child max 448M · mem 89% · cpu 10.6/18 · testing 1s
⚫ w1 · 12:54:37 · <b>UP  </b> · pid 96279 · threads 2,1
⚫ w2 · 12:54:37 · <b>UP  </b> · pid 96280 · threads 2,1
🔵 w1 · 12:54:37 · <b>RUN </b> · 1/6 · "slow thing" · at <b>test/sub/b_test.jl:9</b>
🔵 w2 · 12:54:37 · <b>RUN </b> · 5/6 · "chain one"  · at <b>test/sub/b_test.jl:1</b>
🟢 w1 · 12:54:37 · <b>DONE</b> · 1/6 · "slow thing" · PASS ·  0.0s (93% compile) · maxrss 0.3 GiB
</pre>

⚫ is a worker starting or ending, 🔵 an item starting, 🟢 an item that passed, 🔴
one that failed, errored or timed out, and 🟡 one skipped or never reached. ⚪ is
the run's progress line: on a terminal it stays at the bottom and is redrawn as the
run goes; otherwise it is printed every `monitor_interval` seconds, when the run
moves from setup to testing, and when the machine's memory crosses 90%.

An item that did not pass gets its results and captured output right after its
`DONE` line:

<pre>
🔴 w1 · 12:55:14 · <b>DONE</b> · 1/1 · "fails" · FAIL ·  0.0s (92% compile) · maxrss 0.3 GiB
<b>┌ [1/1] FAIL</b> "fails"
<b>│ </b><b>Test Failed</b> at <b>test/faults_test.jl:6</b>
<b>│ </b>  Expression: 1 == 2
<b>│ </b><b>No captured logs</b>
<b>└ </b>@ test/faults_test.jl:5 on worker 1
</pre>

The run ends with what it cost, stage by stage, followed by `Test`'s usual summary:

<pre>
<b>┌ [YATF]</b> ran 6 test items in 3.3s on 2 workers, all passed
<b>│ </b>setup   · 1.3s · tree max  422M · child max  422M · coordinator
<b>│ </b>testing · 1.8s · tree max  1.0G · child max  452M · coordinator + 2 workers · 87% compile
<b>│ </b>(summed resident sizes over-count pages the processes share)
<b>│ </b>machine · 57.7G of 64.0G in use at peak
<b>└ </b>run state: ~/.julia/yatf/runs/8db4f545/1790247276-96211.yatf
</pre>

The memory figures cover every process the run owns: the coordinator, the workers,
and whatever they spawn, such as `Pkg` precompiling or a process a test starts.
`tree max` is the peak of their sum, `child max` the largest single process, and
the list after it says what the peak was summed over (`coordinator + 8 workers + 3
spawned`, say).

If memory gets tight the run holds off on new items, collects garbage, and only
then restarts the largest worker. The hold is bounded, so pressure caused by
something else on the machine slows a run down but never stalls it.

A run that goes longer without any item finishing than one attempt at any of them
may take (the largest `timeout`, the profiles' `init` and `test_end` limits, a
memory hold, and five minutes to spare) is stopped as hung: the workers are killed,
the items that were running are recorded as timed out, and `runtests` throws. An
item past its own timeout is killed long before that, so this catches only what
should have stopped and did not.

## `test/TestItems.toml`

```toml
[run]
workers = "auto"       # or an integer
timeout = 600          # per test item
init_timeout = 120     # per `init` expression; defaults to `timeout`
test_end_timeout = 60  # per `test_end` expression; defaults to `timeout`

[order]
first = ["build the artifacts"]   # handed out first, in this order
last  = ["tear down the cluster"]

[profiles.bounds]
julia_args = ["--check-bounds=yes"]
threads = "4"
env = { JULIA_DEBUG = "Main" }
init = "using MyPkg"
test_end = "GC.gc(true)"
preferences = "prefs/bounds.toml"
```

An unknown key, or a name in `[order]` that is not a test item, is an error: a
misspelled option that silently does nothing is how a suite ends up not running
the way its author believes it does.

An `[order]` pin is relative to the items that run alongside it. Items under
different profiles run concurrently, and a sandboxed item runs concurrently with
the ordinary ones, so pinning across either boundary does not sequence them.

A profile's `init` runs once per worker before any item, and `test_end` runs after
every item, on the same worker but timed against limits of their own. They are
the suite's own code, so what they cost is not charged to the item, and an item's
timeout stays a budget for the item. What `test_end` finds is reported as the
item's result, because that is what it was checking.

A profile's `preferences` file, relative to `test/`, is laid over the test
environment's `LocalPreferences.toml` in a copy of the environment that its workers
use. Packages see different preferences there, so they are precompiled separately.

## At the REPL

```julia
YATF.activate()        # or YATF.activate("path/to/Package")
YATF.deactivate()
```

`activate` puts the session where a test item's worker is: the package's test
environment active, and `test/testsetups/` on `LOAD_PATH`. `using MySetups` and the
package's test-only dependencies then work the way they do inside an item.
`deactivate` puts both back.

A `@testitem` pasted into the REPL runs there and then:

```julia
julia> @testitem "adds numbers" begin
           @test 1 + 1 == 2
       end
🔵 16:30:28 · RUN  · "adds numbers" · at REPL[2]:1
Test Summary: | Pass  Total  Time
adds numbers  |    1      1  0.0s
🟢 16:30:28 · DONE · "adds numbers" · PASS ·  0.0s (96% compile) · maxrss 0.6 GiB
```

It is read by the same parser as a test file, so a keyword that would be an error
in a file is an error here, and it runs the same way: fresh module, soft scope,
`Test` and the package in scope. `skip` and `failfast` are honoured, and so is
`sandbox`, by starting a worker for the item. `timeout`, `retries` and `chain` need
a run around the item, so they are ignored with a warning, except that an item
with a worker of its own keeps its `timeout` and `retries`. `tags` are ignored.

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

## Inside a test item

```julia
import YATF               # in the item's body
YATF.current_testitem()   # a TestItemInfo: name, file, line, attempt, profile; or nothing
YATF.in_testitem()        # Bool, for this task and the tasks it spawns
YATF.in_yatf_run()        # Bool, process-level, inherited by subprocesses
```

These are for test infrastructure: temporary directories, fixture paths, switching
off telemetry. Library code that changes what it does because it detects that it
is under test stops testing the library. Loading YATF in an item costs each worker
a moment the first time.

## The environment tests run in

Under `Pkg.test`, YATF uses the environment Pkg already built. Otherwise it builds
one with `TestEnv`, so dependencies your package declares only for testing
(`[extras]`/`[targets]`, or `test/Project.toml`) are importable from a test item.
Whatever environment you had active is restored when the run ends.

Generated environments are cached for the session, so calling `runtests()` again
at the REPL does not re-resolve and re-precompile. The cache notices when you
change `Project.toml` or a manifest, and rebuilds.

## Run state

Every run writes a binary record as it goes, so a run that is killed still leaves
a readable account of what had finished. It holds what it takes to run the same
run again somewhere else:

- which items ran, how each ended, how long it took and how much of that was
  compilation, and every attempt and every worker's start and end in order: which
  items a worker had run before it died, and whether it exited, was killed for a
  timeout, or was killed by a signal nobody in the run sent;
- the commit, the Julia version and build, the machine, the settings, the
  profiles with their preferences, and the seed every item's random numbers came
  from;
- the test environment's `Project.toml` and `Manifest.toml`.

The path is printed at the end of every run. Run states live in the depot, in a
directory per project under `yatf/runs/`, or in the directory `YATF_RUNSTATE_DIR`
names. The 20 most recent that this machine recorded are kept, and once a project
no longer exists, the run states this machine recorded for it are deleted too. The
machine is the hostname, or the name `YATF_HOST` gives it.
One recorded elsewhere, such as a run state downloaded from CI, is never changed
or deleted, wherever it is, and a replay deletes nothing.

On CI, cache them from one run to the next, so each run is ordered by the ones
before it, and keep a failed run's as an artifact:

```yaml
- uses: actions/cache/restore@v4
  with:
    path: ${{ runner.temp }}/yatf
    key: yatf-${{ matrix.os }}-${{ matrix.version }}-${{ github.run_id }}-${{ github.run_attempt }}
    restore-keys: yatf-${{ matrix.os }}-${{ matrix.version }}-
- uses: julia-actions/julia-runtest@v1
  env:
    YATF_RUNSTATE_DIR: ${{ runner.temp }}/yatf
    YATF_HOST: ci-${{ matrix.os }}-${{ matrix.version }}
- uses: actions/cache/save@v4
  if: always()
  with:
    path: ${{ runner.temp }}/yatf
    key: yatf-${{ matrix.os }}-${{ matrix.version }}-${{ github.run_id }}-${{ github.run_attempt }}
- uses: actions/upload-artifact@v4
  if: failure()
  with:
    name: yatf-run-state-${{ matrix.os }}-${{ matrix.version }}
    path: ${{ runner.temp }}/yatf
```

A cache is written once per key, so every run saves under a key of its own, and
`restore-keys` brings back the newest one saved before it. It is saved whether or
not the tests passed: which items failed is what orders the next run most. A
runner has a new hostname every run, so `YATF_HOST` names the machine: the run
states the cache brings back are then this machine's, and pruned to the newest 20
like a local directory's, where otherwise they would pile up.

Then, locally, `YATF.read_run_state("run.yatf")` shows what happened, and
`YATF.runtests(replay="run.yatf")` runs the same items with the same settings,
profiles and seed, naming every package whose version differs from the one CI had.

Later runs read the recent run states to plan (see [The plan](#the-plan)):
`runtestsf` takes its items from the newest one. A replay happens only when
asked: a run state lying next to the project is not a request to run differently,
and an explicit keyword always wins.
