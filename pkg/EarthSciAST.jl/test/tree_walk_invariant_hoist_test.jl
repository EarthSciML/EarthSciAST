# Lane-invariant hoisting in the vectorized array kernels.
#
# A subtree of an `arrayop` with no free cell index — `exp(-Ea/T)`, `2*pi*t`, any
# pure parameter/time/scalar-state algebra — has the same value in every lane. The
# vec builders collapse it to ONE `_VK_INVARIANT` node: evaluated once per RHS call
# via the scalar `_eval_node` and broadcast, instead of recomputed per lane with a
# full-length temp buffer at every interior node.
#
# What these tests pin:
#   1. NUMERIC IDENTITY — the whole point. A hoisted RHS is bit-identical to the
#      same model written with the invariant pre-collapsed by hand.
#   2. The hoist actually FIRES (else 1. would pass vacuously forever).
#   3. RE-EVALUATION per call: an invariant over `t` or a scalar STATE is lane-
#      invariant but NOT constant — it must be recomputed every RHS call. A build-time
#      fold would pass a fixed-t test and silently freeze the term.
#   4. The recipe trap: in the symbolic-stencil builder the template's LITERAL/STATE
#      leaves are per-lane RECIPE PLACEHOLDERS, not lane values. The hoist must
#      reconstruct its scalar node from the LOWERED children; reading the source
#      template would splice a placeholder literal into the arithmetic.
#   5. Zero allocations survive the new node kind.

using Test
using EarthSciAST

include("testutils.jl")  # builder quartet + zero_alloc_harness.jl

const ESM = EarthSciAST

_Dt(v) = Dict{String,Any}("op" => "D", "args" => Any[v], "wrt" => "t")
_ix(v, i...) = Dict{String,Any}("op" => "index", "args" => Any[v, i...])
_o(o, a...) = Dict{String,Any}("op" => o, "args" => Any[a...])
_arr(e) = Dict{String,Any}("op" => "arrayop", "output_idx" => Any["i"],
    "ranges" => Dict{String,Any}("i" => Dict{String,Any}("from" => "n")),
    "args" => Any[], "expr" => e)

# 1-D reaction–diffusion. `rate` is spliced in so the SAME equation can be written
# with the invariant inline (hoisted) or pre-collapsed to a bare parameter (nothing
# to hoist) — the two must agree bit-for-bit.
function _rd_model(N; inline_rate::Bool)
    stencil = _o("+", _o("-", _ix("c", _o("-", "i", 1.0)), _o("*", 2.0, _ix("c", "i"))),
                 _ix("c", _o("+", "i", 1.0)))
    rate = inline_rate ? _o("*", "k_rxn", _o("exp", _o("neg", _o("/", "Ea", "T")))) : "r"
    vars = Dict{String,Any}(
        "c" => Dict{String,Any}("type" => "state", "shape" => Any["n"]),
        "k_diff" => Dict{String,Any}("type" => "parameter", "default" => 0.1))
    if inline_rate
        vars["k_rxn"] = Dict{String,Any}("type" => "parameter", "default" => 0.3)
        vars["Ea"] = Dict{String,Any}("type" => "parameter", "default" => 50.0)
        vars["T"] = Dict{String,Any}("type" => "parameter", "default" => 300.0)
    else
        vars["r"] = Dict{String,Any}("type" => "parameter", "default" => 0.3 * exp(-50.0 / 300.0))
    end
    return Dict{String,Any}(
        "esm" => "0.5.0", "metadata" => Dict{String,Any}("name" => "RD"),
        "index_sets" => Dict{String,Any}("n" => Dict{String,Any}("kind" => "interval", "size" => N)),
        "models" => Dict{String,Any}("M" => Dict{String,Any}(
            "variables" => vars,
            "equations" => Any[Dict{String,Any}(
                "lhs" => _arr(_Dt(_ix("c", "i"))),
                "rhs" => _arr(_o("-", _o("*", "k_diff", stencil),
                                 _o("*", rate, _o("^", _ix("c", "i"), 2.0)))))])))
end

# Count `_VecNode`s by kind across every kernel of a built evaluator.
function _kind_hist(f!)
    hist = Dict{UInt8,Int}()
    walk(n) = (hist[n.kind] = get(hist, n.kind, 0) + 1; foreach(walk, n.children))
    for vk in getfield(f!, :vec_kernels)
        walk(vk.template)
    end
    return hist
end

_eval_rhs(f!, u0, p, t) = (du = similar(u0); f!(du, u0, p, t); du)

