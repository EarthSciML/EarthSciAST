"""
    EarthSciASTForwardDiffExt

The AD-primal seam, loaded automatically when `ForwardDiff` is in the session.
It supplies the one method the core `EarthSciAST._value` generic is missing:
unwrap a `ForwardDiff.Dual` to the real number underneath it.

Why an extension rather than a hard dependency: nothing in the numeric core
needs ForwardDiff, and the core's `_value(x) = x` identity is COMPLETE on its
own — a `Dual` cannot exist in a session that has not loaded ForwardDiff, and if
it has, this extension is loaded too (Julia fires an extension as soon as its
trigger package is loaded, whoever loads it — a stiff solver pulling in
ForwardDiff for its Jacobian is enough). So the identity is never wrong and this
method is never missing. Mirrors the `SimulateExt` / `DataRefreshExt` /
`MTKExt` pattern: the base package stays solver- and AD-agnostic.

`_value` exists because the `datetime.*` closed functions decompose a UTC scalar
through the Gregorian calendar — a DISCRETE, piecewise-constant operation that
carries no derivative and that `Dates.unix2datetime` can only perform on a real
`Float64`. See `src/registered_functions.jl` for the full rationale and for the
`interp.*` functions, which stay eltype-generic and do NOT strip.
"""
module EarthSciASTForwardDiffExt

import EarthSciAST: _value
import ForwardDiff

# Recursive, so a nested `Dual` (ForwardDiff-over-ForwardDiff — e.g. a
# second-order sensitivity, or a Hessian over a stiff solve) strips all the way
# down to the underlying real primal in a single call rather than yielding an
# inner `Dual` that `Float64(…)` would still choke on.
@inline _value(d::ForwardDiff.Dual) = _value(ForwardDiff.value(d))

end
