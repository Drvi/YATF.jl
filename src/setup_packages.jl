# Setups as packages. A module in `test/testsetups/` without a project of its own has
# no UUID, and Julia files the precompile cache of such a module under its name
# alone: one file per depot, rewritten by every checkout with a setup of that name
# and by every set of Julia flags. A package's cache is filed under its UUID, with
# the flags and the active project in the file's name, so each keeps its own.

const JuliaSyntax = Base.JuliaSyntax

"""
    setups_to_packages([path])

Make every module in the package's `test/testsetups/` a package of its own, so that
its precompile cache is kept per checkout and per set of Julia flags instead of in
one file that each of them rewrites. `Name.jl` moves to `Name/src/Name.jl`, beside a
`Name/Project.toml` that gives it a UUID and lists the packages it imports as its
`[deps]`. Test items load it with `using Name`, as before.

A package can import only what its `[deps]` list, so run this again after a setup
starts importing something new: it adds what is missing, changes nothing else, and
keeps the UUIDs. An import it cannot see, such as one in code that the setup
generates or evaluates as it loads, goes into `[deps]` by hand.

In a moved file, `@__DIR__` becomes `pkgdir(MyPkg, "test", "testsetups")`, for the
package under test, which names the directory the file was in from anywhere, the
REPL included; `joinpath(@__DIR__, "..", "data")` becomes `pkgdir(MyPkg, "test",
"data")`. A setup that does not import the package gets an `import MyPkg` for it.
Nothing is written unless every setup can be converted: an import that neither the
test environment nor the standard library provides, a relative `include` and
`@__FILE__` are reported instead, all of them at once.

`path` finds the package as it does for [`runtests`](@ref).
"""
function setups_to_packages(args...)
    target = resolve_target(args)
    dir = joinpath(target.testdir, TESTSETUPS_DIR)
    modules = setup_modules(target.testdir)
    if isempty(modules)
        println(stdout, yatf_prefix(), "no setups in ", relpath_or_path(dir, target.root))
        return nothing
    end
    plans = plan_setup_packages(target, dir, modules)
    foreach(write_setup_package, plans)
    print_setup_packages(stdout, plans, dir, target.root)
    return nothing
end

# Converting one setup, worked out before anything is written.
struct SetupPackage
    name::String
    source::String                # the module's file as it is
    entry::String                 # and as it will be, `Name/src/Name.jl`
    code::String                  # the text it will have there
    rewritten::Int                # `@__DIR__`s rewritten on the way
    imported::String              # the package an `import` was added for, or ""
    project::String               # `Name/Project.toml`
    toml::Dict{String, Any}       # what that file will hold
    changed::Bool                 # whether that differs from what it holds now
    deps::Vector{String}          # the setup's dependencies after, sorted
    added::Vector{String}         # of those, the ones this adds
end

moves(p::SetupPackage) = p.source != p.entry

