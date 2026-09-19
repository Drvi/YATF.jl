# Running one test item. This is the only code that evaluates a user's test code,
# and it runs on a worker process (or, in single-process mode, on the coordinator).

"""
    ItemState

What is known about an item. The numeric values are part of the on-disk run state
format, so they may be added to but not renumbered.
"""
@enum ItemState::UInt8 begin
    UNSEEN       = 0
    RUNNING      = 1
    PASSED       = 2
    FAILED       = 3
    ERRORED      = 4
    TIMEDOUT     = 5
    SKIPPED      = 6
    BROKEN_CHAIN = 7
    CANCELLED    = 8
end

is_non_pass(s::ItemState) = !(s === PASSED || s === SKIPPED || s === UNSEEN)

Base.@kwdef struct PerfStats
    elapsed_ns   :: UInt64 = 0
    compile_ns   :: UInt64 = 0
    recompile_ns :: UInt64 = 0
    bytes        :: Int64  = 0
    gc_ns        :: Int64  = 0
end

"""
    ItemSpec

Everything a worker needs to run one item. Serialized to the worker as-is, so it
holds no process-local state.
"""
struct ItemSpec
    index        :: Int32
    ntotal       :: Int32
    name         :: String
    file         :: String
    line         :: Int32
    location     :: String    # file:line as the run reports it, relative to the project
    code         :: Expr
    skip         :: Any
    failfast     :: Bool
    project_name :: String
    profile      :: Symbol
    attempt      :: Int8
    attempts     :: Int8      # how many attempts this item gets in total
    full_stacktraces :: Bool  # keep the frames belonging to the framework itself
    logpath      :: String    # "" to write to the worker's stdout instead
end

struct ItemResult
    index   :: Int32
    state   :: ItemState
    testset :: Test.AbstractTestSet
    stats   :: PerfStats
end

"""
    TestItemInfo

What `YATF.current_testitem()` returns inside a running test item.
"""
struct TestItemInfo
    name    :: String
    file    :: String
    line    :: Int32
    attempt :: Int8
    profile :: Symbol
end

const CURRENT_TESTITEM = ScopedValue{Union{Nothing,TestItemInfo}}(nothing)

"""
    current_testitem() -> Union{Nothing,TestItemInfo}

The test item this task is running inside, or `nothing`.

The value is dynamically scoped, so tasks spawned by the test item see it and a
task created before the item started — a long-lived service started in a
profile's `init` expression, say — does not. For that case, and for subprocesses,
use [`in_yatf_run`](@ref).

This is a hook for test infrastructure: temporary directories, fixture paths,
switching off telemetry. Library code that changes what it does because it
detects that it is under test stops testing the library.
"""
current_testitem() = CURRENT_TESTITEM[]

"""
    in_testitem() -> Bool

Whether this task is running inside a test item. See [`current_testitem`](@ref).
"""
in_testitem() = CURRENT_TESTITEM[] !== nothing

"""
    in_yatf_run() -> Bool

Whether this process was started by a YATF run. Unlike [`in_testitem`](@ref) this
is process-level: it is visible to every task and inherited by subprocesses.
"""
in_yatf_run() = haskey(ENV, "YATF_RUN_ID")

# Adapted from Base.@time: we want compilation time separated out, because on a
# compilation-heavy suite that is the number that explains the run.
macro timed_with_compilation(ex)
    quote
        Base.Experimental.@force_compile
        local gc0 = Base.gc_num()
        local t0 = Base.time_ns()
        Base.cumulative_compile_timing(true)
        local c0 = Base.cumulative_compile_time_ns()
        local val = Base.@__tryfinally($(esc(ex)),
            (t0 = Base.time_ns() - t0;
             Base.cumulative_compile_timing(false);
             c0 = Base.cumulative_compile_time_ns() .- c0))
        local diff = Base.GC_Diff(Base.gc_num(), gc0)
        val, PerfStats(; elapsed_ns=t0, compile_ns=first(c0), recompile_ns=last(c0),
                       bytes=diff.allocd, gc_ns=diff.total_time)
    end
