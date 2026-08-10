# Differential oracle for the B1 codegen tier over PER-LANE interp specs
# (tree_walk/codegen_kernel.jl `_cg_emit_fn`, the `_Interp*LaneSpec` arms).
#
# The kernel-class merge (oop_merge.jl, ON by default) fuses same-structure
# kernels whose `interp.*` calls carry DIFFERENT (same-shape) const tables by
# tabling the specs per lane (`_Interp*LaneSpec`). Before the lane-spec arms,
# `_cg_emit_fn` declined those payloads (`:codegen_decline_fn_payload`), so
# with the merge ON every merged kernel carrying a varying interp table
# silently dropped from the compiled tier to the lane-tape/scalar runners.
#
# What must hold, and is asserted here, for all three payload flavours
# (linear / bilinear / searchsorted):
#   1. THE FIXTURE IS REAL — the class merge fires (kernel count shrinks) and
#      the merged kernel really carries a per-lane spec payload (introspected
#      off the codegen-disabled build's kernel list; without this the tally
#      and identity checks could pass vacuously on an unmerged build).
#   2. THE TIER ACCEPTS — `:codegen_kernel` fires with ZERO
#      `:codegen_decline_fn_payload` in `_CASCADE_TALLY`, and the section's
#      residual kernel list is EMPTY (the merged interp kernel is ON the
#      compiled tier, not silently on a fallback runner).
#   3. BIT-IDENTITY — du is `===` per element (NaN/-0.0 count; never ≈)
#      between the codegen build and ESS_CODEGEN_DISABLE=1, at Float64 AND
#      under ForwardDiff Dual (values + partials via the Jacobian bit-compare
#      — the tier is the AD fast path), and ≡ the UNMERGED build too.
#   4. LANES DISCRIMINATE — with identical u/v states the two blocks differ
#      (the tables differ), so "every lane read the representative's table"
#      can never pass, in either tier.
using Test
using EarthSciAST
using ForwardDiff
include("testutils.jl")
const ESM = EarthSciAST

# Build with codegen and the kernel-class merge toggled independently.
# Returns (f!, u0, p, vmap, diag, tally-snapshot).
function _cgl_build(model, ics; codegen::Bool, merged::Bool=true)
    withenv("ESS_CODEGEN_DISABLE" => (codegen ? nothing : "1"),
            "ESS_OOP_MERGE_DISABLE" => (merged ? nothing : "1")) do
        ESM._reset_cascade_tally!()
        f!, u0, p, _t, vm, diag = ESM._build_evaluator_impl(model;
            initial_conditions=ics)
        (f!, u0, p, vm, diag, copy(ESM._CASCADE_TALLY))
    end
end

_cgl_du(f!, u, p, t) = (d = similar(u); fill!(d, 0.0); f!(d, u, p, t); d)
_cgl_bitsame(a, b) = size(a) == size(b) && all(a .=== b)
# Deterministic probe states, kept inside the interp axes' [0, 4] span (clamp
# semantics are identical either way; interior queries exercise real blends).
_cgl_probe(n, k) =
    Float64[2.0 + 1.3 * sin(1.3i + 0.7k) * cos(0.31i * k) + 0.01i for i in 1:n]

# Does any `:fn` node reachable from K (spine, CSE recipes, invariant recipes,
# template subs) carry a per-lane spec of type `LaneT`? Pins that the fixture
# minted the payload under test. Spines are DAGs — an IdDict visited set keeps
# the walk linear.
function _cgl_has_lanespec(K, ::Type{LaneT}) where {LaneT}
    seen = IdDict{Any,Nothing}()
    visit(nd) = begin
        haskey(seen, nd) && return false
        seen[nd] = nothing
        nd.kind === ESM._NK_OP && nd.op === :fn &&
            nd.payload isa Tuple{String,LaneT} && return true
        any(visit, nd.children)
    end
    visit(K.spine) && return true
    any(visit, K.cse.recipes) && return true
    any(visit, K.cse.inv_recipes) && return true
    return any(S -> _cgl_has_lanespec(S, LaneT), K.subs)
