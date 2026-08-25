# Traced census of the SSA class-to-class rework (ess-oop-ssa) — the register-
# file traffic must actually be GONE from the emitted module, not merely
# equivalent in value.
#
# OPT-IN like every Reactant test here: included by runtests.jl only under
# `ESM_TEST_REACTANT=1`, or run standalone in any env with Reactant:
#
#     ESM_TEST_REACTANT=1 julia --project=@reactant \
#         pkg/EarthSciAST.jl/test/reactant_oop_ssa_test.jl
#
# WHAT IS ASSERTED, in three layers:
#   1. SHAPE, on the RAW (`optimize=false`) module — i.e. what this emitter
#      EMITS, before XLA touches it. Every producer scatter the build skipped
#      is one `stablehlo.dynamic_update_slice` (a whole-`ue` rewrite) that no
#      longer exists: the DUS delta must EQUAL `n_skipped_scatters`. The module
#      must also shrink overall (ops and index constants), and the one place
#      SSA pays — a concatenate per multi-producer reference — is pinned too.
#      The raw module is the honest measure: on toy fixtures XLA's own
#      optimizer happens to converge the ON and OFF programs, but at scale that
#      convergence is exactly what fails (its pairwise slice-CSE went quadratic
#      on CONUS, and the materialized buffers exceed L3), so what matters is
#      never emitting the traffic at all.
#   2. VALUES, compiled ON ≡ compiled OFF, BIT for bit. Redirects change where
#      operands come from, never the arithmetic ops or their order, so this is
#      an enforceable `==`, not a tolerance.
#   3. VALUES, traced ≡ host, to the usual few ulp (XLA reassociates and fuses
#      FMAs — same bar as reactant_oop_test.jl).
using Test
using EarthSciAST
using Reactant

const ESMa = EarthSciAST
const RXa = Reactant

_a_Dt(v) = Dict{String,Any}("op" => "D", "args" => Any[v], "wrt" => "t")
_a_ix(v, i...) = Dict{String,Any}("op" => "index", "args" => Any[v, i...])
_a_o(o, a...) = Dict{String,Any}("op" => o, "args" => Any[a...])
_a_ao(e) = Dict{String,Any}("op" => "arrayop", "output_idx" => Any["i"],
    "ranges" => Dict{String,Any}("i" => Dict{String,Any}("from" => "n")),
    "args" => Any[], "expr" => e)
function _a_doc(name, vars, eqs, N)
    Dict{String,Any}(
        "esm" => "0.5.0", "metadata" => Dict{String,Any}("name" => name),
        "index_sets" => Dict{String,Any}(
            "n" => Dict{String,Any}("kind" => "interval", "size" => N)),
        "models" => Dict{String,Any}("M" => Dict{String,Any}(
            "variables" => vars, "equations" => eqs)))
end
_a_state(; kw...) = Dict{String,Any}("type" => "unknown",
                                     (String(k) => v for (k, v) in kw)...)
_a_param(v) = Dict{String,Any}("type" => "parameter", "default" => v)

# The fan: observeds g and v, each read whole-block by M structurally distinct
# consumer classes (tier-1 direct references; both fill scatters die). Same
# shape as reactant_oop_intern_test.jl and for the same reason — it is
# ReSEACT's chemistry in miniature.
const _A_BODIES = [
    (g, v) -> _a_o("+", g, v),
    (g, v) -> _a_o("*", g, v),
    (g, v) -> _a_o("+", _a_o("exp", _a_o("neg", g)), v),
    (g, v) -> _a_o("*", _a_o("sqrt", _a_o("abs", g)), _a_o("+", v, 1.0)),
]
function _a_fan(N, M)
    vars = Dict{String,Any}(
        "g" => _a_state(shape = Any["n"]), "v" => _a_state(shape = Any["n"]),
        "k" => _a_param(0.25))
    eqs = Any[
        Dict{String,Any}("lhs" => "g",
            "rhs" => _a_ao(_a_o("+", _a_o("*", 2.0, _a_ix("c1", "i")), 1.0))),
        Dict{String,Any}("lhs" => "v",
            "rhs" => _a_ao(_a_o("*", _a_ix("c1", "i"), _a_ix("c1", "i")))),
    ]
    for m in 1:M
        nm = "c$m"
        vars[nm] = _a_state(shape = Any["n"])
        push!(eqs, Dict{String,Any}(
            "lhs" => _a_ao(_a_Dt(_a_ix(nm, "i"))),
            "rhs" => _a_ao(_a_o("*", "k",
                _A_BODIES[m](_a_ix("g", "i"), _a_ix("v", "i"))))))
    end
    _a_doc("SSAFANRX", vars, eqs, N)
end