function plan_setup_packages(target, dir::String, modules::Dict{Symbol, String})
    names = sort!([String(n) for n in keys(modules)])
    problems = String[]
    shown(path) = relpath_or_path(path, target.root)
    # Every setup's UUID first: a setup can import another.
    tomls = Dict{String, Dict{String, Any}}()
    uuids = Dict{String, Base.UUID}()
    for name in names
        project = joinpath(dir, name, "Project.toml")
        toml = isfile(project) ? TOML.parsefile(project) : Dict{String, Any}()
        get(toml, "name", name) == name ||
            push!(problems, "$(shown(project)): names the package `$(toml["name"])`, not `$name`")
        tomls[name] = toml
        uuids[name] = haskey(toml, "uuid") ? Base.UUID(toml["uuid"]) : random_uuid()
    end
    available = test_env_packages(target)
    # What a moved setup's `@__DIR__` becomes `pkgdir` of; `nothing` for a project
    # that is not a package.
    own = TOML.parsefile(target.project)
    pkg = haskey(own, "uuid") ? String(own["name"]) : nothing
    plans = SetupPackage[]
    for name in names
        source = modules[Symbol(name)]
        entry = joinpath(dir, name, "src", name * ".jl")
        project = joinpath(dir, name, "Project.toml")
        code = read(source, String)
        ex = Meta.parseall(code; filename = source)
        err = first_syntax_error(ex)
        if err !== nothing
            push!(problems, "$(shown(source)):$(err[1]): $(err[2])")
            continue
        end
        any(a -> module_expr(a, Symbol(name)) !== nothing, ex.args) ||
            push!(problems, "$(shown(source)): does not define `module $name`")
        if source != entry && ispath(joinpath(dir, name))
            push!(problems, "$(shown(source)): `$name/` is there as well; move one of them aside")
        end
        # The test environment, then the standard library, then the other setups: the
        # order `LOAD_PATH` has them in during a run.
        deps = Dict{String, Base.UUID}()
        unknown = String[]
        for root in imported_roots(ex)
            n = String(root)
            (root in (:Base, :Core, :Main) || n == name) && continue
            u = something(get(available, n, nothing), stdlib_uuid(n), get(uuids, n, nothing), Some(nothing))
            u === nothing ? push!(unknown, n) : (deps[n] = u)
        end
        isempty(unknown) || push!(
            problems,
            "$(shown(source)): imports $(join(("`$n`" for n in sort!(unknown)), ", ")), which neither " *
                "the test environment nor the standard library provides"
        )
        toml = tomls[name]
        have = get(toml, "deps", Dict{String, Any}())
        for (n, u) in deps
            haskey(have, n) && Base.UUID(have[n]) != u &&
                push!(problems, "$(shown(project)): lists `$n` as $(have[n]); it is $u")
        end
        rewritten, imported = 0, false
        if source != entry
            moved, rewritten, imported, hazards = relocate(code, ex, name, pkg)
            for (at, what) in hazards
                push!(problems, "$(shown(source)):$(line_at(code, at)): $what")
            end
            code = moved
            imported && (deps[pkg] = available[pkg])
        end
        added = sort!([n for n in keys(deps) if !haskey(have, n)])
        after = copy(toml)
        after["name"] = name
        after["uuid"] = string(uuids[name])
        alldeps = merge(Dict{String, Any}(have), Dict{String, Any}(n => string(deps[n]) for n in added))
        isempty(alldeps) || (after["deps"] = alldeps)
        push!(plans, SetupPackage(name, source, entry, code, rewritten, imported ? pkg : "", project, after,
                                  after != toml, sort!(collect(keys(alldeps))), added))
    end
    isempty(problems) || throw(
        ConfigError("no setup can be made a package until these are fixed:\n" * join(("  " * p for p in problems), "\n"))
    )
    return plans
end

function write_setup_package(p::SetupPackage)
    if moves(p)
        mkpath(dirname(p.entry))
        write(p.entry, p.code)
        rm(p.source)
    end
    p.changed && open(io -> TOML.print(io, p.toml; sorted = true, by = project_key_order), p.project, "w")
    return nothing
end

# `name` and `uuid` first, as `Pkg` writes a project.
project_key_order(k) = (k == "name" ? 0 : k == "uuid" ? 1 : 2, k)

function print_setup_packages(io::IO, plans::Vector{SetupPackage}, dir::String, root::String)
    head = styled() do s
        print(s, "setups as packages: ")
        printstyled(s, relpath_or_path(dir, root); color = :light_black)
    end
    body = styled() do s
        print_setup_changes(s, plans, dir; done = true)
    end
    print(io, bracket(body, "[YATF]", head, "", :white))
    return nothing
end

# A line per setup, names aligned: what making it a package did, or with
# `done = false` what it would do, and `indent` before each.
function print_setup_changes(io::IO, plans::Vector{SetupPackage}, dir::String; done::Bool, indent = "")
    width = maximum(p -> textwidth(p.name), plans) + 3
    for p in plans
        print(io, indent, rpad(string('`', p.name, "`:"), width), " ")
        if moves(p)
            print(io, done ? "moved to " : "would move to ")
            printstyled(io, relpath(p.entry, dir); color = :light_black)
            p.rewritten > 0 && print(io, " · `@__DIR__` rewritten ", p.rewritten, "×")
            isempty(p.imported) || print(io, " · `import ", p.imported, "` added")
            println(io, " · deps: ", isempty(p.deps) ? "none" : join(p.deps, ", "))
        elseif !p.changed
            println(io, "up to date")
        elseif isempty(p.added)
            println(io, done ? "project written" : "project to write", " · deps: ",
                    isempty(p.deps) ? "none" : join(p.deps, ", "))
        else
            println(io, done ? "added to deps: " : "to add to deps: ", join(p.added, ", "))
        end
    end
    return nothing
end

"""
    test_env_packages(target) -> Dict{String,UUID}

The packages a test item can import by name: `test/Project.toml`'s `[deps]` when
there is one, or else the package's `[deps]` and the extras its `test` target
names, and the package itself either way.
"""
function test_env_packages(target)
    root = TOML.parsefile(target.project)
    out = Dict{String, Base.UUID}()
    haskey(root, "uuid") && (out[root["name"]] = Base.UUID(root["uuid"]))
    testproj = joinpath(target.testdir, "Project.toml")
    if isfile(testproj)
        for (n, u) in get(TOML.parsefile(testproj), "deps", Dict{String, Any}())
            out[n] = Base.UUID(u)
        end
    else
        for (n, u) in get(root, "deps", Dict{String, Any}())
            out[n] = Base.UUID(u)
        end
        test = get(get(root, "targets", Dict{String, Any}()), "test", String[])
        for section in ("extras", "weakdeps"), (n, u) in get(root, section, Dict{String, Any}())
            n in test && (out[n] = Base.UUID(u))
        end
    end
    return out
