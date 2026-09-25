# Turning scanned items into a plan: what runs where and in what order, decided
# once before anything starts. `--dry-run` prints it; a run executes exactly it.

"""
    Items

Per-item data in plan order, as parallel arrays: the scheduler works with indices
and never touches the bulky `code` and `skip`.
"""
struct Items
    name::Vector{String}
    fileidx::Vector{Int32}
    line::Vector{Int32}
    tags::Vector{Symbol}
    tag_span::Vector{UnitRange{Int32}}
    setups::Vector{Symbol}
    setup_span::Vector{UnitRange{Int32}}
    code::Vector{Expr}
    skip::Vector{Any}
    timeout_s::Vector{Int32}
    retries::Vector{Int32}
    failfast::Vector{Int8}
    unit::Vector{UnitIdx}
end

Base.length(it::Items) = length(it.name)
tags_of(it::Items, i) = view(it.tags, it.tag_span[i])
setups_of(it::Items, i) = view(it.setups, it.setup_span[i])

"""
    Why

The class [`order_pool!`](@ref) sorts a unit into, in the order the classes are
handed out: what the dry run says about why an item runs where it does.
"""
@enum Why::UInt8 begin
    PINNED_FIRST    # `[order] first`
    SANDBOXED       # needs a process of its own
    RECENT          # failed in a recorded run, or its file changed since the newest one
    LONG            # long enough to decide how long the run takes
    IN_FILE_ORDER   # everything else
    PINNED_LAST     # `[order] last`
end

"""
    Units

The schedulable thing: a chain of items, or a single item. Chain membership is
represented by the items being contiguous, so the scheduler never has to ask what
chain something belongs to — it dispatches a range.
"""
struct Units
    span::Vector{UnitRange{ItemIdx}}
    profile::Vector{ProfileIdx}
    exclusive::Vector{Bool}
    chain::Vector{Symbol}
    est_s::Vector{Float64}
    why::Vector{Why}            # where `order_pool!` put it, and so why
    failed_ago::Vector{Int32}   # runs since a member last did not pass, -1 for none recorded
    failed_item::Vector{ItemIdx}    # that member, 0 for none
    changed_item::Vector{ItemIdx}   # a member whose file was written since the newest recorded run, 0 for none
end

Base.length(u::Units) = length(u.span)

"""
    Pool

One profile's units in the order they are handed out, as three runs of
consecutive unit indices:

- `head` goes first, in order, to whichever of the pool's workers asks next;
- `body` is in file order, cut into one stretch per worker: each walks its own,
  running neighbouring items that share compiled code;
- `tail` goes last, in order.

What goes where is decided by [`order_pool!`](@ref).
"""
struct Pool
    profile::ProfileIdx
    head::UnitRange{UnitIdx}
    body::UnitRange{UnitIdx}
    tail::UnitRange{UnitIdx}
end

"""
    Startup

Where the time before the first test item went, for the run's header.
"""
mutable struct Startup
    files::Float64   # finding and reading the test files
    plan::Float64   # ordering them and assigning them to workers
    setup::Float64   # the test environment, and precompiling it and the setups
end
Startup() = Startup(0.0, 0.0, 0.0)

struct Plan
    items::Items
    units::Units
    files::Vector{String}
    relfiles::Vector{String}    # `files` relative to the project
    locations::Vector{String}   # `file:line` per item
    profiles::Vector{Profile}
    pools::Vector{Pool}
    slot_pool::Vector{Int32}                 # slot -> pool
    slot_units::Vector{UnitRange{UnitIdx}}   # slot -> its stretch of its pool's body
    pending::Vector{Int32}                   # pools with no slot yet, in pickup order
    setups::Vector{Symbol}               # setups to precompile
    cfg::RunConfig
    root::String
    startup::Startup
    selection::String   # how the items were chosen, as the run says it; empty for all of them
    suite_names::Vector{String}   # every item's name in the suite, chosen or not, sorted
end

nslots(p::Plan) = length(p.slot_pool)
nitems(p::Plan) = length(p.items)

