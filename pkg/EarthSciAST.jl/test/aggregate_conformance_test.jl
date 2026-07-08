# Cross-binding conformance tests for the M1 semiring / index-set worked
# examples (bead ess-my4.1.5) and the M2 value-equality join.on worked examples
# (bead ess-my4.2.5).
#
# Loads the shared fixtures under tests/valid/aggregate/ that carry inline
# `tests` blocks and evaluates each through `build_evaluator`. Julia, Rust, and
# Python all check the SAME inline expected values baked into these shared
# fixtures, so agreement here is the cross-binding semiring-equivalence proof.
# (The M2 many-to-many fixtures are Julia/Python only — the data-derived
# value-equality engine is M3 in the dense Rust evaluator, which sees only the
# degenerate positional join; see the per-testset comments below.)
#
# Each fixture is a constant-RHS contraction from zero initial conditions, so
# the derivative du = f!(u0) the evaluator returns IS the trajectory value at
# t=1 (y(1) = rate·1 = rate). We therefore assert on du directly — exact, and
# no ODE integrator dependency — and the asserted numbers mirror the fixtures'
# inline `tests[].assertions[].expected` (which Rust/Python check via simulate).
#
# RFC: docs/content/rfcs/semiring-faq-unified-ir.md §5.1 / §5.2 / §5.3 / §5.7 / §7.1 / §7.2.

using Test
using EarthSciAST

include("testutils.jl")  # TESTUTILS_REPO_ROOT

const _AGG_REPO_ROOT = TESTUTILS_REPO_ROOT

# Evaluate a shared aggregate fixture and return (du, vmap), seeding every
# state element to zero (the constant-RHS worked examples start from rest).
function _eval_aggregate_fixture(filename::AbstractString, model_name::AbstractString,
                                 elements::Vector{<:AbstractString})
    path = joinpath(_AGG_REPO_ROOT, "tests", "valid", "aggregate", filename)
    @test isfile(path)
    file = EarthSciAST.load(path)
    ics = Dict(e => 0.0 for e in elements)
    f!, u0, p, _, vmap = build_evaluator(file; model_name=model_name,
                                         initial_conditions=ics)
    du = similar(u0)
    f!(du, u0, p, 0.0)
    return du, vmap
end

@testset "aggregate worked-example conformance (ess-my4.1.5)" begin
    # 7.1 FVM diffusion as the default sum_product ring, plus the empty-range
    # 0̄ identity: degenerate[i] = Σ_{j∈∅} i·j = 0 (sum_product 0̄).
    @testset "fvm_diffusion_sum_product" begin
        du, vmap = _eval_aggregate_fixture(
            "fvm_diffusion_sum_product.esm", "FvmDiffusionSumProduct",
            ["flux[1]", "flux[2]", "degenerate[1]", "degenerate[2]"])
        @test du[vmap["flux[1]"]] ≈ 6.0
        @test du[vmap["flux[2]"]] ≈ 12.0
        # Empty sum_product contraction returns the normative 0̄ identity (0).
        @test du[vmap["degenerate[1]"]] == 0.0
        @test du[vmap["degenerate[2]"]] == 0.0
    end

    # min_sum (tropical): ⊕ = min over the additive body i+j.
    @testset "min_sum_tropical" begin
        du, vmap = _eval_aggregate_fixture(
            "min_sum_tropical.esm", "MinSumTropical", ["dist[1]", "dist[2]"])
        @test du[vmap["dist[1]"]] ≈ 2.0   # min(2,3,4)
        @test du[vmap["dist[2]"]] ≈ 3.0   # min(3,4,5)
    end

    # max_product: ⊕ = max over the product body i*j.
    @testset "max_product_saturation" begin
        du, vmap = _eval_aggregate_fixture(
            "max_product_saturation.esm", "MaxProductSaturation", ["best[1]", "best[2]"])
        @test du[vmap["best[1]"]] ≈ 3.0   # max(1,2,3)
        @test du[vmap["best[2]"]] ≈ 6.0   # max(2,4,6)
    end

    # Categorical index set resolves to [1, |members|]; a 3-member set drives a
    # 3-wide contraction identical to an interval of size 3.
    @testset "categorical_index_set" begin
        du, vmap = _eval_aggregate_fixture(
            "categorical_index_set.esm", "CategoricalIndexSet",
            ["emissions[1]", "emissions[2]"])
        @test du[vmap["emissions[1]"]] ≈ 6.0
        @test du[vmap["emissions[2]"]] ≈ 12.0
    end

    # §7.3 DOWNSTREAM geometric FAQ (bead ess-my4.3.10): the second half of the
    # value-invention end-to-end chain. The first half (mesh-edge enumeration via
    # bool_and_or + distinct + skolem, then rank) MINTS the `edges` index set as a
    # CONST-fold whose byte-identical output is pinned by the determinism
    # `edge_enumeration` + cadence `pure_topology` goldens. Post-fold, `edges` is a
    # PRIMITIVE index set, consumed here by a plain sum_product contraction:
    # area_eff[i] = Σ_{e∈edges} i·e over the 5 materialized edges of the canonical
    # 2-triangle mesh. Same inline `expected` as Rust/Python — completing §7.3.
    @testset "area_eff_edge_faq (downstream geometric FAQ over the edge set)" begin
        du, vmap = _eval_aggregate_fixture(
            "area_eff_edge_faq.esm", "AreaEffEdgeFaq",
            ["area_eff[1]", "area_eff[2]"])
        @test du[vmap["area_eff[1]"]] ≈ 15.0   # Σ_{e=1..5} 1·e = 15
        @test du[vmap["area_eff[2]"]] ≈ 30.0   # Σ_{e=1..5} 2·e = 30
    end
