# ===========================================================================
# Causal self-reference (recurrence) well-foundedness — esm-spec §4.3.1.1
# ===========================================================================
#
# The STATIC half of the construct, and the half every binding owes whether or
# not it evaluates anything (CONFORMANCE_SPEC §5.19.5 rejection parity). It
# decides two things about an equation that defines an array-shaped unknown `V`
# and reads `index(V, …)` in its own RHS:
#
#   * whether the read is well founded — affine in its frame symbol with
#     coefficient 1, offset on exactly one axis, and not provably same-cell or
#     later;
#   * whether the construct CARRYING the read can be sequenced cell by cell.
#
# It is deliberately CONSERVATIVE where it cannot prove a lag's sign: an
# unprovable lag is ADMITTED here rather than rejected, because a self-read of a
# cell the sweep has not published cannot return a value at all (esm-spec
# §4.3.1.1 point 5), so soundness does not rest on this check. What rests on it
# is the DIAGNOSTIC — rejecting the shapes that are wrong for every document, at
# validation time with a code, instead of at evaluation time with a fault (or,
# before the construct existed, with a plausible wrong number).
#
# This file is the Julia twin of `check_recurrence_equation` and its helpers in
# `pkg/earthsci-ast-rs/src/structural.rs`; the two must agree on which shapes
# are decidable, since a validator that is stricter than the reference rejects
# documents the reference accepts, which is the same parity defect as admitting
# an illegal one.

"""
    validate_recurrence_semantics(file::EsmFile) -> Vector{StructuralError}

Well-foundedness of every causal self-reference in the document
(esm-spec §4.3.1.1 *Rejections*). Emits `recurrence_not_wellfounded` /
`recurrence_unsupported_form` at the containing equation's `rhs` pointer,
`/models/<M>/equations/<i>/rhs`.

Only TOP-LEVEL models are walked, and only their `equations` — the same surface
the reference implementation checks, so a document either binding accepts is a
document both accept.
"""
function validate_recurrence_semantics(file::EsmFile)::Vector{StructuralError}
    errors = StructuralError[]
    file.models === nothing && return errors
    for model_name in sort!(collect(keys(file.models)))
        model = file.models[model_name]
        # An array-shaped variable is the only thing a causal self-reference can
        # define: a scalar has no axis to fold along. The declared TYPE is
        # deliberately not consulted — the reference implementation keys on the
        # shape alone, and a check that is narrower here would accept documents
        # it rejects, which is the parity defect §5.19.5 is about.
        array_shaped = Set{String}(
            n for (n, v) in model.variables if _recurrence_is_array_shape(v.shape))
        isempty(array_shaped) && continue
        for (i, eq) in enumerate(model.equations)
            _check_recurrence_equation!(errors, file, eq,
                                        "/models/$model_name/equations/$(i-1)/rhs",
                                        array_shaped)
        end
    end
    return errors
end

# An explicit empty shape (`[]`) is a rank-0 declaration, i.e. scalar; so is an
# absent one. Only a non-empty declared shape marks an array.
_recurrence_is_array_shape(shape) = shape !== nothing && !isempty(shape)

# ── Symbol bounds available to the VALIDATOR ────────────────────────────────
#
# Unlike the runtime, the validator sees `ranges` in their AUTHORED form, before
# any resolution against the registry. A dense literal interval, or an
# `interval`-kind index set's `1..size`; anything else — a ragged/dependent
# `of`, a categorical or derived set, an expression-valued bound — is UNKNOWN,
# and an unknown symbol makes a lag unprovable rather than illegal.
function _recurrence_symbol_bounds(spec, file::EsmFile)
    if spec isa IndexSetRef
        isempty(spec.of) || return nothing
        iset = get(file.index_sets, spec.from, nothing)
        iset === nothing && return nothing
        # `interval` by declared size, `categorical` by member count. Both are
        # 1-origin dense ranges at evaluation and the evaluator resolves BOTH
        # before rule building, so leaving `categorical` out here would make the
        # validator prove less than the evaluator — and then reject a document
        # its own evaluator accepts.
        if iset.kind == "interval"
            iset.size === nothing && return nothing
            return (1, Int(iset.size))
        elseif iset.kind == "categorical"
            iset.members === nothing && return nothing
            return (1, length(iset.members))
        end
        return nothing
    elseif spec isa AbstractVector && (length(spec) == 2 || length(spec) == 3)
        # `[lo, hi]`, or the strided `[lo, step, hi]` whose ENDPOINTS are what a
        # lag bound needs (the step never changes which cells exist below `hi`).
        lo, hi = first(spec), last(spec)
        (lo isa Integer && hi isa Integer) || return nothing
        return (Int(lo), Int(hi))
    end
    return nothing
