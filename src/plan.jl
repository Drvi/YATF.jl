# Turning scanned items into a plan.
#
# The plan is computed once, before anything is started, and is the single source
# of truth for what runs where and in what order. `--dry-run` prints this and
# stops; a real run executes exactly it. They are the same code path, which is
# what makes the dry run worth trusting.

"""
    Items

Per-item data in plan order, laid out as arrays rather than objects: the
scheduler only ever touches indices, and the bulky fields (`code`, `skip`) are
never touched on a hot path at all.
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
    group::Vector{Int32}
end

Base.length(u::Units) = length(u.span)

struct Pool
    profile::ProfileIdx
    exclusive::Bool
    slots::Vector{SlotIdx}
    units::Vector{UnitIdx}
    est_s::Float64
end

"""
    Startup

Where the time before the first test item went. Reported in the run's header,
because on a large suite this is the part people wait through and it is otherwise
invisible.
"""
mutable struct Startup
    files::Float64   # finding and reading the test files
    plan::Float64   # ordering them and assigning them to workers
    env::Float64   # building or finding the test environment
    precompile::Float64   # precompiling setups the plan needs
end
Startup() = Startup(0.0, 0.0, 0.0, 0.0)

struct Plan
    items::Items
    units::Units
    files::Vector{String}
    # The same paths relative to the project, computed once here. Every item's
    # report, spec and run state entry needs one, and `relpath` is a split-and-
    # rejoin over two paths: thousands of items against tens of files.
    relfiles::Vector{String}
    # `file:line` per item, built here rather than once per dispatch. An item that
    # is retried is dispatched more than once and this never changes.
    locations::Vector{String}
    profiles::Vector{Profile}
    pools::Vector{Pool}
    slot_pool::Vector{Int32}                # slot -> pool index
    slot_units::Vector{UnitRange{UnitIdx}}   # slot -> its queue, contiguous
    pending::Vector{Int32}                # pools with no slot yet, in pickup order
    pending_units::Vector{UnitRange{UnitIdx}} # their queues, aligned with `pending`
    setups::Vector{Symbol}               # setups to precompile
    cfg::RunConfig
    root::String
    startup::Startup
end

nslots(p::Plan) = length(p.slot_pool)
nitems(p::Plan) = length(p.items)

# Where an item is, as the run reports it.
itemfile(p::Plan, i::Integer) = p.relfiles[p.items.fileidx[i]]
itemlocation(p::Plan, i::Integer) = p.locations[i]

"""
    History

What earlier runs measured, keyed by item name. Empty on a first run, in which
case every estimate is zero and grouping falls back to declaration order.
"""
struct History
    seconds::Dict{String, Float64}
    failed::Set{String}
end
History() = History(Dict{String, Float64}(), Set{String}())

"""
    plan(raw, cfg, profiles; history, root) -> Plan