end

# The full differential for one twin-table model: fixture-really-fired pins,
# acceptance tally, and bit-identity at Float64 + Dual against BOTH references
# (merged interpreter and unmerged build).
function _cgl_differential(model, ics, ::Type{LaneT}; jacobian::Bool=true) where {LaneT}
    fc, u0, p, _, dm, tally = _cgl_build(model, ics; codegen=true, merged=true)
    fr, v0, q, _, _, rtally = _cgl_build(model, ics; codegen=false, merged=true)
    fu, w0, r, _, du_, _ = _cgl_build(model, ics; codegen=false, merged=false)

    # (1) the fixture is real: the class merge fired and minted a lane spec.
    @test dm.n_acc_kernels < du_.n_acc_kernels
    ksr = getfield(fr, :kernel_section)
    @test any(K -> _cgl_has_lanespec(K, LaneT), getfield(ksr, :kernels))

    # (2) the codegen tier accepted the lane-spec payload — no fn_payload
    # decline, and NO residual kernel (the merged kernel is on the compiled
    # tier, not a silent fallback).
    @test get(tally, :codegen_kernel, 0) >= 1
    @test get(tally, :codegen_decline_fn_payload, 0) == 0
    ksc = getfield(fc, :kernel_section)
    @test getfield(ksc, :n_emitted) >= 1
    @test isempty(getfield(ksc, :kernels))
    @test get(rtally, :codegen_kernel, 0) == 0   # the kill switch really kills

    # (3) bit-identity at Float64 …
    @test u0 == v0 && u0 == w0
    for k in 1:5, t in (0.0, 0.7, 3.25)
        u = k == 1 ? copy(u0) : _cgl_probe(length(u0), k)
        duc = _cgl_du(fc, u, p, t)
        @test _cgl_bitsame(duc, _cgl_du(fr, u, q, t))   # ≡ merged interpreter
        @test _cgl_bitsame(duc, _cgl_du(fu, u, r, t))   # ≡ unmerged reference
    end
    # … and under ForwardDiff Dual (du values AND partials, via the Jacobian).
    if jacobian
        Jc = ForwardDiff.jacobian(uu -> _cgl_du(fc, uu, p, 0.4), u0)
        Jr = ForwardDiff.jacobian(uu -> _cgl_du(fr, uu, q, 0.4), v0)
        Ju = ForwardDiff.jacobian(uu -> _cgl_du(fu, uu, r, 0.4), w0)
        @test _cgl_bitsame(Jc, Jr)
        @test _cgl_bitsame(Jc, Ju)
    end
    return nothing
end

# ---- twin-table fixtures (same STRUCTURE, different same-shape tables — one
#      merge class whose fn payload must become an `_Interp*LaneSpec`) --------

const _CGL_AX = [0.0, 1.0, 2.0, 3.0, 4.0]
const _CGL_TA = [10.0, 20.0, 40.0, 80.0, 160.0]
const _CGL_TB = [-3.0, 5.0, -11.0, 17.0, -23.0]
const _CGL_TC = [0.25, -0.5, 1.0, -2.0, 4.0]

_cgl_vars(names...) =
    Dict{String,ESM.ModelVariable}(n => ESM.ModelVariable(ESM.StateVariable)
                                   for n in names)
_cgl_eq(x, body, N) = ESM.Equation(_ao1(_Didx(x, _v("i")), "i", 1, N),
                                   _ao1(body, "i", 1, N))

