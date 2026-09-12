# Every test file carries the prelude it uses.
#
# testutils.jl documents that each file "still runs standalone
# (`julia --project -e 'using EarthSciAST, Test; include("test/<file>")'`) AND
# under runtests.jl". Under runtests.jl a file can violate that and pass anyway:
# `runtests.jl` opens with `using Test` / `using EarthSciAST` / `using JSON3` /
# `include("testutils.jl")`, and 200 more includes follow, so by the time any
# given file runs, almost every name it might want is already in `Main`. Borrow
# one and nothing notices — until someone runs that file on its own (the
# documented way to verify Julia here, since the full test target hangs on the
# shared depot lock) and it dies on an `UndefVarError` before the first
# assertion. Eleven files had drifted that way before this check existed.
#
# So: for each file, what does it USE, and does it IMPORT that?
#
#   1. a `@test…` / `@inferred` macro          ⇒ `using Test`
#   2. `include("testutils.jl")`               ⇒ `using Test` ABOVE that line —
#      the prelude expands a `@test_skip` of its own as it is included, so this
#      one is an ordering requirement, not just a presence one
#   3. a name testutils.jl defines             ⇒ `include("testutils.jl")`
#   4. `SomeModule.something`, where the name
#      is a package this project declares      ⇒ `using SomeModule`
#
# Nothing here is hard-coded. The testutils names in (3) are read out of
# testutils.jl, the modules the prelude itself imports (and therefore hands to
# its includer, which is why (4) does not fire on a file that includes it) are
# read out of testutils.jl too, and the package names in (4) out of
# Project.toml's `[deps]` / `[weakdeps]` / `[extras]` plus the package's own
# `name` — so a new helper or a new test dependency is covered the day it lands.
#
# SCOPE is every `test/*.jl` except `runtests.jl` itself, which is the driver
# that establishes the preamble rather than a file that needs one. There is no
# skip list: an included FRAGMENT (testutils.jl, zero_alloc_harness.jl, the two
# Reactant files) is held to the same bar as an entry point, because a fragment
# that imports what it uses costs nothing and a fragment that does not is one
# `include` away from being the next silent failure.
#
# WHAT THIS CANNOT CATCH. It is static: it verifies the prelude is PRESENT, not
# that the file actually runs in a fresh process. A module reached dynamically
# (`getfield(Main, :JSON3)`, a name interpolated into `@eval`, a macro that
# expands to a reference) is invisible to it, and so is a missing import behind
# any construct the parser does not surface as a qualified reference. It also
# says nothing about whether the file's ASSERTIONS pass.
#
# The evidence for it is agreement, on the case that motivated it, with actually
# running files in fresh processes: every file it flagged and this environment
# could run did fail standalone with the named `UndefVarError`, every one passed
# standalone once the named line was added, and the handful run as controls
# (files it does NOT flag, including one that reaches `JSON3` only through the
# prelude it includes) ran clean. That is agreement on ~15 files, not a sweep of
# all 220 — a measurement, not a guarantee about the next file.
#
# If this fails, add the line it names. Do not narrow the docstring.

# `Test` and nothing else: this file reads the tree, it does not build anything.
# It does not include testutils.jl either — it uses none of those helpers, and an
# import a file does not need is the other half of the habit this check is about.
using Test

const _PRELUDE_TEST_DIR = @__DIR__
const _PRELUDE_PKG_DIR  = normpath(joinpath(_PRELUDE_TEST_DIR, ".."))

# ---------------------------------------------------------------------------
# AST walk. `Meta.parseall` reads a file without running it, so the scan sees
# the file as Julia does rather than as a regex does — a `@test` inside a
# comment or a docstring is simply not in the tree.
# ---------------------------------------------------------------------------