end

# Give the body REPL-like scoping, so `x = 1` at the top of an item followed by a
# loop that uses `x` behaves the way everyone expects.
function softscope(@nospecialize ex)
    if ex isa Expr
        h = ex.head
        h === :toplevel && return Expr(h, map(softscope, ex.args)...)
        h in (:meta, :import, :using, :export, :public, :module, :error, :incomplete, :thunk) && return ex
        h === :global && all(x -> x isa Symbol, ex.args) && return ex
        return Expr(:block, Expr(:softscope, true), ex)
    end
    return ex
end

softscope_all!(@nospecialize ex) = (map!(softscope, ex.args, ex.args); ex)

"""
    run_item(spec) -> ItemResult

Evaluate one test item in a fresh module and return its results. Never throws for
a failing test: a failure is a result, not an error.
"""
function run_item(spec::ItemSpec; printing::Bool=false)
    log_item(spec, "START")
    result = in_item(spec; printing) do
        _run_item(spec)
    end
    log_item(spec, "DONE", result)
    return result
end

"""
    run_test_end(spec, test_end) -> ItemResult

Evaluate a profile's test-end expression in a fresh module, after the item `spec`
describes has finished. Its results are its own: the expression checks what the
item left behind, so what it costs and what it finds belong to the profile rather
than to the item, and the coordinator times it against its own limit.
"""
function run_test_end(spec::ItemSpec, test_end::Expr)
    ts = Test.DefaultTestSet(string(spec.name, " test_end"))
    stats = PerfStats()
    in_item(spec) do
        try
            stats = eval_block!(ts, spec, test_end, string(spec.name, " test_end"))
        finally
            finish_testset!(ts)
        end
    end
    return ItemResult(spec.index, state_of(ts), transferrable(ts), stats)
end

# The scope every piece of a test item's user code runs in: the item is visible to
# `current_testitem`, and nothing the item's testsets record is printed here —
# under a run the coordinator prints them, in one place and in one piece. Run
# straight from a REPL there is no coordinator, and `printing` says so.
function in_item(f, spec::ItemSpec; printing::Bool=false)
    info = TestItemInfo(spec.name, spec.file, spec.line, spec.attempt, spec.profile)
    return with(CURRENT_TESTITEM => info) do
        with_testset_printing(printing) do
            f()
        end
    end
end

# Bracketing lines for every item, on the worker's real stdout rather than in the
# item's captured log: when a run hangs or a machine runs out of memory, the
# question is which items were in flight, and the answer has to be in the output
# whatever the log mode is and whether or not the item ever finishes.
function log_item(spec::ItemSpec, state::AbstractString, result=nothing)
    # The buffer carries the coordinator's colour setting, so `printstyled` emits
    # escapes only when the coordinator is attached to a terminal.
    buf = IOBuffer()
    io = IOContext(buf, :color => get(stdout, :color, false)::Bool)
    # `Libc.strftime` rather than Dates: every worker loads this package, so it
    # carries only what it cannot do without.
    print(io, Libc.strftime("%H:%M:%S", time()), " | ")
    printstyled(io, state; bold=true)
    pad_to(io, 5, textwidth(state))
    if spec.ntotal > 0
        print(io, " (", lpad(spec.index, ndigits(spec.ntotal)), "/", spec.ntotal, ")")
    end
    # Padded so the columns after the name stay put for the whole run; a name
    # longer than the column pushes them out rather than being cut, because the
    # name is what identifies the item.
    print(io, " ")
    pad_to(io, NAME_WIDTH, print_quoted(io, spec.name))
    # A retry is the same item again, so it gets the same line with a marker
    # rather than an announcement of its own.
    spec.attempt > 1 && print(io, " (retry ", spec.attempt - 1, " of ", max(spec.attempts - 1, 1), ")")
    if result === nothing
        print(io, " at ")
        printstyled(io, spec.location; bold=true)
    else
        pct = result.stats.elapsed_ns > 0 ?
            round(Int, 100 * result.stats.compile_ns / result.stats.elapsed_ns) : 0
        printstyled(io, " ", rpad(short_state(result.state), STATE_WIDTH);
                    color=state_color(result.state))
        print(io,
              " in ", lpad(fmt_secs(result.stats.elapsed_ns / 1e9), TIME_WIDTH),
              " (", lpad(pct, 2), "% compile)",
              ", maxrss ", fmt_gib(Sys.maxrss()))
    end
    println(io)
    emit_log(String(take!(buf)))
    return nothing