end

function stdlib_uuid(name::AbstractString)
    project = joinpath(Sys.STDLIB, name, "Project.toml")
    isfile(project) || return nothing
    u = get(TOML.parsefile(project), "uuid", nothing)
    return u === nothing ? nothing : Base.UUID(u)
end

# A version 4 UUID, made as `UUIDs.uuid4` makes one.
random_uuid() = Base.UUID(
    (rand(RandomDevice(), UInt128) & 0xffffffffffff0fff3fffffffffffffff) | 0x00000000000040008000000000000000
)

# The `module name` a top-level statement defines, or `nothing`. A module with a
# docstring parses as the docstring's macro call around the module. Its name and
# body are its last two arguments: from 1.14 a syntax version comes first.
function module_expr(ex, name::Symbol)
    ex isa Expr || return nothing
    ex.head === :module && return ex.args[end - 1] === name ? ex : nothing
    ex.head === :macrocall && return module_expr(ex.args[end], name)
    return nothing
end

# The name the top level of setup module `name` binds package `pkg` to: `pkg` for a
# plain `using pkg` or `import pkg`, `X` for `import pkg as X`, or `nothing`.
function package_binding(ex::Expr, name::Symbol, pkg::Symbol)
    for a in ex.args
        m = module_expr(a, name)
        m === nothing && continue
        for st in m.args[end].args
            st isa Expr && (st.head === :using || st.head === :import) || continue
            for b in st.args
                b isa Expr && b.head === :. && b.args == Any[pkg] && return pkg
                if st.head === :import && b isa Expr && b.head === :as && b.args[1] isa Expr &&
                        b.args[1].args == Any[pkg]
                    return b.args[2]::Symbol
                end
            end
        end
    end
    return nothing
end

# Where `Meta.parseall` put a syntax error in place of a statement: its line and
# message, or `nothing`.
function first_syntax_error(ex::Expr)
    line = 0
    for a in ex.args
        a isa LineNumberNode && (line = a.line; continue)
        if a isa Expr && a.head in (:error, :incomplete)
            msg = a.args[1]
            return (line, msg isa AbstractString ? msg : sprint(showerror, msg))
        end
    end
    return nothing
end

"""
    imported_roots(ex) -> Set{Symbol}

The first name of every module that a `using` or `import` anywhere in `ex` reaches
from outside it: `A` of `using A.B: c` and of `import A as B`, and nothing of
`using .A`.
"""
function imported_roots(ex, out::Set{Symbol} = Set{Symbol}())
    ex isa Expr || return out
    if ex.head === :using || ex.head === :import
        for a in ex.args
            a isa Expr && a.head === :(:) && (a = a.args[1])
            a isa Expr && a.head === :as && (a = a.args[1])
            if a isa Expr && a.head === :. && !isempty(a.args) && a.args[1] isa Symbol && a.args[1] !== :.
                push!(out, a.args[1])
            end
        end
        return out
    end
    for a in ex.args
        imported_roots(a, out)
    end
    return out
end