Validate, group into units, order, and assign to slots.
"""
function plan(
        raw::Vector{RawItem}, cfg::RunConfig; history::History = History(),
        root::AbstractString = "", strict_order::Bool = true
    )
    isempty(raw) && throw(NoTestsError("no test items to run"))
    validate_profiles(raw, cfg)
    # Only a full run can tell a typo in [order] from an item the filter removed,
    # so the check is strict there and permissive under a filter.
    strict_order && validate_order(raw, cfg)

    profiles, profile_idx = profile_table(cfg)
    units_raw = build_units(raw, profile_idx)          # Vector{Vector{RawItem}} + metadata
    order_units!(units_raw, cfg, history)
    pools = build_pools(units_raw, history)
    assign_slots!(pools, cfg, units_raw, history)
    return materialize(units_raw, pools, profiles, cfg, root)
end

function validate_profiles(raw, cfg)
    bad = Dict{Symbol, Vector{RawItem}}()
    for it in raw
        it.profile === DEFAULT_PROFILE && continue
        haskey(cfg.profiles, it.profile) || push!(get!(bad, it.profile, RawItem[]), it)
    end
    isempty(bad) && return
    io = IOBuffer()
    known = sort!(string.(collect(keys(cfg.profiles))))
    for (name, items) in sort!(collect(bad); by = first)
        println(io, "  `sandbox=:$name` has no [profiles.$name] in TestItems.toml, used by:")
        for it in items
            println(io, "    ", repr(it.name), " at ", relpath_or_path(it.file), ":", it.line)
        end
    end
    throw(ConfigError("unknown sandbox profiles (known: $(join(known, ", "))):\n" * String(take!(io))))
end

function validate_order(raw, cfg)
    names = Set(it.name for it in raw)
    missing_ = String[]
    for n in Iterators.flatten((cfg.order_first, cfg.order_last))
        n in names || push!(missing_, n)
    end
    isempty(missing_) && return
    io = IOBuffer()
    println(io, "[order] of TestItems.toml names test items that do not exist:")
    for n in missing_
        near = nearest(n, names)
        println(io, "  ", repr(n), isempty(near) ? "" : "  (did you mean $(join(map(repr, near), " or "))?)")
    end
    throw(ConfigError(String(take!(io))))
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

# A unit under construction: its items, and the properties the scheduler needs.
mutable struct UnitDraft
    items::Vector{RawItem}
    profile::ProfileIdx
    exclusive::Bool
    chain::Symbol
    est_s::Float64
    group::Int32
    pin::Int32                 # <0 pinned to the front, >0 to the back, 0 unpinned
    failed::Bool                  # failed the last recorded run
    key::Tuple{String, Int32}   # first item's (file, line): the tiebreak that makes order deterministic
end

function build_units(raw::Vector{RawItem}, profile_idx)
    chains = Dict{Symbol, Vector{RawItem}}()
    units = UnitDraft[]
    for it in raw
        if it.chain === NO_CHAIN
            push!(
                units, UnitDraft(
                    [it], profile_idx[it.profile], it.exclusive, NO_CHAIN,
                    0.0, Int32(0), Int32(0), false, (it.file, it.line)
                )
            )
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
        push!(
            units, UnitDraft(
                its, profile_idx[first_.profile], false, name, 0.0, Int32(0),
                Int32(0), false, (first_.file, first_.line)
            )
        )
    end
    isempty(errors) || throw(ScanFailure(sort!(errors; by = e -> (e.file, e.line))))
    sort!(units; by = u -> u.key)
    return units
end

# Affinity: items that `using` the same setups, and items from the same file,
# share compiled code. Putting them on one worker is the cheapest way to stop
# paying for the same compilation on several workers at once.
function affinity_key(u::UnitDraft)
    setups = sort!(unique!(reduce(vcat, (it.setups for it in u.items); init = Symbol[])))
    return (setups, u.items[1].file)
end

function order_units!(units::Vector{UnitDraft}, cfg::RunConfig, history::History)
    for u in units
        u.est_s = sum(it -> get(history.seconds, it.name, 0.0), u.items; init = 0.0)
    end
    groups = Dict{Tuple{Vector{Symbol}, String}, Int32}()
    for u in units
        u.group = get!(groups, affinity_key(u), Int32(length(groups) + 1))
    end
    # Failures first: a unit that failed last time is likely still broken, and
    # finding that out early is worth more than any packing gain.
    rank = Dict{String, Int}()
    for (i, n) in enumerate(cfg.order_first)
        rank[n] = -1_000_000 + i
    end
    for (i, n) in enumerate(cfg.order_last)
        rank[n] = 1_000_000 + i
    end
    pos = Dict{UnitDraft, Int}(u => i for (i, u) in enumerate(units))
    for u in units
        u.pin = Int32(clamp(minimum(it -> get(rank, it.name, 0), u.items), -typemax(Int32), typemax(Int32)))
        u.failed = any(it -> it.name in history.failed, u.items)
    end
    sort!(units; by = u -> (u.pin, u.failed ? -1 : 0, pos[u]))
    return units
end

function build_pools(units::Vector{UnitDraft}, history::History)
    byprofile = Dict{Tuple{ProfileIdx, Bool}, Vector{UnitIdx}}()
    for (i, u) in enumerate(units)
        push!(get!(byprofile, (u.profile, u.exclusive), UnitIdx[]), UnitIdx(i))
    end
    keys_ = sort!(collect(keys(byprofile)))
    return [
        Pool(
            p, excl, SlotIdx[], byprofile[(p, excl)],
            sum(i -> units[i].est_s, byprofile[(p, excl)]; init = 0.0)
        )
            for (p, excl) in keys_
    ]
end

# `workers` is a hard cap on live processes, because that cap is what bounds
# memory and duplicated compilation. When there are more pools than slots, a slot
# rebinds to another profile once its own pool drains rather than the cap being
# exceeded.
function assign_slots!(pools::Vector{Pool}, cfg::RunConfig, units, history::History)
    budget = max(cfg.workers, 1)
    order = sortperm(pools; by = p -> (-p.est_s, -length(p.units)))
    slot = SlotIdx(0)
    for k in order
        p = pools[k]
        slot >= budget && break
        push!(p.slots, (slot += SlotIdx(1)))
    end
    # Anything left over goes to the pools with the most work, never beyond the
    # number of units they actually have.
    while slot < budget
        best, bestload = 0, -Inf
        for k in order
            p = pools[k]
            isempty(p.slots) && continue
            length(p.slots) >= length(p.units) && continue
            load = (p.est_s > 0 ? p.est_s : Float64(length(p.units))) / length(p.slots)
            load > bestload || continue  # the pool with the most work per slot gets the next one
            best, bestload = k, load
        end
        best == 0 && break
        push!(pools[best].slots, (slot += SlotIdx(1)))
    end
    return pools
end

# Greedy longest-processing-time-first over the affinity groups: whole groups go
# to the least-loaded slot, so a worker sees related items back to back.
function assign_groups(pool::Pool, units::Vector{UnitDraft})
    nslot = length(pool.slots)
    queues = [UnitIdx[] for _ in 1:max(nslot, 1)]
    nslot == 0 && (append!(queues[1], pool.units); return queues)  # pool waiting for a rebind
    # `[order]` is a hard constraint, so pinned units are placed directly and are
    # never handed to the packer, which would reorder them for cache affinity.
    pinned_first = [u for u in pool.units if units[u].pin < 0]
    pinned_last = [u for u in pool.units if units[u].pin > 0]
    # A unit that failed last time is dispatched before anything the packer would
    # choose: finding out that it is still broken is worth more than a packing win.
    failed_first = [u for u in pool.units if units[u].pin == 0 && units[u].failed]
    groups = Dict{Int32, Vector{UnitIdx}}()
    gorder = Int32[]
    for u in pool.units
        (units[u].pin == 0 && !units[u].failed) || continue
        g = units[u].group
        haskey(groups, g) || push!(gorder, g)
        push!(get!(groups, g, UnitIdx[]), u)
    end
    weight(g) = sum(u -> max(units[u].est_s, 0.0), groups[g]; init = 0.0)
    sort!(gorder; by = g -> (-weight(g), -length(groups[g]), g))
    # Round-robin in listed order: with more than one worker the pinned items are
    # *dispatched* in this order, which is what ordering can mean when several
    # processes run at once. Sequential execution is what `chain` is for.
    for (j, u) in enumerate(pinned_first)
        push!(queues[mod1(j, nslot)], u)
    end
    for (j, u) in enumerate(failed_first)
        push!(queues[mod1(j, nslot)], u)
    end
    load = zeros(Float64, nslot)
    for g in gorder
        s = argmin(load)
        append!(queues[s], groups[g])
        load[s] += max(weight(g), Float64(length(groups[g])))
    end
    for (j, u) in enumerate(pinned_last)
        push!(queues[mod1(j, nslot)], u)
    end
    rebalance_empty!(queues)
    return queues
end

# A group is kept whole for cache affinity, but an idle worker beats affinity we
# cannot yet prove pays for itself: hand the tail of the longest queue to any slot
# that would otherwise have nothing to do. The tail is the right end to give away
# because it is the part the owner has not warmed up either.
function rebalance_empty!(queues::Vector{Vector{UnitIdx}})
    while true
        empty_i = findfirst(isempty, queues)
        empty_i === nothing && return queues
        donor = argmax(map(length, queues))
        length(queues[donor]) >= 2 || return queues
        push!(queues[empty_i], pop!(queues[donor]))
    end
    return
end

function materialize(
        units::Vector{UnitDraft}, pools::Vector{Pool},
        profiles::Vector{Profile}, cfg::RunConfig, root::AbstractString
    )
    # Linearize: slot by slot, queue order, items in unit order. Item index order
    # is therefore the order items run if the slots were concatenated, which is
    # what the dry run prints and what the run state is indexed by.
    slot_pool = Int32[]
    slot_queue = Vector{UnitIdx}[]
    for (k, p) in enumerate(pools)
        qs = assign_groups(p, units)
        for (j, s) in enumerate(p.slots)
            push!(slot_pool, Int32(k)); push!(slot_queue, qs[j])
        end
        isempty(p.slots) || continue
        # A pool with no slot yet still needs its queue kept for the slot that
        # will rebind to it later.
        push!(slot_pool, Int32(k)); push!(slot_queue, qs[1])
    end
    pending = Int32[]
    keep = trues(length(slot_pool))
    for (i, k) in enumerate(slot_pool)
        if isempty(pools[k].slots)
            push!(pending, k); keep[i] = false
        end
    end

    name = String[]; fileidx = Int32[]; line = Int32[]
    tags = Symbol[]; tag_span = UnitRange{Int32}[]
    setups = Symbol[]; setup_span = UnitRange{Int32}[]
    code = Expr[]; skip = Any[]; timeout = Int32[]; retries = Int32[]
    failfast = Int8[]; item_unit = UnitIdx[]
    files = String[]; fileids = Dict{String, Int32}()
    uspan = UnitRange{ItemIdx}[]; uprofile = ProfileIdx[]; uexcl = Bool[]
    uchain = Symbol[]; uest = Float64[]; ugroup = Int32[]
    slot_units = UnitRange{UnitIdx}[]
    all_setups = Symbol[]

    # Slots that have work first, then the queues waiting for a rebind, so that
    # unit indices stay ascending within a slot.
    emit_order = vcat(
        [(i, slot_queue[i]) for i in eachindex(slot_queue) if keep[i]],
        [(i, slot_queue[i]) for i in eachindex(slot_queue) if !keep[i]]
    )
    for (_, q) in emit_order
        ufirst = UnitIdx(length(uspan) + 1)
        for u in q
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
            push!(uchain, d.chain); push!(uest, d.est_s); push!(ugroup, d.group)
        end
        push!(slot_units, ufirst:UnitIdx(length(uspan)))
    end

    items = Items(
        name, fileidx, line, tags, tag_span, setups, setup_span,
        code, skip, timeout, retries, failfast, item_unit
    )
    us = Units(uspan, uprofile, uexcl, uchain, uest, ugroup)
    # Queues for slots come first in `emit_order`, so the trailing entries are the
    # queues waiting for a slot to rebind to them.
    nreal = count(keep)
    relfiles = String[relpath_or_path(f, root) for f in files]
    return Plan(
        items, us, files, relfiles,
        String[string(relfiles[fileidx[i]], ":", line[i]) for i in eachindex(name)],
        profiles, pools, slot_pool[keep], slot_units[1:nreal],
        pending, slot_units[(nreal + 1):end], sort!(unique!(all_setups)), cfg, String(root),
        Startup()
    )
end

function span!(store::Vector{T}, vals::Vector{T}) where {T}
    first_ = Int32(length(store) + 1)
    append!(store, vals)
    return first_:Int32(length(store))
end
