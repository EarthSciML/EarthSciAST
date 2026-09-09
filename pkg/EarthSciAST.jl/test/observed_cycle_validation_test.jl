# Observed dependency cycles — the STRUCTURAL contract (esm-spec §4.9.6,
# CONFORMANCE_SPEC §5.19.5; issue #181).
#
# An observed is defined by the RHS of the equation whose LHS names it, so the
# definitions induce a dependency graph over the observed names and a cycle in
# it means no evaluation order satisfies every definition. Every case here
# asserts the exact CODE and the exact PATH, because those are the pair the
# corpus pins across bindings — `/models/<M>`, never an equation, because a
# cycle belongs to no single equation. The PROSE is deliberately not pinned
# (§5.19.5); what IS required of it is that it NAME the observeds on the cycle,
# which the message assertions below check by name rather than by string
# equality.
#
# The hand-built cases call `validate_observed_cycles` directly, the same way
# recurrence_validation_test.jl calls `validate_recurrence_semantics`: a
# hand-built model is rarely balanced or dimensionally complete, and an
# unrelated finding must not be able to masquerade as this one.

using Test
using EarthSciAST
using OrderedCollections: OrderedDict

include("testutils.jl")  # TESTUTILS_REPO_ROOT + the _v/_i/_n/_op/_idx AST quartet

const ESM_OC = EarthSciAST

# A one-model document over an `interval` index set `steps`, so array-shaped
# declarations in these tests resolve exactly as they do in the fixtures.
_oc_file(vars::AbstractDict, eqs::Vector; subsystems=OrderedDict{String,ESM_OC.SubsystemNode}()) =
    ESM_OC.EsmFile("1.0.0", ESM_OC.Metadata("ObsCycle");
        models=Dict("M" => ESM_OC.Model(vars, ESM_OC.Equation[eqs...];
                                        subsystems=subsystems)),
        index_sets=OrderedDict("steps" => ESM_OC.IndexSet("interval"; size=4)))

_oc_scalar() = ESM_OC.ModelVariable(ESM_OC.UnknownVariable; units="1")
_oc_array() = ESM_OC.ModelVariable(ESM_OC.UnknownVariable; shape=Any["steps"], units="1")
_oc_param() = ESM_OC.ModelVariable(ESM_OC.ParameterVariable; units="1", default=1.0)