end

"""
    print_quoted(io, s) -> Int

Write `s` as `repr` would and return the width written.

`repr` builds an `IOBuffer` and an escaped copy of the string; almost no test item
name holds anything that needs escaping, and this runs twice for every item in the
suite. When there is nothing to escape the quotes go straight to `io`.
"""
function print_quoted(io::IO, s::AbstractString)
    if needs_escaping(s)
        quoted = repr(s)
        print(io, quoted)
        return textwidth(quoted)
    end
    print(io, '"', s, '"')
    return textwidth(s) + 2
end

# What `repr` of a string would change. Anything unprintable covers the control
# characters and the escapes Julia writes for them.
needs_escaping(s::AbstractString) =
    any(c -> c == '"' || c == '\\' || c == '$' || !isprint(c), s)

# Padding without building a padded copy of the thing being padded.
function pad_to(io::IO, width::Integer, used::Integer)
    for _ in 1:(width - used)
        write(io, UInt8(' '))
    end
    return nothing
end

"""
    LOG_SINK

Where an item's `START`/`DONE` lines go. On a worker that is the process's own
stdout, which the coordinator relays a line at a time. Running in this process
there is nobody to relay them, and writing straight to stdout would cut across
whatever the coordinator is printing — so it installs a sink of its own.
"""
const LOG_SINK = Ref{Any}(nothing)

function emit_log(line::AbstractString)
    sink = LOG_SINK[]
    if sink === nothing
        write(stdout, line)
        flush(stdout)
    else
        sink(line)
    end
    return nothing
end

"""
    trim_internal_frames(stack)

Cut each backtrace short at the first frame belonging to this package. Below that
point every frame is the machinery that called the test item — the evaluation, the
capture, the socket — and none of it says anything about why the item failed.

`runtests(full_stacktraces=true)` keeps them, for when the machinery is the
suspect.
"""
function trim_internal_frames(stack)
    return Base.ExceptionStack([(exception=e.exception, backtrace=trim_backtrace(e.backtrace))
                                for e in stack])
end

const SRC_DIR = @__DIR__

function trim_backtrace(bt)
    bt === nothing && return bt
    try
        for (i, ptr) in enumerate(bt)
            for frame in Base.StackTraces.lookup(ptr)
                frame.from_c && continue
                startswith(string(frame.file), SRC_DIR) || continue
                return bt[1:max(i - 1, 0)]
            end
        end
    catch
        # A backtrace we cannot walk is one we leave alone.
    end
    return bt
end

"""
    short_state(state) -> String

The outcome as it appears in a run's output. The four everyday ones are kept to
four characters so the column stays narrow across thousands of lines; the rare
ones are spelled out and are allowed to push the line, which is the right way for
an unusual outcome to catch the eye.
"""
short_state(state::ItemState) =
    state === PASSED       ? "PASS" :
    state === FAILED       ? "FAIL" :
    state === ERRORED      ? "ERR"  :
    state === SKIPPED      ? "SKIP" :
    state === TIMEDOUT     ? "TIMEOUT" :
    state === BROKEN_CHAIN ? "BROKEN" :
    state === CANCELLED    ? "CANCELLED" : string(state)

"""
    state_color(state) -> Symbol

`Test`'s palette, so an outcome looks the same here as it does in the summary
`Test` prints: green for a pass, red for anything that went wrong, yellow for
what was set aside.
"""
state_color(state::ItemState) =
    state === PASSED ? :green :
    state === SKIPPED || state === CANCELLED ? Base.warn_color() :
    is_non_pass(state) ? Base.error_color() : :default

