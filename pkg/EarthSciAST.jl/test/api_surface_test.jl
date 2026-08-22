# The Julia binding's public surface must equal the API manifest.
#
# `api-surface.json` at the repo root is the cross-language record of what every
# binding exports (see API_SPEC.md). This test pins the Julia half: a name in
# `EarthSciAST`'s `export` block that the manifest does not list fails, and a
# Julia name in the manifest that the module does not export fails too.
#
# The surface is read from `names(EarthSciAST)` rather than by parsing the
# `export` block, so what is asserted is what a caller can actually reach after
# `using EarthSciAST` — including anything an `@eval`'d or macro-generated
# export would add.
#
# If this test fails you have changed the public API. That is allowed — but
# regenerate the manifest in the same commit:
#
#     python3 scripts/gen-api-surface.py
#
# and then say in API_SPEC.md which tier the new symbol lands in.

# `using Test` MUST precede the testutils include: testutils.jl uses `@test_skip`
# at top level, so `Test` has to be in scope in `Main` already. Including it
# first only works when some earlier file in runtests.jl happened to import Test
# — running this file standalone (the documented way to verify Julia here, since
# the full test target hangs on the shared depot lock) then fails with
# `UndefVarError: @test_skip not defined`.
using Test
using JSON3
using EarthSciAST

include("testutils.jl")

@testset "public API surface" begin
    manifest_path = joinpath(TESTUTILS_REPO_ROOT, "api-surface.json")
    @test isfile(manifest_path)
    manifest = JSON3.read(read(manifest_path, String))

    # A binding entry is a string, or an array when the binding exports aliases
    # for one canonical symbol (Julia's mutating `!` twin is the live case).
    spellings(entry) = entry isa AbstractString ? [String(entry)] : String.(entry)

    declared = Set{String}()
    for sym in manifest.symbols
        haskey(sym.bindings, :julia) || continue
        union!(declared, spellings(sym.bindings.julia))
    end

    # `names(M)` includes the module's own name; that is not part of the surface.
    exported = Set(String(n) for n in names(EarthSciAST) if n !== :EarthSciAST)

    # Guard against a manifest that failed to load leaving every check vacuous.
    @test length(exported) > 200
    @test length(declared) > 200

    extra = sort(collect(setdiff(exported, declared)))
    if !isempty(extra)
        @info """exported by EarthSciAST but absent from api-surface.json.
              Add them by re-running `python3 scripts/gen-api-surface.py`, then \
              assign each a tier in API_SPEC.md.""" extra
    end
    @test isempty(extra)

    missing_syms = sort(collect(setdiff(declared, exported)))
    if !isempty(missing_syms)
        @info """declared for julia in api-surface.json but not exported.
              Either restore the export or drop it from the manifest — dropping a \
              `stable` symbol is a major-version break (API_SPEC.md §3).""" missing_syms
    end
    @test isempty(missing_syms)

    # Every exported name must actually resolve: an `export` of a name nothing
    # defines is legal Julia and silently ships a broken surface.
    unresolved = sort([n for n in exported
                       if !isdefined(EarthSciAST, Symbol(n))])
    @test isempty(unresolved)

    # A symbol the manifest calls a `type` must be a type here, and one it calls
    # an `error` must be an Exception subtype.
    kind_mismatches = String[]
    for sym in manifest.symbols
        haskey(sym.bindings, :julia) || continue
        for name in spellings(sym.bindings.julia)
            isdefined(EarthSciAST, Symbol(name)) || continue
            value = getfield(EarthSciAST, Symbol(name))
            if sym.kind == "error"
                (value isa Type && value <: Exception) ||
                    push!(kind_mismatches, "$name: manifest says error, is $(typeof(value))")
            elseif sym.kind == "type"
                # A manifest `type` may be a DataType, a UnionAll, or an enum
                # instance's type; it must not be a plain function.
                value isa Function &&
                    push!(kind_mismatches, "$name: manifest says type, is a function")
            elseif sym.kind == "function"
                (value isa Type) &&
                    push!(kind_mismatches, "$name: manifest says function, is a type")
            end
        end
    end
    if !isempty(kind_mismatches)
        @info "kind mismatches vs api-surface.json" kind_mismatches
    end
    @test isempty(kind_mismatches)
end
