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

# ---------------------------------------------------------------------------
# SHARING a lane-invariant subtree — across kernels, and with the scalar CSE
# prelude (EarthSciSerialization-ha2; audit finding #4 (c) and (d)).
#
# The hoist above makes an invariant subtree cost ONE scalar eval per kernel per
# RHS call instead of N. But each kernel hoisted in isolation, and none of them
# talked to the scalar CSE prelude, so a factor written into two array equations
# and one scalar equation was still evaluated THREE times per call — and the
# scalar occurrence looked like a SINGLETON to `_cse_count!` (which walks
# `ASTExpr` entries; the array path produces none), so it did not even get a
# prelude slot of its own.
#
# `_share_lane_invariants!` (tree_walk/invariant_share.jl) closes both directions
# with a post-pass over the compiled `_Node` IR. What these tests pin:
#
#   1. THE REPRO — 2 array kernels + 1 scalar equation, one slot, one evaluation.
#   2. Cross-kernel sharing with no scalar occurrence at all.
#   3. Kernel → EXISTING prelude slot: an invariant that a scalar-CSE'd def
#      already computes reuses that slot rather than minting a new one. This is
#      the case that forces the value-number key to EXPAND through `_NK_CACHED`:
#      the def's own body is already compressed into cache reads, the payload is
#      written out in full, and they must still be recognized as one value.
#   4. THE KEY IS EXACT — invariants that merely LOOK alike (different parameter,
#      different literal, different `interp.linear` table, different forcing-buffer
#      offset) must never collide. Asserted on the VALUES, because a bad key here
#      produces silently wrong numbers, not a crash. `_struct_sig!` would merge
#      three of these four (it ignores literal values and the `fn` spec by design,
#      to group cells into one template) — which is exactly why this pass has its
#      own key and does not reuse it.
#   5. A kernel-unique invariant is LEFT ALONE (a slot would cost more than it saves).
#   6. `:inplace` and `:oop` agree bit-for-bit, and `f!` still allocates nothing.
# ---------------------------------------------------------------------------

# Every `_VK_INVARIANT` payload across every kernel of a built evaluator, in
# kernel order.
function _inv_payloads(f!)
    out = ESM._Node[]
    walk(n) = (n.kind === ESM._VK_INVARIANT && push!(out, n.payload::ESM._Node);
               foreach(walk, n.children))
    for vk in getfield(f!, :vec_kernels)
        walk(vk.template)
    end
    return out
end

# Is `n` a bare read of CSE prelude slot `s`?
_is_cached(n::ESM._Node, s::Int) = n.kind === ESM._NK_CACHED && n.idx == s
_is_cached(n::ESM._Node) = n.kind === ESM._NK_CACHED

# Does `n` (a compiled scalar tree) contain a read of slot `s`?
_reads_slot(n::ESM._Node, s::Int) =
    _is_cached(n, s) || any(c -> _reads_slot(c, s), n.children)

# How many `_NK_OP` nodes with op `o` are actually EVALUATED per RHS call: the
# prelude runs once, each scalar equation's tree runs once, and each kernel's
# `_VK_INVARIANT` payload runs once. (Lane-varying `_VK_OP`s are a different
# question — this counts the once-per-call scalar work, which is what the pass
# is about.)
function _evals_per_call(f!, o::Symbol)
    cnt(n::ESM._Node) = (n.kind === ESM._NK_OP && n.op === o ? 1 : 0) +
                        sum(cnt, n.children; init = 0)
    tot = sum(cnt, getfield(f!, :cse_prelude); init = 0)
    tot += sum(cnt(nd) for (_, nd) in getfield(f!, :rhs_list); init = 0)
    tot += sum(cnt, _inv_payloads(f!); init = 0)
    return tot
end

# The lane-invariant Arrhenius factor `A*exp(-Ea/(R*Tref))`: pure parameter
# algebra, no free cell index, and structurally identical wherever it is written.
_arrh() = _op("*", _v("A"), _op("exp", _op("/", _op("neg", _v("Ea")),
                                           _op("*", _v("R"), _v("Tref")))))
_arrh_val(; A = 1e6, Ea = 5000.0, R = 8.314, Tref = 298.0) = A * exp(-Ea / (R * Tref))

_arrh_params() = Dict{String,ESM.ModelVariable}(
    "A"    => ModelVariable(ParameterVariable; default = 1e6),
    "Ea"   => ModelVariable(ParameterVariable; default = 5000.0),
    "R"    => ModelVariable(ParameterVariable; default = 8.314),
    "Tref" => ModelVariable(ParameterVariable; default = 298.0))

