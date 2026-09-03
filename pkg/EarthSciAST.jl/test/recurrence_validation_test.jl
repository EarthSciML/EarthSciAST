# Causal self-reference (recurrence) — the STATIC contract (esm-spec §4.3.1.1,
# CONFORMANCE_SPEC §5.19.5).
#
# Every case here asserts the exact CODE and the exact PATH, because rejection
# parity is stated over both: a binding that rejects the right documents under
# the wrong code, or points at the wrong field, has not implemented §5.19.5.
# The pointer convention is the containing equation's `rhs`, `/models/<M>/
# equations/<i>/rhs`, shared with the sibling aggregate checks.
#
# The rejection cases build the AST directly rather than adding fixtures: the
# shared corpus is cross-binding property and each of these shapes is a
# one-node mutation of the same legal document, which reads better as a table
# here than as six near-identical files.

using Test
using EarthSciAST
using OrderedCollections: OrderedDict

include("testutils.jl")  # TESTUTILS_REPO_ROOT + the _v/_i/_op/_idx AST quartet

const ESM_R = EarthSciAST

# One model, one array unknown `s` over a 4-element `steps`, and the given RHS.
# `steps` is an `interval` set so the validator can resolve `k`'s bounds — the
# same shape the numeric fixtures use.
function _recur_file(rhs::ESM_R.ASTExpr; lhs=_v("s"))
    vars = Dict{String,ESM_R.ModelVariable}(
        "s" => ESM_R.ModelVariable(ESM_R.UnknownVariable; shape=Any["steps"], units="1"))
    model = ESM_R.Model(vars, ESM_R.Equation[ESM_R.Equation(lhs, rhs)])
    return ESM_R.EsmFile("1.0.0", ESM_R.Metadata("Recur");
        models=Dict("M" => model),
        index_sets=OrderedDict("steps" => ESM_R.IndexSet("interval"; size=4)))
end

# `aggregate{output_idx: [k], ranges: {k: steps, extra…}} body`.
_recur_agg(body::ESM_R.ASTExpr; extra_ranges=Dict{String,Any}()) =
    _op("aggregate"; output_idx=Any["k"], expr_body=body, reduce="+",
        ranges=merge(Dict{String,Any}("k" => ESM_R.IndexSetRef("steps")), extra_ranges))

# The legal body this file's rejections are each one mutation away from:
# `ifelse(k <= 1, 1.0, 2 * s[k-1])`.
_recur_guarded(read::ESM_R.ASTExpr) =
    _op("ifelse", _op("<=", _v("k"), _i(1)), _n(1.0), _op("*", read, _n(2.0)))

# The recurrence findings only, so an unrelated finding (units, balance) in a
# hand-built model cannot masquerade as one.
_recur_findings(file) = [e for e in ESM_R.validate_recurrence_semantics(file)]

