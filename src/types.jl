const ItemIdx = Int32
const UnitIdx = Int32
const ProfileIdx = Int8
const SlotIdx = Int16

const NO_CHAIN = Symbol("")
const DEFAULT_PROFILE = :default

const USE_RUN_DEFAULT = Int32(-1)

"""
    RawItem

One `@testitem` as the scanner read it: a pure function of the file's bytes.
`code` and `skip` are unevaluated; they only ever run where the item runs.
"""
struct RawItem
    name::String
    file::String
    line::Int32
    tags::Vector{Symbol}
    setups::Vector{Symbol}   # modules `using`d by the body, filtered to known setups
    code::Expr
    skip::Any              # Bool, or an expression evaluated on the worker
    timeout_s::Int32            # USE_RUN_DEFAULT to inherit
    retries::Int32            # USE_RUN_DEFAULT to inherit
    failfast::Int8             # -1 to inherit, 0/1 otherwise
    chain::Symbol           # NO_CHAIN when the item stands alone
    profile::Symbol           # DEFAULT_PROFILE, or a name from TestItems.toml
    exclusive::Bool             # sandbox=true: alone in a process, torn down after
end

# A problem in a test file, located. Scanning collects all of them before failing,
# so five broken files are five errors, not one.
struct ScanError
    file::String
    line::Int32
    msg::String
end

Base.show(io::IO, e::ScanError) = print(io, relpath_or_path(e.file), ":", e.line, ": ", e.msg)

struct ScanFailure <: Exception
    errors::Vector{ScanError}
end

function Base.showerror(io::IO, e::ScanFailure)
    n = length(e.errors)
    println(io, "YATF found ", n, n == 1 ? " problem" : " problems", " while reading test files:")
    for err in e.errors
        println(io, "  ", err)
    end
    return
end

struct NoTestsError <: Exception
    msg::String
end
Base.showerror(io::IO, e::NoTestsError) = print(io, "YATF: ", e.msg)

struct ConfigError <: Exception
    msg::String
end
Base.showerror(io::IO, e::ConfigError) = print(io, "YATF: ", e.msg)

"""
    RunStalled

Thrown when no test item finished for longer than one attempt at any of them may
take (see [`stall_limit`](@ref)): something that should have stopped did not, and
the run was stopped as hung.
"""
struct RunStalled <: Exception
    limit::Float64
end
Base.showerror(io::IO, e::RunStalled) = print(
    io, "YATF: no test item finished in ", fmt_seconds(e.limit),
    ", longer than one attempt at any of them may take, so the run was stopped as hung; ",
    "the items that were running are recorded as timed out"
)

"""
    TagExpr

A tag selection written in Julia's own syntax — `"!slow"`, `"fast && !slow"`,
`"juliac || serializer"` — for what a vector of tags cannot say. `&&` binds
tighter than `||`; there are no parentheses. Held in disjunctive normal form.
"""
struct TagExpr
    text::String
    alternatives::Vector{Vector{Tuple{Symbol, Bool}}}   # (tag, must be present)
end
Base.show(io::IO, e::TagExpr) = show(io, e.text)

# Anything that is not whitespace or an operator. `:` is refused so that `":fast"`
# says what is wrong instead of matching nothing.
const TAG_NAME = r"^[^\s!&|:()]+$"

function parse_tag_expr(text::AbstractString)
    alternatives = Vector{Tuple{Symbol, Bool}}[]
    for alt in split(text, "||")
        terms = Tuple{Symbol, Bool}[]
        for term in split(alt, "&&")
            s = strip(term)
            present = !startswith(s, '!')
            present || (s = strip(chop(s; head = 1, tail = 0)))
            isempty(s) && throw(
                ArgumentError(
                    "`tags = $(repr(text))`: a tag name is missing" * (present ? "" : " after `!`")
                )
            )
            occursin(TAG_NAME, s) || throw(
                ArgumentError(
                    "`tags = $(repr(text))`: $(repr(String(s))) is not a tag name; a tag " *
                        "expression is names joined with `&&` and `||`, each optionally " *
                        "negated with `!`, as in `fast && !slow`"
                )
            )
            push!(terms, (Symbol(s), present))
        end
        push!(alternatives, terms)
    end
    return TagExpr(String(text), alternatives)
end

"""
    Filter

A run's selection: `name` (exact, a `Regex`, or a set of exact names) and `tags`
(a vector an item must carry all of, or a [`TagExpr`](@ref)) are matched against items, `paths` against their files (empty
means all), and `line` picks the item defined at or above it. Every test file is
read whatever the selection: a suite that does not parse is broken, not smaller.
"""
struct Filter
    name::Union{Nothing, String, Regex, Set{String}}
    tags::Union{Nothing, Vector{Symbol}, TagExpr}
    paths::Vector{String}
    line::Int32
end
Filter(; name = nothing, tags = nothing, paths = String[], line = 0) =
    Filter(name, _astags(tags), collect(paths), Int32(line))

_astags(::Nothing) = nothing
_astags(t::Symbol) = [t]
_astags(t::AbstractString) = parse_tag_expr(t)
function _astags(t)
    applicable(iterate, t) || throw(ArgumentError(
        "`tags = $(repr(t))`: expected a tag name, a collection of tag names, or a tag " *
            "expression written as a string, as in `tags = \"fast && !slow\"`"
    ))
    return Symbol[_astag(x) for x in t]
end

_astag(t::Symbol) = t
function _astag(t::AbstractString)
    # An operator inside an element is a tag expression handed over one element at
    # a time; read as a name it would match nothing and say nothing.
    occursin(TAG_NAME, t) || throw(ArgumentError(
        "`tags`: $(repr(String(t))) is not a tag name; write a tag expression as one " *
            "string rather than as an element, as in `tags = $(repr(String(t)))` on its own"
    ))
    return Symbol(t)
end
_astag(t) = throw(ArgumentError(
    "`tags`: $(repr(t)) is not a tag name; tags are symbols or strings"
))

matches_name(::Nothing, ::AbstractString) = true
matches_name(f::AbstractString, name::AbstractString) = f == name
matches_name(f::Regex, name::AbstractString) = occursin(f, name)
matches_name(f::Set{String}, name::AbstractString) = name in f

matches_tags(::Nothing, ::Vector{Symbol}) = true
matches_tags(want::Vector{Symbol}, have::Vector{Symbol}) = all(in(have), want)
matches_tags(e::TagExpr, have::Vector{Symbol}) =
    any(alt -> all(((tag, present),) -> (tag in have) == present, alt), e.alternatives)

# A selected path is either the file itself or a directory holding it. Both come
# from `abspath` and `walkdir`, so both use the platform's own separator.
matches_path(paths::Vector{String}, file::AbstractString) =
    isempty(paths) || any(p -> file == p || startswith(file, joinpath(p, "")), paths)

# What separates the parts of a path here: `/`, and on Windows `\` as well.
const PATH_SEPARATORS = Sys.iswindows() ? ('\\', '/') : ('/',)

# A test item the filter did not select. Names must be unique across the suite,
# not just across one run's selection.
struct ItemName
    name::String
    file::String
    line::Int32
end

function relpath_or_path(path::AbstractString, root::AbstractString = something(PROJECT_ROOT[], ""))
    isempty(root) && return path
    r = relpath(path, root)
    return startswith(r, "..") ? path : r
end

const PROJECT_ROOT = Ref{Union{Nothing, String}}(nothing)