"""
    relocate(code, ex, name, pkg) -> (code, rewritten, imported, hazards)

The text of setup `name` for its new place, two directories deeper in `Name/src/`.
Each `@__DIR__` in code, not in strings or comments, becomes
`pkgdir(pkg, "test", "testsetups")`, which names the directory the file was in
wherever the code runs, the REPL included, and the `".."`s of a
`joinpath(@__DIR__, "..", …)` fold into that call. The package is named as the setup
binds it; a setup that does not gets an `import` of it after its `module` line
(`imported`). `hazards` are what would change meaning and is not rewritten: each
`@__FILE__` and each `include` of a relative path written out, by byte offset.
"""
function relocate(code::String, ex::Expr, name::String, pkg::Union{Nothing, String})
    bytes = codeunits(code)
    toks = JuliaSyntax.tokenize(code)
    n = lastindex(toks)
    text(i) = String(view(bytes, Int(first(toks[i].range)):Int(last(toks[i].range))))
    kind(i) = string(JuliaSyntax.kind(toks[i]))
    first_byte(i) = Int(first(toks[i].range))
    last_byte(i) = Int(last(toks[i].range))
    # From 1.14 a zero-width token follows `module`, the syntax version.
    blank(i) = kind(i) in ("Whitespace", "NewlineWs", "Comment") || isempty(toks[i].range)
    next_token(i) = (j = i + 1; while j <= n && blank(j); j += 1; end; j)
    prev_token(i) = (j = i - 1; while j >= 1 && blank(j); j -= 1; end; j)
    bound = pkg === nothing ? nothing : package_binding(ex, Symbol(name), Symbol(pkg))
    ref = string(something(bound, pkg, ""))
    edits = Tuple{UnitRange{Int}, String}[]
    hazards = Tuple{Int, String}[]
    for i in eachindex(toks)
        at = first_byte(i)
        # Matched by text: what follows `@` is a `MacroName` on some Julia versions
        # and an `Identifier` on others.
        if kind(i) == "@" && i < n
            macro_name = text(i + 1)
            if macro_name == "__DIR__" && pkg === nothing
                push!(hazards, (at, "`@__DIR__` would become `pkgdir` of the package under test, " *
                                    "and the project is not a package"))
            elseif macro_name == "__DIR__"
                stop, last_tok = last_byte(i + 1), i + 1
                # `@__DIR__()` is the same call.
                if i + 3 <= n && text(i + 2) == "(" && text(i + 3) == ")"
                    stop, last_tok = last_byte(i + 3), i + 3
                end
                parts = ["test", TESTSETUPS_DIR]
                p = prev_token(i)
                f = p >= 1 ? prev_token(p) : 0
                if f >= 1 && text(p) == "(" && kind(f) == "Identifier" && text(f) == "joinpath"
                    # Each `".."` after it climbs out of `parts`; the call's other
                    # arguments and its closing parenthesis are left as they are.
                    at, j = first_byte(f), last_tok
                    while !isempty(parts)
                        c = next_token(j)
                        (c <= n && text(c) == ",") || break
                        q = next_token(c)
                        (q + 2 <= n && kind(q) == "\"" && kind(q + 1) == "String" && text(q + 1) == ".." &&
                            kind(q + 2) == "\"") || break
                        pop!(parts)
                        j = q + 2
                        stop = last_byte(j)
                    end
                    push!(edits, (at:stop, string("pkgdir(", ref, join(", \"$c\"" for c in parts))))
                else
                    push!(edits, (at:stop, string("pkgdir(", ref, join(", \"$c\"" for c in parts), ")")))
                end
            elseif macro_name == "__FILE__"
                push!(hazards, (at, "`@__FILE__` would change with the move; use `@__DIR__`, which is " *
                                    "rewritten to keep its meaning"))
            end
        elseif kind(i) == "Identifier" && text(i) == "include" && i + 3 <= n && text(i + 1) == "(" &&
                kind(i + 2) == "\"" && kind(i + 3) == "String" && !isabspath(text(i + 3))
            push!(hazards, (at, "`include` of a relative path would look in `src/` after the move; use " *
                                "`include(joinpath(@__DIR__, …))`, which is rewritten to keep its meaning"))
        end
    end
    rewritten = length(edits)
    imported = rewritten > 0 && bound === nothing && pkg !== nothing
    if imported
        # On a line of its own after `module Name`, indented as the body is.
        for i in eachindex(toks)
            kind(i) in ("module", "baremodule") || continue
            j = next_token(i)
            (j <= n && text(j) == name) || continue
            nl = findnext(==(UInt8('\n')), bytes, last_byte(j))
            at = nl === nothing ? length(bytes) + 1 : nl + 1
            push!(edits, (at:(at - 1), string(nl === nothing ? "\n" : "", body_indent(bytes, at), "import ", pkg, "\n")))
            break
        end
    end
    sort!(edits; by = e -> first(e[1]))
    return replace_ranges(code, edits), rewritten, imported, hazards
end

# The leading blanks of the first line from byte `from` on that has anything else.
function body_indent(bytes, from::Int)
    pos = from
    while pos <= length(bytes)
        stop = something(findnext(==(UInt8('\n')), bytes, pos), length(bytes) + 1)
        k = findfirst(b -> !(b in (UInt8(' '), UInt8('\t'), UInt8('\r'))), view(bytes, pos:(stop - 1)))
        k === nothing || return String(bytes[pos:(pos + k - 2)])
        pos = stop + 1
    end
    return ""
end

# `code` with each range replaced by its text, the ranges in order. An empty range,
# `at:at-1`, inserts at `at`.
function replace_ranges(code::String, edits::Vector{Tuple{UnitRange{Int}, String}})
    isempty(edits) && return code
    bytes = codeunits(code)
    io = IOBuffer()
    pos = 1
    for (r, with) in edits
        write(io, view(bytes, pos:(first(r) - 1)), with)
        pos = last(r) + 1
    end
    write(io, view(bytes, pos:length(bytes)))
    return String(take!(io))
end

line_at(code::String, byte::Integer) = count(==(UInt8('\n')), view(codeunits(code), 1:(byte - 1))) + 1
