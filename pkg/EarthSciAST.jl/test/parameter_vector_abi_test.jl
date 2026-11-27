# `p` AS AN `AbstractVector` — the parameter-vector ABI.
#
# A `NamedTuple` `p` is the right container for
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
# happens. `ComponentVector(p)` converts the build's `p` directly, in the
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
#      that build_pipeline.jl warns about (~48 B/call when the union boxes).

using Test
include("testutils.jl")
using EarthSciAST
using ForwardDiff
using ComponentArrays

const _PV_ESM = EarthSciAST

include("zero_alloc_harness.jl")

_pv_ao(e) = Dict{String, Any}(
    "op" => "faq", "output_idx" => Any["i"],
    "ranges" => Dict{String, Any}("i" => Dict{String, Any}("from" => "n")),
    "args" => Any[], "expr" => e
)
# A state starts at 0 unless the caller gives a `default`.
_pv_state(; kw...) = Dict{String, Any}(
    "type" => "unknown", "default" => 0.0,
    (String(k) => v for (k, v) in kw)...
)
_pv_param(v) = Dict{String, Any}("type" => "parameter", "default" => v)
_pv_doc(name, vars, eqs; index_sets = nothing) = begin
    d = Dict{String, Any}(
        "esm" => "2.0.0",
        "metadata" => Dict{String, Any}("name" => name),
        "models" => Dict{String, Any}(
            "M" => Dict{String, Any}(
                "variables" => vars, "equations" => eqs
            )
        )
    )
    index_sets === nothing || (d["index_sets"] = index_sets)
    d
end

# 1-D reaction–diffusion: the ARRAY path — access
# kernels, the lane-invariant `exp(-Ea/T)` hoist, and the codegen tier.
function _pv_rd(N)
    stencil = jop(
        "+", jop(
            "-", jidx("c", jop("-", "i", 1.0)),
            jop("*", 2.0, jidx("c", "i"))
        ),
        jidx("c", jop("+", "i", 1.0))
    )
    rate = jop("*", "k_rxn", jop("exp", jop("neg", jop("/", "Ea", "T"))))
    return _pv_doc(
        "RD",
        Dict{String, Any}(
            "c" => _pv_state(shape = Any["n"]),
            "k_diff" => _pv_param(0.1), "k_rxn" => _pv_param(0.3),
            "Ea" => _pv_param(50.0), "T" => _pv_param(300.0)
        ),
        Any[
            Dict{String, Any}(
                "lhs" => _pv_ao(jD(jidx("c", "i"))),
                "rhs" => _pv_ao(
                    jop(
                        "-", jop("*", "k_diff", stencil),
                        jop(
                            "*", rate,
                            jop("^", jidx("c", "i"), 2.0)
                        )
                    )
                )
            ),
        ];
        index_sets = Dict{String, Any}(
            "n" => Dict{String, Any}("kind" => "interval", "size" => N)
        )
    )
end

# 0-D with a shared subexpression: a non-empty CSE prelude, so the SCALAR `_Node`
# walker (`_eval_node`) is exercised and not only the array kernels.
# Between the two models every `_NK_PARAM` arm in the package is reached.
function _pv_zerod()
    shared = jop(
        "*", jop("exp", jop("neg", jop("/", "Ea", "T"))),
        jop("*", "x", "y")
    )
    return _pv_doc(
        "Z",
        Dict{String, Any}(
            "x" => _pv_state(default = 0.7),
            "y" => _pv_state(default = 0.4),
            "Ea" => _pv_param(50.0), "T" => _pv_param(300.0),
            "k" => _pv_param(1.3)
        ),
        Any[
            Dict{String, Any}(
                "lhs" => jD("x"),
                "rhs" => jop("neg", jop("*", "k", shared))
            ),
            Dict{String, Any}("lhs" => jD("y"), "rhs" => shared),
        ]
    )
end

_pv_seed(n) = [0.5 + 0.1k for k in 1:n]

@testset "parameter-vector ABI (`p::AbstractVector`)" begin
    rd8 = _PV_ESM.Internal.build(_pv_rd(8))
    rd16 = _PV_ESM.Internal.build(_pv_rd(16))

    @testset "param_map is the build's own parameter order" begin
        p = rd8.p
        pm = param_map(p)
        @test pm isa Dict{String, Int}
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
        @test param_map(nothing) == Dict{String, Int}()
    end

    @testset "both emitters accept a vector `p`, BIT-IDENTICALLY" begin
        for (name, build) in (
                ("reaction-diffusion N=16", rd16),
                ("0-D with a CSE prelude", _PV_ESM.Internal.build(_pv_zerod())),
            )
            @testset "$name" begin
                fi, u0, p, _, _ = build
                u = length(u0) == 2 ? [0.7, 0.4] : _pv_seed(length(u0))
                t = 0.37

                cv = ComponentVector(p)                     # named AND dense
                pv = collect(Float64, values(p))            # dense only

                ref_ip = rhs_du(fi, u, p, t)
                @test rhs_du(fi, u, cv, t) == ref_ip
                @test rhs_du(fi, u, pv, t) == ref_ip

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
        fi, _, p, _, _ = rd16
        u = _pv_seed(N)
        t = 0.37
        w = [1.0 + 0.05k for k in 1:N]
        syms = keys(p)
        pv0 = collect(Float64, values(p))
        ax = getaxes(ComponentVector(p))

        obj(q) = begin
            du = zeros(promote_type(eltype(u), eltype(q)), N)
            fi(du, u, q, t)
            sum(w .* du)
        end
        # The NamedTuple reference, i.e. what parameter_gradient_test.jl pins.
        g_ref = ForwardDiff.gradient(
            θ -> obj(NamedTuple{syms}(Tuple(θ))), pv0
        )
        @test all(!iszero, g_ref)

        # Same gradient, `p` handed over as a plain Vector …
        @test ForwardDiff.gradient(obj, pv0) == g_ref
        # … and as a ComponentVector.
        g_cv = ForwardDiff.gradient(θ -> obj(ComponentVector(θ, ax...)), pv0)
        @test g_cv == g_ref
    end

    @testset "a SHORT parameter vector is refused, not read past" begin
        # The one failure mode a vector `p` has and a NamedTuple `p` does not.
        # `_read_param_data` is deliberately not `@inbounds` so this raises.
        N = 8
        fi, _, p, _, _ = rd8
        u = _pv_seed(N)
        short = collect(Float64, values(p))[1:(end - 1)]
        @test_throws BoundsError rhs_du(fi, u, short, 0.0)
    end

    @testset "no allocation regression on the scalar parameter read" begin
        # build_pipeline.jl's JL-J0 feasibility note warns that a RUNTIME-SYMBOL `getfield`
        # on a heterogeneous NamedTuple boxes the union (~48 B/call). The scalar
        # `_NK_PARAM` path never had that problem (its symbol is on the node), and
        # an index into a homogeneous vector must not introduce one.
        N = 64
        fi, u0, p, _, _ = _PV_ESM.Internal.build(_pv_rd(N))
        u = _pv_seed(N)
        du = similar(u)
        for (name, q) in [
                "NamedTuple" => p, "ComponentVector" => ComponentVector(p),
                "Vector" => collect(Float64, values(p)),
            ]
            @testset "$name" begin
                @test rhs_alloc_bytes(fi, du, u, q, 0.37) == 0
            end
        end
    end
end