end

# The affine form of an index expression with respect to the frame symbol `sym`:
# the COEFFICIENT of `sym`, plus the bounds of the symbol-free part — `nothing`
# for those bounds when they cannot be proved. `nothing` for the whole result
# when the expression is not affine at all.
#
# The two halves carry different obligations, and the asymmetry is normative
# (esm-spec §4.3.1.1 "Admitted lag"). The COEFFICIENT must be provable: without
# it the read names no position relative to the cell being written, so which axis
# the recurrence folds along — and in which direction — is undecidable. The
# CONSTANT PART need not be: an unprovable one is a lag of unknown SIGN, which
# the spec admits because a self-read resolves only against cells the sweep has
# already published, so an ill-founded read faults rather than returning a
# number.
#
# That is also what keeps this check from disagreeing with an evaluator. A
# validator sees `ranges` before they are resolved against the registry and so
# proves strictly less; treating "unproven" as "illegal" would reject documents
# the evaluator accepts, which is the one divergence between the two that is
# never defensible.
function _recurrence_affine_in_sym(e::ASTExpr, sym::AbstractString,
                                   env::Dict{String,Tuple{Int,Int}})
    if e isa IntExpr
        n = Int(e.value)
        return (0, (n, n))
    elseif e isa NumExpr
        # A JSON number that happens to be integral is still an integer offset.
        (isfinite(e.value) && isinteger(e.value)) || return nothing
        n = Int(e.value)
        return (0, (n, n))
    elseif e isa VarExpr
        e.name == sym && return (1, (0, 0))
        # A symbol this checker cannot bound — a parameter, a derived axis —
        # contributes coefficient 0 with UNKNOWN bounds, and stays affine.
        return (0, get(env, e.name, nothing))
    elseif e isa OpExpr && length(e.args) == 2
        a = _recurrence_affine_in_sym(e.args[1], sym, env)
        a === nothing && return nothing
        b = _recurrence_affine_in_sym(e.args[2], sym, env)
        b === nothing && return nothing
        ca, ka = a
        cb, kb = b
        both = (ka === nothing || kb === nothing) ? nothing : (ka, kb)
        if e.op == "+"
            return (ca + cb, both === nothing ? nothing :
                    (both[1][1] + both[2][1], both[1][2] + both[2][2]))
        elseif e.op == "-"
            return (ca - cb, both === nothing ? nothing :
                    (both[1][1] - both[2][2], both[1][2] - both[2][1]))
        elseif e.op == "*"
            # One side must be a proved integer CONSTANT for the product to stay
            # affine; the coefficient of the other side scales by it.
            k, other = if ca == 0 && ka !== nothing && ka[1] == ka[2]
                ka[1], b
            elseif cb == 0 && kb !== nothing && kb[1] == kb[2]
                kb[1], a
            else
                return nothing
            end
            co, ko = other
            ko === nothing && return (co * k, nothing)
            p, q = ko[1] * k, ko[2] * k
            return (co * k, (min(p, q), max(p, q)))
        end
        return nothing
    end
    return nothing
end

# One self-read the structural walk found: its index arguments, the symbol
# bounds in scope where it was found, and whether it was reached ONLY through a
# construct that cannot be restricted to one cell.
struct _RecurrenceSelfRead
    args::Vector{ASTExpr}
    env::Dict{String,Tuple{Int,Int}}
    unsequenceable::Bool
