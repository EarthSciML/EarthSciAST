# Discrete-cadence materialization (the middle cadence phase; DiscreteMaterializer).
# A state-free array observed transitively tainted by a live `param_arrays` forcing
# buffer is cut out of the per-step RHS into a cache buffer filled once per refresh,
# gathered live by the hot RHS — instead of inlined + recomputed every step (which,
# for a deep regrid->physics chain, collapses into an un-lowerable RHS). Opt-in via
# the `materialize_out` sink; without it, the pre-cut inline path is byte-identical.
#
# This is solver-free (builds the RHS, evaluates it directly): the fill/cache
# semantics and the classification are the contract, not the integration.
using Test
using EarthSciAST
const _DM_ESS = EarthSciAST

_dm_fixture() = joinpath(@__DIR__, "fixtures", "discrete_materialize.esm")

# g[j] = sum_i W[i,j]*src[i]   (param-tainted -> discrete);  k[j] = sum_i W[i,j]*offset
const _DM_W = [1.0 2.0 3.0; 4.0 5.0 6.0]     # W[i,j], i=1..2, j=1..3
_dm_g(src)     = [sum(_DM_W[i, j] * src[i] for i in 1:2) for j in 1:3]
_dm_k(offset)  = [sum(_DM_W[i, j] * offset for i in 1:2) for j in 1:3]

@testset "discrete-cadence materialization (DiscreteMaterializer)" begin
    file = _DM_ESS.load(_dm_fixture())
    ics = Dict{String,Float64}("c[1]" => 0.0, "c[2]" => 0.0, "c[3]" => 0.0)

    @testset "cut matches the inline baseline; only the param-tainted var is cached" begin
        # Inline baseline (no sink): g and k are both inlined into the state RHS.
        srcA = [1.0, 1.0]
        f0!, u00, p0, _, vm0 = _DM_ESS.build_evaluator(file; initial_conditions=ics,
            const_arrays=Dict("W" => _DM_W), param_arrays=Dict("src" => srcA))
        du0 = zero(u00); f0!(du0, u00, p0, 0.0)
        base = [du0[vm0["c[$j]"]] for j in 1:3]
        @test base ≈ _dm_g([1.0, 1.0]) .+ _dm_k(1.0)   # offset default = 1.0

        # Cut (sink): g becomes a discrete cache; k (const-fed) stays inline.
        srcB = [1.0, 1.0]
        dm = _DM_ESS.DiscreteMaterializer()
        f!, u0, p, _, vm = _DM_ESS.build_evaluator(file; initial_conditions=ics,
            const_arrays=Dict("W" => _DM_W), param_arrays=Dict("src" => srcB),
            materialize_out=dm)
        @test haskey(dm.caches, "g")             # param-tainted, state-free -> cached
        @test !haskey(dm.caches, "k")            # const-fed -> NOT cached (regression guard)
        @test dm.caches["g"] == _dm_g([1.0, 1.0])
        du = zero(u0); f!(du, u0, p, 0.0)
        @test [du[vm["c[$j]"]] for j in 1:3] == base   # cut is numerically identical
    end

    @testset "the cache is discrete: stale until materialize!, then tracks" begin
        srcB = [1.0, 1.0]
        dm = _DM_ESS.DiscreteMaterializer()
        f!, u0, p, _, vm = _DM_ESS.build_evaluator(file; initial_conditions=ics,
            const_arrays=Dict("W" => _DM_W), param_arrays=Dict("src" => srcB),
            materialize_out=dm)
        du = zero(u0); f!(du, u0, p, 0.0)
        initial = [du[vm["c[$j]"]] for j in 1:3]

        # Refresh the raw buffer in place but DON'T re-materialize: the RHS reads the
        # cache, so it must be STALE — it did NOT recompute g from the new src.
        srcB .= [2.0, 3.0]
        fill!(du, 0.0); f!(du, u0, p, 0.0)
        @test [du[vm["c[$j]"]] for j in 1:3] == initial

        # Re-materialize (what the refresh callback's post_refresh hook does): the
        # cache updates and the RHS tracks.
        dm.materialize!()
        @test dm.caches["g"] == _dm_g([2.0, 3.0])
        fill!(du, 0.0); f!(du, u0, p, 0.0)
        @test [du[vm["c[$j]"]] for j in 1:3] ≈ _dm_g([2.0, 3.0]) .+ _dm_k(1.0)
    end

    @testset "no sink ⇒ no discrete cut (opt-in), build still succeeds" begin
        # Without the sink the param-tainted g stays inlined — the pre-cut path.
        src = [1.0, 1.0]
        f!, u0, p, _, vm = _DM_ESS.build_evaluator(file; initial_conditions=ics,
            const_arrays=Dict("W" => _DM_W), param_arrays=Dict("src" => src))
        du = zero(u0); f!(du, u0, p, 0.0)
        @test [du[vm["c[$j]"]] for j in 1:3] ≈ _dm_g([1.0, 1.0]) .+ _dm_k(1.0)
    end