# THREE members (u/v/w with tables A/B/C): lanes 1:N / N+1:2N / 2N+1:3N of the
# merged kernel each read their OWN table — a misaddressed lane index cannot
# alias back onto the right spec.
function _cgl_linear_model(N)
    body(x, tbl) = _op("+",
        _op("fn", _const(tbl), _const(_CGL_AX), _idx(x, _v("i")); name="interp.linear"),
        _op("*", _n(-0.5), _idx(x, _v("i"))))
    ESM.Model(_cgl_vars("u", "v", "w"),
              [_cgl_eq("u", body("u", _CGL_TA), N),
               _cgl_eq("v", body("v", _CGL_TB), N),
               _cgl_eq("w", body("w", _CGL_TC), N)])
end

const _CGL_BTA = Any[Any[1.0, 1.5, 2.0], Any[1.1, 1.6, 2.1], Any[1.2, 1.7, 2.2]]
const _CGL_BTB = Any[Any[-9.0, 3.0, -1.0], Any[2.5, -4.0, 0.5], Any[-0.25, 8.0, -6.0]]
const _CGL_BAX = [0.0, 1.0, 2.0]

function _cgl_bilinear_model(N)
    body(x, tbl) = _op("fn", _const(tbl), _const(_CGL_BAX), _const(_CGL_BAX),
                       _idx(x, _v("i")), _idx(x, _op("+", _v("i"), _i(1)));
                       name="interp.bilinear")
    ESM.Model(_cgl_vars("u", "v"),
              [_cgl_eq("u", body("u", _CGL_BTA), N),
               _cgl_eq("v", body("v", _CGL_BTB), N)])
end

const _CGL_SSA = [0.5, 1.5, 2.5, 3.5]
const _CGL_SSB = [1.0, 2.0, 2.0, 3.0]     # duplicates: the fiddly boundary case

function _cgl_searchsorted_model(N)
    body(x, xs) = _op("fn", _idx(x, _v("i")), _const(xs); name="interp.searchsorted")
    ESM.Model(_cgl_vars("u", "v"),
              [_cgl_eq("u", body("u", _CGL_SSA), N),
               _cgl_eq("v", body("v", _CGL_SSB), N)])
end

_cgl_ics(names, N) =
    Dict("$x[$k]" => 2.0 + sin(0.3k + 0.1j) for (j, x) in enumerate(names), k in 1:N)

@testset "codegen tier accepts per-lane interp specs (kernel-class merge)" begin

    @testset "interp.linear × 3 tables (N=$N)" for N in (7, 24)
        _cgl_differential(_cgl_linear_model(N), _cgl_ics(("u", "v", "w"), N),
                          ESM._InterpLinearLaneSpec)
    end

    @testset "interp.bilinear × 2 tables (N=$N)" for N in (6, 17)
        _cgl_differential(_cgl_bilinear_model(N), _cgl_ics(("u", "v"), N),
                          ESM._InterpBilinearLaneSpec)
    end

    @testset "interp.searchsorted × 2 knot vectors (N=$N)" for N in (6, 17)
        # Jacobian included: the piecewise-constant partials are trivially
        # zero, but the Dual VALUES must still round-trip the lane addressing.
        _cgl_differential(_cgl_searchsorted_model(N), _cgl_ics(("u", "v"), N),
                          ESM._InterpSearchsortedLaneSpec)
    end

    @testset "lanes discriminate: identical states, different tables" begin
        # u and v get the SAME ICs; their du blocks must differ (tables differ)
        # in the codegen build — a per-lane addressing bug that fed every lane
        # the representative's table would make them equal.
        N = 9
        ics = Dict("$x[$k]" => 2.0 + sin(0.3k) for x in ("u", "v", "w"), k in 1:N)
        f!, u0, p, vm, _, tally = _cgl_build(_cgl_linear_model(N), ics;
                                             codegen=true, merged=true)
        @test get(tally, :codegen_decline_fn_payload, 0) == 0
        du = _cgl_du(f!, u0, p, 0.0)
        ublk = [du[vm["u[$k]"]] for k in 1:N]
        vblk = [du[vm["v[$k]"]] for k in 1:N]
        wblk = [du[vm["w[$k]"]] for k in 1:N]
        @test ublk != vblk && ublk != wblk && vblk != wblk
    end
end
