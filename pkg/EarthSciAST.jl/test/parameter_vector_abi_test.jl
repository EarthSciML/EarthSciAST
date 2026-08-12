# `p` AS AN `AbstractVector` — the parameter-vector ABI.
#
# `p` used to be a `NamedTuple` and nothing else. That is the right container for
# a HUMAN (parameters have names, and a name is checkable where a position is not)
# and the right one for the RHS (a compile-time-literal `getfield` is free), but it
# is the wrong container for every consumer that wants to MOVE the parameters: an
# optimizer wants a dense buffer to perturb, a sensitivity driver wants to seed one
# tangent per component, and a reverse-mode AD backend wants somewhere to
# accumulate a gradient. All three want an `AbstractVector`.
#
# A `ComponentVector` is both at once, and that is why it is the shape this ABI
# targets: the name → index axis lives in the TYPE, so `getdata` hands out the
# plain dense `Vector` with no copy and the naming is erased before any arithmetic
# happens. `ComponentVector(p)` converts `build_evaluator`'s `p` directly, in the
# order `param_map(p)` reports.
#
# WHAT IS ASSERTED.
#
#   1. BOTH emitters accept a `ComponentVector` (and a plain `Vector`) as `p`, and
#      return `du` BIT-IDENTICALLY equal to the NamedTuple call. Bit-identity, not
#      `isapprox`: this is the same compiled IR walked in the same order, and the
#      only thing that changed is how one scalar leaf is fetched. Anything less
#      than `==` would mean the read seam altered an arithmetic result, and the
#      whole design of `_read_param` is that it cannot.
#   2. `param_map(p)` is the build's own order (sorted `param_names`, which is
#      also `keys(p)`'s order), so a vector built from it lines up with the `idx`
#      baked into every `_NK_PARAM` node — by construction, not by agreement.
#   3. ForwardDiff `∂/∂p` over a `ComponentVector`/`Vector` reproduces the
#      NamedTuple gradient. `_rhs_value_type(u, ::AbstractVector, t)` is what makes
#      this work: `u` stays `Float64`, `eltype(p)` goes `Dual`.
#   4. A SHORT vector is refused loudly (`BoundsError`) rather than reading past
#      the end. A vector `p` has no other detector — a NamedTuple catches a
#      missing parameter by name — so `_read_param_data` is deliberately NOT
#      `@inbounds`.
#   5. No allocation regression. The `f!` zero-allocation discipline holds for
#      every container; measured, an index into a homogeneous vector is strictly
#      better than the runtime-symbol `getfield` on a heterogeneous NamedTuple
#      that build.jl warns about (~48 B/call when the union boxes).
#
# The TRACED half — `∂/∂p` w.r.t. a traced `ComponentVector`, with no global
# `Reactant.allowscalar(true)` — is in test/reactant_param_vector_test.jl, gated on
# `ESM_TEST_REACTANT=1` and included from the bottom of this file (the Reactant
# macros are why it is a separate file; see parameter_gradient_test.jl's note).

using Test
using EarthSciAST
using ForwardDiff
using ComponentArrays

const _PV_ESM = EarthSciAST

include("zero_alloc_harness.jl")

_pv_Dt(v) = Dict{String,Any}("op" => "D", "args" => Any[v], "wrt" => "t")
_pv_ix(v, i...) = Dict{String,Any}("op" => "index", "args" => Any[v, i...])
_pv_o(o, a...) = Dict{String,Any}("op" => o, "args" => Any[a...])
_pv_ao(e) = Dict{String,Any}("op" => "arrayop", "output_idx" => Any["i"],
    "ranges" => Dict{String,Any}("i" => Dict{String,Any}("from" => "n")),
    "args" => Any[], "expr" => e)
_pv_state(; kw...) = Dict{String,Any}("type" => "state",
                                      (String(k) => v for (k, v) in kw)...)
_pv_param(v) = Dict{String,Any}("type" => "parameter", "default" => v)
_pv_doc(name, vars, eqs; index_sets = nothing) = begin
    d = Dict{String,Any}("esm" => "0.5.0",
                         "metadata" => Dict{String,Any}("name" => name),
                         "models" => Dict{String,Any}("M" => Dict{String,Any}(
                             "variables" => vars, "equations" => eqs)))
    index_sets === nothing || (d["index_sets"] = index_sets)
    d