end

# Ops whose operands are consumed WHOLE: a self-read underneath one of these
# names a cell of an array that has to exist in full before the op can run, so
# no cell-by-cell sweep can supply it (`recurrence_unsupported_form`).
#
# `apply_expression_template` is deliberately NOT here. Its operands ride the
# `bindings` field, which this walk does not visit (and must not start visiting
# unilaterally — five bindings mirror this field set and §5.19.5 is exact
# agreement), so listing it would be a rule that barely reached what it named.
# It is also unreachable in practice: template applications expand at LOAD, and
# one surviving into an evaluation position is already an `unlowered_operator`
# error (esm-spec §9.6.4). So this list names only the ops that legitimately
# reach evaluation and consume an operand whole.
_recurrence_op_blocks_cell_restriction(op::AbstractString) =
    op in ("reshape", "transpose", "concat", "broadcast")

# Collect every `index(var, …)` read of `var` in `e`, and note whether `var` is
# also read BARE. `env` is the stack of aggregate range bounds in scope (pushed
# on the way down, snapshotted at each read); `blocked` marks a subtree already
# under a whole-operand op.
#
# The traversed child set is the reference's: `args`, `expr`, `filter`, `key`,
# `lower`, `upper`, and `values`. It is deliberately NOT `child_exprs` — that
# also descends `bindings`, `axes` and expression-valued `ranges` bounds, and
# finding a self-read the reference does not find would reject a document the
# reference accepts.
function _collect_recurrence_self_reads!(e::ASTExpr, var::AbstractString, file::EsmFile,
                                         env::Vector{Pair{String,Tuple{Int,Int}}},
                                         blocked::Bool,
                                         out::Vector{_RecurrenceSelfRead},
                                         bare::Ref{Bool})
    if !(e isa OpExpr)
        e isa VarExpr && e.name == var && (bare[] = true)
        return out
    end
    pushed = 0
    if e.op == "aggregate" && e.ranges !== nothing
        for sym in sort!(collect(keys(e.ranges)))
            b = _recurrence_symbol_bounds(e.ranges[sym], file)
            b === nothing && continue
            push!(env, String(sym) => b)
            pushed += 1
        end
    end
    is_self_index = e.op == "index" && !isempty(e.args) &&
                    e.args[1] isa VarExpr && (e.args[1]::VarExpr).name == var
    if is_self_index
        snapshot = Dict{String,Tuple{Int,Int}}(env)
        push!(out, _RecurrenceSelfRead(e.args[2:end], snapshot, blocked))
    end
    # A `makearray` REGION VALUE (`values`) is evaluated once for the whole
    # region, so a self-read inside one cannot be sequenced: §4.3.2's region
    # order fixes which write WINS, not which cell is EVALUATED when.
    blocked_children = blocked || _recurrence_op_blocks_cell_restriction(e.op)
    for (j, a) in enumerate(e.args)
        (is_self_index && j == 1) && continue
        _collect_recurrence_self_reads!(a, var, file, env, blocked_children, out, bare)
    end
    for side in (e.expr_body, e.filter, e.key, e.lower, e.upper)
        side === nothing && continue
        _collect_recurrence_self_reads!(side, var, file, env, blocked_children, out, bare)
    end
    if e.values !== nothing
        for v in e.values
            _collect_recurrence_self_reads!(v, var, file, env, true, out, bare)
        end
    end
    resize!(env, length(env) - pushed)
    return out
end

# The variable an equation DEFINES, if its LHS names one: a bare variable, or
# the §4.3 indexed-aggregate LHS form `aggregate{expr: index(V, k…)}`. A
# DERIVATIVE LHS (`D(u)`) defines no array algebraically — a stencil read of `u`
# at `i−1` there is a gather on the solver's state vector, not a
# self-reference — so it deliberately yields `nothing`.
function _recurrence_lhs_target(lhs::ASTExpr)
    if lhs isa VarExpr
        return (lhs.name, nothing)
    elseif lhs isa OpExpr && lhs.op == "aggregate"
        inner = lhs.expr_body
        (inner isa OpExpr && inner.op == "index" && !isempty(inner.args)) || return nothing
        head = inner.args[1]
        head isa VarExpr || return nothing
        return (head.name, lhs.output_idx)
    end
    return nothing
