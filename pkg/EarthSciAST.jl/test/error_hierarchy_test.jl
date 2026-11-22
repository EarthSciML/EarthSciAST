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

    # Walk the module (and its namespaced submodule) for concrete Exception
    # types and assert every one of them is under the root. `all=true` reaches
    # the unexported internals — the control-flow signals (`_Decline`,
    # `_DiagnosticCap`, …) are covered deliberately. The one exception is
    # `_HaloDone` (src/range/tile.jl), which leaves a build at the range seam
    # and is kept outside the root on purpose, so that no `catch` of an
    # `EarthSciASTError` between the seam and its handler can swallow it.
    @testset "every exception type in the package subtypes it" begin
        strays = String[]
        found = 0
        for mod in (EarthSciAST, EarthSciAST.Relational)
            for n in names(mod; all = true)
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
        @test strays == ["EarthSciAST._HaloDone"]
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
                rm(path; force = true)
            end
        end
        caught = Symbol[]
        for f in (
                () -> parse_math("1 +", String[], :typst),                  # document_format.jl
                () -> canonicalize(NumExpr(NaN)),                           # canonicalize.jl
                () -> migrate(EsmFile("0.5.0", Metadata("m")), "1.0.0"),     # migration.jl
                bad_json,
            )                                                   # parse.jl
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
        @test all(
            k -> string(k) == uppercase(getproperty(ERROR_CODES, k)),
            keys(ERROR_CODES)
        )
    end

    @testset "every exported error type leads with `code` and prints one way" begin
        exported = [
            getfield(EarthSciAST, n) for n in names(EarthSciAST)
                if (v = getfield(EarthSciAST, n); v isa DataType && v <: EarthSciASTError && isconcretetype(v))
        ]
        # Guard the scan against a reflection change that finds nothing.
        @test length(exported) >= 25
        @test isempty([T for T in exported if fieldname(T, 1) !== :code || fieldtype(T, 1) !== String])
        @test fieldname(EarthSciAST.Relational.FloatKeyError, 1) === :code
        # The types' own `showerror` methods are gone: one method serves them all.
        @test isempty([T for T in exported if which(showerror, Tuple{IO, T}).sig !== Tuple{typeof(showerror), IO, EarthSciASTError}])

        e = ParseError("bad", nothing; code = "removed_op", path = "/models/M", file = "/a/b.esm")
        @test (error_code(e), error_message(e), error_path(e), error_file(e)) ==
            ("removed_op", "bad", "/models/M", "/a/b.esm")
        @test sprint(showerror, e) == "ParseError [removed_op]: bad (at /models/M in /a/b.esm)"
        @test sprint(showerror, ParseError("bad")) == "ParseError: bad"
        e = SimulateError("no such key", "unknown_override_key")
        @test (error_code(e), error_message(e), error_path(e)) == ("unknown_override_key", "no such key", "")
        @test sprint(showerror, e) == "SimulateError [unknown_override_key]: no such key"
        e = TreeWalkError("E_TREEWALK_ARITY", "op '+' takes 2 operands")
        @test sprint(showerror, e) == "TreeWalkError [E_TREEWALK_ARITY]: op '+' takes 2 operands"
        e = ConflictingDerivativeError(["A.x"], "both an equation and a reaction")
        @test error_code(e) == "conflicting_derivative"
        @test startswith(sprint(showerror, e), "ConflictingDerivativeError [conflicting_derivative]: ")
        @test error_message(e) == sprint(showerror, e)[(length("ConflictingDerivativeError [conflicting_derivative]: ") + 1):end]
    end

    @testset "every local E_ code literal is listed" begin
        # The Julia-evaluator codes stay out of ERROR_CODES (not a cross-binding
        # contract); this is their typo guard.
        root = joinpath(@__DIR__, "..")
        seen = Set{String}()
        for dir in ("src", "ext"), (d, _, fs) in walkdir(joinpath(root, dir)), f in fs
            endswith(f, ".jl") || continue
            for m in eachmatch(r"\"(E_[A-Z0-9_]+)\"", read(joinpath(d, f), String))
                push!(seen, String(m.captures[1]))
            end
        end
        @test length(seen) >= 50
        @test isempty(setdiff(seen, Set(EarthSciAST._LOCAL_ERROR_CODES)))
        @test isempty(intersect(Set(EarthSciAST._LOCAL_ERROR_CODES), Set(error_code_names())))
    end

    @testset "every SimulateError and RefreshError raise passes a code" begin
        # The one-argument constructor leaves `code` empty; every raise site
        # names a registered code instead.
        root = joinpath(@__DIR__, "..")
        uncoded = String[]
        function scan(ex, name, file, line)
            if ex isa LineNumberNode
                return ex.line
            elseif ex isa Expr
                if ex.head == :call && ex.args[1] === name
                    pos = [a for a in ex.args[2:end] if !(a isa Expr && a.head in (:kw, :parameters))]
                    typed = any(a -> a isa Expr && a.head == :(::), pos)
                    (length(pos) < 2 && !typed) && push!(uncoded, "$file:$line")
                end
                for a in ex.args
                    l = scan(a, name, file, line)
                    l isa Int && (line = l)
                end
            end
            return nothing
        end
        for (name, dirs) in ((:SimulateError, ("src", "ext")), (:RefreshError, ("src", "ext"))),
                dir in dirs, (d, _, fs) in walkdir(joinpath(root, dir)), f in fs
            endswith(f, ".jl") || continue
            p = joinpath(d, f)
            scan(Meta.parseall(read(p, String); filename = p), name, relpath(p, root), 0)
        end
        @test isempty(uncoded)
    end

    @testset "the corpus-pinned codes are registered" begin
        # Spot-check across every family, so a family dropped wholesale is caught.
        for c in (
                "undefined_variable", "equation_count_mismatch",
                "unit_inconsistency", "unit_parse_error",
                "unresolved_subsystem_ref", "operator_import_unresolved",
                "coupling_library_illegal_payload", "removed_op",
                "metaparameter_type_error", "unlowered_operator",
            )
            @test c in error_code_names()
        end
    end

    @testset "every esm-spec §9.6.6 code is registered" begin
        # The §9.6.6 table is "cross-language uniform", so every binding's
        # registry must carry every code in it.
        spec = read(joinpath(@__DIR__, "..", "..", "..", "esm-spec.md"), String)
        sections = filter(s -> startswith(s, "9.6.6 "), split(spec, "\n#### "))
        @test length(sections) == 1
        codes = [
            String(m.captures[1])
                for m in eachmatch(r"^\| `([a-z][a-z0-9_]*)` \|"m, only(sections))
        ]
        # Guard the extraction: a heading or table-layout change that matched
        # nothing would pass the membership check vacuously.
        @test length(codes) >= 30
        @test isempty(setdiff(Set(codes), Set(error_code_names())))
    end
end
