# Per-term provenance through flatten (esm-libraries-spec §4.7.5, CONFORMANCE_SPEC
# §5.48, issue #539).
#
# The flatten corpus (`flatten_conformance_test.jl`) pins the rendered
# contribution lists of every case. This file checks what a rendering cannot:
#
#   * the INVARIANT, by evaluation: `body(eq)` evaluates BIT FOR BIT to the
#     left-fold sum of its contributions' values, at sampled non-default states,
#     for every equation of the term_provenance fixtures and of the rest of the
#     corpus where the evaluator can;
#   * the systems-order pair, non-vacuity, and every contribution flatten makes
#     having an author;
#   * the passes over a flattened system (template expansion, table-lookup
#     lowering) keeping the list, and the keyword copy constructor resetting it.

using Test
using JSON3
using EarthSciAST

if !isdefined(Main, :ESM_TESTUTILS_LOADED)
    include("testutils.jl")
end

const _TP_TESTS = joinpath(TESTUTILS_REPO_ROOT, "tests")
const _TP_DIR = joinpath(_TP_TESTS, "conformance", "term_provenance", "fixtures")
const _TP_FIXTURES = sort(filter(f -> endswith(f, ".esm"), readdir(_TP_DIR)))
const _TP_CORPUS = JSON3.read(read(joinpath(_TP_TESTS, "conformance", "flatten", "cases.json"),
                                   String)).cases

_tp_flatten(path) = flatten(load_path(path))
_tp_origins(c::Contribution) = [o.component === nothing ? (:coupling, o.coupling) :
                                (:component, o.component) for o in c.origins]

function _tp_equation(flat, lhs::AbstractString)
    hits = [i for (i, eq) in enumerate(flat.equations) if to_ascii(eq.lhs) == lhs]
    @assert length(hits) == 1 "expected one equation $(lhs), got $(length(hits))"
    return flat.equations[hits[1]], equation_contributions(flat)[hits[1]]
end

# ── the invariant, by evaluation ─────────────────────────────────────────────

# Independent sampled states per equation: one state can sum to the same bits in
# every association by chance; several make that vanishingly unlikely.
const _TP_SAMPLES = 8

# A deterministic, non-default value for `name` in sample `salt`. The magnitudes
# spread over many decades, so that summing in another association rounds
# differently — which is what lets a bit comparison see the order.
function _tp_sample(name::AbstractString, salt::Integer)
    h = hash(string(salt, ":", name)) % UInt64(2)^40
    return (1.0 + (h % 100003) / 100003.0) * 10.0^(Int((h >> 17) % 13) - 6)
end

struct _TPUnevaluable <: Exception end

_tp_left_fold(parts) = foldl(+, parts)
_tp_right_fold(parts) = foldr(+, parts)

# Scalar equations: `evaluate_expr` over sampled bindings of every free name.
function _tp_scalar_values(flat, eq, cs, salt)
    names = Set{String}()
    for c in cs
        union!(names, free_variables(c.expr))
    end
    bindings = Dict{String,Float64}()
    for n in names
        n == "t" && continue
        v = get(flat.state_variables, n, get(flat.parameters, n, nothing))
        (v !== nothing && v.shape !== nothing && !isempty(v.shape)) && throw(_TPUnevaluable())
        bindings[n] = _tp_sample(n, salt)
    end
    bindings["t"] = 0.75
    body = evaluate_expr(eq.rhs, bindings)
    parts = Float64[evaluate_expr(c.expr, bindings) for c in cs]
    return [body], [parts]
end