@testset "lane-invariant subtrees are shared across kernels and with the prelude" begin

    # ---------------------------------------------------------------------
    # 1. THE REPRO. `A*exp(-Ea/(R*Tref))` in two array equations AND one scalar
    #    equation. Before: `_VK_INVARIANT` per kernel = [1, 1], `n_cse_slots = 0`
    #    → the identical subtree evaluated 3× per RHS call.
    # ---------------------------------------------------------------------
    @testset "2 array kernels + 1 scalar equation → ONE slot, ONE evaluation" begin
        N = 8
        vars = merge(_arrh_params(), Dict{String,ESM.ModelVariable}(
            "u" => ModelVariable(StateVariable),
            "w" => ModelVariable(StateVariable),
            "s" => ModelVariable(StateVariable; default = 1.0)))
        eqs = ESM.Equation[
            ESM.Equation(_ao1(_Didx("u", _v("i")), "i", 1, N),
                         _ao1(_op("*", _arrh(), _idx("u", _v("i"))), "i", 1, N)),
            ESM.Equation(_ao1(_Didx("w", _v("i")), "i", 1, N),
                         _ao1(_op("*", _arrh(), _idx("w", _v("i"))), "i", 1, N)),
            ESM.Equation(_op("D", _v("s"); wrt = "t"), _op("*", _arrh(), _v("s"))),
        ]
        ics = merge(Dict("u[$k]" => 1.0 for k in 1:N), Dict("w[$k]" => 1.0 for k in 1:N))
        f!, u0, p, _, vm, diag =
            ESM._build_evaluator_impl(ESM.Model(vars, eqs); initial_conditions = ics)

        # -- structural --
        @test diag.n_vec_kernels == 2
        @test diag.n_cse_slots == 0            # the scalar pass still sees a singleton...
        @test diag.n_invariant_slots == 1      # ...and the IR post-pass names it once
        @test diag.n_invariant_shared == 2     # both kernels' payloads collapsed
        @test diag.n_invariant_scalar_shared == 1   # ...and the scalar occurrence too

        prelude = getfield(f!, :cse_prelude)
        @test length(prelude) == 1
        @test length(getfield(f!, :cse_cache).f64) == 1   # scratch grew with it

        # Both kernels' invariant payloads are now a bare read of THE SAME slot...
        pls = _inv_payloads(f!)
        @test length(pls) == 2
        @test all(n -> _is_cached(n, 1), pls)
        # ...and so is the scalar equation's occurrence.
        @test length(getfield(f!, :rhs_list)) == 1
        @test _reads_slot(getfield(f!, :rhs_list)[1][2], 1)

        # The `exp` — the expensive part — is now evaluated ONCE per RHS call, not 3×.
        @test _evals_per_call(f!, :exp) == 1

        # -- numeric: bit-identical to the value computed directly --
        k = _arrh_val()
        u = copy(u0)
        for i in 1:N
            u[vm["u[$i]"]] = 0.5i
            u[vm["w[$i]"]] = 0.25i
        end
        u[vm["s"]] = 3.0
        du = similar(u); f!(du, u, p, 0.0)
        for i in 1:N
            @test du[vm["u[$i]"]] == k * (0.5i)     # bit-for-bit
            @test du[vm["w[$i]"]] == k * (0.25i)
        end
        @test du[vm["s"]] == k * 3.0
    end

    # ---------------------------------------------------------------------
    # 2. Cross-kernel only (audit finding #4c): no scalar equation anywhere.
    # ---------------------------------------------------------------------
    @testset "cross-kernel only: two array equations share one slot" begin
        N = 12
        vars = merge(_arrh_params(), Dict{String,ESM.ModelVariable}(
            "u" => ModelVariable(StateVariable), "w" => ModelVariable(StateVariable)))
        eqs = ESM.Equation[
            ESM.Equation(_ao1(_Didx("u", _v("i")), "i", 1, N),
                         _ao1(_op("*", _arrh(), _idx("u", _v("i"))), "i", 1, N)),
            ESM.Equation(_ao1(_Didx("w", _v("i")), "i", 1, N),
                         _ao1(_op("+", _arrh(), _idx("w", _v("i"))), "i", 1, N)),
        ]
        ics = merge(Dict("u[$k]" => 0.0 for k in 1:N), Dict("w[$k]" => 0.0 for k in 1:N))
        f!, u0, p, _, vm, diag =
            ESM._build_evaluator_impl(ESM.Model(vars, eqs); initial_conditions = ics)

        @test diag.n_vec_kernels == 2
        @test diag.n_scalar_entries == 0
        @test diag.n_invariant_slots == 1
        @test diag.n_invariant_shared == 2
        @test diag.n_invariant_scalar_shared == 0
        pls = _inv_payloads(f!)
        @test length(pls) == 2
        @test all(n -> _is_cached(n, 1), pls)
        @test _evals_per_call(f!, :exp) == 1

        k = _arrh_val()
        u = copy(u0)
        for i in 1:N
            u[vm["u[$i]"]] = 2.0i
            u[vm["w[$i]"]] = 3.0i
        end
        du = similar(u); f!(du, u, p, 0.0)
        for i in 1:N
            @test du[vm["u[$i]"]] == k * (2.0i)
            @test du[vm["w[$i]"]] == k + (3.0i)
        end
    end

    # ---------------------------------------------------------------------
    # 3. Kernel → EXISTING prelude slot (audit finding #4d proper). The scalar
    #    equations already share `exp(-Ea/(R*Tref))` twice, so the scalar pass
    #    caches it. The kernel's invariant is the SAME value and must reuse that
    #    slot, minting no new one.
    #
    #    This is the test that forces `_NK_CACHED` expansion in the key: the
    #    prelude def's body has itself been compressed into cache reads
    #    (`exp(CACHED(j))`), while the kernel payload is written out in full
    #    (`exp(/(neg(Ea), *(R,Tref)))`). A key that did not expand through the
    #    cached ref would see two different computations and miss the share.
    # ---------------------------------------------------------------------
    @testset "an invariant that a prelude def already computes reuses that slot" begin
        N = 6
        expfac() = _op("exp", _op("/", _op("neg", _v("Ea")),
                                  _op("*", _v("R"), _v("Tref"))))
        vars = merge(_arrh_params(), Dict{String,ESM.ModelVariable}(
            "c" => ModelVariable(StateVariable),
            "x" => ModelVariable(StateVariable; default = 2.0),
            "y" => ModelVariable(StateVariable; default = 5.0)))
        eqs = ESM.Equation[
            ESM.Equation(_op("D", _v("x"); wrt = "t"), _op("*", expfac(), _v("x"))),
            ESM.Equation(_op("D", _v("y"); wrt = "t"), _op("*", expfac(), _v("y"))),
            ESM.Equation(_ao1(_Didx("c", _v("i")), "i", 1, N),
                         _ao1(_op("*", expfac(), _idx("c", _v("i"))), "i", 1, N)),
        ]
        ics = Dict("c[$k]" => 1.0 for k in 1:N)
        f!, u0, p, _, vm, diag =
            ESM._build_evaluator_impl(ESM.Model(vars, eqs); initial_conditions = ics)

        @test diag.n_cse_slots >= 1            # the scalar pass cached `exp(...)`
        @test diag.n_invariant_slots == 0      # no NEW slot was needed...
        @test diag.n_invariant_shared == 1     # ...the kernel reused the existing one
        pls = _inv_payloads(f!)
        @test length(pls) == 1
        @test _is_cached(pls[1])
        # The slot it reads is one the SCALAR pass created, not one appended here.
        @test pls[1].idx <= diag.n_cse_slots
        # ...and the prelude is still exactly the scalar pass's.
        @test length(getfield(f!, :cse_prelude)) == diag.n_cse_slots
        @test _evals_per_call(f!, :exp) == 1

        e = exp(-5000.0 / (8.314 * 298.0))
        u = copy(u0)
        for i in 1:N; u[vm["c[$i]"]] = 0.5i; end
        u[vm["x"]] = 2.0; u[vm["y"]] = 5.0
        du = similar(u); f!(du, u, p, 0.0)
        @test du[vm["x"]] == e * 2.0
        @test du[vm["y"]] == e * 5.0
        for i in 1:N
            @test du[vm["c[$i]"]] == e * (0.5i)
        end
    end

    # ---------------------------------------------------------------------
    # 4. THE KEY MUST BE EXACT. Four families of near-miss invariants: each
    #    appears in TWO kernels (so a correct key gives each its OWN slot) and
    #    differs from its neighbour only in a leaf value or a `fn` spec — the
    #    very things `_struct_sig!` throws away. Values are the assertion.
    # ---------------------------------------------------------------------
    @testset "near-miss invariants never collide" begin

        @testset "different PARAMETERS" begin
            # exp(-Ea/(R*T1)) in kernels 1,2 · exp(-Ea/(R*T2)) in kernels 3,4
            N = 5
            fac(T) = _op("exp", _op("/", _op("neg", _v("Ea")),
                                    _op("*", _v("R"), _v(T))))
            vars = Dict{String,ESM.ModelVariable}(
                "Ea" => ModelVariable(ParameterVariable; default = 5000.0),
                "R"  => ModelVariable(ParameterVariable; default = 8.314),
                "T1" => ModelVariable(ParameterVariable; default = 298.0),
                "T2" => ModelVariable(ParameterVariable; default = 350.0))
            names = ["a", "b", "c", "d"]
            for nm in names
                vars[nm] = ModelVariable(StateVariable)
            end
            eqs = [ESM.Equation(_ao1(_Didx(nm, _v("i")), "i", 1, N),
                                _ao1(_op("*", fac(j <= 2 ? "T1" : "T2"),
                                         _idx(nm, _v("i"))), "i", 1, N))
                   for (j, nm) in enumerate(names)]
            ics = Dict("$(nm)[$k]" => 1.0 for nm in names for k in 1:N)
            f!, u0, p, _, vm, diag =
                ESM._build_evaluator_impl(ESM.Model(vars, eqs); initial_conditions = ics)
            @test diag.n_invariant_slots == 2       # TWO distinct values → two slots
            @test diag.n_invariant_shared == 4

            e1 = exp(-5000.0 / (8.314 * 298.0))
            e2 = exp(-5000.0 / (8.314 * 350.0))
            @test e1 != e2
            u = copy(u0)
            for nm in names, k in 1:N; u[vm["$(nm)[$k]"]] = 1.0 + 0.1k; end
            du = similar(u); f!(du, u, p, 0.0)
            for (j, nm) in enumerate(names), k in 1:N
                @test du[vm["$(nm)[$k]"]] == (j <= 2 ? e1 : e2) * (1.0 + 0.1k)
            end
        end

        @testset "different LITERALS (what `_struct_sig!` deliberately ignores)" begin
            # exp(2.0*g) in kernels 1,2 · exp(3.0*g) in kernels 3,4. `_struct_sig!`
            # prints a bare `L` for BOTH literals — sharing on that key would give
            # every equation the first-seen literal's value.
            N = 5
            fac(c) = _op("exp", _op("*", _n(c), _v("g")))
            vars = Dict{String,ESM.ModelVariable}(
                "g" => ModelVariable(ParameterVariable; default = 0.25))
            names = ["a", "b", "c", "d"]
            for nm in names
                vars[nm] = ModelVariable(StateVariable)
            end
            eqs = [ESM.Equation(_ao1(_Didx(nm, _v("i")), "i", 1, N),
                                _ao1(_op("*", fac(j <= 2 ? 2.0 : 3.0),
                                         _idx(nm, _v("i"))), "i", 1, N))
                   for (j, nm) in enumerate(names)]
            ics = Dict("$(nm)[$k]" => 1.0 for nm in names for k in 1:N)
            f!, u0, p, _, vm, diag =
                ESM._build_evaluator_impl(ESM.Model(vars, eqs); initial_conditions = ics)
            @test diag.n_invariant_slots == 2
            @test diag.n_invariant_shared == 4

            e1 = exp(2.0 * 0.25)
            e2 = exp(3.0 * 0.25)
            @test e1 != e2
            u = copy(u0)
            for nm in names, k in 1:N; u[vm["$(nm)[$k]"]] = 2.0 + 0.5k; end
            du = similar(u); f!(du, u, p, 0.0)
            for (j, nm) in enumerate(names), k in 1:N
                @test du[vm["$(nm)[$k]"]] == (j <= 2 ? e1 : e2) * (2.0 + 0.5k)
            end
        end

        @testset "`interp.linear` with different const TABLES" begin
            # `_struct_sig!` keys a `fn` on `payload[1]` — the NAME — and not on the
            # typed spec, so it cannot tell these two apart. This key must.
            N = 5
            tblA = [10.0, 20.0, 40.0, 80.0, 160.0]
            tblB = [-1.0, -2.0, -4.0, -8.0, -16.0]
            ax = [0.0, 1.0, 2.0, 3.0, 4.0]
            fac(tbl) = _op("fn", _const(tbl), _const(ax), _v("t"); name = "interp.linear")
            names = ["a", "b", "c", "d"]
            vars = Dict{String,ESM.ModelVariable}(
                nm => ModelVariable(StateVariable) for nm in names)
            eqs = [ESM.Equation(_ao1(_Didx(nm, _v("i")), "i", 1, N),
                                _ao1(_op("*", fac(j <= 2 ? tblA : tblB),
                                         _idx(nm, _v("i"))), "i", 1, N))
                   for (j, nm) in enumerate(names)]
            ics = Dict("$(nm)[$k]" => 1.0 for nm in names for k in 1:N)
            f!, u0, p, _, vm, diag =
                ESM._build_evaluator_impl(ESM.Model(vars, eqs); initial_conditions = ics)
            @test diag.n_invariant_slots == 2
            @test diag.n_invariant_shared == 4

            u = copy(u0)
            for nm in names, k in 1:N; u[vm["$(nm)[$k]"]] = 1.0 + 0.3k; end
            du = similar(u)
            for t in (0.5, 2.25, 3.75)
                f!(du, u, p, t)
                rA = Float64(ESM.evaluate_closed_function("interp.linear", Any[tblA, ax, t]))
                rB = Float64(ESM.evaluate_closed_function("interp.linear", Any[tblB, ax, t]))
                @test rA != rB
                for (j, nm) in enumerate(names), k in 1:N
                    @test du[vm["$(nm)[$k]"]] == (j <= 2 ? rA : rB) * (1.0 + 0.3k)
                end
            end
        end

        @testset "different forcing-buffer OFFSETS" begin
            # Live `param_arrays` gathers reach the prelude through the SCALAR pass
            # (a `_VK_INVARIANT` payload can never hold one — `_VK_PGATHER` is not
            # lane-invariant), so the key is exercised here by NUMBERING those defs:
            # a key that ignored the gather's offset would map two different prelude
            # slots to one value number and let a later rewrite read the wrong one.
            # An array equation is present so the pass actually runs.
            N = 4
            buf = [2.0, 5.0, 11.0]
            g(k) = _op("exp", _idx("forcing", _i(k)))
            vars = Dict{String,ESM.ModelVariable}(
                "c" => ModelVariable(StateVariable),
                "q" => ModelVariable(ParameterVariable; default = 1.5),
                "x" => ModelVariable(StateVariable; default = 1.0),
                "y" => ModelVariable(StateVariable; default = 1.0),
                "z" => ModelVariable(StateVariable; default = 1.0),
                "w" => ModelVariable(StateVariable; default = 1.0))
            eqs = ESM.Equation[
                # `exp(forcing[1])` twice and `exp(forcing[2])` twice ⇒ two prelude slots.
                ESM.Equation(_op("D", _v("x"); wrt = "t"), _op("*", g(1), _v("x"))),
                ESM.Equation(_op("D", _v("y"); wrt = "t"), _op("+", g(1), _v("y"))),
                ESM.Equation(_op("D", _v("z"); wrt = "t"), _op("*", g(2), _v("z"))),
                ESM.Equation(_op("D", _v("w"); wrt = "t"), _op("+", g(2), _v("w"))),
                ESM.Equation(_ao1(_Didx("c", _v("i")), "i", 1, N),
                             _ao1(_op("*", _op("exp", _v("q")), _idx("c", _v("i"))),
                                  "i", 1, N)),
            ]
            ics = Dict("c[$k]" => 1.0 for k in 1:N)
            f!, u0, p, _, vm, diag = ESM._build_evaluator_impl(ESM.Model(vars, eqs);
                initial_conditions = ics, param_arrays = Dict("forcing" => buf))
            @test diag.n_cse_slots >= 2         # the two gathers were NOT merged

            u = copy(u0)
            u[vm["x"]] = 3.0; u[vm["y"]] = 4.0; u[vm["z"]] = 5.0; u[vm["w"]] = 6.0
            for k in 1:N; u[vm["c[$k]"]] = 0.5k; end
            du = similar(u); f!(du, u, p, 0.0)
            e1, e2 = exp(2.0), exp(5.0)
            @test e1 != e2
            @test du[vm["x"]] == e1 * 3.0
            @test du[vm["y"]] == e1 + 4.0
            @test du[vm["z"]] == e2 * 5.0       # NOT e1 — a merged key would show here
            @test du[vm["w"]] == e2 + 6.0
            for k in 1:N
                @test du[vm["c[$k]"]] == exp(1.5) * (0.5k)
            end
        end
    end

    # ---------------------------------------------------------------------
    # 5. A kernel-unique invariant is LEFT ALONE. The `_VK_INVARIANT` node already
    #    evaluates it exactly once per call; a slot would add a store and a load to
    #    save nothing.
    # ---------------------------------------------------------------------
    @testset "a kernel-unique invariant is not promoted to a slot" begin
        N = 7
        vars = Dict{String,ESM.ModelVariable}(
            "u" => ModelVariable(StateVariable), "w" => ModelVariable(StateVariable),
            "g" => ModelVariable(ParameterVariable; default = 0.25),
            "h" => ModelVariable(ParameterVariable; default = 4.0))
        eqs = ESM.Equation[
            ESM.Equation(_ao1(_Didx("u", _v("i")), "i", 1, N),
                         _ao1(_op("*", _op("exp", _v("g")), _idx("u", _v("i"))), "i", 1, N)),
            ESM.Equation(_ao1(_Didx("w", _v("i")), "i", 1, N),
                         _ao1(_op("*", _op("sin", _v("h")), _idx("w", _v("i"))), "i", 1, N)),
        ]
        ics = merge(Dict("u[$k]" => 1.0 for k in 1:N), Dict("w[$k]" => 1.0 for k in 1:N))
        f!, u0, p, _, vm, diag =
            ESM._build_evaluator_impl(ESM.Model(vars, eqs); initial_conditions = ics)

        @test diag.n_vec_kernels == 2
        @test diag.n_invariant_slots == 0
        @test diag.n_invariant_shared == 0
        @test isempty(getfield(f!, :cse_prelude))
        # Both stay plain `_VK_INVARIANT`s over a real subtree, not a cache read.
        pls = _inv_payloads(f!)
        @test length(pls) == 2
        @test all(n -> n.kind === ESM._NK_OP, pls)
        @test !any(_is_cached, pls)

        u = copy(u0)
        for k in 1:N; u[vm["u[$k]"]] = 1.0k; u[vm["w[$k]"]] = 2.0k; end
        du = similar(u); f!(du, u, p, 0.0)
        for k in 1:N
            @test du[vm["u[$k]"]] == exp(0.25) * (1.0k)
            @test du[vm["w[$k]"]] == sin(4.0) * (2.0k)
        end
    end

    # ---------------------------------------------------------------------
    # 6. Both emitters, and the zero-alloc property.
    # ---------------------------------------------------------------------
    @testset ":inplace and :oop agree bit-for-bit, and f! still allocates nothing" begin
        N = 16
        vars = merge(_arrh_params(), Dict{String,ESM.ModelVariable}(
            "u" => ModelVariable(StateVariable),
            "w" => ModelVariable(StateVariable),
            "s" => ModelVariable(StateVariable; default = 1.0)))
        eqs = ESM.Equation[
            ESM.Equation(_ao1(_Didx("u", _v("i")), "i", 1, N),
                         _ao1(_op("*", _arrh(), _idx("u", _v("i"))), "i", 1, N)),
            ESM.Equation(_ao1(_Didx("w", _v("i")), "i", 1, N),
                         _ao1(_op("*", _arrh(), _op("+", _idx("w", _v("i")), _v("t"))),
                              "i", 1, N)),
            ESM.Equation(_op("D", _v("s"); wrt = "t"), _op("*", _arrh(), _v("s"))),
        ]
        model = ESM.Model(vars, eqs)
        ics = merge(Dict("u[$k]" => 1.0 for k in 1:N), Dict("w[$k]" => 1.0 for k in 1:N))

        fi!, u0, p, _, vm = ESM.build_evaluator(model; initial_conditions = ics)
        fo, _, po, _, _ = ESM.build_evaluator(model; initial_conditions = ics, form = :oop)

        k = _arrh_val()
        u = copy(u0)
        for i in 1:N
            u[vm["u[$i]"]] = 0.5i
            u[vm["w[$i]"]] = 0.25i
        end
        u[vm["s"]] = 3.0
        for t in (0.0, 1.75, -0.5)
            du = similar(u); fi!(du, u, p, t)
            @test fo(u, po, t) == du            # the two emitters, bit-for-bit
            for i in 1:N
                @test du[vm["u[$i]"]] == k * (0.5i)
                @test du[vm["w[$i]"]] == k * (0.25i + t)
            end
            @test du[vm["s"]] == k * 3.0
        end

        # The prelude read is a field load into a preallocated scratch, so the RHS
        # stays allocation-free — the property the shared slot must not cost.
        du = similar(u0)
        @test rhs_alloc_bytes(fi!, du, u0, p, 1.25) == 0
    end
end