end

# 1-D reaction–diffusion (reactant_oop_test.jl's `_rd`): the ARRAY path — access
# kernels, the lane-invariant `exp(-Ea/T)` hoist, and the codegen tier.
function _pv_rd(N)
    stencil = _pv_o("+", _pv_o("-", _pv_ix("c", _pv_o("-", "i", 1.0)),
                               _pv_o("*", 2.0, _pv_ix("c", "i"))),
                    _pv_ix("c", _pv_o("+", "i", 1.0)))
    rate = _pv_o("*", "k_rxn", _pv_o("exp", _pv_o("neg", _pv_o("/", "Ea", "T"))))
    _pv_doc("RD",
        Dict{String,Any}("c" => _pv_state(shape = Any["n"]),
                         "k_diff" => _pv_param(0.1), "k_rxn" => _pv_param(0.3),
                         "Ea" => _pv_param(50.0), "T" => _pv_param(300.0)),
        Any[Dict{String,Any}("lhs" => _pv_ao(_pv_Dt(_pv_ix("c", "i"))),
            "rhs" => _pv_ao(_pv_o("-", _pv_o("*", "k_diff", stencil),
                                  _pv_o("*", rate,
                                        _pv_o("^", _pv_ix("c", "i"), 2.0)))))];
        index_sets = Dict{String,Any}(
            "n" => Dict{String,Any}("kind" => "interval", "size" => N)))
end

# 0-D with a shared subexpression: a non-empty CSE prelude, so the SCALAR `_Node`
# walker (`_eval_node` / `_oop_eval`) is exercised and not only the array kernels.
# Between the two models every `_NK_PARAM` arm in the package is reached.
function _pv_zerod()
    shared = _pv_o("*", _pv_o("exp", _pv_o("neg", _pv_o("/", "Ea", "T"))),
                   _pv_o("*", "x", "y"))
    _pv_doc("Z",
        Dict{String,Any}("x" => _pv_state(default = 0.7),
                         "y" => _pv_state(default = 0.4),
                         "Ea" => _pv_param(50.0), "T" => _pv_param(300.0),
                         "k" => _pv_param(1.3)),
        Any[Dict{String,Any}("lhs" => _pv_Dt("x"),
                             "rhs" => _pv_o("neg", _pv_o("*", "k", shared))),
            Dict{String,Any}("lhs" => _pv_Dt("y"), "rhs" => shared)])
end

_pv_seed(n) = [0.5 + 0.1k for k in 1:n]
_pv_ip(f!, u, p, t) = (du = zero(u); f!(du, u, p, t); du)

