using Test
using EarthSciAST

include("testutils.jl")

# ---------------------------------------------------------------------------
# The package-wide exception root (src/errors.jl) and the central diagnostic-code
# registry (src/error_codes.jl).
#
# Both exist so a caller has ONE thing to reach for: one `catch` clause that
# covers every failure this package can raise, and one place that owns the code
# strings those failures carry. Neither guarantee survives on its own — a new
# `struct FooError <: Exception` or a new inline `"some_code"` literal
# reintroduces the gap silently. These tests are the guards.
# ---------------------------------------------------------------------------

@testset "error hierarchy + code registry" begin

    @testset "EarthSciASTError is the root, and is still an Exception" begin
        @test EarthSciASTError isa Type
        @test isabstracttype(EarthSciASTError)
        # The whole point of the supertype is that it does not BREAK anything:
        # every pre-existing `catch e; e isa Exception` site must still fire.
        @test EarthSciASTError <: Exception
    end

    # Walk the module (and its two namespaced submodules) for concrete Exception
    # types and assert every one of them is under the root. `all=true` reaches
    # the unexported internals — the control-flow signals (`_CodegenDecline`,
    # `_StencilFallback`, …) are covered deliberately, so the rule "every
    # exception in this package is an EarthSciASTError" has no exceptions.
    @testset "every exception type in the package subtypes it" begin
        strays = String[]
        found = 0
        for mod in (EarthSciAST, EarthSciAST.Cadence, EarthSciAST.Relational)
            for n in names(mod; all=true)
                v = try
                    getfield(mod, n)
                catch
                    continue
                end
                (v isa DataType && v <: Exception) || continue
                v === EarthSciASTError && continue
                found += 1
                v <: EarthSciASTError || push!(strays, string(nameof(mod), ".", n))
            end
        end
        # Guard the scan: a reflection change that found nothing would pass the
        # subset check vacuously.
        @test found >= 30
        @test isempty(strays)
    end

    @testset "a single catch clause covers the surface" begin
        # Five unrelated failure modes, five concrete types from five different
        # source files, one clause.
        bad_json = () -> begin
            path = tempname() * ".esm"
            write(path, "{not json")
            try
                load_path(path)
            finally
                rm(path; force=true)
            end
        end
        caught = Symbol[]
        for f in (() -> parse_expression("1 +"),                              # parse_expression_text.jl
                  () -> evaluate_closed_function("no_such_function", Any[1.0]),  # registered_functions.jl
                  () -> canonicalize(NumExpr(NaN)),                           # canonicalize.jl
                  () -> migrate(EsmFile("0.5.0", Metadata("m")), "1.0.0"),     # migration.jl
                  bad_json)                                                   # parse.jl
            try
                f()
                push!(caught, :no_throw)
            catch e
                push!(caught, e isa EarthSciASTError ? :root : :stray)
            end
        end
        @test all(==(:root), caught)
    end

    # The one documented hole, pinned so it stays deliberate: `load` of a path
    # that does not exist surfaces Base's `SystemError` from the `open` call
    # unwrapped. That is an I/O failure, not an ESM diagnostic, and wrapping it
    # would change `load`'s observable error type — so the root covers every
    # error the package RAISES, not every error a call through it can surface.
    # A caller that also wants I/O failures still needs `catch e` on its own.
    @testset "known boundary: a missing file is an I/O error, not an ESM one" begin
        e = try
            load_path("/nonexistent/definitely_not_here.esm")
            nothing
        catch err
            err
        end
        @test e isa SystemError
        @test !(e isa EarthSciASTError)
    end

    @testset "ERROR_CODES is a registry of unique, well-formed code strings" begin
        codes = collect(values(ERROR_CODES))
        @test !isempty(codes)
        @test all(c -> c isa String, codes)
        # Values are the cross-binding contract: snake_case, no whitespace.
        @test all(c -> occursin(r"^[a-z][a-z0-9_]*$", c), codes)
        # A duplicated value would make the registry ambiguous — two names for
        # one code, and a rename of "the wrong one" would be invisible.
        @test length(unique(codes)) == length(codes)
        @test error_code_names() == sort(codes)
        # Field names are the SCREAMING_SNAKE_CASE of their values, the
        # convention TypeScript's ERROR_CODES and Python's ErrorCode share, so
        # a reader can go from a wire code back to the field without a lookup.
        @test all(k -> string(k) == uppercase(getproperty(ERROR_CODES, k)),
                  keys(ERROR_CODES))
    end

    @testset "the corpus-pinned codes are registered" begin
        # Spot-check across every family, so a family dropped wholesale is caught.
        for c in ("undefined_variable", "equation_count_mismatch",
                  "unit_inconsistency", "unit_parse_error",
                  "unresolved_subsystem_ref", "template_import_unresolved",
                  "coupling_library_illegal_payload", "unknown_closed_function",
                  "metaparameter_type_error", "unlowered_operator")
            @test c in error_code_names()
        end
    end
end
