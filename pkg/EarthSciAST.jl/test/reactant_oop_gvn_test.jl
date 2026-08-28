# Trace-time emission VALUE NUMBERING (ess-oop-gvn; ext/EarthSciASTReactantExt.jl's
# four-argument `_oop_op`, `_oop_const`, `_oop_powlit` and the three-argument
# scalar reads).
#
# THE DEFECT THIS PINS, and why it is a different one from ess-oop-intern.
# Read interning removes duplicate READS. This removes duplicate EVERYTHING
# ELSE, and it exists because the compiled IR is a DAG that the out-of-place
# emitter walks as a TREE: `_oop_eval` / `_oop_eval_acck` carry no per-node memo,
# so a subtree reachable from k parents is RE-EMITTED k times. On host that is
# free; under a trace each re-walk manufactures a fresh cone of MLIR ops that XLA
# must then discover to be redundant — pairwise, and therefore quadratically.
#
# Measured on ReSEACT (13x7x72 CONUS), `@code_hlo optimize=false` against the
# same program optimized: the chemistry RHS emitted 8.6x more ops than survived,
# the symbolic band Jacobian 8.3x, one ROS23 step 12.1x. Every one of those
# surplus ops is a compile-time cost and none of them is a run-time one.
#
# SCALAR CONSTANTS ARE THE LOAD-BEARING CASE and the test below weights them
# accordingly. Reactant memoizes an ARRAY constant by value (a task-local table
# keyed on the `DenseElementsAttribute`, hoisted to the entry block) but a SCALAR
# constant goes `Ops.constant(::Number)` -> `Ops.fill` -> a fresh
# `stablehlo.constant`, unconditionally. One coefficient used at N sites is
# therefore N distinct SSA values — which does not merely add N-1 ops, it DEFEATS
# the cascade, because `k .* x` at two sites then has different operand ids and
# neither the products nor anything above them can share.
#
# WHAT IS ASSERTED, in the four layers reactant_oop_intern_test.jl established:
#   1. ENGAGEMENT. `oop_gvn_stats().hits > 0` under a trace, `== 0` on host and
#      under `ESS_OOP_GVN=0`. A memo that quietly stopped matching would
#      otherwise still pass every value test.
#   2. SHAPE. The raw (`optimize=false`) census must show strictly fewer ops, and
#      strictly fewer `stablehlo.constant`s, with value numbering on — and every
#      hit must correspond to exactly one op not emitted.
#   3. VALUES, ON ≡ OFF, BIT for bit. This is an enforceable `==`, not a
#      tolerance: the reused SSA value IS the result the duplicate op would have
#      produced, over the same operands, so every consumer receives an identical
#      tensor and the two programs differ only by ops with no other effect.
#   4. The OPTIMIZED programs agree — same op count, same bits. That is the real
#      correctness signal for this feature: if the optimized count moved, the
#      emitter removed something XLA would NOT have removed, i.e. not redundancy.
#
# HOST IS NOT INVOLVED, by the same construction as ess-oop-intern: the memo
# object comes from `_oop_new_memo`, which is `nothing` for every non-traced
# element type, so on host every seam here is its unmemoized definition with a
# zero-sized argument.
using Test
using EarthSciAST
using Reactant

const ESMg = EarthSciAST
const RXg = Reactant

_g_Dt(v) = Dict{String,Any}("op" => "D", "args" => Any[v], "wrt" => "t")
_g_ix(v, i...) = Dict{String,Any}("op" => "index", "args" => Any[v, i...])
_g_o(o, a...) = Dict{String,Any}("op" => o, "args" => Any[a...])
_g_ao(e) = Dict{String,Any}("op" => "arrayop", "output_idx" => Any["i"],
    "ranges" => Dict{String,Any}("i" => Dict{String,Any}("from" => "n")),
    "args" => Any[], "expr" => e)

# A miniature of the shape that produces the 12x: M equations over the same two
# materialized array observeds, each combining them through a body that REPEATS
# the same coefficients and the same sub-expressions. Nothing here is contrived —
# `2.5` appearing in six equations is what a reaction mechanism's stoichiometry
# looks like, and `exp(-g)` recurring is what a shared rate constant looks like.
const _G_BODIES = [
    (g, v) -> _g_o("+", _g_o("*", 2.5, g), _g_o("*", 2.5, v)),
    (g, v) -> _g_o("*", _g_o("exp", _g_o("neg", g)), _g_o("+", v, 2.5)),
    (g, v) -> _g_o("-", _g_o("*", 2.5, _g_o("exp", _g_o("neg", g))), v),
    (g, v) -> _g_o("/", _g_o("+", g, 2.5), _g_o("+", 1.0, _g_o("*", 2.5, v))),
    (g, v) -> _g_o("+", _g_o("^", g, 2.0), _g_o("*", 2.5, _g_o("^", v, 2.0))),
    (g, v) -> _g_o("*", _g_o("+", g, 2.5), _g_o("-", _g_o("exp", _g_o("neg", g)), v)),
]