end

# Resolver-level invalid fixture (bead ess-my4.1.6; RFC §5.2): an `aggregate`
# `{from}` range naming an index set absent from the model `index_sets` registry
# is SCHEMA-VALID (so `load` succeeds) but rejected by the index-set-registry
# resolver inside `build_evaluator` — no implicit interval is inferred for an
# undeclared name. Schema-only bindings (TypeScript/Go) accept it; see
# tests/invalid/expected_errors.json (resolver_only entry).
@testset "invalid: undeclared {from} index set rejected (ess-my4.1.6)" begin
    path = joinpath(_AGG_REPO_ROOT, "tests", "invalid", "aggregate",
                    "undeclared_from_name.esm")
    @test isfile(path)
    file = EarthSciAST.load(path)   # schema-valid: load must succeed
    err = try
        build_evaluator(file; model_name="UndeclaredFrom")
        nothing
    catch e
        e
    end
    @test err isa EarthSciAST.TreeWalkError
    @test occursin("ghost_cells", sprint(showerror, err))
end

# M2 join.on conformance (bead ess-my4.2.5). Evaluates the shared join fixtures
# under tests/valid/aggregate/. Julia and Python check the SAME inline expected
# values; Rust additionally checks the degenerate fixture (the value-equality
# m·n engine is M3 in Rust, so the m2m fixtures are Julia/Python here). The
# RFC §5.3 / §5.7 / §7.2 semantics: inner-only; m·n defined; output in declared
# index order (permutation-invariant value); float/null keys rejected at build.
@testset "join.on worked-example conformance (ess-my4.2.5)" begin
    # §7.2 MOVES running-exhaust contraction as the degenerate positional join:
    # the join key columns are the loop indices, so the gate admits every
    # (sourceType x fuelType) combination — byte-identical to the join-free
    # contraction. running_exhaust[p] = p · Σ_{src,fuel} src·fuel = 9p.
    @testset "join_moves_running_exhaust (degenerate positional)" begin
        du, vmap = _eval_aggregate_fixture(
            "join_moves_running_exhaust.esm", "MovesRunningExhaust",
            ["running_exhaust[1]", "running_exhaust[2]"])
        @test du[vmap["running_exhaust[1]"]] ≈ 9.0
        @test du[vmap["running_exhaust[2]"]] ≈ 18.0
    end

    # True value-equality many-to-many join: the shared key "coal" (multiplicity
    # 2 left, 2 right) contributes 2·2 = 4 product terms; "oil"/"gas" unmatched.
    # The constant body 1 makes the reduction COUNT admitted combinations = 4
    # (vs the join-free full product 3·3 = 9), pinning the m·n cardinality.
    @testset "join_disaggregation_m2m (m·n cardinality)" begin
        du, vmap = _eval_aggregate_fixture(
            "join_disaggregation_m2m.esm", "Disaggregation", ["count"])
        @test du[vmap["count"]] ≈ 4.0
    end

    # Determinism: the SAME join with both key sets' members reordered yields the
    # identical count (4) — value-equality matches by member value, not declared
    # position (§5.7 rule 5). Agreement with the canonical fixture above is the
    # permuted-input -> identical-result proof.
    @testset "join_disaggregation_m2m_permuted (determinism)" begin
        du, vmap = _eval_aggregate_fixture(
            "join_disaggregation_m2m_permuted.esm", "DisaggregationPermuted", ["count"])
        @test du[vmap["count"]] ≈ 4.0
    end

    # Build-time key-type rejection (RFC §5.3 / §5.7 rule 1). These shared
    # fixtures live in tests/invalid/aggregate/build_time/ — schema-valid (so the
    # Go/TS schema harness, which globs the parent dir non-recursively, skips
    # them) but rejected by the evaluating bindings at build. A float member or a
    # null member in a join key set must make `build_evaluator` raise, never
    # silently bucket on a non-portable key.
    @testset "build-time key-type rejection" begin
        function _build_error_msg(filename, model_name)
            path = joinpath(_AGG_REPO_ROOT, "tests", "invalid", "aggregate",
                            "build_time", filename)
            @test isfile(path)
            file = EarthSciAST.load(path)
            try
                build_evaluator(file; model_name=model_name,
                                initial_conditions=Dict("count" => 0.0))
                return nothing
            catch e
                return sprint(showerror, e)
            end
        end

        msg_float = _build_error_msg("float_join_key.esm", "FloatJoinKey")
        @test msg_float !== nothing            # rejected, not silently evaluated
        @test occursin("float", lowercase(msg_float))

        msg_null = _build_error_msg("null_in_key_column.esm", "NullInKeyColumn")
        @test msg_null !== nothing             # rejected, not silently evaluated
        @test occursin("null", lowercase(msg_null))
    end
end