"""
    _prelude_facts(path) -> NamedTuple

What one test file imports, uses and defines.

  * `bound`     — module names the file brings into scope (`using M`,
                  `import M`, `import M as N` ⇒ `N`). A `using M: x` binds `x`
                  and NOT `M`, and is deliberately not counted: a file that
                  writes `M.something` after `using M: x` really is missing an
                  import (checked — Julia leaves `M` undefined there).
  * `macros`    — every macro the file calls, by name (`Symbol("@testset")`).
  * `qualified` — every `M` appearing as `M.something`.
  * `includes`  — every literal `include("…")` target.
  * `defined`   — every name the file itself binds, so a local helper that
                  happens to share a testutils name is not counted as borrowing
                  it, and an alias (`const ESM = EarthSciAST`) is not read as a
                  missing import.
  * `symbols`   — every symbol anywhere in the tree, for the testutils check.
"""
function _prelude_facts(path::AbstractString)
    bound     = Set{Symbol}()
    macros    = Set{Symbol}()
    qualified = Set{Symbol}()
    includes  = Set{String}()
    defined   = Set{Symbol}()
    symbols   = Set{Symbol}()

    # `Expr(:., :M)` inside a using/import clause; `Expr(:as, clause, :N)`.
    function modname(e)
        e isa Expr || return nothing
        e.head === :. && !isempty(e.args) && e.args[1] isa Symbol && return e.args[1]
        return nothing
    end
    function walk_useclause(e)
        e isa Expr || return
        if e.head === :as
            length(e.args) == 2 && e.args[2] isa Symbol && push!(bound, e.args[2])
            return                      # `import M as N` binds N, not M
        elseif e.head === :(:)          # `using M: x` — binds x, not M
            return
        end
        m = modname(e)
        m === nothing || push!(bound, m)
    end
    function def_name(x)
        x isa Symbol && return x
        x isa Expr || return nothing
        x.head === :call && !isempty(x.args) && return def_name(x.args[1])
        x.head in (:where, :(::)) && !isempty(x.args) && return def_name(x.args[1])
        return nothing
    end

    function walk(e)
        e isa Symbol && (push!(symbols, e); return)
        e isa Expr || return
        if e.head in (:using, :import)
            for a in e.args
                walk_useclause(a)
            end
            return                      # the clause itself is not a reference
        elseif e.head === :macrocall && !isempty(e.args) && e.args[1] isa Symbol
            push!(macros, e.args[1])
        elseif e.head === :. && length(e.args) == 2 &&
               e.args[1] isa Symbol && e.args[2] isa QuoteNode
            push!(qualified, e.args[1])
        elseif e.head === :call && !isempty(e.args) && e.args[1] === :include &&
               length(e.args) >= 2 && e.args[2] isa AbstractString
            push!(includes, String(e.args[2]))
        elseif e.head in (:function, :macro, :(=), :const, :struct, :abstract,
                          :global, :local)
            n = def_name(isempty(e.args) ? nothing : e.args[1])
            n === nothing || push!(defined, n)
        end
        for a in e.args
            walk(a)
        end
        return
    end

    walk(Meta.parseall(read(path, String); filename = path))
    return (; bound, macros, qualified, includes, defined, symbols)
end

"""
    _testutils_exports() -> Set{Symbol}

The names testutils.jl defines, read from testutils.jl — so a helper added there
is covered without touching this file.

TOP-LEVEL definitions only. testutils.jl wraps its whole body in an
`if !isdefined(…)` guard, so the walk descends through `block`/`if` and stops at
the first definition: a local `x` inside `_stencil_model`'s body is not a name
anyone can borrow, and counting it would flag every file in the tree that
happens to use an `x`.
"""
function _testutils_exports()
    out = Set{Symbol}()
    function def_name(x)
        x isa Symbol && return x
        x isa Expr || return nothing
        x.head === :call && !isempty(x.args) && return def_name(x.args[1])
        x.head in (:where, :(::)) && !isempty(x.args) && return def_name(x.args[1])
        return nothing
    end
    function toplevel(e)
        e isa Expr || return
        if e.head in (:toplevel, :block, :if, :module)
            for a in e.args
                toplevel(a)
            end
        elseif e.head === :const && !isempty(e.args)
            toplevel(e.args[1])
        elseif e.head in (:function, :macro, :(=), :struct)
            n = def_name(e.args[1])
            n === nothing || push!(out, n)
        end
        return
    end
    path = joinpath(_PRELUDE_TEST_DIR, "testutils.jl")
    toplevel(Meta.parseall(read(path, String); filename = path))
    delete!(out, :ESM_TESTUTILS_LOADED)   # the include guard, not a helper
    return out
end

"""
    _declared_packages() -> Set{Symbol}

Every package name this project declares — `[deps]`, `[weakdeps]` and
`[extras]` of Project.toml, plus the package's own `name`. A `Mod.` reference to
anything outside this set is some local alias or a submodule, not an import this
check has an opinion about.
"""
function _declared_packages()
    out = Set{Symbol}()
    section = ""
    for line in eachline(joinpath(_PRELUDE_PKG_DIR, "Project.toml"))
        s = strip(line)
        if startswith(s, "[")
            section = s
        elseif section in ("[deps]", "[weakdeps]", "[extras]")
            m = match(r"^([A-Za-z_][A-Za-z0-9_]*)\s*=", s)
            m === nothing || push!(out, Symbol(m.captures[1]))
        elseif isempty(section)
            m = match(r"^name\s*=\s*\"([^\"]+)\"", s)
            m === nothing || push!(out, Symbol(m.captures[1]))
        end
    end
    return out