end

# ════════════════════════════════════════════════════════════════════════════
# The cadence CLASSIFIER must see a state reference wherever it hides (ess-5d1)
# ════════════════════════════════════════════════════════════════════════════
# A discrete-cadence cache is filled with u = 0 / t = 0 and refilled only on a data
# refresh, so a def that reaches a continuous state or `t` must NEVER be classified
# discrete — it would freeze at u = 0 with no error. The classifier decides this with
# a name-reachability closure over `_referenced_var_names`, which used to walk only
# `args`/`expr_body`/`lower`/`upper`/`values`. A state read from an aggregate `filter`
# predicate (a RUNTIME `ifelse(pred, term, 0̄)` guard — resolve.jl), a value-invention
# `key`, a table-lookup axis (`table_axes`) or an expression-valued dense `ranges`
# bound was therefore INVISIBLE, and the def was silently frozen. Two layers now:
#   (a) the walker goes through the shared `child_exprs` enumeration → every field;
#   (b) `_build_discrete_materializer!` CHECKS the compiled fill node for a state /
#       `t` leaf, so a future classifier blind spot is a build error, not a wrong
#       trajectory.
_dmc_n(x) = _DM_ESS.NumExpr(Float64(x))
_dmc_i(x) = _DM_ESS.IntExpr(Int64(x))
_dmc_v(s) = _DM_ESS.VarExpr(s)
_dmc_op(o, args...; kw...) = _DM_ESS.OpExpr(o, _DM_ESS.ASTExpr[args...]; kw...)
_dmc_idx(vv, is...) = _dmc_op("index", _dmc_v(vv), is...)

# `Fcache[j] = Σ raw[j]` over a LIVE forcing buffer `raw` — param-tainted. Whether it
# is state-reaching depends ONLY on `extra`, the field under test.
_dmc_agg(; kw...) = _dmc_op("aggregate"; output_idx=Any["j"], ranges=Dict("j" => [1, 4]),
    reduce="+", expr_body=_dmc_idx("raw", _dmc_v("j")), kw...)

# Run the cadence split on a single def. Returns the discrete set.
_dmc_split(rhs) = first(_DM_ESS._discrete_materialize_split(
    _DM_ESS.Equation[_DM_ESS.Equation(_dmc_v("Fcache"), rhs)],
    Set(["Fcache"]),      # inline candidates (array observeds)
    Set{String}(),        # const-tier pool
    ["u"],                # continuous state var names
    ["raw"],              # live `param_arrays` forcing buffer names
    Set{String}()))       # scalar params

@testset "cadence classifier sees state refs in every expression field (ess-5d1)" begin
    @testset "control: a state-free, param-tainted aggregate IS still cut" begin
        # The whole point of the tier — this must not regress. No state anywhere.
        @test _dmc_split(_dmc_agg()) == Set(["Fcache"])
        # And a state read from the BODY (the field the walker always saw) is still
        # correctly kept OUT — the pre-existing behavior, unchanged.
        @test _dmc_split(_dmc_op("aggregate"; output_idx=Any["j"],
            ranges=Dict("j" => [1, 4]), reduce="+",
            expr_body=_dmc_op("*", _dmc_idx("raw", _dmc_v("j")),
                              _dmc_idx("u", _dmc_v("j"))))) == Set{String}()
    end

    @testset "state in `filter` ⇒ NOT discrete (the ess-5d1 regression)" begin
        # aggregate(raw[j], filter = u[j] > 0): `u` appears ONLY in the filter, which
        # lowers to a runtime `ifelse(u[j] > 0, raw[j], 0)` guard — a live state read.
        agg = _dmc_agg(filter=_dmc_op(">", _dmc_idx("u", _dmc_v("j")), _dmc_n(0)))
        @test "u" in _DM_ESS._referenced_var_names(agg)
        @test _dmc_split(agg) == Set{String}()
        # `t` in the filter is the same bug (the fill runs at t = 0).
        @test _dmc_split(_dmc_agg(
            filter=_dmc_op(">", _dmc_v("t"), _dmc_n(0)))) == Set{String}()
    end

    @testset "state in `key` ⇒ NOT discrete" begin
        agg = _dmc_agg(distinct=true,
            key=_dmc_op("skolem", _dmc_idx("u", _dmc_v("j"))))
        @test "u" in _DM_ESS._referenced_var_names(agg)
        @test _dmc_split(agg) == Set{String}()
    end

    @testset "state in `table_axes` ⇒ NOT discrete" begin
        # A table lookup whose axis coordinate is a state value.
        lookup = _dmc_op("table_lookup"; table="T",
            table_axes=Dict{String,_DM_ESS.ASTExpr}("x" => _dmc_idx("u", _dmc_v("j"))))
        agg = _dmc_op("aggregate"; output_idx=Any["j"], ranges=Dict("j" => [1, 4]),
            reduce="+", expr_body=_dmc_op("*", _dmc_idx("raw", _dmc_v("j")), lookup))
        @test "u" in _DM_ESS._referenced_var_names(agg)
        @test _dmc_split(agg) == Set{String}()
    end

    @testset "state in a dense `ranges` bound ⇒ NOT discrete" begin
        # An expression-valued dense range bound (child_exprs walks these).
        agg = _dmc_op("aggregate"; output_idx=Any["j"],
            ranges=Dict("j" => [1, 4], "i" => Any[_dmc_i(1), _dmc_idx("u", _dmc_i(1))]),
            reduce="+",
            expr_body=_dmc_op("*", _dmc_idx("raw", _dmc_v("j")), _dmc_v("i")))
        @test "u" in _DM_ESS._referenced_var_names(agg)
        @test _dmc_split(agg) == Set{String}()
    end

    @testset "state in an integral bound / makearray value ⇒ still seen" begin
        # `lower`/`upper`/`values` were already walked — pin them so routing the
        # walker through `child_exprs` did not LOSE coverage.
        @test "u" in _DM_ESS._referenced_var_names(
            _dmc_op("integral", _dmc_v("x"); int_var="x",
                    lower=_dmc_n(0), upper=_dmc_idx("u", _dmc_i(1))))
        @test "u" in _DM_ESS._referenced_var_names(
            _dmc_op("makearray"; values=_DM_ESS.ASTExpr[_dmc_idx("u", _dmc_i(1))]))
    end
