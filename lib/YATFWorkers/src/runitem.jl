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
    maxrss       :: UInt64 = 0   # the worker process's largest resident size so far, when the item ended
end

"""
    ItemSpec

Everything a worker needs to run one item. Serialized to the worker as-is, so it
holds no process-local state.
"""
struct ItemSpec
    index        :: Int32
    name         :: String
    file         :: String
    line         :: Int32
    code         :: Expr
    skip         :: Any
    failfast     :: Bool
    project_name :: String
    profile      :: Symbol
    attempt      :: Int8
    full_stacktraces :: Bool  # keep the frames belonging to the framework itself
    logpath      :: String    # "" to write to the worker's stdout instead
    seed         :: UInt64    # where the item's random numbers start
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

# `f()`, with what it cost put in `stats` even when it throws: an item that errors
# took time too, and that time is what the next run schedules it by. Compilation
# is kept apart because on a compilation-heavy suite it is what explains the run.
function timed!(f, stats::Base.RefValue{PerfStats})
    gc0 = Base.gc_num()
    t0 = Base.time_ns()
    Base.cumulative_compile_timing(true)
    c0 = Base.cumulative_compile_time_ns()
    try
        return f()
    finally
        elapsed = Base.time_ns() - t0
        Base.cumulative_compile_timing(false)
        c = Base.cumulative_compile_time_ns() .- c0
        diff = Base.GC_Diff(Base.gc_num(), gc0)
        stats[] = PerfStats(; elapsed_ns = elapsed, compile_ns = first(c), recompile_ns = last(c),
                            bytes = diff.allocd, gc_ns = diff.total_time, maxrss = Sys.maxrss())
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
    run_item(spec; printing=false, enter=nothing) -> ItemResult

Evaluate one test item in a fresh module and return its results. Never throws for
a failing test: a failure is a result, not an error.

With `enter`, the item's body becomes a function of no arguments that is handed to
`enter(body)` to call, which is how a debugger steps into it (see
[`enter_item`](@ref)).
"""
run_item(spec::ItemSpec; printing::Bool=false, enter=nothing) =
    in_item(() -> _run_item(spec, enter), spec; printing)

# The lines a worker writes to its stdout as an item starts and finishes: data for
# the coordinator, which draws the RUN and DONE lines from them. On stdout rather
# than with the result because the item's own output travels there, and the DONE
# line must come after all of it.
const RECORD_MARK = "\x1eYATF "
record_run(spec::ItemSpec) = string(RECORD_MARK, "RUN ", spec.index, " ", spec.attempt)
record_done(spec::ItemSpec, r::ItemResult) = string(
    RECORD_MARK, "DONE ", spec.index, " ", spec.attempt, " ", UInt8(r.state), " ",
    r.stats.elapsed_ns, " ", r.stats.compile_ns, " ", r.stats.maxrss
)

"""
    run_test_end(spec, test_end) -> ItemResult

Evaluate a profile's `test_end` expression in a fresh module, after the item
`spec` describes. Its results and its cost belong to the profile rather than the
item, and the coordinator times it against a limit of its own.
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

# The scope an item's user code runs in: the item is visible to `current_testitem`,
# and its testsets print nothing here, because under a run the coordinator prints
# them. Straight from a REPL there is no coordinator, and `printing` says so.
function in_item(f, spec::ItemSpec; printing::Bool=false)
    info = TestItemInfo(spec.name, spec.file, spec.line, spec.attempt, spec.profile)
    return with(CURRENT_TESTITEM => info) do
        with_testset_printing(printing) do
            f()
        end
    end
end

"""
    trim_internal_frames(stack)

Cut each backtrace at the first frame belonging to this package: below it is the
machinery that called the item, which says nothing about why it failed.
`runtests(full_stacktraces=true)` keeps them.
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

function _run_item(spec::ItemSpec, enter=nothing)
    if should_skip(spec)
        ts = Test.DefaultTestSet(spec.name)
        Test.record(ts, Test.Broken(:skipped, spec.name))
        return ItemResult(spec.index, SKIPPED, transferrable(ts), PerfStats(; maxrss=Sys.maxrss()))
    end
    ts = Test.DefaultTestSet(spec.name; failfast=spec.failfast)
    stats = PerfStats()
    try
        stats = eval_block!(ts, spec, spec.code, spec.name, enter)
    finally
        finish_testset!(ts)
    end
    return ItemResult(spec.index, state_of(ts), transferrable(ts), stats)
end

# Evaluate one block of a test item's user code in a fresh module, recording into
# `ts` and capturing its output into the item's log. Never throws except on an
# interrupt: an exception that escapes the block is an `Error` record, which is
# what makes a crashing test item a result rather than a failure of the run.
function eval_block!(ts::Test.AbstractTestSet, spec::ItemSpec, code::Expr, modname::AbstractString,
                     enter=nothing)
    stats = Ref(PerfStats())
    # The `Test` this package already has, bound in the module rather than found by
    # name: `@test` works whether or not the test environment declares `Test`, and a
    # worker does not load YATF, the whole coordinator, to reach it.
    prelude = Any[Expr(:const, Expr(:(=), :Test, Test)), :(using .Test)]
    isempty(spec.project_name) || push!(prelude, :(using $(Symbol(spec.project_name))))
    evaluate = if enter === nothing
        body = softscope_all!(Expr(:block, prelude..., code.args...))
        () -> Core.eval(Main, Expr(:module, true, gensym(modname), body))
    else
        () -> enter_item(enter, prelude, code, modname, spec)
    end
    try
        with_testset(ts) do
            timed!(stats) do
                capture_output(spec.logpath) do
                    with_seed(spec.seed) do
                        with_source_path(evaluate, spec.file)
                    end
                end
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
    return stats[]
end

"""
    enter_item(enter, prelude, code, modname, spec)