const NAME_WIDTH  = 40
const STATE_WIDTH = 4     # "PASS"; the rarer outcomes are longer and may overflow
const TIME_WIDTH  = 6     # "999.9s"; an item that runs longer than that pushes the column

# One unit each, always: a column that switches between ms and s, or MiB and GiB,
# cannot be compared down the page at a glance.
fmt_secs(s::Real) = string(round(s; digits=1), "s")
fmt_gib(b::Real) = string(round(b / 2^30; digits=1), " GiB")

function _run_item(spec::ItemSpec)
    if should_skip(spec)
        ts = Test.DefaultTestSet(spec.name)
        Test.record(ts, Test.Broken(:skipped, spec.name))
        return ItemResult(spec.index, SKIPPED, transferrable(ts), PerfStats())
    end
    ts = Test.DefaultTestSet(spec.name; failfast=spec.failfast)
    stats = PerfStats()
    try
        stats = eval_block!(ts, spec, spec.code, spec.name)
    finally
        finish_testset!(ts)
    end
    return ItemResult(spec.index, state_of(ts), transferrable(ts), stats)
end

# Evaluate one block of a test item's user code in a fresh module, recording into
# `ts` and capturing its output into the item's log. Never throws except on an
# interrupt: an exception that escapes the block is an `Error` record, which is
# what makes a crashing test item a result rather than a failure of the run.
function eval_block!(ts::Test.AbstractTestSet, spec::ItemSpec, code::Expr, modname::AbstractString)
    stats = PerfStats()
    body = Expr(:block)
    # Through YATF rather than directly, so that an item's `@test` works whatever
    # the test environment does or does not declare (§3.1 of the design).
    push!(body.args, :(using YATF.Test))
    isempty(spec.project_name) || push!(body.args, :(using $(Symbol(spec.project_name))))
    append!(body.args, code.args)
    softscope_all!(body)
    mod_expr = Expr(:module, true, gensym(modname), body)
    try
        with_testset(ts) do
            _, stats = @timed_with_compilation capture_output(spec.logpath) do
                with_source_path(() -> Core.eval(Main, mod_expr), spec.file)
                nothing
            end
        end
    catch err
        err isa InterruptException && rethrow()
        if !is_failfast_error(err)
            try
                stack = Base.current_exceptions()
                spec.full_stacktraces || (stack = trim_internal_frames(stack))
                Test.record(ts, Test.Error(:nontest_error, Expr(:tuple), err, stack,
                                           LineNumberNode(Int(spec.line), spec.file)))
            catch err2
                is_failfast_error(err2) || rethrow()
            end
        end
    end
    return stats
end

function finish_testset!(ts::Test.AbstractTestSet)
    without_enclosing_testset() do
        try
            Test.finish(ts)
        catch e
            e isa Test.TestSetException || rethrow()
        end
    end
    return ts
end

is_failfast_error(err) = isdefined(Test, :FailFastError) && err isa Test.FailFastError

function should_skip(spec::ItemSpec)
    spec.skip isa Bool && return spec.skip
    body = softscope_all!(Expr(:block, deepcopy(spec.skip)))
    mod = Module(Symbol("skip_", spec.name))
    skip = Core.eval(mod, body)
    skip isa Bool || error("test item $(repr(spec.name)): `skip` must evaluate to a Bool, got $(repr(skip))")
    return skip
end

# A per-item testset is a result to be shipped, not something to print on the
# worker; the coordinator prints the run's summary once, in one place.
function with_testset_printing(f, enabled::Bool)
    isdefined(Test, :TESTSET_PRINT_ENABLE) || return f()
    flag = Test.TESTSET_PRINT_ENABLE
    # A `ScopedValue` on Julia 1.13, a `Ref` before it. Both are internal to Test,
    # so read the shape rather than the version number.
    flag isa ScopedValue && return with(f, flag => enabled)
    prev = flag[]
    flag[] = enabled
    try
        return f()
    finally
        flag[] = prev
    end
