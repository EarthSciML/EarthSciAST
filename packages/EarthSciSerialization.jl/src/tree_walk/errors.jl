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
evaluate. `code` is always one of the `E_TREEWALK_*` codes from the
bead's acceptance criterion; `detail` carries op name or variable name
for diagnostics.
"""
struct TreeWalkError <: Exception
    code::String
    detail::String
end

Base.showerror(io::IO, e::TreeWalkError) =
    print(io, "$(e.code): $(e.detail)")