Hand the item's body to `enter` as a function of no arguments, for it to call: how
a debugger steps into an item, a line of the test file at a time. A function body
cannot hold everything a module can, so what has to stay at top level (`using`,
`struct`, `const`, a method added to a function or type the module already has, and
whatever a macro expands to that is one of those) is evaluated in the item's module
first, in the order written. The function holds the rest.
"""
function enter_item(enter, prelude::Vector{Any}, code::Expr, modname::AbstractString, spec::ItemSpec)
    at = LineNumberNode(Int(spec.line), Symbol(spec.file))
    mod = Core.eval(Main, Expr(:module, true, gensym(modname), Expr(:block, prelude...)))
    defined = Set{Symbol}(Base.invokelatest(names, mod; all = true))
    line = at
    body = Any[at]   # the method is the item's, so it is where the item is declared
    for ex in code.args
        if ex isa LineNumberNode
            line = ex
        elseif Base.invokelatest(needs_top_level, mod, ex, defined)
            Core.eval(mod, Expr(:block, line, ex))
            union!(defined, Base.invokelatest(names, mod; all = true))
        else
            push!(body, line, ex)
        end
    end
    # What the body returns once it has run to its end. A debugger that is quit
    # returns something else, and an item cut short has no verdict to give.
    push!(body, ITEM_FINISHED)
    f = Core.eval(mod, Expr(:block, at, Expr(:function, Expr(:call, :testitem), Expr(:block, body...))))
    Base.invokelatest(enter, f) === ITEM_FINISHED || error(
        "the test item was left before it finished; what ran until then is recorded, and the rest did not run"
    )
    return nothing
end

struct ItemFinished end
const ITEM_FINISHED = ItemFinished()

# Heads that mean something only at top level; `:toplevel` is what `@enum` expands to.
const TOP_LEVEL_HEADS = (:using, :import, :export, :public, :struct, :abstract, :primitive,
                         :macro, :module, :const, :toplevel)

# Whether a statement of the body has to be evaluated at the item module's top level
# rather than inside a function. Asked of the module as it is by then, so a macro can
# come from a `using` above it, and `defined` holds the names the module owns so far.
function needs_top_level(mod::Module, @nospecialize(ex), defined::Set{Symbol})
    ex isa Expr || return false
    ex.head in TOP_LEVEL_HEADS && return true
    ex.head === :macrocall && return needs_top_level(mod, macroexpand(mod, ex), defined)
    ex.head in (:block, :if, :elseif) && return any(a -> needs_top_level(mod, a, defined), ex.args)
    return adds_method_to_global(ex, defined)
end

# `Base.show(io::IO, p::Point) = ...`, `(p::Point)(x) = ...`, or `Point() = Point(0)`
# once `Point` is the module's: a method on a function or type that lives in a
# module, which only a top-level definition can add. A definition under a name the
# module does not own is a local function, and may close over the body's variables.
function adds_method_to_global(ex::Expr, defined::Set{Symbol})
    ex.head === :function || ex.head === :(=) || return false
    sig = ex.args[1]
    while sig isa Expr && (sig.head === :where || sig.head === :(::))
        sig = sig.args[1]
    end
    sig isa Expr || return false
    ex.head === :function && sig.head === :. && return true   # `function Base.f end`
    sig.head === :call || return false
    callee = sig.args[1]
    return callee isa Symbol ? callee in defined : true
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

# How Test tracks the active testset is internal: a task-local stack before 1.13,
# scoped values from 1.13. The shape is detected rather than the version.
"""
    without_enclosing_testset(f)

Run `f` with no enclosing testset in scope. `Test.finish` attaches a testset to the
enclosing one whenever the depth is not zero, and an item's results belong to the
run's report, not to whatever `@testset` the caller of `runtests` is inside.
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

# The item's random numbers start from its seed, and the task's own stream is put
# back afterwards: in a run without workers this task is the caller's.
function with_seed(f, seed::UInt64)
    saved = copy(Random.default_rng())
    Random.seed!(seed)
    try
        return f()
    finally
        copy!(Random.default_rng(), saved)
    end
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
        line_buffered!(io)
        redirect_stdout(io) do
            redirect_stderr(io) do
                with_logger(ConsoleLogger(IOContext(io, :color => color))) do
                    f()
                end
            end
        end
    end
end

# `bufmode_t` in Julia's src/support/ios.h: bm_none = 1000, bm_line, bm_block, bm_mem.
const IOS_LINE_BUFFERED = Cint(1001)

# A process killed by a signal never flushes, so a block-buffered capture loses the
# lines an item printed just before it crashed, and the runtime's own crash report,
# written straight to the descriptor, lands ahead of them. Line-buffered, every
# finished line is on disk as it is printed, at about 2 µs a line. `Base` has no
# setting for this, and a stream that refuses it is still a working capture.
function line_buffered!(io::IOStream)
    ccall(:ios_bufmode, Cint, (Ptr{Cvoid}, Cint), io.ios, IOS_LINE_BUFFERED) == 0 ||
        @warn "YATF worker: captured output is block-buffered; a crash may lose its last lines" maxlog = 1
    return io
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