@testset "parameter-vector ABI (`p::AbstractVector`)" begin

    @testset "param_map is the build's own parameter order" begin
        _, _, p, _, _ = _PV_ESM.build_evaluator(_pv_rd(8))
        pm = param_map(p)
        @test pm isa Dict{String,Int}
        # It IS `keys(p)`'s order, and `keys(p)` is `sort!(param_names)`.
        @test sort(collect(keys(pm))) == sort(String[String(k) for k in keys(p)])
        for (i, k) in enumerate(keys(p))
            @test pm[String(k)] == i
        end
        @test sort(collect(values(pm))) == collect(1:length(p))
        @test collect(keys(pm))[sortperm(collect(values(pm)))] ==
              sort(String[String(k) for k in keys(p)])
        # …and a ComponentVector built from `p` agrees with it component by
        # component, which is the whole contract a caller relies on.
        cv = ComponentVector(p)
        for (name, i) in pm
            @test cv[i] == p[Symbol(name)]
        end
        # A parameter-free model maps to the empty Dict, not to an error.
        @test param_map(nothing) == Dict{String,Int}()
    end

    @testset "both emitters accept a vector `p`, BIT-IDENTICALLY" begin
        for (name, doc, N) in [("reaction-diffusion N=16", _pv_rd(16), 16),
                               ("0-D with a CSE prelude", _pv_zerod(), 2)]
            @testset "$name" begin
                fi, u0, p, _, _ = _PV_ESM.build_evaluator(doc)
                fo, _, _, _, _ = _PV_ESM.build_evaluator(doc; form = :oop)
                u = length(u0) == 2 ? [0.7, 0.4] : _pv_seed(N)
                t = 0.37

                cv = ComponentVector(p)                     # named AND dense
                pv = collect(Float64, values(p))            # dense only

                ref_ip = _pv_ip(fi, u, p, t)
                ref_oop = fo(u, p, t)
                # The pre-existing pin, restated here so a failure localizes.
                @test ref_ip == ref_oop

                @test _pv_ip(fi, u, cv, t) == ref_ip
                @test _pv_ip(fi, u, pv, t) == ref_ip
                @test fo(u, cv, t) == ref_oop
                @test fo(u, pv, t) == ref_oop

                # The value type is derived from all three arguments for a vector
                # `p` exactly as it is for a NamedTuple one.
                @test _PV_ESM._rhs_value_type(u, pv, t) === Float64
                @test _PV_ESM._rhs_value_type(u, cv, t) === Float64
                @test _PV_ESM._rhs_value_type(u, Float32[1.0f0], t) === Float64
            end
        end
    end

    @testset "ForwardDiff ∂/∂p over a vector `p`" begin
        N = 16
        doc = _pv_rd(N)
        fi, _, p, _, _ = _PV_ESM.build_evaluator(doc)
        fo, _, _, _, _ = _PV_ESM.build_evaluator(doc; form = :oop)
        u = _pv_seed(N)
        t = 0.37
        w = [1.0 + 0.05k for k in 1:N]
        syms = keys(p)
        pv0 = collect(Float64, values(p))
        ax = getaxes(ComponentVector(p))

        # The NamedTuple reference, i.e. what parameter_gradient_test.jl pins.
        g_ref = ForwardDiff.gradient(
            θ -> sum(w .* fo(u, NamedTuple{syms}(Tuple(θ)), t)), pv0)
        @test all(!iszero, g_ref)

        # Same gradient, `p` handed over as a plain Vector …
        @test ForwardDiff.gradient(θ -> sum(w .* fo(u, θ, t)), pv0) == g_ref
        # … and as a ComponentVector, through BOTH emitters.
        g_cv = ForwardDiff.gradient(
            θ -> sum(w .* fo(u, ComponentVector(θ, ax...), t)), pv0)
        @test g_cv == g_ref
        g_cv_ip = ForwardDiff.gradient(θ -> begin
                q = ComponentVector(θ, ax...)
                du = zeros(eltype(θ), N)
                fi(du, u, q, t)
                sum(w .* du)
            end, pv0)
        @test isapprox(g_cv_ip, g_ref; rtol = 1e-12)
    end

    @testset "a SHORT parameter vector is refused, not read past" begin
        # The one failure mode a vector `p` has and a NamedTuple `p` does not.
        # `_read_param_data` is deliberately not `@inbounds` so this raises.
        N = 8
        fo, _, p, _, _ = _PV_ESM.build_evaluator(_pv_rd(N); form = :oop)
        u = _pv_seed(N)
        short = collect(Float64, values(p))[1:(end - 1)]
        @test_throws BoundsError fo(u, short, 0.0)
    end

    @testset "no allocation regression on the scalar parameter read" begin
        # build.jl's JL-J0 feasibility note warns that a RUNTIME-SYMBOL `getfield`
        # on a heterogeneous NamedTuple boxes the union (~48 B/call). The scalar
        # `_NK_PARAM` path never had that problem (its symbol is on the node), and
        # an index into a homogeneous vector must not introduce one.
        N = 64
        fi, u0, p, _, _ = _PV_ESM.build_evaluator(_pv_rd(N))
        u = _pv_seed(N)
        du = similar(u)
        for (name, q) in ["NamedTuple" => p, "ComponentVector" => ComponentVector(p),
                          "Vector" => collect(Float64, values(p))]
            @testset "$name" begin
                @test rhs_alloc_bytes(fi, du, u, q, 0.37) == 0
            end
        end
    end
end

# ---- Traced (Reactant/XLA) — opt-in ----------------------------------------
if get(ENV, "ESM_TEST_REACTANT", "0") == "1"
    include("reactant_param_vector_test.jl")
else
    @info "skipping the traced parameter-vector tests " *
          "(reactant_param_vector_test.jl); set ESM_TEST_REACTANT=1, with " *
          "Reactant in the environment, to run them"
end