end

"""
    _testutils_provides() -> Set{Symbol}

The modules `include("testutils.jl")` brings into the INCLUDING module, read
from testutils.jl's own `using` lines. `include` is textual, so those imports
land in the includer's scope: a file that includes the prelude and then writes
`JSON3.read` is not borrowing anything it has no claim to.

`Test` is deliberately NOT in this set even though testutils.jl imports it.
testutils.jl expands a `@test_skip` of its own, and macro expansion happens when
the file is INCLUDED — so `Test` has to be in scope BEFORE the include, which
makes it a precondition of the prelude rather than something the prelude
supplies. (This is the hazard api_surface_test.jl's header already documents.)
"""
function _testutils_provides()
    f = _prelude_facts(joinpath(_PRELUDE_TEST_DIR, "testutils.jl"))
    return setdiff(f.bound, Set([:Test]))
end

_is_test_macro(m::Symbol) =
    (startswith(String(m), "@test") || String(m) == "@inferred")

# Line of the first `using Test`, and of the `include("testutils.jl")`, or
# `nothing`. Read from the text rather than the AST because what matters here is
# ORDER, and a line number is the honest unit for that.
function _prelude_lines(path::AbstractString)
    using_test = nothing
    include_tu = nothing
    for (i, line) in enumerate(eachline(path))
        startswith(lstrip(line), "#") && continue
        using_test === nothing && occursin(r"^\s*using\s+Test\b", line) && (using_test = i)
        include_tu === nothing && occursin("include(\"testutils.jl\")", line) && (include_tu = i)
    end
    return (using_test, include_tu)
end

"""
    _missing_prelude(path, tu_names, tu_gives, pkgs) -> Vector{String}

The lines `path` should carry and does not, each spelled as the line to add.
"""
function _missing_prelude(path::AbstractString, tu_names::Set{Symbol},
                          tu_gives::Set{Symbol}, pkgs::Set{Symbol})
    f = _prelude_facts(path)
    has_tu = "testutils.jl" in f.includes
    missing_lines = String[]

    # (1) a Test macro of its own, or (2) the prelude include, which expands one.
    if :Test ∉ f.bound && (any(_is_test_macro, f.macros) || has_tu)
        push!(missing_lines, "using Test")
    elseif has_tu
        ut, itu = _prelude_lines(path)
        ut === nothing || itu === nothing || ut < itu ||
            push!(missing_lines,
                  "using Test   # MOVE it above the testutils.jl include on " *
                  "line $(itu); the include expands a `@test_skip`")
    end

    # (3) a name testutils.jl defines, without the include that defines it.
    borrowed = sort!(String.(collect(setdiff(intersect(f.symbols, tu_names), f.defined))))
    isempty(borrowed) || has_tu ||
        push!(missing_lines,
              "include(\"testutils.jl\")   # uses " * join(borrowed, ", "))

    # (4) `SomeModule.something` for a package this project declares, unless the
    #     file imports it or the prelude it includes already did.
    for m in sort!(collect(intersect(f.qualified, pkgs)))
        m in f.bound || m in f.defined || (has_tu && m in tu_gives) ||
            push!(missing_lines, "using $(m)")
    end
    return missing_lines
end

@testset "every test file carries the prelude it uses" begin
    tu_names = _testutils_exports()
    tu_gives = _testutils_provides()
    pkgs     = _declared_packages()
    @test :TESTUTILS_REPO_ROOT in tu_names && :_require_fixture in tu_names
    @test :JSON3 in tu_gives && :Test ∉ tu_gives
    @test :Test in pkgs && :EarthSciAST in pkgs   # Project.toml was really read

    files = sort!(filter(f -> endswith(f, ".jl") && f != "runtests.jl",
                         readdir(_PRELUDE_TEST_DIR)))
    @test length(files) > 100                      # the sweep is not vacuous

    offenders = String[]
    for f in files
        lines = _missing_prelude(joinpath(_PRELUDE_TEST_DIR, f),
                                 tu_names, tu_gives, pkgs)
        isempty(lines) && continue
        push!(offenders, "  $(f)\n" * join(("      add: " * l for l in lines), "\n"))
    end

    @test isempty(offenders) || error(
        "$(length(offenders)) test file(s) use a name they do not import, so " *
        "they run only under runtests.jl and fail standalone " *
        "(testutils.jl documents that both must work). Add the line named:\n" *
        join(offenders, "\n"))
end
