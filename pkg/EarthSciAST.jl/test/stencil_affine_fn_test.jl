# Differential test for interp `:fn` nodes on the affine access-kernel path
# (ess-affine). An interp leaf (`interp.linear` / `interp.bilinear` /
# `interp.searchsorted`) inside an arrayop RHS used to force a whole-equation
# fallback (`_lower_to_access` threw `_StencilFallback`). It is now modelled: the
# fn node is lowered with its `(fname, spec)` payload carried through, and
# `_eval_acc_op` gained a `:fn` arm mirroring `_eval_node_op` (SAME cores, SAME
# const tables). Build each model two ways and require BIT-IDENTITY:
#   * ESS_AFFINE=1          → affine access-kernel path (must FIRE: n_acc ≥ 1)
#   * ESS_STENCIL_DISABLE=1 → per-cell reference
# The const table/axis of an interp are captured in the spec payload, not as
# children — only the scalar query args are lowered as lanes, so a query that is a
# neighbour gather (ghost at the boundary → literal 0.0) is exercised too.
using Test
using EarthSciAST
include("testutils.jl")
const ESM = EarthSciAST

function _affine_build_fn(model, ics; affine::Bool, const_arrays=Dict())
    envs = affine ? ("ESS_AFFINE" => "1", "ESS_STENCIL_DISABLE" => nothing) :
                    ("ESS_AFFINE" => nothing, "ESS_STENCIL_DISABLE" => "1")
    withenv(envs...) do
        f!, u0, p, _tspan, vmap, diag =
            ESM._build_evaluator_impl(model; initial_conditions=ics, form=:inplace,
                                      const_arrays=const_arrays)
        du = zero(u0); f!(du, u0, p, 0.0)
        (du, u0, vmap, diag)
    end
end

const _LT = [10.0, 20.0, 40.0, 80.0, 160.0]
const _LA = [0.0, 1.0, 2.0, 3.0, 4.0]

# D(u[i]) = interp.linear(table, axis, u[i]) — pure local query, one box.
function _fn_local_model(N)
    vars = Dict("u" => ESM.ModelVariable(ESM.StateVariable))
    body = _op("fn", _const(_LT), _const(_LA), _idx("u", _v("i")); name="interp.linear")
    ESM.Model(vars, [ESM.Equation(_ao1(_Didx("u", _v("i")), "i", 1, N),
                                  _ao1(body, "i", 1, N))])
end

# D(u[i]) = interp.linear(table, axis, u[i+1]) + (u[i-1] − 2u[i] + u[i+1]) — the
# interp query is a NEIGHBOUR (ghost at i=N) and it is summed with a Laplacian, so
# interior + two boundary boxes all carry the fn leaf.
function _fn_combined_model(N)
    vars = Dict("u" => ESM.ModelVariable(ESM.StateVariable))
    itp = _op("fn", _const(_LT), _const(_LA),
              _idx("u", _op("+", _v("i"), _i(1))); name="interp.linear")
    lap = _op("+", _idx("u", _op("-", _v("i"), _i(1))),
                   _op("*", _n(-2.0), _idx("u", _v("i"))),
                   _idx("u", _op("+", _v("i"), _i(1))))
    ESM.Model(vars, [ESM.Equation(_ao1(_Didx("u", _v("i")), "i", 1, N),
                                  _ao1(_op("+", itp, lap), "i", 1, N))])
end

# D(u[i]) = interp.searchsorted(u[i], xs) — Int-returning core wrapped to Float64.
function _fn_searchsorted_model(N)
    vars = Dict("u" => ESM.ModelVariable(ESM.StateVariable))
    body = _op("fn", _idx("u", _v("i")), _const(_LA); name="interp.searchsorted")
    ESM.Model(vars, [ESM.Equation(_ao1(_Didx("u", _v("i")), "i", 1, N),
                                  _ao1(body, "i", 1, N))])
end

# D(u[i]) = interp.bilinear(table, ax, ay, u[i], u[i+1]) — two query children, the
# second a neighbour (ghost at the boundary).
const _BT = Any[Any[1.0, 1.5, 2.0], Any[1.1, 1.6, 2.1], Any[1.2, 1.7, 2.2]]
const _BX = [0.0, 1.0, 2.0]
const _BY = [0.0, 1.0, 2.0]
function _fn_bilinear_model(N)
    vars = Dict("u" => ESM.ModelVariable(ESM.StateVariable))
    body = _op("fn", _const(_BT), _const(_BX), _const(_BY),
               _idx("u", _v("i")), _idx("u", _op("+", _v("i"), _i(1)));
               name="interp.bilinear")
    ESM.Model(vars, [ESM.Equation(_ao1(_Didx("u", _v("i")), "i", 1, N),
                                  _ao1(body, "i", 1, N))])
end

@testset "affine interp :fn ≡ per-cell (differential, ess-affine)" begin
    @testset "linear local query (N=$N)" for N in (8, 32, 64)
        ics = Dict("u[$k]" => 2.0 + sin(0.3k) for k in 1:N)
        du_a, _, _, d = _affine_build_fn(_fn_local_model(N), ics; affine=true)
        du_r, _, _, _ = _affine_build_fn(_fn_local_model(N), ics; affine=false)
        @test d.n_acc_kernels >= 1
        @test d.n_vec_kernels == 0
        @test du_a == du_r
    end

    @testset "linear neighbour query + Laplacian, ghost boxes (N=$N)" for N in (8, 32, 64)
        ics = Dict("u[$k]" => 2.0 + sin(0.3k) for k in 1:N)
        du_a, _, _, d = _affine_build_fn(_fn_combined_model(N), ics; affine=true)
        du_r, _, _, _ = _affine_build_fn(_fn_combined_model(N), ics; affine=false)
        @test d.n_acc_kernels >= 1
        @test d.n_vec_kernels == 0
        @test du_a == du_r
    end

    @testset "interp kernel count N-independent" begin
        counts = map((8, 32, 128)) do N
            ics = Dict("u[$k]" => 2.0 + sin(0.3k) for k in 1:N)
            _, _, _, d = _affine_build_fn(_fn_combined_model(N), ics; affine=true)
            d.n_acc_kernels
        end
        @test all(==(counts[1]), counts)   # interior + 2 boundary, regardless of N
    end

    @testset "searchsorted (Int core → Float64) (N=$N)" for N in (8, 32)
        ics = Dict("u[$k]" => 1.7 + 0.03k for k in 1:N)
        du_a, _, _, d = _affine_build_fn(_fn_searchsorted_model(N), ics; affine=true)
        du_r, _, _, _ = _affine_build_fn(_fn_searchsorted_model(N), ics; affine=false)
        @test d.n_acc_kernels >= 1
        @test d.n_vec_kernels == 0
        @test du_a == du_r
    end

    @testset "bilinear two queries, ghost neighbour (N=$N)" for N in (8, 32)
        ics = Dict("u[$k]" => 0.5 + 0.9sin(0.2k) for k in 1:N)
        du_a, _, _, d = _affine_build_fn(_fn_bilinear_model(N), ics; affine=true)
        du_r, _, _, _ = _affine_build_fn(_fn_bilinear_model(N), ics; affine=false)
        @test d.n_acc_kernels >= 1
        @test d.n_vec_kernels == 0
        @test du_a == du_r
    end
end