end

# How Test tracks the active testset is internal and has changed shape: a
# task-local stack with push/pop before Julia 1.13, scoped values from 1.13 on.
# Detect the shape rather than the version, and let `test_runitem.jl` fail loudly
# if a future release grows a third one.
"""
    without_enclosing_testset(f)

Run `f` with no enclosing testset in scope.

`Test.finish` attaches a testset to the enclosing one whenever the testset depth
is not zero. A test item's results belong to the run's own report, so finishing
one must not silently graft it onto whatever `@testset` the caller of
`runtests` happened to be inside.
"""
function without_enclosing_testset(f)
    if isdefined(Test, :TESTSET_DEPTH) && Test.TESTSET_DEPTH isa ScopedValue
        return with(f, Test.TESTSET_DEPTH => 0, Test.CURRENT_TESTSET => Test.FallbackTestSet())
    end
    # Before the scoped-value rewrite the stack lived in task-local storage.
    tls = task_local_storage()
    key = :__BASETESTNEXT__
    prev = get(tls, key, nothing)
    tls[key] = Test.AbstractTestSet[]
    try
        return f()
    finally
        prev === nothing ? delete!(tls, key) : (tls[key] = prev)
    end
end

function with_testset(f, ts::Test.AbstractTestSet)
    if isdefined(Test, :CURRENT_TESTSET) && Test.CURRENT_TESTSET isa ScopedValue
        return with(f, Test.CURRENT_TESTSET => ts,
                       Test.TESTSET_DEPTH => Test.get_testset_depth() + 1)
    elseif isdefined(Test, :push_testset)
        Test.push_testset(ts)
        try
            return f()
        finally
            Test.pop_testset()
        end
    end
    error("YATF cannot tell how this Julia's Test stdlib tracks the active testset; " *
          "this build of Test is not supported")
end

function with_source_path(f, path)
    tls = task_local_storage()
    prev = get(tls, :SOURCE_PATH, nothing)
    tls[:SOURCE_PATH] = path
    try
        return f()
    finally
        prev === nothing ? delete!(tls, :SOURCE_PATH) : (tls[:SOURCE_PATH] = prev)
    end
end

# stdout/stderr redirection is process-wide, which is fine because a worker runs
# one item at a time. An empty path means eager logs: leave the streams alone and
# let the coordinator relay them as they appear.
function capture_output(f, logpath::AbstractString)
    isempty(logpath) && return f()
    # Read before redirecting: this is the coordinator's setting, passed down as
    # the worker's `--color` flag. The captured file is not a terminal, so the
    # logger has to be told, or every captured log record comes out grey.
    color = get(stdout, :color, false)::Bool
    open(logpath, "a") do io
        redirect_stdout(io) do
            redirect_stderr(io) do
                with_logger(ConsoleLogger(IOContext(io, :color => color))) do
                    f()
                end
            end
        end
    end
end

function state_of(ts::Test.AbstractTestSet)
    state = PASSED
    for r in ts.results
        if r isa Test.Error
            return ERRORED
        elseif r isa Test.Fail
            state = FAILED
        elseif r isa Test.AbstractTestSet
            s = state_of(r)
            s === ERRORED && return ERRORED
            s === FAILED && (state = FAILED)
        end
    end
    return state
end

# Results travel between processes, so anything in them that only makes sense in
# the process that produced it has to go.
function transferrable(ts::Test.AbstractTestSet)
    for (i, res) in enumerate(ts.results)
        ts.results[i] = transferrable(res)
    end
    return ts
end

function transferrable(res::Test.Pass)
    res.test_type === :test_throws &&
        return Test.Pass(:test_throws, nothing, nothing, string(res.value))
    return Test.Pass(res.test_type, res.orig_expr, nothing, res.value, res.source, res.message_only)
end

transferrable(@nospecialize(x)) = x