# Lifted equations: each contribution is evaluated per cell inside the lift's
# own `faq` shell, the body as the right-hand side itself.
function _tp_lifted_values(flat, eq, cs, salt)
    rhs = eq.rhs::OpExpr
    arrays = Dict{String,Any}()
    params = Dict{String,Float64}()
    for c in cs, n in free_variables(c.expr)
        n in rhs.output_idx && continue
        n == "t" && continue
        shape = get(flat.lifted_shapes, n, nothing)
        if shape === nothing
            params[n] = _tp_sample(n, salt)
        else
            arrays[n] = reshape([_tp_sample("$(n)[$k]", salt) for k in 1:prod(shape)],
                                Tuple(shape))
        end
    end
    species = only(keys(flat.lifted_shapes))
    cells = [collect(Tuple(ci)) for ci in CartesianIndices(Tuple(flat.lifted_shapes[species]))]
    ev(e) = evaluate_cellwise(e, cells; const_arrays=arrays, params=params, t=0.75)
    body = ev(rhs)
    per_c = [ev(EarthSciAST.reconstruct(rhs; expr_body=c.expr)) for c in cs]
    return body, [Float64[p[k] for p in per_c] for k in eachindex(cells)]
end

"""
Check the invariant for one equation at `_TP_SAMPLES` states. Returns
`(evaluated, discriminating)`: `evaluated` is false when the evaluator cannot
evaluate the equation (an undiscretized spatial operator, an arrayed operand
outside the lift); `discriminating` is true when some sample sums the
contributions to different bits in the right-nested association.
"""
function _tp_check_invariant(flat, eq, cs; label="")
    lifted = EarthSciAST._is_lifted(eq, flat.lifted_shapes)
    discriminating = false
    for salt in 1:_TP_SAMPLES
        bodies, partss = try
            lifted ? _tp_lifted_values(flat, eq, cs, salt) :
                     _tp_scalar_values(flat, eq, cs, salt)
        catch err
            err isa InterruptException && rethrow()
            return false, false
        end
        for (body, parts) in zip(bodies, partss)
            fold = _tp_left_fold(parts)
            @test (label, to_ascii(eq.lhs), salt, reinterpret(UInt64, body)) ==
                  (label, to_ascii(eq.lhs), salt, reinterpret(UInt64, fold))
            discriminating |= reinterpret(UInt64, _tp_right_fold(parts)) !=
                              reinterpret(UInt64, fold)
        end
    end
    return true, discriminating
end