@testset "Observed dependency cycles (§4.9.6)" begin

    @testset "the code is in the registry" begin
        # error_hierarchy_test.jl already pins `uppercase(value) == fieldname`
        # for every entry; this is the §4.9.6-specific half — that the
        # vocabulary this binding advertises actually contains the new code, so
        # a caller routing on `error_code_names()` can see it.
        @test "observed_cycle" in EarthSciAST.error_code_names()
        @test EarthSciAST.ERROR_CODES.OBSERVED_CYCLE == "observed_cycle"
    end

    # ── The shared cross-binding fixture ───────────────────────────────────
    #
    # Three ARRAY observeds over one index set reading each other elementwise:
    # gamfac -> hpbl -> wscale -> gamfac. The fourth observed, `in_pbl`, is the
    # whole reason the fixture has this shape — it is declared, defined and
    # referenced perfectly well and merely reads `hpbl`, and it is the name the
    # build used to report (`E_TREEWALK_UNBOUND_NAME: 'in_pbl'`) because it is
    # what the materialization walk happened to try first after the cycle
    # stalled. A binding that names it has misattributed the defect.
    @testset "tests/invalid/observed_cycle_array_elementwise.esm is rejected" begin
        path = joinpath(TESTUTILS_REPO_ROOT, "tests", "invalid",
                        "observed_cycle_array_elementwise.esm")
        if _require_fixture(path)
            res = validate_path(path)
            @test !res.is_valid
            @test isempty(res.schema_errors)   # the defect is structural, not schematic

            found = [e for e in res.structural_errors
                     if e.error_type == EarthSciAST.ERROR_CODES.OBSERVED_CYCLE]
            @test length(found) == 1
            err = found[1]
            @test err.path == "/models/YSU"

            # The message must NAME the observeds on the cycle (§4.9.6).
            for name in ("gamfac", "hpbl", "wscale")
                @test occursin(name, err.message)
            end
            # ... and must NOT name the innocent bystander. This is issue #181
            # in one assertion.
            @test !occursin("in_pbl", err.message)
            @test !("in_pbl" in err.details["cycle"])

            # `details.cycle` is a PATH — traversal order with the entry node
            # repeated to close it — not one of the §7.1.0 lexicographic name
            # lists. Sorted DFS roots make it deterministic, so it is pinned
            # exactly.
            @test err.details["cycle"] == ["gamfac", "hpbl", "wscale", "gamfac"]
            @test err.details["dependency_type"] == "observed_definitions"

            # And the cycle is the ONLY kind of structural finding: a cyclic
            # document must not also collect collateral errors that would
            # confuse the author about which one to fix — least of all one
            # against a bystander, which is the whole defect being fixed.
            @test Set(e.error_type for e in res.structural_errors) ==
                  Set([EarthSciAST.ERROR_CODES.OBSERVED_CYCLE])
        end
    end

    # ── Cycles of length ≥ 2 ───────────────────────────────────────────────

    @testset "a two-variable scalar cycle a -> b -> a" begin
        file = _oc_file(
            Dict("a" => _oc_scalar(), "b" => _oc_scalar()),
            [ESM_OC.Equation(_v("a"), _op("+", _v("b"), _n(1.0))),
             ESM_OC.Equation(_v("b"), _op("+", _v("a"), _n(1.0)))])
        errs = ESM_OC.validate_observed_cycles(file)
        @test length(errs) == 1
        @test errs[1].error_type == "observed_cycle"
        @test errs[1].path == "/models/M"
        # Sorted roots: `a` is entered first, so `a` closes the cycle.
        @test errs[1].details["cycle"] == ["a", "b", "a"]
        @test occursin("a -> b -> a", errs[1].message)
    end

    @testset "one cycle is reported per model" begin
        # Two disjoint cycles (a↔b and c↔d). §4.9.6: a binding reports ONE — a
        # second is usually the same defect from another entry point, and the
        # author fixes them one at a time regardless.
        file = _oc_file(
            Dict("a" => _oc_scalar(), "b" => _oc_scalar(),
                 "c" => _oc_scalar(), "d" => _oc_scalar()),
            [ESM_OC.Equation(_v("a"), _v("b")), ESM_OC.Equation(_v("b"), _v("a")),
             ESM_OC.Equation(_v("c"), _v("d")), ESM_OC.Equation(_v("d"), _v("c"))])
        errs = ESM_OC.validate_observed_cycles(file)
        @test length(errs) == 1
        @test errs[1].details["cycle"] == ["a", "b", "a"]
    end

    # ── Cycles of length ONE, i.e. the mis-gating guards ───────────────────
    #
    # CONFORMANCE_SPEC §5.19.5 names two ways to get the recurrence exemption
    # wrong, and the WIDE one — exempting "any self-edge" rather than a
    # recurrence CANDIDATE — silently drops both of these.

    @testset "a scalar self-reference x ~ x + 1 is a cycle of length one" begin
        file = _oc_file(Dict("x" => _oc_scalar()),
                        [ESM_OC.Equation(_v("x"), _op("+", _v("x"), _n(1.0)))])
        errs = ESM_OC.validate_observed_cycles(file)
        @test length(errs) == 1
        @test errs[1].error_type == "observed_cycle"
        @test errs[1].path == "/models/M"
        @test errs[1].details["cycle"] == ["x", "x"]
        @test occursin("x", errs[1].message)
        # A scalar has no axis to fold along, so it is not a recurrence
        # candidate and the recurrence pass must say nothing about it.
        @test isempty(ESM_OC.validate_recurrence_semantics(file))
    end

    @testset "a BARE array self-reference s ~ s + 1 is a cycle of length one" begin
        # Array-shaped, so the shape half of candidacy holds — but the
        # self-reference is BARE, never through `index`, so it is not a
        # candidate and keeps the cycle diagnosis it has always had.
        file = _oc_file(Dict("s" => _oc_array()),
                        [ESM_OC.Equation(_v("s"), _op("+", _v("s"), _n(1.0)))])
        errs = ESM_OC.validate_observed_cycles(file)
        @test length(errs) == 1
        @test errs[1].details["cycle"] == ["s", "s"]
    end

    # ── The recurrence self-edge is NOT one of these edges ─────────────────

    @testset "tests/valid/recurrence_causal_self_reference.esm still validates clean" begin
        path = joinpath(TESTUTILS_REPO_ROOT, "tests", "valid",
                        "recurrence_causal_self_reference.esm")
        if _require_fixture(path)
            res = validate_path(path)
            @test isempty(res.structural_errors)
            @test isempty(res.schema_errors)
            @test res.is_valid
        end
    end

    @testset "a well-founded recurrence candidate has its self-edge dropped" begin
        # `s[k] = ifelse(k <= 1, 1.0, 2 * s[k-1])` — the canonical §4.3.1.1
        # spelling, array-shaped with an `index` self-read, so a CANDIDATE.
        body = _op("ifelse", _op("<=", _v("k"), _i(1)), _n(1.0),
                   _op("*", _idx("s", _op("-", _v("k"), _i(1))), _n(2.0)))
        rhs = _op("aggregate"; output_idx=Any["k"], expr_body=body, reduce="+",
                  ranges=Dict{String,Any}("k" => ESM_OC.IndexSetRef("steps")))
        file = _oc_file(Dict("s" => _oc_array()), [ESM_OC.Equation(_v("s"), rhs)])
        @test isempty(ESM_OC.validate_observed_cycles(file))
    end

    @testset "an ILL-FOUNDED candidate still gets its recurrence diagnosis" begin
        # The gate is CANDIDACY, never the well-foundedness verdict. A forward
        # read `s[k+1]` is a candidate (array-shaped, `index` self-read) and is
        # ill founded — so the self-edge is still dropped here and the
        # `recurrence_not_wellfounded` diagnosis is the one the author reads.
        # Gating on the verdict instead would collapse this document to one
        # cycle error and lose that name (CONFORMANCE_SPEC §5.19.5).
        body = _op("*", _idx("s", _op("+", _v("k"), _i(1))), _n(2.0))
        rhs = _op("aggregate"; output_idx=Any["k"], expr_body=body, reduce="+",
                  ranges=Dict{String,Any}("k" => ESM_OC.IndexSetRef("steps")))
        file = _oc_file(Dict("s" => _oc_array()), [ESM_OC.Equation(_v("s"), rhs)])
        @test isempty(ESM_OC.validate_observed_cycles(file))
        rec = ESM_OC.validate_recurrence_semantics(file)
        @test length(rec) == 1
        @test rec[1].error_type == EarthSciAST.ERROR_CODES.RECURRENCE_NOT_WELLFOUNDED
    end

    # ── No false positives ─────────────────────────────────────────────────

    @testset "an acyclic observed chain is not a cycle" begin
        # c -> b -> a, three levels deep and read twice per level, which is the
        # shape a naive "any repeated name" check trips over.
        file = _oc_file(
            Dict("a" => _oc_scalar(), "b" => _oc_scalar(),
                 "c" => _oc_scalar(), "p" => _oc_param()),
            [ESM_OC.Equation(_v("a"), _op("*", _v("p"), _n(2.0))),
             ESM_OC.Equation(_v("b"), _op("+", _v("a"), _v("a"))),
             ESM_OC.Equation(_v("c"), _op("+", _v("b"), _op("*", _v("b"), _v("a"))))])
        @test isempty(ESM_OC.validate_observed_cycles(file))
    end

    @testset "a chain deeper than the call stack is not a cycle either" begin
        # The walk's depth is the length of the longest observed CHAIN, which is
        # a property of the DOCUMENT and unbounded — not the expression nesting
        # the schema caps. A recursive DFS raised `StackOverflowError` ("program
        # state may be corrupted") on an ACYCLIC chain of somewhere under 20 000
        # observeds, so the walk is iterative and this pins that. Exercised on
        # the graph walker directly: building a 20 000-equation `Model` to reach
        # it would measure the constructors, not the walk.
        n = 20_000
        adj = Dict{String,Vector{String}}("x$(n - 1)" => String[])
        for i in 0:(n - 2)
            adj["x$i"] = ["x$(i + 1)"]
        end
        @test ESM_OC._first_observed_cycle(adj) === nothing
        # …and closing it into a ring at the same depth still names the path.
        adj["x$(n - 1)"] = ["x0"]
        cycle = ESM_OC._first_observed_cycle(adj)
        @test cycle !== nothing
        @test length(cycle) == n + 1
        @test cycle[1] == "x0"
        @test cycle[end] == "x0"
    end

    @testset "a bound loop symbol does not manufacture an edge" begin
        # `y`'s aggregate binds the loop symbol `i`, and the model ALSO declares
        # an observed named `i` that reads `y`. Without binder subtraction the
        # loop symbol reads as a reference and closes a phantom `y -> i -> y`.
        agg = _op("aggregate"; output_idx=Any["i"],
                  expr_body=_op("*", _v("p"), _v("i")), reduce="+",
                  ranges=Dict{String,Any}("i" => ESM_OC.IndexSetRef("steps")))
        file = _oc_file(
            Dict("y" => _oc_array(), "i" => _oc_scalar(), "p" => _oc_param()),
            [ESM_OC.Equation(_v("y"), agg),
             ESM_OC.Equation(_v("i"), _idx("y", _i(1)))])
        @test isempty(ESM_OC.validate_observed_cycles(file))
    end

    @testset "an ODE state read by its own derivative equation is not a cycle" begin
        # `D(x) = -k*x` is not an observed DEFINITION at all (§6.3.1), so the
        # state never enters this graph — the classification does that work and
        # this test pins that it keeps doing it.
        file = _oc_file(
            Dict("x" => _oc_scalar(), "k" => _oc_param()),
            [ESM_OC.Equation(_D("x"), _op("*", _op("-", _v("k")), _v("x")))])
        @test isempty(ESM_OC.validate_observed_cycles(file))
    end

    # ── Recursion into subsystems ──────────────────────────────────────────

    @testset "a cycle inside a subsystem is reported at the subsystem's path" begin
        inner = ESM_OC.Model(
            Dict("a" => _oc_scalar(), "b" => _oc_scalar()),
            ESM_OC.Equation[ESM_OC.Equation(_v("a"), _v("b")),
                            ESM_OC.Equation(_v("b"), _v("a"))])
        file = _oc_file(Dict("p" => _oc_param()), ESM_OC.Equation[];
                        subsystems=OrderedDict{String,ESM_OC.SubsystemNode}("S" => inner))
        errs = ESM_OC.validate_observed_cycles(file)
        @test length(errs) == 1
        @test errs[1].path == "/models/M/subsystems/S"
        @test errs[1].error_type == "observed_cycle"
    end

    # ── The pass is wired into validate_structural ─────────────────────────

    @testset "validate_structural runs the check" begin
        file = _oc_file(
            Dict("a" => _oc_scalar(), "b" => _oc_scalar()),
            [ESM_OC.Equation(_v("a"), _v("b")), ESM_OC.Equation(_v("b"), _v("a"))])
        codes = Set(e.error_type for e in EarthSciAST.validate_structural(file))
        @test "observed_cycle" in codes
    end
end