end

# Check ONE equation. Emits nothing when the RHS contains no self-read, which is
# every equation in every document that does not use the construct.
function _check_recurrence_equation!(errors::Vector{StructuralError}, file::EsmFile,
                                     eq::Equation, field_path::String,
                                     array_shaped::Set{String})
    target = _recurrence_lhs_target(eq.lhs)
    target === nothing && return errors
    var, lhs_idx = target
    var in array_shaped || return errors

    env = Pair{String,Tuple{Int,Int}}[]
    reads = _RecurrenceSelfRead[]
    bare = Ref(false)
    _collect_recurrence_self_reads!(eq.rhs, var, file, env, false, reads, bare)
    isempty(reads) && return errors

    push_err! = (code, message, axis) -> push!(errors, StructuralError(
        field_path, message, code,
        Dict{String,Any}("variable" => var, "recurrence_axis" => axis)))

    if bare[]
        push_err!(ERROR_CODES.RECURRENCE_NOT_WELLFOUNDED,
            "'$var' is read bare inside its own defining equation as well as through " *
            "`index`. A bare read names the whole array, which does not exist while the " *
            "recurrence sweeps it (esm-spec §4.3.1.1).", nothing)
        return errors
    end
    if any(r -> r.unsequenceable, reads)
        push_err!(ERROR_CODES.RECURRENCE_UNSUPPORTED_FORM,
            "a causal self-read of '$var' is reached only through a construct that " *
            "evaluates its operand whole — a `makearray` region value, or a " *
            "`reshape`/`transpose`/`concat`/`broadcast` operand — so no cell-by-cell sweep " *
            "can supply it. A `makearray`'s region order fixes which write WINS, not the " *
            "order cells are EVALUATED in (esm-spec §4.3.1.1, §4.3.2); write the recurrence " *
            "as one `aggregate` with the base case as an `ifelse` guard in the body.",
            nothing)
        return errors
    end

    # The cell frame: the indexed-aggregate LHS's own indices, else the RHS
    # aggregate's.
    rhs_agg = (eq.rhs isa OpExpr && (eq.rhs::OpExpr).op == "aggregate") ?
              (eq.rhs::OpExpr) : nothing
    raw_idx = lhs_idx !== nothing ? lhs_idx :
              (rhs_agg === nothing ? nothing : rhs_agg.output_idx)
    if raw_idx === nothing
        push_err!(ERROR_CODES.RECURRENCE_UNSUPPORTED_FORM,
            "the definition of '$var' reads '$var' at another position, but the equation " *
            "declares no cell frame to sweep: its RHS is not an `aggregate` over the " *
            "variable's axes and its LHS is not the indexed-aggregate form " *
            "`aggregate{expr: index($var, k…)}` (esm-spec §4.3.1.1).", nothing)
        return errors
    end
    idx_names = String[string(s) for s in raw_idx]
    if isempty(idx_names) || any(n -> tryparse(Int, n) !== nothing, idx_names)
        push_err!(ERROR_CODES.RECURRENCE_UNSUPPORTED_FORM,
            "the recurrence definition of '$var' has no symbolic output index to fold " *
            "along ($(idx_names)); a literal singleton dimension cannot be a recurrence " *
            "axis (esm-spec §4.3.1.1).", nothing)
        return errors
    end

    frame_env = Dict{String,Tuple{Int,Int}}()
    if rhs_agg !== nothing && rhs_agg.ranges !== nothing
        for (sym, spec) in rhs_agg.ranges
            b = _recurrence_symbol_bounds(spec, file)
            b === nothing || (frame_env[String(sym)] = b)
        end
    end

    axis = nothing   # the one frame position every self-read must agree on
    for read in reads
        if length(read.args) != length(idx_names)
            push_err!(ERROR_CODES.RECURRENCE_NOT_WELLFOUNDED,
                "a causal self-read of '$var' supplies $(length(read.args)) indices but " *
                "its frame has $(length(idx_names)) axes; every self-read indexes every " *
                "axis (esm-spec §4.3.1.1).", nothing)
            return errors
        end
        env = merge(frame_env, read.env)
        lagged = nothing
        for (d, arg) in enumerate(read.args)
            sym = idx_names[d]
            aff = _recurrence_affine_in_sym(arg, sym, env)
            if aff === nothing
                push_err!(ERROR_CODES.RECURRENCE_NOT_WELLFOUNDED,
                    "index $(d-1) of a causal self-read of '$var' is not affine in its frame " *
                    "symbol '$sym'. A self-read names a position RELATIVE to the cell being " *
                    "written (`$sym - 1`, `$sym - a`, `$sym - a - 2`), which is what makes " *
                    "the recurrence axis and its direction decidable (esm-spec §4.3.1.1).",
                    nothing)
                return errors
            end
            coef, konst = aff
            if coef != 1
                push_err!(ERROR_CODES.RECURRENCE_NOT_WELLFOUNDED,
                    "index $(d-1) of a causal self-read of '$var' carries its frame symbol " *
                    "'$sym' with coefficient $coef, not 1, so it does not name a position " *
                    "relative to the cell being written (esm-spec §4.3.1.1).", nothing)
                return errors
            end
            # An unprovable constant part is a lag of UNKNOWN SIGN. This axis
            # IS the recurrence axis — the read is not the identity — and the
            # cells where the lag would be non-causal cannot be read at all,
            # because the sweep has not published them. Admitting it still
            # COUNTS the axis, though: two unprovable offsets are two axes.
            if konst === nothing
                if lagged !== nothing
                    push_err!(ERROR_CODES.RECURRENCE_NOT_WELLFOUNDED,
                        "a causal self-read of '$var' is offset on more than one axis. A " *
                        "recurrence folds along exactly ONE axis; every other index must be " *
                        "the bare frame symbol (esm-spec §4.3.1.1).", sym)
                    return errors
                end
                lagged = d
                continue
            end
            clo, chi = konst
            # lag = sym - arg, so the symbol-free part's bounds invert.
            lag_lo, lag_hi = -chi, -clo
            (lag_lo == 0 && lag_hi == 0) && continue   # stays on this axis's own cell
            if lag_hi <= 0
                push_err!(ERROR_CODES.RECURRENCE_NOT_WELLFOUNDED,
                    "index $(d-1) of a causal self-read of '$var' names the cell being " *
                    "written, or a later one, on axis '$sym'. A causal self-reference reads " *
                    "strictly EARLIER positions; no sweep order can satisfy a same-cell or " *
                    "forward read (esm-spec §4.3.1.1).", sym)
                return errors
            end
            if lagged !== nothing
                push_err!(ERROR_CODES.RECURRENCE_NOT_WELLFOUNDED,
                    "a causal self-read of '$var' is offset on more than one axis. A " *
                    "recurrence folds along exactly ONE axis; every other index must be the " *
                    "bare frame symbol (esm-spec §4.3.1.1).", sym)
                return errors
            end
            lagged = d
        end
        if lagged === nothing
            push_err!(ERROR_CODES.RECURRENCE_NOT_WELLFOUNDED,
                "a causal self-read of '$var' is at the same cell on every axis, so it " *
                "defines '$var' in terms of itself rather than of an earlier position " *
                "(esm-spec §4.3.1.1).", nothing)
            return errors
        end
        if axis === nothing
            axis = lagged
        elseif axis != lagged
            push_err!(ERROR_CODES.RECURRENCE_NOT_WELLFOUNDED,
                "the causal self-reads of '$var' disagree on the recurrence axis: one " *
                "folds along '$(idx_names[axis])' and another along '$(idx_names[lagged])'. " *
                "A definition folds along exactly one axis (esm-spec §4.3.1.1).",
                idx_names[lagged])
            return errors
        end
    end
    return errors