# No workers: everything happens in this process.
single_process(p::Plan) = p.cfg.workers == 0

# Where an item is, as the run reports it.
itemfile(p::Plan, i::Integer) = p.relfiles[p.items.fileidx[i]]
itemlocation(p::Plan, i::Integer) = p.locations[i]

"""
    History

What earlier runs measured, keyed by item name: how long each item took and how
many runs ago it last did not pass (0 for the newest run); and when the newest
run started (0 without one). Empty on a first run: nothing has an estimate, and
the body is cut by count.
"""
struct History
    seconds::Dict{String, Float64}
    failed::Dict{String, Int}
    since::Float64
end
History() = History(Dict{String, Float64}(), Dict{String, Int}(), 0.0)

"""
    plan(raw, cfg; history, root, strict_order, selection, suite_names) -> Plan

Validate, group into units, put each profile's units in the order they are handed
out, and cut each pool's body into one stretch per slot.
"""
function plan(
        raw::Vector{RawItem}, cfg::RunConfig; history::History = History(),
        root::AbstractString = "", strict_order::Bool = true, selection::AbstractString = "",
        suite_names::Vector{String} = String[it.name for it in raw]
    )
    isempty(raw) && throw(NoTestsError("no test items to run"))
    validate_profiles(raw, cfg)
    # Only a full run can tell a typo in [order] from an item the filter removed,
    # so the check is strict there and permissive under a filter.
    strict_order && validate_order(raw, cfg)

    profiles, profile_idx = profile_table(cfg)
    units = build_units(raw, profile_idx, history)
    pools = [findall(d -> d.profile == k, units) for k in sort!(unique(d.profile for d in units))]
    slots = count_slots(pools, units, cfg)
    changed = changed_files(units, history.since)
    for (k, pool) in enumerate(pools)
        order_pool!(pool, units, slots[k], cfg, history, changed)
    end
    return materialize(units, pools, slots, profiles, cfg, root, selection, sort(suite_names))
end

function validate_profiles(raw, cfg)
    bad = Dict{Symbol, Vector{RawItem}}()
    for it in raw
        it.profile === DEFAULT_PROFILE && continue
        haskey(cfg.profiles, it.profile) || push!(get!(bad, it.profile, RawItem[]), it)
    end
    isempty(bad) && return
    known = sort!(string.(collect(keys(cfg.profiles))))
    throw(ConfigError(sprint() do io
        println(io, "unknown sandbox profiles (known: ", join(known, ", "), "):")
        for (name, items) in sort!(collect(bad); by = first)
            println(io, "  `sandbox=:$name` has no [profiles.$name] in TestItems.toml, used by:")
            foreach(it -> println(io, "    ", repr(it.name), " at ", relpath_or_path(it.file), ":", it.line), items)
        end
    end))
end

function validate_order(raw, cfg)
    names = Set(it.name for it in raw)
    missing_ = String[]
    for n in Iterators.flatten((cfg.order_first, cfg.order_last))
        n in names || push!(missing_, n)
    end
    isempty(missing_) && return
    throw(ConfigError(sprint() do io
        println(io, "[order] of TestItems.toml names test items that do not exist:")
        for n in missing_
            near = nearest(n, names)
            println(io, "  ", repr(n), isempty(near) ? "" : "  (did you mean $(join(map(repr, near), " or "))?)")
        end
    end))
end

# Cheap edit-distance-ish suggestion: a typo'd name should not send anyone hunting.
function nearest(name::AbstractString, names, k::Int = 2)
    scored = sort!([(levenshtein(name, n), n) for n in names]; by = first)
    cutoff = max(3, length(name) ÷ 3)
    return [n for (d, n) in Iterators.take(scored, k) if d <= cutoff]
end

function levenshtein(a::AbstractString, b::AbstractString)
    m, n = length(a), length(b)
    prev = collect(0:n)
    curr = similar(prev)
    for (i, ca) in enumerate(a)
        curr[1] = i
        for (j, cb) in enumerate(b)
            curr[j + 1] = min(prev[j + 1] + 1, curr[j] + 1, prev[j] + (ca == cb ? 0 : 1))
        end
        prev, curr = curr, prev
    end
    return prev[n + 1]