function _g_doc(N, M)
    vars = Dict{String,Any}(
        "g" => Dict{String,Any}("type" => "unknown", "shape" => Any["n"]),
        "v" => Dict{String,Any}("type" => "unknown", "shape" => Any["n"]),
        "k" => Dict{String,Any}("type" => "parameter", "default" => 0.25))
    eqs = Any[
        Dict{String,Any}("lhs" => "g",
            "rhs" => _g_ao(_g_o("+", _g_o("*", 2.5, _g_ix("c1", "i")), 1.0))),
        Dict{String,Any}("lhs" => "v",
            "rhs" => _g_ao(_g_o("*", _g_ix("c1", "i"), _g_ix("c1", "i")))),
    ]
    for m in 1:M
        nm = "c$m"
        vars[nm] = Dict{String,Any}("type" => "unknown", "shape" => Any["n"])
        body = _G_BODIES[m](_g_ix("g", "i"), _g_ix("v", "i"))
        push!(eqs, Dict{String,Any}(
            "lhs" => _g_ao(_g_Dt(_g_ix(nm, "i"))),
            "rhs" => _g_ao(_g_o("*", "k", body))))
    end
    Dict{String,Any}(
        "esm" => "0.5.0", "metadata" => Dict{String,Any}("name" => "GVN"),
        "index_sets" => Dict{String,Any}(
            "n" => Dict{String,Any}("kind" => "interval", "size" => N)),
        "models" => Dict{String,Any}("M" =>
            Dict{String,Any}("variables" => vars, "equations" => eqs)))
end

_g_ops(mod) = count(l -> occursin(" = stablehlo.", l) || occursin(" = \"stablehlo", l),
                    split(string(mod), '\n'))

# A `broadcast_in_dim` whose input and output types are IDENTICAL is the
# identity function, emitted only because `Reactant.broadcast_to_size` does not
# check. Counting them is how the native-emission tier is measured.
function _g_identity_bcast(mod)
    n = 0
    for l in split(string(mod), '\n')
        occursin("stablehlo.broadcast_in_dim", l) || continue
        m = match(r"\(tensor<([^>]+)>\) -> tensor<([^>]+)>", l)
        m !== nothing && m.captures[1] == m.captures[2] && (n += 1)
    end
    return n
end
_g_count(mod, op) = length(findall(op, string(mod)))
_g_dev(p::NamedTuple) = NamedTuple{keys(p)}(map(RXg.ConcreteRNumber, values(p)))
_g_dev(::Nothing) = nothing
_g_bits(v::AbstractVector{Float64}) = reinterpret(UInt64, v)