end


# ===========================================================================
# Build-time recognition — the seam between a recurrence and a CYCLE
# ===========================================================================
#
# `_resolve_observed` (tree_walk/helpers.jl) collapses observed-into-observed
# references by SUBSTITUTION to a fixed point. Substituting a variable's body
# into itself never terminates, so a self-reference of any kind hit its
# iteration cap and came out as `E_TREEWALK_OBSERVED_CYCLE` — which is the
# wrong diagnosis for a recurrence: esm-spec §4.3.1.1 says in as many words
# that "a recurrence definition is NOT a cyclic algebraic system", the self-edge
# `V → V` being an ORDERING within one variable rather than a dependency
# between two.
#
# So the two shapes have to be told apart before the fixed point runs:
#
#   * `:indexed` — every self-reference goes through `index(V, …)`. That is a
#     recurrence, whose static well-foundedness `validate()` has already
#     decided (see above). It is not a cycle and must not be reported as one.
#   * `:bare` — `V` names itself whole. Not a recurrence under any reading
#     (§4.3.1.1 rejects it outright), and a genuine self-cycle: it keeps the
#     cycle diagnosis it has always had.
#   * `:none` — the overwhelmingly common case; nothing changes for it.
#
# Recognition here is deliberately more permissive than the validator's walk:
# it descends every expression-bearing field, because a MISSED recurrence is
# the dangerous direction. A recurrence that slipped through would be handed to
# the ordinary array path, whose per-cell kernels are independent and
# class-merged — and CONFORMANCE_SPEC §5.19.2 forbids exactly that, because
# reordering cells that are not independent computes something else rather than
# something equivalent.