end

function profile_table(cfg::RunConfig)
    names = sort!(collect(keys(cfg.profiles)); by = n -> (n !== DEFAULT_PROFILE, string(n)))
    profiles = Profile[cfg.profiles[n] for n in names]
    idx = Dict{Symbol, ProfileIdx}(n => ProfileIdx(i) for (i, n) in enumerate(names))
    return profiles, idx
end

# A unit under construction: its items, and what the scheduler decides with.
mutable struct UnitDraft
    const items::Vector{RawItem}
    const profile::ProfileIdx
    const exclusive::Bool
    const chain::Symbol
    const est_s::Float64
    key::Tuple{Int, Int, Float64, String, Int32}   # its place in its pool; see `order_pool!`
    why::Why
    failed_ago::Int32
    failed_at::Int    # which of `items` failed most recently, 0 for none
    changed_at::Int   # which of `items` has a file written since the newest run, 0 for none
end

function build_units(raw::Vector{RawItem}, profile_idx, history::History)
    draft(its, exclusive, chain) = UnitDraft(
        its, profile_idx[its[1].profile], exclusive, chain,
        sum(it -> get(history.seconds, it.name, 0.0), its; init = 0.0), (0, 0, 0.0, "", Int32(0)),
        IN_FILE_ORDER, Int32(-1), 0, 0
    )
    chains = Dict{Symbol, Vector{RawItem}}()
    units = UnitDraft[]
    for it in raw
        if it.chain === NO_CHAIN
            push!(units, draft([it], it.exclusive, NO_CHAIN))
        else
            push!(get!(chains, it.chain, RawItem[]), it)
        end
    end
    errors = ScanError[]
    for (name, its) in chains
        sort!(its; by = i -> (i.file, i.line))
        first_ = its[1]
        for it in its
            if it.profile !== first_.profile
                push!(
                    errors, ScanError(
                        it.file, it.line,
                        "chain `:$name` mixes sandbox profiles: $(repr(it.name)) uses " *
                            "`:$(it.profile)` but $(repr(first_.name)) uses `:$(first_.profile)`; " *
                            "a chain runs in one process, so it must have one profile"
                    )
                )
            end
        end
        push!(units, draft(its, false, name))
    end
    isempty(errors) || throw(ScanFailure(sort!(errors; by = e -> (e.file, e.line))))
    return units
end

# `workers` is a hard cap on live processes, because that cap is what bounds
# memory and duplicated compilation. Every pool gets a slot while there are slots
# to give, the most work first; the rest go where the most work per slot is, never
# more slots than a pool has units. A pool left without a slot is taken by the
# first slot whose own pool runs out of work.
function count_slots(pools::Vector{Vector{Int}}, units::Vector{UnitDraft}, cfg::RunConfig)
    work = map(pools) do pool
        w = sum(u -> units[u].est_s, pool; init = 0.0)
        w > 0 ? w : Float64(length(pool))
    end
    n = zeros(Int, length(pools))
    budget = max(cfg.workers, 1)
    for k in sortperm(work; rev = true)
        budget == 0 && break
        n[k] = 1
        budget -= 1
    end
    while budget > 0
        k = argmax(k -> 0 < n[k] < length(pools[k]) ? work[k] / n[k] : -Inf, eachindex(pools))
        0 < n[k] < length(pools[k]) || break
        n[k] += 1
        budget -= 1
    end
    return n
end

# Files written since the newest recorded run started: what is being worked on,
# and so the likeliest to have something to say.
function changed_files(units::Vector{UnitDraft}, since::Float64)
    since > 0 || return Set{String}()
    return Set(f for f in unique(it.file for d in units for it in d.items) if mtime(f) > since)
end

const HEAD_CLASSES = Int(PINNED_FIRST):Int(LONG)
const TAIL_CLASS = Int(PINNED_LAST)

