# Reading test files. The scanner parses and never evaluates, so no test file can
# hang, crash or allocate in the process that coordinates the run.

const TEST_FILE_SUFFIXES = ("_test.jl", "_tests.jl")
const TESTSETUPS_DIR = "testsetups"

is_test_file(path::AbstractString) = any(s -> endswith(path, s), TEST_FILE_SUFFIXES)

"""
    discover(testdir) -> Vector{String}

Every test file under `testdir`, sorted. See [`walk_test_dir`](@ref).
"""
discover(testdir::AbstractString) = first(walk_test_dir(testdir))

"""
    walk_test_dir(testdir) -> (tests, strays)

Every test file under `testdir`, and every other Julia file there, both sorted.
Hidden files and directories, `testsetups/` and subprojects (directories with a
`Project.toml`) are skipped. The strays are reported, not skipped: a file of tests
not named `*_test.jl` would otherwise never run, and the run would pass without it.
"""
function walk_test_dir(testdir::AbstractString)
    tests, strays = String[], String[]
    isdir(testdir) || return tests, strays
    for (dir, dirs, names) in walkdir(testdir; topdown = true)
        filter!(dirs) do d
            !startswith(d, '.') && d != TESTSETUPS_DIR &&
                !isfile(joinpath(dir, d, "Project.toml"))
        end
        for n in names
            startswith(n, '.') && continue
            if is_test_file(n)
                push!(tests, joinpath(dir, n))
            elseif endswith(n, ".jl") && !(n == RUNTESTS_FILE && dir == testdir)
                push!(strays, joinpath(dir, n))
            end
        end
    end
    return sort!(tests), sort!(strays)
end

# `Pkg.test` runs this one, so it belongs at the top of `test/` and nowhere else.
const RUNTESTS_FILE = "runtests.jl"

# One error per file, because the fix is per file.
stray_error(path::AbstractString) = ScanError(
    path, 0,
    "not a test file. Test files are named `*_test.jl` or `*_tests.jl`; shared code goes in " *
        "`test/$TESTSETUPS_DIR/` as a module that test items load with `using`; a directory " *
        "with its own Project.toml is left alone. Rename it, move it there, or remove it."
)

"""
    setup_modules(testdir) -> Dict{Symbol,String}

The modules `test/testsetups/` makes loadable: `Name.jl` or `Name/src/Name.jl`.
"""
function setup_modules(testdir::AbstractString)
    out = Dict{Symbol, String}()
    dir = joinpath(testdir, TESTSETUPS_DIR)
    isdir(dir) || return out
    for n in sort!(readdir(dir))
        path = joinpath(dir, n)
        if isfile(path) && endswith(n, ".jl")
            out[Symbol(chop(n; tail = 3))] = path
        elseif isdir(path)
            inner = joinpath(path, "src", n * ".jl")
            isfile(inner) && (out[Symbol(n)] = inner)
        end
    end
    return out
end

### Statement extraction ###################################################

# `Meta.parseall` returns a syntax error as a statement at the line where parsing
# stopped, rather than throwing. Nothing after it can be trusted, so it is the
# file's one error.
function scan_file!(
        items::Vector{RawItem}, errors::Vector{ScanError}, names::Vector{ItemName},
        path::String, filter::Filter, known_setups
    )
    src = try
        read(path, String)
    catch e
        push!(errors, ScanError(path, 0, "could not read file: $(sprint(showerror, e))"))
        return
    end
    line = Int32(0)
    for a in Meta.parseall(src; filename = path).args
        if a isa LineNumberNode
            line = Int32(a.line)
        elseif a isa Expr && a.head in (:error, :incomplete)
            msg = a.args[1]
            push!(errors, ScanError(path, line, msg isa AbstractString ? msg : sprint(showerror, msg)))
            return
        else
            handle_statement!(items, errors, names, a, path, line, filter, known_setups)
        end
    end
    return
end

### Header parsing #########################################################

function handle_statement!(items, errors, names, ex, path, line, filter, known_setups)
    if !(ex isa Expr) || ex.head !== :macrocall || ex.args[1] !== Symbol("@testitem")
        what = ex isa Expr && ex.head === :macrocall ? string(ex.args[1]) : summary(ex)
        push!(
            errors, ScanError(
                path, line,
                "test files may only contain `@testitem` declarations, found `$what`"
            )
        )
        return
    end
    item = parse_testitem(ex, path, line, errors, known_setups)
    item === nothing && return
    if !(matches_path(filter.paths, path) && matches_name(filter.name, item.name) &&
            matches_tags(filter.tags, item.tags))
        push!(names, ItemName(item.name, path, item.line))
        return
    end
    push!(items, item)
    return
