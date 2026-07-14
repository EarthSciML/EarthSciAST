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

# ---------------------------------------------------------------------------
# Closed functions (`fn`) are hoist candidates too (EarthSciSerialization-805).
#
# A closed function is PURE, so a `fn` call whose query args are all lane-invariant
# has ONE value for the whole kernel. It used to be an unconditional hoist BARRIER:
# `_maybe_hoist_invariant` bailed on `op === :fn`, so `interp.linear(tbl, ax, t)` — a
# pure function of time, the FastJX shape — ran as a per-lane map (N table lookups per
# RHS call instead of 1) AND, because a hoist needs ALL children invariant, blocked
# every ANCESTOR of the `fn` from hoisting as well. This is the same barrier ess-obs
# removed from the scalar CSE pass.
#
# The hoist decision stays "all children lane-invariant", NOT "fn is invariant": a
# per-cell query (`interp.linear(tbl, ax, u[i])`) is genuinely lane-VARYING and must
# still lower to a `_VK_FN` map. Note the const table/axis args live in the typed
# `_Interp*Spec` payload, not in `children` — children are only the scalar queries.
# ---------------------------------------------------------------------------

const _HTBL = [10.0, 20.0, 40.0, 80.0, 160.0]
const _HAX = [0.0, 1.0, 2.0, 3.0, 4.0]
const _HXS = [1.0, 2.0, 3.0, 4.0, 5.0]
const _HBTBL = Any[Any[1.0, 1.5, 2.0], Any[1.1, 1.6, 2.1], Any[1.2, 1.7, 2.2]]
const _HBAX = [10.0, 100.0, 1000.0]
const _HBAY = [0.1, 0.5, 1.0]

# One-equation arrayop model: D(u[i]) = <body>, over N cells.
function _fn_model(body, N; params = Dict{String,Float64}())
    vars = Dict{String,ESM.ModelVariable}("u" => ModelVariable(StateVariable))
    for (k, v) in params
        vars[k] = ModelVariable(ParameterVariable; default = v)
    end
    return ESM.Model(vars, [ESM.Equation(_ao1(_Didx("u", _v("i")), "i", 1, N),
                                         _ao1(body, "i", 1, N))])
end

_fn_build(body, N; params = Dict{String,Float64}(), u = k -> 1.0 + 0.01k) =
    ESM.build_evaluator(_fn_model(body, N; params);
                        initial_conditions = Dict("u[$k]" => u(k) for k in 1:N))