# Under this many seconds a unit is never long, whatever its share: started last, it
# ends the run a moment later, and a suite of quick items would otherwise be all head.
const LONG_FLOOR_S = 3.0

"""
    order_pool!(pool, units, nslots, cfg, history, changed)

Sort a pool's units into the order they are handed out, by class and then within
it:

0. `[order] first`, in the order listed;
1. sandboxed units, in file order: each needs a fresh process, and at the start
   every process is fresh, so running them first discards no compiled code;
2. units that failed recently, or whose file changed since the last run: the
   answer most likely to matter, as early as it can be had. A failure in the
   newest run and a changed file come first, then older failures, the more recent
   first; file order within each;
3. units long enough to decide how long the run takes — more than a quarter of
   one slot's share of the pool's work, and at least `LONG_FLOOR_S` — longest first;
4. everything else, in file order, where neighbours share compiled code;
5. `[order] last`, in the order listed.

Classes 0–3 are the pool's head, 4 its body and 5 its tail. A chain goes where
its most urgent member would. The class is recorded as a [`Why`](@ref), whose
values are these numbers.
"""
function order_pool!(pool::Vector{Int}, units::Vector{UnitDraft}, nslots::Int, cfg, history::History, changed)
    pin = Dict{String, Int}()
    for (i, n) in enumerate(cfg.order_first)
        pin[n] = i - length(cfg.order_first) - 1
    end
    for (i, n) in enumerate(cfg.order_last)
        pin[n] = i
    end
    share = sum(u -> units[u].est_s, pool; init = 0.0) / max(nslots, 1)
    for u in pool
        d = units[u]
        p = minimum(it -> get(pin, it.name, 0), d.items)
        at = (d.items[1].file, d.items[1].line)
        ago, k = findmin(it -> get(history.failed, it.name, typemax(Int)), d.items)
        d.failed_ago = ago == typemax(Int) ? Int32(-1) : Int32(ago)
        d.failed_at = ago == typemax(Int) ? 0 : k
        d.changed_at = something(findfirst(it -> it.file in changed, d.items), 0)
        urgency = d.changed_at > 0 ? 0 : ago
        d.why = p < 0 ? PINNED_FIRST : p > 0 ? PINNED_LAST : d.exclusive ? SANDBOXED :
            urgency < typemax(Int) ? RECENT :
            d.est_s >= LONG_FLOOR_S && d.est_s > share / 4 ? LONG : IN_FILE_ORDER
        d.key = (
            Int(d.why), d.why === RECENT ? urgency : p, d.why === LONG ? -d.est_s : 0.0, at...,
        )
    end
    return sort!(pool; by = u -> units[u].key)
end

# What a unit without an estimate counts as: the median of the estimates there are,
# or a second when there are none, so that units with nothing known still count
# the same as one another.
function typical_estimate(est::AbstractVector{Float64})
    known = sort!(filter(>(0), est))
    return isempty(known) ? 1.0 : known[(end + 1) ÷ 2]
end

"""
    stretches(body, est, file, n) -> Vector{UnitRange}

`body` cut into `n` stretches holding about the same estimated work — the same
number of units when nothing is estimated — each cut made at the file boundary
nearest its ideal place, so that one worker walks a whole file. A unit with no
estimate counts as a typical one.
"""
function stretches(body::UnitRange{UnitIdx}, est::Vector{Float64}, file::Vector{Int32}, n::Int)
    m = length(body)
    guess = typical_estimate(est[body])
    cum = cumsum([e > 0 ? e : guess for e in est[body]])
    at = [j for j in 1:(m - 1) if file[body[j]] != file[body[j + 1]]]
    isempty(at) && (at = collect(1:(m - 1)))
    cuts = [isempty(at) ? m : at[argmin(abs.(cum[at] .- k * cum[end] / n))] for k in 1:(n - 1)]
    edges = [0; cuts; m]
    return [body[(edges[k] + 1):edges[k + 1]] for k in 1:n]
end

