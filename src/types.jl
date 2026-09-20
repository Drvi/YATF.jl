const ItemIdx = Int32
const UnitIdx = Int32
const ProfileIdx = Int8
const SlotIdx = Int16

const NO_CHAIN = Symbol("")
const DEFAULT_PROFILE = :default
const EXCLUSIVE_SUFFIX = "__exclusive"

const USE_RUN_DEFAULT = Int32(-1)

"""
    RawItem

One `@testitem` as the scanner read it: a pure function of the file's bytes.
Nothing here was evaluated; `code` and `skip` are unevaluated expressions that
only ever run on the process that runs the test item.
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

"""
    ScanError

A problem in a test file, located. Scanning collects every one of these before
failing, so a user with five broken files sees five errors, not one.
"""
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
    TagExpr

A tag selection written as a string in Julia's own syntax — `"fast"`, `"!slow"`,
`"fast && !slow"`, `"juliac || serializer"` — for what a vector of tags cannot say:
that an item must *not* carry a tag, or may carry one of several. `&&` binds
tighter than `||`, and there are no parentheses. Held in disjunctive normal form,
so matching an item is one pass over a small flat table.
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

The whole of a run's selection, applied while scanning. `name` and `tags` are
matched against every item, `paths` against the file it is in (empty means every
file), and `line` selects the single item defined at or above that line. `tags` is
a vector an item must carry every one of, or a [`TagExpr`](@ref).

Every test file is read whether or not the selection can reach it: a suite that
does not parse, or that declares one name twice, is a broken suite and not a
smaller one. What the filter decides is which items *run*.
"""
struct Filter
    name::Union{Nothing, String, Regex}
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
    # An operator inside an element is a tag expression that was handed over one
    # element at a time. Read as a name it would match nothing and say nothing.
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
# `bytes` overload: avoids materializing a String for the common exact-match case
matches_name(::Nothing, ::AbstractVector{UInt8}) = true
matches_name(f::AbstractString, name::AbstractVector{UInt8}) = codeunits(f) == name
matches_name(f::Regex, name::AbstractVector{UInt8}) = occursin(f, String(copy(name)))

matches_tags(::Nothing, ::Vector{Symbol}) = true
matches_tags(want::Vector{Symbol}, have::Vector{Symbol}) = all(in(have), want)
matches_tags(e::TagExpr, have::Vector{Symbol}) =
    any(alt -> all(((tag, present),) -> (tag in have) == present, alt), e.alternatives)

# A selected path is either the file itself or a directory holding it.
matches_path(paths::Vector{String}, file::AbstractString) =
    isempty(paths) || any(p -> file == p || startswith(file, endswith(p, '/') ? p : p * "/"), paths)

"""
    ItemName

The name and place of a test item the filter did not select. Kept because name
uniqueness is a property of the suite, not of one run's selection: without these,
two items could share a name for as long as no single run saw both.
"""
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
