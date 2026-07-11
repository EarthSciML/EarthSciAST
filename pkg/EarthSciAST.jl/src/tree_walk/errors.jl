# ========================================================================
# tree_walk/errors.jl — part of the tree-walk evaluator (gt-e8yw).
# Included by src/tree_walk.jl; see that file for the full layout and
# include order. Section 1: the TreeWalkError type and its E_TREEWALK_* codes.
# ========================================================================

# ============================================================
# 1. Error type
# ============================================================

"""
    TreeWalkError

Raised when the walker encounters an operator or construct it cannot
evaluate. `code` is one of two families:

* an `E_TREEWALK_*` code from the bead's acceptance criterion — this
  evaluator's own build/eval failures; or
* the bare `unlowered_operator` code (esm-spec §4.2 / §9.6.8), thrown by
  `_compile_op` when a rewrite-target operator (an RHS-position `D`, or
  `grad`/`div`/`laplacian`) reaches evaluation without a discretization
  rule having lowered it. That code is DELIBERATELY not `E_TREEWALK_*`:
  it is the uniform cross-binding wire code every implementation surfaces
  for this pipeline violation, so it must not be renamed to match the
  local convention.

`detail` carries op name or variable name for diagnostics.
"""
struct TreeWalkError <: Exception
    code::String
    detail::String
end

Base.showerror(io::IO, e::TreeWalkError) =
    print(io, "$(e.code): $(e.detail)")