function materialize(
        units::Vector{UnitDraft}, pools::Vector{Vector{Int}}, slots::Vector{Int},
        profiles::Vector{Profile}, cfg::RunConfig, root::AbstractString, selection::AbstractString,
        suite_names::Vector{String}
    )
    # Pool by pool, in the order each hands out its units: item index order is the
    # order of the plan, which is what the dry run prints and what the run state
    # is indexed by.
    name = String[]; fileidx = Int32[]; line = Int32[]
    tags = Symbol[]; tag_span = UnitRange{Int32}[]
    setups = Symbol[]; setup_span = UnitRange{Int32}[]
    code = Expr[]; skip = Any[]; timeout = Int32[]; retries = Int32[]
    failfast = Int8[]; item_unit = UnitIdx[]
    files = String[]; fileids = Dict{String, Int32}()
    uspan = UnitRange{ItemIdx}[]; uprofile = ProfileIdx[]; uexcl = Bool[]
    uchain = Symbol[]; uest = Float64[]; ufile = Int32[]
    uwhy = Why[]; uago = Int32[]; ufailed = ItemIdx[]; uchanged = ItemIdx[]
    all_setups = Symbol[]
    ps = Pool[]; slot_pool = Int32[]; slot_units = UnitRange{UnitIdx}[]; pending = Int32[]
    for (k, pool) in enumerate(pools)
        start = length(uspan)
        for u in pool
            d = units[u]
            ifirst = ItemIdx(length(name) + 1)
            for it in d.items
                push!(name, it.name)
                fid = get!(fileids, it.file) do
                    push!(files, it.file); Int32(length(files))
                end
                push!(fileidx, fid); push!(line, it.line)
                push!(tag_span, span!(tags, it.tags))
                push!(setup_span, span!(setups, it.setups))
                append!(all_setups, it.setups)
                push!(code, it.code); push!(skip, it.skip)
                push!(timeout, it.timeout_s); push!(retries, it.retries)
                push!(failfast, it.failfast)
                push!(item_unit, UnitIdx(length(uspan) + 1))
            end
            push!(uspan, ifirst:ItemIdx(length(name)))
            push!(uprofile, d.profile); push!(uexcl, d.exclusive)
            push!(uchain, d.chain); push!(uest, d.est_s); push!(ufile, fileidx[ifirst])
            push!(uwhy, d.why); push!(uago, d.failed_ago)
            push!(ufailed, d.failed_at == 0 ? ItemIdx(0) : ifirst + ItemIdx(d.failed_at - 1))
            push!(uchanged, d.changed_at == 0 ? ItemIdx(0) : ifirst + ItemIdx(d.changed_at - 1))
        end
        nhead = count(u -> units[u].key[1] in HEAD_CLASSES, pool)
        ntail = count(u -> units[u].key[1] == TAIL_CLASS, pool)
        stop = length(uspan)
        between(a, b) = UnitIdx(a):UnitIdx(b)
        body = between(start + nhead + 1, stop - ntail)
        push!(ps, Pool(units[pool[1]].profile, between(start + 1, start + nhead), body, between(stop - ntail + 1, stop)))
        slots[k] == 0 && push!(pending, Int32(k))
        for r in stretches(body, uest, ufile, slots[k])
            push!(slot_pool, Int32(k)); push!(slot_units, r)
        end
    end

    items = Items(
        name, fileidx, line, tags, tag_span, setups, setup_span,
        code, skip, timeout, retries, failfast, item_unit
    )
    relfiles = String[relpath_or_path(f, root) for f in files]
    return Plan(
        items, Units(uspan, uprofile, uexcl, uchain, uest, uwhy, uago, ufailed, uchanged), files, relfiles,
        String[string(relfiles[fileidx[i]], ":", line[i]) for i in eachindex(name)],
        profiles, ps, slot_pool, slot_units, pending, sort!(unique!(all_setups)), cfg,
        String(root), Startup(), String(selection), suite_names
    )
end

function span!(store::Vector{T}, vals::Vector{T}) where {T}
    first_ = Int32(length(store) + 1)
    append!(store, vals)
    return first_:Int32(length(store))
end