@testset "closed functions (`fn`) hoist when every query arg is lane-invariant" begin
    N = 100

    @testset "interp.linear(tbl, ax, t) * u[i] → INVARIANT, no per-lane FN" begin
        body = _op("*", _op("fn", _const(_HTBL), _const(_HAX), _v("t"); name = "interp.linear"),
                   _idx("u", _v("i")))
        f!, u0, p, _, vm = _fn_build(body, N)
        h = _kind_hist(f!)
        @test get(h, ESM._VK_INVARIANT, 0) == 1   # the whole interp call, hoisted
        @test get(h, ESM._VK_FN, 0) == 0          # ...and NOT a per-lane map
        # Numeric identity with the pre-fix per-lane behaviour: every lane must still
        # get exactly `interp.linear(tbl, ax, t) * u[k]` — computed here through the
        # cross-binding scalar contract, not through the evaluator under test.
        for t in (0.0, 0.5, 1.75, 3.0, 9.0, -2.0)
            r = Float64(ESM.evaluate_closed_function("interp.linear", Any[_HTBL, _HAX, t]))
            du = _eval_rhs(f!, u0, p, t)
            for k in 1:N
                @test du[vm["u[$k]"]] == r * u0[vm["u[$k]"]]   # bit-for-bit
            end
        end
    end

    @testset "interp.linear(tbl, ax, u[i]) * 2 → still a per-lane FN" begin
        body = _op("*", _op("fn", _const(_HTBL), _const(_HAX), _idx("u", _v("i"));
                            name = "interp.linear"), _n(2.0))
        qs = k -> -1.0 + 0.06k              # spans below-clamp, knots, above-clamp
        f!, u0, p, _, vm = _fn_build(body, N; u = qs)
        h = _kind_hist(f!)
        @test get(h, ESM._VK_FN, 0) == 1        # per-cell query ⇒ lane-VARYING
        @test get(h, ESM._VK_INVARIANT, 0) == 0
        du = _eval_rhs(f!, u0, p, 0.0)
        for k in 1:N
            ref = Float64(ESM.evaluate_closed_function("interp.linear",
                                                       Any[_HTBL, _HAX, qs(k)]))
            @test du[vm["u[$k]"]] == ref * 2.0
        end
    end

    @testset "maximality: an all-invariant parent absorbs the hoisted fn" begin
        # (interp.linear(tbl, ax, t) * kk) * u[i] — the `* kk` multiply is itself
        # lane-invariant, so the WHOLE `interp * kk` subtree must collapse to ONE
        # `_VK_INVARIANT`, not an INVARIANT fn under a separate OP. Before the fix the
        # unhoistable `_VK_FN` child barred this parent from hoisting at all.
        inner = _op("*", _op("fn", _const(_HTBL), _const(_HAX), _v("t");
                             name = "interp.linear"), _v("kk"))
        body = _op("*", inner, _idx("u", _v("i")))
        f!, u0, p, _, vm = _fn_build(body, N; params = Dict("kk" => 3.0))
        h = _kind_hist(f!)
        @test get(h, ESM._VK_INVARIANT, 0) == 1   # ONE node, not two
        @test get(h, ESM._VK_FN, 0) == 0
        @test get(h, ESM._VK_OP, 0) == 1          # only the outer `* u[i]` survives
        @test get(h, ESM._VK_PARAM, 0) == 0       # `kk` was absorbed into the hoist
        for t in (0.25, 2.5)
            r = Float64(ESM.evaluate_closed_function("interp.linear", Any[_HTBL, _HAX, t]))
            du = _eval_rhs(f!, u0, p, t)
            for k in 1:N
                @test du[vm["u[$k]"]] == (r * 3.0) * u0[vm["u[$k]"]]
            end
        end
    end

    @testset "searchsorted / bilinear: invariant query hoists, per-cell query does not" begin
        # searchsorted(t, xs) — one TIME child ⇒ hoists.
        f!, u0, p, _, vm = _fn_build(
            _op("*", _op("fn", _v("t"), _const(_HXS); name = "interp.searchsorted"),
                _idx("u", _v("i"))), N)
        h = _kind_hist(f!)
        @test get(h, ESM._VK_INVARIANT, 0) == 1
        @test get(h, ESM._VK_FN, 0) == 0
        for t in (0.5, 2.0, 2.5, 6.0)
            r = Float64(ESM.evaluate_closed_function("interp.searchsorted", Any[t, _HXS]))
            du = _eval_rhs(f!, u0, p, t)
            @test all(du[vm["u[$k]"]] == r * u0[vm["u[$k]"]] for k in 1:N)
        end

        # searchsorted(u[i], xs) — per-cell query ⇒ stays a map.
        qs = k -> 0.5 + 0.05k
        g!, v0, pg, _, vmg = _fn_build(
            _op("fn", _idx("u", _v("i")), _const(_HXS); name = "interp.searchsorted"),
            N; u = qs)
        hg = _kind_hist(g!)
        @test get(hg, ESM._VK_FN, 0) == 1
        @test get(hg, ESM._VK_INVARIANT, 0) == 0
        dg = _eval_rhs(g!, v0, pg, 0.0)
        for k in 1:N
            @test dg[vmg["u[$k]"]] ==
                  Float64(ESM.evaluate_closed_function("interp.searchsorted", Any[qs(k), _HXS]))
        end

        # bilinear(tbl, ax, ay, t, cz) — TIME + PARAM children ⇒ both invariant ⇒ hoists.
        b!, b0, pb, _, vmb = _fn_build(
            _op("*", _op("fn", _const(_HBTBL), _const(_HBAX), _const(_HBAY),
                         _v("t"), _v("cz"); name = "interp.bilinear"),
                _idx("u", _v("i"))), N; params = Dict("cz" => 0.5))
        hb = _kind_hist(b!)
        @test get(hb, ESM._VK_INVARIANT, 0) == 1
        @test get(hb, ESM._VK_FN, 0) == 0
        for t in (5.0, 55.0, 500.0, 2000.0)
            r = Float64(ESM.evaluate_closed_function("interp.bilinear",
                                                     Any[_HBTBL, _HBAX, _HBAY, t, 0.5]))
            du = _eval_rhs(b!, b0, pb, t)
            @test all(du[vmb["u[$k]"]] == r * b0[vmb["u[$k]"]] for k in 1:N)
        end

        # bilinear(tbl, ax, ay, u[i], cz) — one per-cell query is enough to keep the map.
        xq = k -> 10.0 * k
        c!, c0, pc, _, vmc = _fn_build(
            _op("fn", _const(_HBTBL), _const(_HBAX), _const(_HBAY),
                _idx("u", _v("i")), _v("cz"); name = "interp.bilinear"),
            N; params = Dict("cz" => 0.5), u = xq)
        hc = _kind_hist(c!)
        @test get(hc, ESM._VK_FN, 0) == 1
        @test get(hc, ESM._VK_INVARIANT, 0) == 0
        dc = _eval_rhs(c!, c0, pc, 0.0)
        for k in 1:N
            @test dc[vmc["u[$k]"]] ==
                  Float64(ESM.evaluate_closed_function("interp.bilinear",
                                                       Any[_HBTBL, _HBAX, _HBAY, xq(k), 0.5]))
        end
    end

    @testset "boxed all-scalar path (datetime.*) is correct hoisted and unhoisted" begin
        # `datetime.*` carries a `(fname, nothing)` payload and no typed spec: the vec
        # arm is a BOXED per-lane map. Hoisted, it routes to the scalar `:fn` arm's boxed
        # branch instead — the same `evaluate_closed_function`, once per call.
        f!, u0, p, _, vm = _fn_build(
            _op("*", _op("fn", _v("t"); name = "datetime.day_of_year"),
                _idx("u", _v("i"))), 16)
        h = _kind_hist(f!)
        @test get(h, ESM._VK_INVARIANT, 0) == 1
        @test get(h, ESM._VK_FN, 0) == 0
        for t in (0.0, 86400.0 * 45, 86400.0 * 200)
            r = Float64(ESM.evaluate_closed_function("datetime.day_of_year", Any[t]))
            du = _eval_rhs(f!, u0, p, t)
            @test all(du[vm["u[$k]"]] == r * u0[vm["u[$k]"]] for k in 1:16)
        end

        # A per-cell query keeps the boxed map.
        secs = k -> 86400.0 * (10k)
        g!, v0, pg, _, vmg = _fn_build(
            _op("fn", _idx("u", _v("i")); name = "datetime.day_of_year"), 16; u = secs)
        @test get(_kind_hist(g!), ESM._VK_FN, 0) == 1
        dg = _eval_rhs(g!, v0, pg, 0.0)
        for k in 1:16
            @test dg[vmg["u[$k]"]] ==
                  Float64(ESM.evaluate_closed_function("datetime.day_of_year", Any[secs(k)]))
        end
    end

    @testset "a hoisted fn RHS is still allocation-free" begin
        for M in (64, 512)
            body = _op("*", _op("fn", _const(_HTBL), _const(_HAX), _v("t");
                                name = "interp.linear"), _idx("u", _v("i")))
            ics = Dict("u[$k]" => 1.0 + 0.01k for k in 1:M)
            @test built_rhs_alloc_bytes(_fn_model(body, M); initial_conditions = ics,
                                        t = 1.25) == 0
        end
    end
end