@testset "per-term provenance" begin

    @testset "invariant: $(f)" for f in _TP_FIXTURES
        flat = _tp_flatten(joinpath(_TP_DIR, f))
        isempty(flat.template_registry) || (flat = expand_flattened_refs(flat))
        results = [_tp_check_invariant(flat, eq, cs; label=f)
                   for (eq, cs) in zip(flat.equations, equation_contributions(flat))]
        # Only `grad` without a discretization is out of the evaluator's reach.
        f == "placeholder_expansion.esm" || @test (f, all(first, results)) == (f, true)
        # With three or more contributions the check must be able to see the order.
        for ((ok, disc), cs) in zip(results, equation_contributions(flat))
            (ok && length(cs) >= 3) || continue
            @test (f, "discriminating", disc) == (f, "discriminating", true)
        end
    end

    @testset "invariant over the corpus, where it evaluates" begin
        evaluated = 0
        for case in _TP_CORPUS
            flat = try
                _tp_flatten(joinpath(_TP_TESTS, String(case.fixture)))
            catch
                continue
            end
            isempty(flat.template_registry) || (flat = expand_flattened_refs(flat))
            for (eq, cs) in zip(flat.equations, equation_contributions(flat))
                ok, _ = _tp_check_invariant(flat, eq, cs; label=String(case.id))
                evaluated += ok
            end
        end
        # Guard against a harness that silently evaluates nothing.
        @test evaluated > 50
    end

    @testset "every contribution flatten makes has an author" begin
        for case in _TP_CORPUS
            flat = _tp_flatten(joinpath(_TP_TESTS, String(case.fixture)))
            id = String(case.id)
            @test (id, length(equation_contributions(flat))) == (id, length(flat.equations))
            for (eq, cs) in zip(flat.equations, equation_contributions(flat))
                @test (id, to_ascii(eq.lhs), isempty(cs)) == (id, to_ascii(eq.lhs), false)
                for c in cs
                    @test (id, to_ascii(eq.lhs), isempty(c.origins), allunique(c.origins)) ==
                          (id, to_ascii(eq.lhs), false, true)
                end
            end
        end
    end

    # ── the step table, row by row ───────────────────────────────────────────

    @testset "the systems order changes the order, not the origins" begin
        _, ab = _tp_equation(_tp_flatten(joinpath(_TP_DIR, "systems_order_ab.esm")), "D(Chem.O3)/Dt")
        _, ba = _tp_equation(_tp_flatten(joinpath(_TP_DIR, "systems_order_ba.esm")), "D(Chem.O3)/Dt")
        pairs(cs) = [(to_ascii(c.expr), _tp_origins(c)) for c in cs]
        @test sort(pairs(ab), by=string) == sort(pairs(ba), by=string)
        @test [_tp_origins(c) for c in ab] == [[(:component, "Chem")], [(:component, "Sink")]]
        @test [_tp_origins(c) for c in ba] == [[(:component, "Sink")], [(:component, "Chem")]]
    end

    @testset "structurally identical contributions stay two" begin
        _, cs = _tp_equation(_tp_flatten(joinpath(_TP_DIR, "non_vacuity.esm")), "D(Chem.O3)/Dt")
        @test [to_ascii(c.expr) for c in cs[2:end]] == ["Emis.flux", "Emis.flux"]
        @test [_tp_origins(c) for c in cs[2:end]] ==
              [[(:component, "OpA")], [(:component, "OpB")]]
    end

    @testset "a chained compose names every author" begin
        flat = _tp_flatten(joinpath(_TP_TESTS, "coupling", "chained_operator_compose.esm"))
        eq, cs = _tp_equation(flat, "D(Chem.O3)/Dt")
        @test [_tp_origins(c) for c in cs] ==
              [[(:component, c)] for c in ("Src", "Sink", "Chem", "Adv")]
        # The right-hand side is built from the list: one sum over the four.
        @test eq.rhs isa OpExpr && eq.rhs.op == "+" && length(eq.rhs.args) == 4
    end

    @testset "an additive couple appends, and creates a tendency for an unknown only" begin
        flat = _tp_flatten(joinpath(_TP_DIR, "couple_additive.esm"))
        _, co2 = _tp_equation(flat, "D(Atm.CO2)/Dt")
        @test [_tp_origins(c) for c in co2] == [[(:component, "Atm")], [(:coupling, 1)]]
        # The variable_map that ran afterwards rewrote the input, not the author.
        @test to_ascii(co2[2].expr) == "Ocean.Fref"
        _, o2 = _tp_equation(flat, "D(Atm.O2)/Dt")
        @test [_tp_origins(c) for c in o2] == [[(:coupling, 1)], [(:coupling, 1)]]
        # A parameter target takes no tendency.
        @test isempty([eq for eq in flat.equations if occursin("Atm.flux", to_ascii(eq.lhs))])
    end

    @testset "a multiplicative couple collapses to the union" begin
        _, cs = _tp_equation(_tp_flatten(joinpath(_TP_DIR, "couple_multiplicative.esm")),
                             "D(Chem.O3)/Dt")
        @test length(cs) == 1
        @test _tp_origins(cs[1]) ==
              [(:component, "Chem"), (:component, "Sink"), (:coupling, 1)]
    end

    @testset "a translate factor collapses only a multi-contribution B" begin
        flat = _tp_flatten(joinpath(_TP_DIR, "translate_factor.esm"))
        _, y = _tp_equation(flat, "D(Host.Y)/Dt")
        @test [_tp_origins(c) for c in y] ==
              [[(:component, "Host")], [(:component, "Chem"), (:component, "Sink")]]
        _, w = _tp_equation(flat, "D(Host.W)/Dt")
        @test [_tp_origins(c) for c in w] == [[(:component, "Host")], [(:component, "Chem")]]
    end

    @testset "an expression transform's observed is authored by the coupling" begin
        flat = _tp_flatten(joinpath(_TP_DIR, "variable_map.esm"))
        _, e = _tp_equation(flat, "Chem.e")
        @test [_tp_origins(c) for c in e] == [[(:coupling, 1)]]
        _, o3 = _tp_equation(flat, "D(Chem.O3)/Dt")
        @test [_tp_origins(c) for c in o3] == [[(:component, "Chem")]]
    end

    @testset "a resolved time derivative keeps the referencing origin" begin
        eq, cs = _tp_equation(_tp_flatten(joinpath(_TP_DIR, "rhs_time_derivative.esm")),
                              "Diag.rate")
        @test [_tp_origins(c) for c in cs] == [[(:component, "Diag")]]
        @test !occursin("D(", to_ascii(eq.rhs))
    end

    @testset "the lift indexes inside each contribution and wraps their sum" begin
        flat = _tp_flatten(joinpath(_TP_DIR, "pointwise_lift.esm"))
        lifted = [(eq, cs) for (eq, cs) in zip(flat.equations, equation_contributions(flat))
                  if EarthSciAST._is_lifted(eq, flat.lifted_shapes)]
        @test length(lifted) == 1
        eq, cs = only(lifted)
        @test eq.rhs isa OpExpr && eq.rhs.op == "faq"
        @test [_tp_origins(c) for c in cs] == [[(:component, c)] for c in ("Chem", "Src", "Adv")]
        @test to_ascii(eq.rhs.expr_body) == to_ascii(EarthSciAST._fold_contributions(cs))
    end

    @testset "template expansion rewrites inside the contribution" begin
        flat = _tp_flatten(joinpath(_TP_DIR, "template_reference.esm"))
        _, before = _tp_equation(flat, "D(Chem.O3)/Dt")
        _, after = _tp_equation(expand_flattened_refs(flat), "D(Chem.O3)/Dt")
        @test [_tp_origins(c) for c in after] == [_tp_origins(c) for c in before]
        @test !occursin("<", to_ascii(after[1].expr))
    end

    @testset "table-lookup lowering keeps the contributions" begin
        flat = _tp_flatten(joinpath(_TP_TESTS, "conformance", "function_tables", "linear",
                                    "fixture.esm"))
        lowered = EarthSciAST.lower_table_lookups(flat)
        @test lowered !== flat
        changed = 0
        for (i, (eq, cs)) in enumerate(zip(lowered.equations, equation_contributions(lowered)))
            @test [_tp_origins(c) for c in cs] ==
                  [_tp_origins(c) for c in equation_contributions(flat)[i]]
            @test all(!isempty(c.origins) for c in cs)
            changed += to_ascii(eq.rhs) != to_ascii(flat.equations[i].rhs)
            ok, _ = _tp_check_invariant(lowered, eq, cs; label="lowered")
            @test ok
        end
        @test changed > 0
    end

    # ── the types and the copy constructor ───────────────────────────────────

    @testset "a TermOrigin names exactly one author" begin
        @test TermOrigin(component="A.B").component == "A.B"
        @test TermOrigin(coupling=0).coupling == 0
        @test_throws ArgumentError TermOrigin()
        @test_throws ArgumentError TermOrigin(component="A", coupling=0)
        @test_throws ArgumentError TermOrigin(coupling=-1)
        @test TermOrigin(component="A") == TermOrigin(component="A")
    end

    @testset "replacing the equations alone resets the list to unknown authors" begin
        flat = _tp_flatten(joinpath(_TP_TESTS, "coupling", "chained_operator_compose.esm"))
        # Copying any other field keeps the list.
        same = FlattenedSystem(flat; domain=flat.domain)
        @test equation_contributions(same) == equation_contributions(flat)
        eqs = copy(flat.equations)
        reset = FlattenedSystem(flat; equations=eqs)
        @test length(equation_contributions(reset)) == length(eqs)
        for (eq, cs) in zip(eqs, equation_contributions(reset))
            @test length(cs) == 1
            @test cs[1].expr === eq.rhs
            @test isempty(cs[1].origins)
        end
        # A list that does not match the equations is refused.
        @test_throws ArgumentError FlattenedSystem(flat; equations=eqs[1:end-1],
            equation_contributions=equation_contributions(flat))
    end
end