end

# The keywords a `@testitem` accepts. A position in this tuple is a bit in the
# `seen` mask below, which is how a keyword given twice is caught without a set
# per item.
const ITEM_KEYWORDS = (:tags, :timeout, :retries, :skip, :failfast, :chain, :sandbox)

function keyword_bit(key::Symbol)
    i = findfirst(==(key), ITEM_KEYWORDS)
    return i === nothing ? UInt8(0) : UInt8(1) << (i - 1)
end

function parse_testitem(ex::Expr, path, line, errors, known_setups)
    err(msg) = (push!(errors, ScanError(path, line, msg)); nothing)
    # Indexed rather than sliced: slices would copy `ex.args` twice for every item.
    lo, hi = 2, length(ex.args)
    lo > hi && return err("`@testitem` needs a name and a body")
    if ex.args[lo] isa LineNumberNode
        line = Int32(ex.args[lo].line)
        lo += 1
    end
    lo > hi && return err("`@testitem` needs a name and a body")
    name = ex.args[lo]
    name isa String || return err("`@testitem` needs a string literal name, got `$(_show(name))`")
    isempty(strip(name)) && return err("`@testitem` name must not be blank")
    hi - lo >= 1 || return err("`@testitem $(repr(name))` has no `begin ... end` body")
    body = ex.args[hi]
    (body isa Expr && body.head === :block) ||
        return err("`@testitem $(repr(name))` must end with a `begin ... end` body")

    tags = Symbol[]; setups = Symbol[]
    timeout = USE_RUN_DEFAULT; retries = USE_RUN_DEFAULT
    failfast = Int8(-1); chain = NO_CHAIN; profile = DEFAULT_PROFILE
    exclusive = false; skip = false
    seen = UInt8(0)
    for k in (lo + 1):(hi - 1)
        kw = ex.args[k]
        if !(kw isa Expr && kw.head === :(=) && kw.args[1] isa Symbol)
            return err("`@testitem $(repr(name))`: expected `key=value`, got `$(_show(kw))`")
        end
        key, val = kw.args[1], kw.args[2]
        bit = keyword_bit(key)
        if bit != 0
            seen & bit == 0 || return err("`@testitem $(repr(name))`: `$key` given twice")
            seen |= bit
        end
        if key === :skip
            # The one keyword that may be an expression: it runs on the worker.
            skip = val isa QuoteNode ? val.value : val
        elseif key === :tags
            v = literal(val)
            (v isa Vector && all(x -> x isa Symbol, v)) ||
                return err("`@testitem $(repr(name))`: `tags` must be a vector of symbols, got `$(_show(val))`")
            tags = Symbol[x for x in v]
        elseif key === :timeout
            v = literal(val)
            (v isa Real && v > 0) ||
                return err("`@testitem $(repr(name))`: `timeout` must be a positive number of seconds, got `$(_show(val))`")
            timeout = Int32(ceil(v))
        elseif key === :retries
            v = literal(val)
            (v isa Integer && v >= 0) ||
                return err("`@testitem $(repr(name))`: `retries` must be a non-negative integer, got `$(_show(val))`")
            retries = Int32(v)
        elseif key === :failfast
            v = literal(val)
            v isa Bool || return err("`@testitem $(repr(name))`: `failfast` must be `true` or `false`, got `$(_show(val))`")
            failfast = Int8(v)
        elseif key === :chain
            v = literal(val)
            v isa Symbol || return err("`@testitem $(repr(name))`: `chain` must be a symbol, got `$(_show(val))`")
            chain = v
        elseif key === :sandbox
            v = literal(val)
            if v isa Bool
                exclusive = v
            elseif v isa Symbol
                profile = v
            else
                return err("`@testitem $(repr(name))`: `sandbox` must be `true` or a profile name, got `$(_show(val))`")
            end
        else
            return err(
                "`@testitem $(repr(name))`: unknown keyword `$key`; " *
                    "known keywords are tags, timeout, retries, skip, failfast, chain, sandbox"
            )
        end
    end
    if exclusive && chain !== NO_CHAIN
        return err(
            "`@testitem $(repr(name))`: `sandbox=true` means alone in a process and " *
                "`chain=:$chain` means together with its chain, so they cannot be combined"
        )
    end
    collect_setups!(setups, body, known_setups)
    return RawItem(
        name, path, line, tags, unique!(setups), body, skip,
        timeout, retries, failfast, chain, profile, exclusive
    )
end