"""
    recurrence_self_reference_kind(name, body) -> Symbol

How `body` refers to `name`: `:indexed` (at least one `index(name, …)` read, so
the equation is a recurrence CANDIDATE), `:bare` (named whole and never through
`index`, so it is not one), or `:none`.
"""
function recurrence_self_reference_kind(name::AbstractString, body::ASTExpr)::Symbol
    indexed = Ref(false)
    bare = Ref(false)
    _walk_self_reference!(body, name, indexed, bare)
    indexed[] && return :indexed
    bare[] && return :bare
    return :none
end

function _walk_self_reference!(e::ASTExpr, name::AbstractString,
                               indexed::Ref{Bool}, bare::Ref{Bool})
    if e isa VarExpr
        e.name == name && (bare[] = true)
        return nothing
    end
    e isa OpExpr || return nothing
    # POSITIONAL, not identity-based: hash-consing shares leaf nodes, so the
    # `VarExpr` at `args[1]` may be the very same object as a bare read
    # elsewhere in the tree, and skipping "that object" would skip both.
    self_head = e.op == "index" && !isempty(e.args) &&
                e.args[1] isa VarExpr && (e.args[1]::VarExpr).name == name
    self_head && (indexed[] = true)
    for j in eachindex(e.args)
        (self_head && j == 1) && continue
        _walk_self_reference!(e.args[j], name, indexed, bare)
    end
    for side in (e.expr_body, e.filter, e.key, e.lower, e.upper)
        side === nothing || _walk_self_reference!(side, name, indexed, bare)
    end
    if e.values !== nothing
        for v in e.values
            _walk_self_reference!(v, name, indexed, bare)
        end
    end
    for m in (e.table_axes, e.bindings)
        m === nothing && continue
        for k in sort!(collect(keys(m)))
            _walk_self_reference!(m[k], name, indexed, bare)
        end
    end
    if e.ranges !== nothing
        for k in sort!(collect(keys(e.ranges)))
            v = e.ranges[k]
            v isa AbstractVector || continue
            for x in v
                x isa ASTExpr && _walk_self_reference!(x, name, indexed, bare)
            end
        end
    end
    return nothing
end