@testset "lane-invariant hoisting in vectorized kernels" begin

    @testset "hoisted RHS is bit-identical to the hand-collapsed one" begin
        for N in (16, 257)
            fa, ua, pa, _, _ = ESM.build_evaluator(_rd_model(N; inline_rate = true))
            fb, ub, pb, _, _ = ESM.build_evaluator(_rd_model(N; inline_rate = false))
            u = [0.3 + 0.7sin(0.21k) for k in 1:N]
            da = _eval_rhs(fa, u, pa, 0.0)
            db = _eval_rhs(fb, u, pb, 0.0)
            @test da == db          # bit-for-bit, not isapprox
        end
    end

    @testset "the hoist actually fires (and removes the interior temp buffers)" begin
        f_in, = ESM.build_evaluator(_rd_model(257; inline_rate = true))
        f_pre, = ESM.build_evaluator(_rd_model(257; inline_rate = false))
        h_in = _kind_hist(f_in)
        # `k_rxn * exp(-Ea/T)` collapses to a single INVARIANT node...
        @test get(h_in, ESM._VK_INVARIANT, 0) >= 1
        # ...and the 4 OP nodes it contained (*, exp, neg, /) are gone: the inline
        # form now compiles to no more OP nodes than the pre-collapsed form.
        @test get(h_in, ESM._VK_OP, 0) <= get(_kind_hist(f_pre), ESM._VK_OP, 0)
    end

    @testset "an invariant over t is RE-EVALUATED each call, not frozen at build" begin
        # D(c[i]) = sin(2*t) * c[i]   — `sin(2t)` is lane-invariant but time-varying.
        N = 32
        doc = Dict{String,Any}(
            "esm" => "0.5.0", "metadata" => Dict{String,Any}("name" => "TV"),
            "index_sets" => Dict{String,Any}("n" => Dict{String,Any}("kind" => "interval", "size" => N)),
            "models" => Dict{String,Any}("M" => Dict{String,Any}(
                "variables" => Dict{String,Any}("c" => Dict{String,Any}("type" => "state", "shape" => Any["n"])),
                "equations" => Any[Dict{String,Any}(
                    "lhs" => _arr(_Dt(_ix("c", "i"))),
                    "rhs" => _arr(_o("*", _o("sin", _o("*", 2.0, "t")), _ix("c", "i"))))])))
        f!, u0, p, _, _ = ESM.build_evaluator(doc)
        @test get(_kind_hist(f!), ESM._VK_INVARIANT, 0) >= 1   # sin(2t) hoisted
        u = [1.0 + 0.1k for k in 1:N]
        for t in (0.0, 0.37, 1.9, -2.5)
            @test _eval_rhs(f!, u, p, t) ≈ sin(2t) .* u
        end
    end

    @testset "an invariant over a scalar STATE tracks u, not a build-time value" begin
        # D(c[i]) = s * c[i];  D(s) = 0.  `s` is a 0-D state read inside the arrayop:
        # lane-invariant, but it moves with the integrator.
        N = 24
        doc = Dict{String,Any}(
            "esm" => "0.5.0", "metadata" => Dict{String,Any}("name" => "SS"),
            "index_sets" => Dict{String,Any}("n" => Dict{String,Any}("kind" => "interval", "size" => N)),
            "models" => Dict{String,Any}("M" => Dict{String,Any}(
                "variables" => Dict{String,Any}(
                    "c" => Dict{String,Any}("type" => "state", "shape" => Any["n"]),
                    "s" => Dict{String,Any}("type" => "state")),
                "equations" => Any[
                    Dict{String,Any}("lhs" => _arr(_Dt(_ix("c", "i"))),
                                     "rhs" => _arr(_o("*", _o("*", "s", "s"), _ix("c", "i")))),
                    Dict{String,Any}("lhs" => _Dt("s"), "rhs" => 0.0)])))
        f!, u0, p, _, vm = ESM.build_evaluator(doc)
        @test get(_kind_hist(f!), ESM._VK_INVARIANT, 0) >= 1   # s*s hoisted
        for sval in (2.0, -1.5, 0.0)
            u = copy(u0)
            for k in 1:N; u[vm["c[$k]"]] = 0.5k; end
            u[vm["s"]] = sval
            du = _eval_rhs(f!, u, p, 0.0)
            for k in 1:N
                @test du[vm["c[$k]"]] == sval * sval * (0.5k)
            end
        end
    end

    @testset "symbolic-stencil path: per-lane const recipes are not spliced into the hoist" begin
        # The stencil builder resolves LITERAL/STATE leaves through per-lane RECIPES,
        # so the template's own `literal`/`idx` fields are placeholders. A hoist that
        # rebuilt its scalar node from the TEMPLATE (rather than from the lowered
        # children) would splice a placeholder into `k*a[i]` here. Mixing a per-cell
        # const array (a lane-VARYING recipe leaf) with a lane-INVARIANT parameter
        # subtree in one stencil equation is exactly that trap.
        N = 64
        a = [1.0 + 0.5k for k in 1:N]
        doc = Dict{String,Any}(
            "esm" => "0.5.0", "metadata" => Dict{String,Any}("name" => "MIX"),
            "index_sets" => Dict{String,Any}("n" => Dict{String,Any}("kind" => "interval", "size" => N)),
            "models" => Dict{String,Any}("M" => Dict{String,Any}(
                "variables" => Dict{String,Any}(
                    "c" => Dict{String,Any}("type" => "state", "shape" => Any["n"]),
                    "g" => Dict{String,Any}("type" => "parameter", "default" => 3.0),
                    "h" => Dict{String,Any}("type" => "parameter", "default" => 7.0)),
                # D(c[i]) = (g/h) * a[i] + c[i]   — `g/h` invariant, `a[i]` per-cell const
                "equations" => Any[Dict{String,Any}(
                    "lhs" => _arr(_Dt(_ix("c", "i"))),
                    "rhs" => _arr(_o("+", _o("*", _o("/", "g", "h"), _ix("a", "i")),
                                     _ix("c", "i"))))])))
        f!, u0, p, _, vm = ESM.build_evaluator(doc; const_arrays = Dict("a" => a))
        @test get(_kind_hist(f!), ESM._VK_INVARIANT, 0) >= 1   # g/h hoisted
        u = copy(u0)
        for k in 1:N; u[vm["c[$k]"]] = 0.25k; end
        du = _eval_rhs(f!, u, p, 0.0)
        for k in 1:N
            @test du[vm["c[$k]"]] ≈ (3.0 / 7.0) * a[k] + 0.25k
        end
    end

    @testset "hoisted RHS stays allocation-free" begin
        for N in (64, 512)
            ics = Dict("c[$k]" => 0.3 + 0.2k for k in 1:N)
            @test built_rhs_alloc_bytes(_rd_model(N; inline_rate = true);
                                        initial_conditions = ics) == 0
        end
    end
end