@testset "trace-time emission value numbering" begin
    N, M = 12, length(_G_BODIES)
    fo, u0, p, _, _ = ESMg.build_evaluator(_g_doc(N, M); form = :oop)
    fi, _, _, _, _ = ESMg.build_evaluator(_g_doc(N, M))
    u = Float64[0.4 * sin(0.9k) + 1.1 for k in 1:length(u0)]
    host = fo(u, p, 0.0)
    ref = (du = zero(u); fi(du, u, p, 0.0); du)
    @test host == ref                       # the emitter itself, unchanged

    ur = RXg.ConcreteRArray(copy(u)); pr = _g_dev(p); tr = RXg.ConcreteRNumber(0.0)
    # Distinct closure objects per mode: Reactant keys its compilation caches on
    # the callee, so reusing one across the ON and OFF builds could hand the
    # second build the first one's program and make the comparison vacuous.
    h_on = (uu, pp, tt) -> fo(uu, pp, tt)
    h_off = (uu, pp, tt) -> fo(uu, pp, tt)

    # ---- 1 + 2. engagement, and the raw census -----------------------------
    stats = Dict{String,Any}(); raw = Dict{String,Int}(); consts = Dict{String,Int}()
    optops = Dict{String,Int}()
    for (mode, hh) in (("1", h_on), ("0", h_off))
        withenv("ESS_OOP_GVN" => mode) do
            ESMg.oop_gvn_stats_reset!()
            m0 = RXg.@code_hlo optimize = false hh(ur, pr, tr)
            stats[mode] = ESMg.oop_gvn_stats()
            raw[mode] = _g_ops(m0)
            consts[mode] = _g_count(m0, "stablehlo.constant")
            optops[mode] = _g_ops(RXg.@code_hlo hh(ur, pr, tr))
        end
    end

    @test stats["1"].hits > 0               # value numbering ENGAGED
    @test stats["0"].hits == 0              # kill switch: tables never consulted
    @test stats["0"].misses == 0

    # Every hit is exactly one op not emitted... except that a hit ALSO prevents
    # the ops its (now shared) result would have fed from being duplicated, so
    # the saving is at least the hit count.
    @test raw["1"] < raw["0"]
    @test raw["0"] - raw["1"] >= stats["1"].hits

    # The coefficient `2.5` recurs in every body; without constant interning it
    # is one `stablehlo.constant` per occurrence.
    @test consts["1"] < consts["0"]

    # ---- 3. traced ON ≡ traced OFF, BIT for bit ----------------------------
    on = withenv("ESS_OOP_GVN" => "1") do
        Array(RXg.@jit h_on(ur, pr, tr))
    end
    off = withenv("ESS_OOP_GVN" => "0") do
        Array(RXg.@jit h_off(ur, pr, tr))
    end
    @test _g_bits(on) == _g_bits(off)

    # ---- 4. the OPTIMIZED programs agree -----------------------------------
    # The load-bearing correctness claim: only redundancy was removed, so what
    # XLA is left holding is the same program either way.
    @test optops["1"] == optops["0"]

    # ---- traced ≡ host, to a few ulp (XLA reassociates; see reactant_oop_test)
    @test isapprox(on, host; rtol = 1e-14)

    # ---- the native-emission tier (ess-oop-native) -------------------------
    #
    # Same four-layer bar. The SHAPE assertion here is not "fewer ops" in the
    # abstract but specifically "fewer IDENTITY broadcasts", because that is the
    # exact waste this tier removes: `broadcast_to_size` emitting a
    # `broadcast_in_dim` from a type to itself.
    @testset "native op emission" begin
        n_on = (uu, pp, tt) -> fo(uu, pp, tt)
        n_off = (uu, pp, tt) -> fo(uu, pp, tt)
        ident = Dict{String,Int}(); nops = Dict{String,Int}(); nopt = Dict{String,Int}()
        for (mode, gg) in (("1", n_on), ("0", n_off))
            withenv("ESS_OOP_NATIVE" => mode) do
                m0 = RXg.@code_hlo optimize = false gg(ur, pr, tr)
                ident[mode] = _g_identity_bcast(m0)
                nops[mode] = _g_ops(m0)
                nopt[mode] = _g_ops(RXg.@code_hlo gg(ur, pr, tr))
            end
        end
        @test ident["1"] < ident["0"]       # the scaffolding is gone
        @test nops["1"] < nops["0"]
        @test nopt["1"] == nopt["0"]        # and XLA is left with the same program

        nat_on = withenv("ESS_OOP_NATIVE" => "1") do
            Array(RXg.@jit n_on(ur, pr, tr))
        end
        nat_off = withenv("ESS_OOP_NATIVE" => "0") do
            Array(RXg.@jit n_off(ur, pr, tr))
        end
        # `stablehlo.add`/`subtract`/`multiply`/`divide`/`negate` on f64 ARE the
        # IEEE operations Julia's operators are, so this is `==`, not a tolerance.
        @test _g_bits(nat_on) == _g_bits(nat_off)
    end

    # ---- all three switches off is the pre-feature emitter -----------------
    @testset "everything off reproduces the unmemoized emitter" begin
        b_off = (uu, pp, tt) -> fo(uu, pp, tt)
        r = withenv("ESS_OOP_GVN" => "0", "ESS_OOP_NATIVE" => "0",
                    "ESS_OOP_INTERN" => "0") do
            Array(RXg.@jit b_off(ur, pr, tr))
        end
        @test _g_bits(r) == _g_bits(on)
    end

    # ---- host never builds a memo ------------------------------------------
    @testset "host is not involved" begin
        ESMg.oop_gvn_stats_reset!()
        h2 = fo(u, p, 0.0)
        @test h2 == host
        @test ESMg.oop_gvn_stats() == (hits = 0, misses = 0)
        @test ESMg._oop_new_memo(u) === nothing
    end

    # ---- the two features are independent switches -------------------------
    @testset "ESS_OOP_INTERN and ESS_OOP_GVN are independent" begin
        h_ni = (uu, pp, tt) -> fo(uu, pp, tt)
        r = withenv("ESS_OOP_INTERN" => "0", "ESS_OOP_GVN" => "1") do
            ESMg.oop_gvn_stats_reset!(); ESMg.oop_intern_stats_reset!()
            v = Array(RXg.@jit h_ni(ur, pr, tr))
            @test ESMg.oop_gvn_stats().hits > 0     # numbering still fires
            @test ESMg.oop_intern_stats() == (hits = 0, misses = 0)
            v
        end
        @test _g_bits(r) == _g_bits(on)
    end
end