@testset "Causal self-reference: static well-foundedness (§4.3.1.1)" begin

    @testset "the legal document validates clean" begin
        path = joinpath(TESTUTILS_REPO_ROOT, "tests", "valid",
                        "recurrence_causal_self_reference.esm")
        if _require_fixture(path)
            res = validate_path(path)
            @test isempty(res.structural_errors)
            @test isempty(res.schema_errors)
            @test res.is_valid
        end

        # And the canonical spelling of §4.3.1.1's own example, built here so
        # the ACCEPT side of the table is exercised on the same AST shape every
        # rejection below mutates.
        legal = _recur_file(_recur_agg(_recur_guarded(
            _idx("s", _op("-", _v("k"), _i(1))))))
        @test isempty(_recur_findings(legal))
    end

    # ── The `recurrence_not_wellfounded` table ─────────────────────────────
    #
    # Each row is a self-read no sweep order can satisfy, so each is a
    # STRUCTURAL defect rather than a runtime boundary: before the construct
    # existed every one of them produced a plausible wrong number.
    @testset "$name is recurrence_not_wellfounded" for (name, read) in [
        # A forward read: cell k would have to wait for cell k+1.
        ("a forward read index(s, k+1)", _idx("s", _op("+", _v("k"), _i(1)))),
        # The cell being written — a definition of `s[k]` in terms of `s[k]`.
        ("a same-cell read index(s, k)", _idx("s", _v("k"))),
        # Not affine in the frame symbol with coefficient 1, so neither the
        # axis nor the direction is decidable.
        ("a non-affine index index(s, 2*k)",
         _idx("s", _op("*", _i(2), _v("k")))),
        # A bare constant names an absolute position, not one relative to the
        # cell being written; its lag is `k - 1`, which is not earlier at k=1.
        ("a constant index index(s, 1)", _idx("s", _i(1))),
    ]
        file = _recur_file(_recur_agg(_recur_guarded(read)))
        errs = _recur_findings(file)
        @test length(errs) == 1
        @test errs[1].error_type == "recurrence_not_wellfounded"
        @test errs[1].path == "/models/M/equations/0/rhs"
        @test errs[1].details["variable"] == "s"
    end

    @testset "a bare read alongside an index read is recurrence_not_wellfounded" begin
        # `s + 2 * s[k-1]`: the bare `s` names the whole array, which does not
        # exist at any point during the sweep that fills it.
        body = _op("ifelse", _op("<=", _v("k"), _i(1)), _n(1.0),
                   _op("+", _v("s"),
                       _op("*", _idx("s", _op("-", _v("k"), _i(1))), _n(2.0))))
        errs = _recur_findings(_recur_file(_recur_agg(body)))
        @test length(errs) == 1
        @test errs[1].error_type == "recurrence_not_wellfounded"
        @test errs[1].path == "/models/M/equations/0/rhs"
        @test occursin("read bare", errs[1].message)
    end

    @testset "a self-read in a makearray region value is recurrence_unsupported_form" begin
        # §4.3.2's "later entries overwrite earlier ones" fixes which write
        # WINS, not the order cells are EVALUATED in, and a region's value is
        # evaluated once for the whole region — so this is not a sweep the
        # runtime can honour, and saying so beats a wrong answer.
        region = _op("makearray";
            regions=[[Any[1, 4]]],
            values=ESM_R.ASTExpr[_idx("s", _op("-", _v("k"), _i(1)))])
        errs = _recur_findings(_recur_file(_recur_agg(region)))
        @test length(errs) == 1
        @test errs[1].error_type == "recurrence_unsupported_form"
        @test errs[1].path == "/models/M/equations/0/rhs"
    end

    @testset "the codes are registered and reach validate_structural" begin
        @test "recurrence_not_wellfounded" in ESM_R.error_code_names()
        @test "recurrence_unsupported_form" in ESM_R.error_code_names()
        # Wiring, not vocabulary: the check must run from the public entry
        # point, not only when called directly.
        file = _recur_file(_recur_agg(_recur_guarded(_idx("s", _v("k")))))
        codes = [e.error_type for e in ESM_R.validate_structural(file)]
        @test "recurrence_not_wellfounded" in codes
    end

    @testset "a derivative LHS is never a recurrence" begin
        # `D(s) ~ aggregate{… s[k-1] …}` is a STENCIL gather on the solver's
        # own state vector, not a self-definition, and it must keep validating
        # exactly as it did before the construct existed (RFC §3 rule 5).
        rhs = _recur_agg(_recur_guarded(_idx("s", _op("-", _v("k"), _i(1)))))
        file = _recur_file(rhs; lhs=_op("D", _v("s"); wrt="t"))
        @test isempty(_recur_findings(file))
        # And the forward read that WOULD be rejected on an algebraic LHS is
        # equally not this check's business here.
        fwd = _recur_agg(_recur_guarded(_idx("s", _op("+", _v("k"), _i(1)))))
        @test isempty(_recur_findings(_recur_file(fwd; lhs=_op("D", _v("s"); wrt="t"))))
    end

    @testset "an unprovable lag is ADMITTED, not rejected" begin
        # `s[k - a]` with `a` in `[0, 3]`: the lag STRADDLES zero, so it cannot
        # be proved strictly earlier. §4.3.1.1 admits it deliberately — the
        # runtime is fail-closed, so the cells where it is not earlier fault
        # rather than returning a laundered zero, and requiring the proof would
        # reject the factored spelling of a bounded-lag fold.
        body = _op("ifelse", _op("==", _v("a"), _i(0)), _n(1.0),
                   _idx("s", _op("-", _v("k"), _v("a"))))
        file = _recur_file(_recur_agg(body; extra_ranges=Dict{String,Any}("a" => Any[0, 3])))
        @test isempty(_recur_findings(file))

        # And `s[k - L]` with `L` a PARAMETER, which nothing static can bound.
        # The proof obligation splits: the COEFFICIENT of `k` must be provably
        # 1 (it is), the lag's SIGN need not be provable at all. A validator
        # that rejected this would reject a document its own evaluator accepts —
        # the one divergence between the two that is never defensible.
        pfile = _recur_file(_recur_agg(_op("ifelse", _op("<=", _v("k"), _v("L")), _n(1.0),
                                           _idx("s", _op("-", _v("k"), _v("L"))))))
        pfile.models["M"].variables["L"] =
            ESM_R.ModelVariable(ESM_R.ParameterVariable; default=2.0, units="1")
        @test isempty(_recur_findings(pfile))

        # Admitting it identifies the axis but does NOT stop counting axes:
        # `m[i - n, j - n]` with `n` unbounded is still two axes.
        two = _op("aggregate"; output_idx=Any["i", "j"], reduce="+",
            ranges=Dict{String,Any}("i" => ESM_R.IndexSetRef("steps"),
                                    "j" => ESM_R.IndexSetRef("steps")),
            expr_body=_idx("m", _op("-", _v("i"), _v("n")), _op("-", _v("j"), _v("n"))))
        tvars = Dict{String,ESM_R.ModelVariable}(
            "m" => ESM_R.ModelVariable(ESM_R.UnknownVariable;
                                       shape=Any["steps", "steps"], units="1"),
            "n" => ESM_R.ModelVariable(ESM_R.ParameterVariable; default=1.0, units="1"))
        tmodel = ESM_R.Model(tvars, ESM_R.Equation[ESM_R.Equation(_v("m"), two)])
        tfile = ESM_R.EsmFile("1.0.0", ESM_R.Metadata("Recur");
            models=Dict("M" => tmodel),
            index_sets=OrderedDict("steps" => ESM_R.IndexSet("interval"; size=4)))
        terrs = _recur_findings(tfile)
        @test length(terrs) == 1
        @test terrs[1].error_type == "recurrence_not_wellfounded"
    end

    # ── The SHARED rejection corpus ────────────────────────────────────────
    #
    # `tests/conformance/recurrence/rejections.json` drives every binding with
    # the same eight malformed documents. A per-binding unit test is not enough
    # for this: the candidacy-vs-verdict gate (§5.19.5) fails NOTHING in a
    # binding's own tests, which is exactly how five bindings drift apart on a
    # single `if`. The corpus pins the `(code, path)` pair and deliberately NOT
    # the prose — the same defect legitimately reads differently depending on
    # which check reached it first.
    @testset "shared rejection corpus (tests/conformance/recurrence)" begin
        manifest_path = joinpath(TESTUTILS_REPO_ROOT, "tests", "conformance",
                                 "recurrence", "rejections.json")
        if _require_fixture(manifest_path)
            manifest = JSON3.read(read(manifest_path, String))
            # Assert the contract the corpus declares, so a silent relaxation of
            # it (prose suddenly pinned, or a case quietly dropped) fails here.
            @test manifest.pinned.code === true
            @test manifest.pinned.path === true
            @test manifest.pinned.message === false
            @test length(manifest.cases) == 8
            for case in manifest.cases
                @testset "$(case.id)" begin
                    res = validate_text(JSON3.write(case.document))
                    codes = [e.error_type for e in res.structural_errors]
                    # GUARD 1. Each corpus document is illegal for exactly ONE
                    # reason — the recurrence rule. A document that drifted
                    # schema-invalid would be refused for a shape error instead,
                    # satisfying an "it was rejected" check while testing nothing
                    # about this construct.
                    @test isempty(res.schema_errors)
                    # GUARD 2. No case may come back as a whole-document or a
                    # cycle error. This states CONFORMANCE_SPEC §5.19.5's
                    # candidacy regression directly and independently of the
                    # per-case pair: gate the self-edge exemption on the
                    # well-foundedness VERDICT instead of on CANDIDACY and every
                    # case collapses to one of these, with the
                    # `recurrence_*` diagnosis never reached. If this fires, the
                    # fix is to gate on candidacy — an array-shaped unknown with
                    # at least one `index` self-read, well founded or not.
                    @test !("load_error" in codes)
                    @test !("circular_dependency" in codes)
                    hits = [e for e in res.structural_errors
                            if e.error_type == String(case.expected_code)]
                    @test length(hits) >= 1
                    @test any(e -> e.path == String(case.expected_path), hits)
                end
            end
        end
    end

    @testset "a document with no self-read is untouched" begin
        # The construct is opt-in by construction: nothing here has an
        # `index(s, …)` inside `s`'s own definition, so the pass emits nothing.
        plain = _recur_file(_recur_agg(_op("*", _v("k"), _n(2.0))))
        @test isempty(_recur_findings(plain))
    end

    # ── The self-edge is not a cycle ───────────────────────────────────────
    #
    # esm-spec §4.3.1.1: "A recurrence definition is NOT a cyclic algebraic
    # system." The tree-walk build used to disagree — `_resolve_observed`
    # substitutes observed bodies to a fixed point, a self-reference never
    # converges, and the iteration cap surfaced as `E_TREEWALK_OBSERVED_CYCLE`.
    # These two testsets pin the distinction from both sides.
    @testset "a legal recurrence is not reported as a cycle" begin
        path = joinpath(TESTUTILS_REPO_ROOT, "tests", "valid",
                        "recurrence_causal_self_reference.esm")
        if _require_fixture(path)
            err = try
                build_evaluator(load_path(path))
                nothing
            catch e
                e
            end
            @test err isa EarthSciAST.TreeWalkError
            # The decline names the construct. What it must NOT say is "cycle":
            # this backend reorders per-cell kernels and so cannot honour the
            # fixed sweep order (CONFORMANCE_SPEC §5.19.2), which is a statement
            # about the BACKEND, not about the document.
            @test err.code == "E_TREEWALK_UNSUPPORTED_RECURRENCE"
            @test err.code != "E_TREEWALK_OBSERVED_CYCLE"
            @test occursin("r", err.detail)
        end
    end

    @testset "a cycle through two distinct variables is still rejected" begin
        # `a ~ b + 1; b ~ a + 1` closes a real cycle. Admitting the self-edge
        # must not weaken this: a binding that admits a recurrence by disabling
        # its observed-cycle detector has not implemented §5.19.5.
        vars = Dict{String,ESM_R.ModelVariable}(
            "x" => ESM_R.ModelVariable(ESM_R.UnknownVariable; default=1.0),
            "a" => ESM_R.ModelVariable(ESM_R.UnknownVariable),
            "b" => ESM_R.ModelVariable(ESM_R.UnknownVariable))
        eqs = ESM_R.Equation[
            ESM_R.Equation(_v("a"), _op("+", _v("b"), _n(1.0))),
            ESM_R.Equation(_v("b"), _op("+", _v("a"), _n(1.0))),
            ESM_R.Equation(_D("x"), _v("a")),
        ]
        err = try
            build_evaluator(ESM_R.Model(vars, eqs))
            nothing
        catch e
            e
        end
        @test err isa EarthSciAST.TreeWalkError
        @test err.code == "E_TREEWALK_OBSERVED_CYCLE"
    end

    @testset "a BARE self-reference is still a cycle, not a recurrence" begin
        # `y ~ y + 1` is no recurrence under any reading — §4.3.1.1 rejects a
        # bare self-read outright — so it keeps the cycle diagnosis rather than
        # borrowing the recurrence decline.
        vars = Dict{String,ESM_R.ModelVariable}(
            "x" => ESM_R.ModelVariable(ESM_R.UnknownVariable; default=1.0),
            "y" => ESM_R.ModelVariable(ESM_R.UnknownVariable))
        eqs = ESM_R.Equation[
            ESM_R.Equation(_v("y"), _op("+", _v("y"), _n(1.0))),
            ESM_R.Equation(_D("x"), _v("y")),
        ]
        err = try
            build_evaluator(ESM_R.Model(vars, eqs))
            nothing
        catch e
            e
        end
        @test err isa EarthSciAST.TreeWalkError
        @test err.code == "E_TREEWALK_OBSERVED_CYCLE"
    end

    @testset "recurrence_self_reference_kind is a CANDIDACY predicate" begin
        # `:indexed` means "the recurrence check owns this equation's
        # diagnosis", not "this equation is well founded" — see the file-level
        # note in src/recurrence.jl. So an ill-founded self-read is still a
        # candidate, which is what keeps its `recurrence_not_wellfounded`
        # diagnosis from being replaced by a cycle error.
        f = ESM_R.recurrence_self_reference_kind
        @test f("s", _recur_agg(_recur_guarded(
            _idx("s", _op("-", _v("k"), _i(1)))))) === :indexed
        @test f("s", _recur_agg(_recur_guarded(
            _idx("s", _op("+", _v("k"), _i(1)))))) === :indexed
        # Bare AND indexed is still a candidate: there IS an `index` self-read.
        @test f("s", _recur_agg(_op("+", _v("s"),
            _idx("s", _op("-", _v("k"), _i(1)))))) === :indexed
        # Bare ONLY has no axis to fold along, so it is not a candidate.
        @test f("s", _recur_agg(_op("+", _v("s"), _n(1.0)))) === :bare
        @test f("s", _recur_agg(_op("*", _v("k"), _n(2.0)))) === :none
        # A self-read reached only through a `makearray` region VALUE is still a
        # self-read: the decline must see it too, or it would fall onto the
        # reordering path.
        @test f("s", _op("makearray"; regions=[[Any[1, 4]]],
            values=ESM_R.ASTExpr[_idx("s", _op("-", _v("k"), _i(1)))])) === :indexed
    end

    @testset "the numeric fixtures validate clean" begin
        dir = joinpath(TESTUTILS_REPO_ROOT, "tests", "fixtures", "recurrence")
        if isdir(dir)
            files = sort(filter(f -> endswith(f, ".esm"), readdir(dir)))
            @test !isempty(files)
            for f in files
                @testset "$f" begin
                    res = validate_path(joinpath(dir, f))
                    @test isempty(res.structural_errors)
                    @test res.is_valid
                end
            end
        end
    end
end