# The chain: g → h → state, `h` split by the build into interior + boundary
# kernels, so the final `h` read is a TWO-producer slice+concat reference and
# all three fill scatters die.
function _a_chain(N)
    _a_doc("SSACHAINRX",
        Dict{String,Any}("u" => _a_state(shape = Any["n"]),
                         "g" => _a_state(shape = Any["n"]),
                         "h" => _a_state(shape = Any["n"]),
                         "k" => _a_param(0.25)),
        Any[Dict{String,Any}("lhs" => "g",
                "rhs" => _a_ao(_a_o("+", _a_o("*", 2.0, _a_ix("u", "i")), 1.0))),
            Dict{String,Any}("lhs" => "h",
                "rhs" => _a_ao(_a_o("+", _a_ix("g", "i"),
                                    _a_ix("g", _a_o("+", "i", 1.0))))),
            Dict{String,Any}("lhs" => _a_ao(_a_Dt(_a_ix("u", "i"))),
                "rhs" => _a_ao(_a_o("-", _a_o("*", "k", _a_ix("h", "i")),
                                    _a_ix("u", "i"))))],
        N)
end

_a_census(mod) = begin
    s = string(mod)
    Dict(op => length(findall(op, s)) for op in
         ("stablehlo.slice", "stablehlo.gather", "stablehlo.dynamic_update_slice",
          "stablehlo.concatenate", "stablehlo.constant"))
end
_a_ops(mod) = count(l -> occursin(" = stablehlo.", l) || occursin(" = \"stablehlo", l),
                    split(string(mod), '\n'))
_a_dev(p::NamedTuple) = NamedTuple{keys(p)}(map(RXa.ConcreteRNumber, values(p)))
_a_dev(::Nothing) = nothing
_a_bits(v::AbstractVector{Float64}) = reinterpret(UInt64, v)

# The flag is read at BUILD time, so ON and OFF are two separate builds — which
# also gives Reactant two distinct callees and keeps its compile cache honest.
function _a_build_pair(doc)
    fon, u0, p, _, _ = withenv("ESS_OOP_SSA" => "1") do
        ESMa.build_evaluator(doc; form = :oop)
    end
    foff, _, _, _, _ = ESMa.build_evaluator(doc; form = :oop)
    return fon, foff, u0, p
end

@testset "SSA dataflow census (ESS_OOP_SSA, traced)" begin
    for (name, doc, want_skip, want_extra_concat) in
        [("fan over two observeds", _a_fan(12, length(_A_BODIES)), 2, 0),
         ("two-level chain, split producer", _a_chain(12), 3, 1)]
        @testset "$name" begin
            fon, foff, u0, p = _a_build_pair(doc)
            s = ESMa.oop_ssa_stats(fon)
            @test s.enabled
            @test s.n_fast == s.n_edges > 0         # full coverage on this fixture
            @test s.n_skipped_scatters == want_skip
            @test !ESMa.oop_ssa_stats(foff).enabled

            u = Float64[0.4 * sin(0.9k) + 1.1 for k in 1:length(u0)]
            ur = RXa.ConcreteRArray(copy(u))
            pr = _a_dev(p)
            tr = RXa.ConcreteRNumber(0.0)
            g_on = (a, b, c) -> fon(a, b, c)
            g_off = (a, b, c) -> foff(a, b, c)

            raw_on = RXa.@code_hlo optimize = false g_on(ur, pr, tr)
            raw_off = RXa.@code_hlo optimize = false g_off(ur, pr, tr)
            con, coff = _a_census(raw_on), _a_census(raw_off)

            # Every statically skipped producer scatter is one whole-`ue`
            # dynamic_update_slice that was never emitted.
            @test coff["stablehlo.dynamic_update_slice"] -
                  con["stablehlo.dynamic_update_slice"] == want_skip
            # The redirected reads stop addressing `ue`, so the module carries
            # fewer index constants and fewer ops overall...
            @test con["stablehlo.constant"] < coff["stablehlo.constant"]
            @test _a_ops(raw_on) < _a_ops(raw_off)
            # ...and reads never got WORSE: slices+gathers do not increase.
            _reads(c) = c["stablehlo.slice"] + c["stablehlo.gather"]
            @test _reads(con) <= _reads(coff)
            # The one cost SSA pays: a concatenate per multi-producer reference.
            @test con["stablehlo.concatenate"] -
                  coff["stablehlo.concatenate"] == want_extra_concat

            # Compiled ON ≡ compiled OFF, bit for bit; and ≡ host to a few ulp.
            von = Array(RXa.@jit g_on(ur, pr, tr))
            voff = Array(RXa.@jit g_off(ur, pr, tr))
            @test _a_bits(von) == _a_bits(voff)
            host = fon(u, p, 0.0)
            @test host == foff(u, p, 0.0)
            @test isapprox(von, host; rtol = 1e-14, atol = 1e-15)
        end
    end
end
