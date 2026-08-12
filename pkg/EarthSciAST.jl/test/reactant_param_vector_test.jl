# The TRACED half of test/parameter_vector_abi_test.jl — a vector `p` under XLA.
#
# OPT-IN: `include`d only from the bottom of parameter_vector_abi_test.jl under
# `ESM_TEST_REACTANT=1`, and it reads that file's model, RHSs and host references.
# (Separate FILE, not a branch, because `Reactant.@compile` is a MACRO and an `if`
# around it still macro-expands — see parameter_gradient_test.jl's note.)
#
# THE POINT: NO GLOBAL `Reactant.allowscalar(true)`.
#
# A traced `ComponentVector`'s data is a `TracedRArray`, and XLA REJECTS scalar
# indexing of one ("Scalar indexing is disallowed") rather than silently emitting
# a per-element read. The tempting fix is `Reactant.allowscalar(true)` at the top
# of the program, and it is the wrong one twice over: it is global (it disarms the
# guard for every array in the session, including the O(#cells) reads it exists to
# catch), and it is a caller-side ritual that every consumer would have to
# remember. So the read is fixed INSIDE the seam instead —
# `_param_data`/`_read_param_data`, ComponentArrays supplying the unwrap and
# Reactant the scoped `@allowscalar` read — and it is bounded by construction:
# O(#PARAMETERS) per RHS, a fact of the DOCUMENT, never of the grid.
#
# The first testset PROVES the flag is off rather than assuming it: it asserts
# that the raw read the seam replaces still throws in the same session. Without
# that, every assertion below would silently also pass with the global flag on,
# and the property under test would not be tested at all.

using Test
using Reactant
using ComponentArrays

const _PVR_RX = Reactant
const _PVR_Enzyme = Reactant.Enzyme

try
    _PVR_RX.set_default_backend("cpu")
catch
end
# Belt and braces: whatever ran before this file, the guard is ARMED here.
_PVR_RX.allowscalar(false)

const _PVR_N = 16
const _PVR_DOC = _pv_rd(_PVR_N)
const _PVR_FO, _, _PVR_P, _, _ = _PV_ESM.build_evaluator(_PVR_DOC; form = :oop)
const _PVR_U = _pv_seed(_PVR_N)
const _PVR_T = 0.37
const _PVR_W = [1.0 + 0.05k for k in 1:_PVR_N]
const _PVR_CV = ComponentVector(_PVR_P)
const _PVR_SYMS = keys(_PVR_P)

_pvr_obj(u, q, t) = sum(_PVR_W .* _PVR_FO(u, q, t))
const _PVR_GREF = ForwardDiff.gradient(
    θ -> _pvr_obj(_PVR_U, NamedTuple{_PVR_SYMS}(Tuple(θ)), _PVR_T),
    collect(Float64, values(_PVR_P)))

@testset "parameter-vector ABI — traced (Reactant/XLA)" begin

    @testset "the scalar-indexing guard is ARMED (no global allowscalar)" begin
        # If this test ever fails, every other test in this file is vacuous:
        # it would mean scalar indexing was globally permitted and the seam was
        # never the thing making the traced reads work.
        q = _PVR_RX.to_rarray(_PVR_CV)
        raw = v -> ComponentArrays.getdata(v)[2] * 10.0
        @test_throws Exception (_PVR_RX.@compile sync = true raw(q))
    end

    @testset "a traced ComponentVector `p` gives the host answer" begin
        ur, tr = _PVR_RX.ConcreteRArray(_PVR_U), _PVR_RX.ConcreteRNumber(_PVR_T)
        qr = _PVR_RX.to_rarray(_PVR_CV)
        xla = _PVR_RX.@compile sync = true _PVR_FO(ur, qr, tr)
        # rtol, not `==`: XLA reassociates and fuses FMAs (reactant_oop_test.jl's
        # header). The bit-identity claim is the HOST one, next door.
        @test isapprox(Array(xla(ur, qr, tr)), _PVR_FO(_PVR_U, _PVR_P, _PVR_T);
                       rtol = 1e-14, atol = 1e-15)

        # …and it is a REAL XLA input: the SAME compiled program, new components.
        cv2 = copy(_PVR_CV)
        cv2.k_diff *= 2.0
        b = Array(xla(ur, _PVR_RX.to_rarray(cv2), tr))
        @test isapprox(b, _PVR_FO(_PVR_U, cv2, _PVR_T); rtol = 1e-14, atol = 1e-15)
        @test !isapprox(b, Array(xla(ur, qr, tr)); rtol = 1e-12)
    end

    @testset "traced reverse-mode ∂/∂p over a ComponentVector" begin
        # The gradient comes back STRUCTURED — a ComponentVector over the same
        # axis — which is the property that makes this container worth having:
        # an optimizer reads `getdata(g)` as a dense vector, a human reads
        # `g.k_diff`, and neither has to know the other's view.
        gfun = (u, q, t) -> _PVR_Enzyme.gradient(_PVR_Enzyme.Reverse, _pvr_obj,
                                                 _PVR_Enzyme.Const(u), q,
                                                 _PVR_Enzyme.Const(t))[2]
        ur, tr = _PVR_RX.ConcreteRArray(_PVR_U), _PVR_RX.ConcreteRNumber(_PVR_T)
        qr = _PVR_RX.to_rarray(_PVR_CV)
        gx = _PVR_RX.@compile sync = true gfun(ur, qr, tr)
        g = gx(ur, qr, tr)
        gv = [Float64(getproperty(g, s)) for s in _PVR_SYMS]
        @test isapprox(gv, _PVR_GREF; rtol = 1e-8)
    end

    @testset "traced reverse-mode ∂/∂p over a plain Vector" begin
        # The same gradient with no ComponentArrays in the picture, so a failure
        # localizes to the container rather than to the seam.
        gfun = (u, q, t) -> _PVR_Enzyme.gradient(_PVR_Enzyme.Reverse, _pvr_obj,
                                                 _PVR_Enzyme.Const(u), q,
                                                 _PVR_Enzyme.Const(t))[2]
        ur, tr = _PVR_RX.ConcreteRArray(_PVR_U), _PVR_RX.ConcreteRNumber(_PVR_T)
        pvr = _PVR_RX.ConcreteRArray(collect(Float64, values(_PVR_P)))
        gx = _PVR_RX.@compile sync = true gfun(ur, pvr, tr)
        @test isapprox(Array(gx(ur, pvr, tr)), _PVR_GREF; rtol = 1e-8)
    end
end