# Keyword values must be literals: a keyword that needs evaluating would mean
# running user code to find out what to run.
struct NotALiteral end
function literal(@nospecialize(v))
    v isa Union{Bool, Integer, AbstractFloat, String, Char} && return v
    v isa QuoteNode && v.value isa Symbol && return v.value
    if v isa Expr && (v.head === :vect || v.head === :tuple)
        out = Any[]
        for a in v.args
            x = literal(a)
            x isa NotALiteral && return NotALiteral()
            push!(out, x)
        end
        return isempty(out) ? Any[] : [x for x in out]
    end
    if v isa Expr && v.head === :call && length(v.args) == 3 && v.args[1] in (:*, :+, :-, :/)
        # `timeout=5*60` reads better than `timeout=300`, and folding literal
        # arithmetic looks nothing up.
        a, b = literal(v.args[2]), literal(v.args[3])
        (a isa Real && b isa Real) || return NotALiteral()
        return getfield(Base, v.args[1])(a, b)
    end
    return NotALiteral()
end

_show(@nospecialize(x)) = x isa NotALiteral ? "?" : sprint(show, x; context = :limit => true)

function collect_setups!(out::Vector{Symbol}, @nospecialize(ex), known)
    ex isa Expr || return out
    if ex.head === :using || ex.head === :import
        for a in ex.args
            m = module_head(a)
            m !== nothing && haskey(known, m) && push!(out, m)
        end
    else
        for a in ex.args
            collect_setups!(out, a, known)
        end
    end
    return out
end

function module_head(@nospecialize(a))
    a isa Expr || return nothing
    a.head === :. && !isempty(a.args) && a.args[1] isa Symbol && return a.args[1]
    a.head === :(:) && return module_head(a.args[1])
    return nothing
end

### Driver #################################################################

"""
    scan(files, filter, known_setups; ntasks, strays) -> Vector{RawItem}

Read every file, in parallel, and return the items that pass `filter` sorted by
(file, line). Throws a `ScanFailure` listing every problem, the `strays` among
them, so one run surfaces every broken file.
"""
function scan(
        files::Vector{String}, filter::Filter, known_setups::Dict{Symbol, String};
        ntasks::Int = default_scan_tasks(),
        strays::Vector{String} = String[]
    )
    nt = clamp(ntasks, 1, max(1, length(files)))
    chunks = [(sizehint!(RawItem[], 64), ScanError[], sizehint!(ItemName[], 64)) for _ in 1:nt]
    ch = Channel{String}(length(files))
    foreach(f -> put!(ch, f), files)
    close(ch)
    @sync for t in 1:nt
        items, errors, names = chunks[t]
        Threads.@spawn begin
            its, errs, nms = $items, $errors, $names
            for path in ch
                scan_file!(its, errs, nms, path, filter, known_setups)
            end
        end
    end
    errors = ScanError[stray_error(path) for path in strays]
    for c in chunks
        append!(errors, c[2])
    end
    if !isempty(errors)
        sort!(errors; by = e -> (e.file, e.line))
        throw(ScanFailure(errors))
    end
    items = reduce(vcat, (c[1] for c in chunks); init = RawItem[])
    sort!(items; by = i -> (i.file, i.line))
    rejected = reduce(vcat, (c[3] for c in chunks); init = ItemName[])
    check_unique_names(items, rejected)
    filter.line > 0 && (items = select_by_line(items, filter.line))
    return items
end

# Twice the threads to hide file IO; capped, because parsing is allocation-bound.
default_scan_tasks() = clamp(2 * Threads.nthreads(), 1, 16)

# `runtests("file.jl:42")` means the item that line is inside: the last one that
# starts at or before it.
function select_by_line(items::Vector{RawItem}, line::Int32)
    best = nothing
    for it in items
        it.line <= line && (best === nothing || it.line > best.line) && (best = it)
    end
    return best === nothing ? RawItem[] : [best]
end

# Over every item in the suite, selected or not: a name that is unique only
# because this run filtered out its twin is not a unique name.
function check_unique_names(items::Vector{RawItem}, rejected::Vector{ItemName} = ItemName[])
    all_names = ItemName[ItemName(it.name, it.file, it.line) for it in items]
    append!(all_names, rejected)
    sort!(all_names; by = n -> (n.file, n.line))
    seen = Dict{String, ItemName}()
    errors = ScanError[]
    for it in all_names
        prev = get(seen, it.name, nothing)
        if prev === nothing
            seen[it.name] = it
        else
            push!(
                errors, ScanError(
                    it.file, it.line,
                    "duplicate test item name $(repr(it.name)); also declared at " *
                        "$(relpath_or_path(prev.file)):$(prev.line). Names identify items in " *
                        "TestItems.toml, in the run state and on the command line, so they must be unique."
                )
            )
        end
    end
    isempty(errors) || throw(ScanFailure(errors))
    return items
end