end

# ── The build-time safety net: a state-dependent fill kernel is a BUILD ERROR ──
# Independently of whether the classifier is right, `_build_discrete_materializer!`
# refuses to compile a fill node that reads `u` or `t`. Drive it directly with a
# deliberately mis-classified def — this is exactly the shape the old classifier let
# through, and it is what turned a wrong trajectory into a loud failure.
@testset "discrete fill kernels are CHECKED state-free at build (ess-5d1)" begin
    raw = [1.0, 2.0, 3.0, 4.0]
    mk(pgather) = _DM_ESS._build_discrete_materializer!(
        _DM_ESS.DiscreteMaterializer(),
        Set(["Fcache"]),
        Dict{String,_DM_ESS.ASTExpr}("Fcache" => pgather),
        Dict{String,_DM_ESS.ASTExpr}(),                                  # resolved_obs
        Dict{String,Tuple{Vector{Int},Vector{Int}}}("u" => ([1], [4])),  # array_var_info
        Dict{String,Int}("u[$j]" => j for j in 1:4),                     # var_map
        Dict{String,Any}(),                                              # const_arrays
        Dict{String,_DM_ESS._PGatherArray}(                              # live buffers
            "raw" => _DM_ESS._PGatherArray(raw, [4])),
        Set{Symbol}(), Dict{String,Any}(), nothing, 4)

    @testset "a state-reading fill throws E_TREEWALK_DISCRETE_MATERIALIZE" begin
        err = try
            mk(_dmc_agg(filter=_dmc_op(">", _dmc_idx("u", _dmc_v("j")), _dmc_n(0))))
            nothing
        catch e
            e
        end
        @test err isa _DM_ESS.TreeWalkError
        @test err.code == "E_TREEWALK_DISCRETE_MATERIALIZE"
        @test occursin("Fcache", err.detail)                     # names the offender
        @test occursin("continuous state variable", err.detail)  # and says why
    end

    @testset "a `t`-reading fill throws too" begin
        err = try
            mk(_dmc_agg(filter=_dmc_op(">", _dmc_v("t"), _dmc_n(0))))
            nothing
        catch e
            e
        end
        @test err isa _DM_ESS.TreeWalkError
        @test err.code == "E_TREEWALK_DISCRETE_MATERIALIZE"
        @test occursin("Fcache", err.detail)
        @test occursin("`t`", err.detail)
    end

    @testset "control: the legitimate state-free fill still builds and fills" begin
        # A `_NK_PARAM_GATHER` (the raw forcing read) is EXPECTED, not rejected.
        dm = _DM_ESS.DiscreteMaterializer()
        _DM_ESS._build_discrete_materializer!(dm,
            Set(["Fcache"]),
            Dict{String,_DM_ESS.ASTExpr}("Fcache" => _dmc_agg()),
            Dict{String,_DM_ESS.ASTExpr}(),
            Dict{String,Tuple{Vector{Int},Vector{Int}}}("u" => ([1], [4])),
            Dict{String,Int}("u[$j]" => j for j in 1:4),
            Dict{String,Any}(),
            Dict{String,_DM_ESS._PGatherArray}(
                "raw" => _DM_ESS._PGatherArray(raw, [4])),
            Set{Symbol}(), Dict{String,Any}(), nothing, 4)
        @test dm.caches["Fcache"] == raw       # initial fill reads the live buffer
        raw .= [9.0, 9.0, 9.0, 9.0]
        dm.materialize!()                      # and refreshes on demand
        @test dm.caches["Fcache"] == [9.0, 9.0, 9.0, 9.0]
    end
end
