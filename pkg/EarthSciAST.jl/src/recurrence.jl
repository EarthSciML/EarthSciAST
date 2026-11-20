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
document both accept. Each model is read through its validation view
(`views`, a validation pass's `_UnitsInputs.models`; built here when absent),
and each `apply_expression_template` reference through its frame against the
model's template table, never expanded, so a self-read or a group peer inside
a template body is seen as the build sees it.
"""
function validate_recurrence_semantics(file::EsmFile; views = nothing)::Vector{StructuralError}
    errors = StructuralError[]
    file.models === nothing && return errors
    for model_name in sort!(collect(keys(file.models)))
        model = _units_view(file, model_name, file.models[model_name], views)
        templates = _tpl_component_table(file, "models", model_name)
        # An array-shaped variable is the only thing a causal self-reference can
        # define: a scalar has no axis to fold along. The declared TYPE is
        # deliberately not consulted — the reference implementation keys on the
        # shape alone, and a check that is narrower here would accept documents
        # it rejects, which is the parity defect §5.19.5 is about.
        array_shaped = Set{String}(
            n for (n, v) in model.variables if _recurrence_is_array_shape(v.shape)
        )
        isempty(array_shaped) && continue
        # esm-spec §4.3.1.2: a recurrence group's members count their peers'
        # `index` reads as causal reads, and their frames are compared once
        # every member has one.
        groups = recurrence_groups(model; templates)
        frames = _RecurrenceFrame[]
        for (i, eq) in enumerate(model.equations)
            t = _recurrence_lhs_target(eq.lhs)
            g = t === nothing ? nothing :
                something(findfirst(gr -> t[1] in gr, groups), 0)
            group = (g === nothing || g == 0) ? nothing : groups[g]
            frame = _check_recurrence_equation!(
                errors, file, eq, i,
                _pointer("", "models", model_name, "equations", i, "rhs"),
                array_shaped; group = group, templates = templates
            )
            (frame !== nothing && group !== nothing) && push!(frames, frame)
        end
        for g in groups
            members = filter(f -> f.var in g, frames)
            v = _recurrence_group_verdict(members)
            v.ref === nothing && continue
            if v.mismatch !== nothing
                f = members[v.mismatch]
                var, first_var = f.var, members[v.ref].var
                _report!(
                    errors, ERROR_CODES.RECURRENCE_GROUP_AXIS_MISMATCH,
                    _pointer("", "models", model_name, "equations", f.eq, "rhs"),
                    "'$var' and '$first_var' read each other as a recurrence group, but " *
                        "'$var' does not sweep the same frame: every member shares one " *
                        "cell frame — the same `output_idx`, the same ranges — and one " *
                        "recurrence axis (esm-spec §4.3.1.2).",
                    Dict{String, Any}("variable" => var, "group" => sort!(collect(g)))
                )
                continue
            end
            # Rule 1: the same-cell reads between members must admit an order.
            cycle = v.cycle
            if cycle !== nothing
                at = members[findfirst(f -> f.var in cycle, members)]
                _report!(
                    errors, ERROR_CODES.RECURRENCE_NOT_WELLFOUNDED,
                    _pointer("", "models", model_name, "equations", at.eq, "rhs"),
                    "the members of a recurrence group read one another at the cell being " *
                        "written in a cycle (" * join(cycle, " -> ") * "), so no order " *
                        "within the cell satisfies them. Reads between members at the same " *
                        "position must be acyclic (esm-spec §4.3.1.2 rule 1).",
                    Dict{String, Any}("variable" => at.var, "cycle" => cycle)
                )
            end
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
_recurrence_symbol_bounds(spec, file::EsmFile) = _recurrence_symbol_bounds(spec, file.index_sets)

function _recurrence_symbol_bounds(spec, index_sets::AbstractDict)
    if spec isa IndexSetRef
        isempty(spec.of) || return nothing
        iset = get(index_sets, spec.from, nothing)
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
function _recurrence_affine_in_sym(
        e::ASTExpr, sym::AbstractString,
        env::Dict{String, Tuple{Int, Int}}
    )
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
            return (
                ca + cb, both === nothing ? nothing :
                    (both[1][1] + both[2][1], both[1][2] + both[2][2]),
            )
        elseif e.op == "-"
            return (
                ca - cb, both === nothing ? nothing :
                    (both[1][1] - both[2][2], both[1][2] - both[2][1]),
            )
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

# ── One self-read's lag, shared by the validator and the build ──────────────

# A self-read that is well founded along its frame: `axis` is the one frame
# position it is offset on (0 when it is at the same cell on every axis),
# `lag_hi` the largest proved upper bound of its lag there (0 when unproved),
# and `proven` whether every value of that lag was shown `>= 1`.
struct _ReadLag
    axis::Int
    lag_hi::Int
    proven::Bool
end

# Why a self-read is not well founded (esm-spec §4.3.1.1): `kind` is
# `:arity`, `:not_affine`, `:coefficient`, `:not_earlier`, `:two_axes` or
# `:member_select`; `index` the 1-based frame position, `sym` its frame symbol,
# `coef` the coefficient found, `nargs` the number of indices supplied and
# `naxes` the number of frame axes.
struct _LagDefect
    kind::Symbol
    index::Int
    sym::String
    coef::Int
    nargs::Int
    naxes::Int
end

"""
    _recurrence_read_lag(args, idx_names, env; member_sym = nothing) -> Union{_ReadLag, _LagDefect}

The lag analysis of one self-read `index(V, args...)` in a frame whose output
indices are `idx_names`, with symbol bounds `env` (esm-spec §4.3.1.1): every
index affine in its frame symbol with coefficient 1, offset on at most one
axis, and never at the cell being written or a later one there. An unprovable
constant part is a lag of unknown sign: admitted, but it counts as the axis.
`member_sym` names the stacked member axis of a recurrence group (esm-spec
§4.3.1.2), where a read selects a member with an integer constant.
"""
function _recurrence_read_lag(
        args, idx_names::Vector{String}, env::Dict{String, Tuple{Int, Int}};
        member_sym::Union{Nothing, String} = nothing
    )::Union{_ReadLag, _LagDefect}
    defect(kind, d = 0, coef = 0) = _LagDefect(
        kind, d, d == 0 ? "" : idx_names[d], coef, length(args), length(idx_names)
    )
    length(args) == length(idx_names) || return defect(:arity)
    lagged = 0
    lag_hi = 0
    proven = true
    for (d, arg) in enumerate(args)
        sym = idx_names[d]
        if member_sym !== nothing && sym == member_sym
            arg isa IntExpr && continue
            return defect(:member_select, d)
        end
        aff = _recurrence_affine_in_sym(arg, sym, env)
        aff === nothing && return defect(:not_affine, d)
        coef, konst = aff
        coef == 1 || return defect(:coefficient, d, coef)
        if konst === nothing
            lagged == 0 || return defect(:two_axes, d)
            lagged = d
            proven = false
            continue
        end
        # lag = sym - arg, so the symbol-free part's bounds invert.
        lo, hi = -konst[2], -konst[1]
        (lo == 0 && hi == 0) && continue   # stays on this axis's own cell
        hi <= 0 && return defect(:not_earlier, d)
        lagged == 0 || return defect(:two_axes, d)
        lagged = d
        proven &= lo >= 1
        lag_hi = hi
    end
    return _ReadLag(lagged, lag_hi, lagged == 0 || proven)
end

# The message of a lag defect in the definition of `var`.
function _lag_defect_message(d::_LagDefect, var::AbstractString)::String
    k = d.kind
    i = d.index - 1
    if k === :arity
        return "a causal self-read of '$var' supplies $(d.nargs) indices but its frame " *
            "has $(d.naxes) axes; every self-read indexes every axis (esm-spec §4.3.1.1)."
    elseif k === :not_affine
        sym = d.sym
        return "index $i of a causal self-read of '$var' is not affine in its frame " *
            "symbol '$sym'. A self-read names a position RELATIVE to the cell being " *
            "written (`$sym - 1`, `$sym - a`, `$sym - a - 2`), which is what makes " *
            "the recurrence axis and its direction decidable (esm-spec §4.3.1.1). " *
            "If the offset is read from data (`$sym - index(lag, $sym)`), it has no " *
            "direct spelling; contract it instead: either order the axis so the " *
            "predecessor is the preceding position and the lag is the constant 1, or " *
            "range a contracted index `a` over the lag's bounds and select the matching " *
            "term with `ifelse(index(lag, $sym) == a, " *
            "<term reading index($var, $sym - a)>, 0)`."
    elseif k === :coefficient
        return "index $i of a causal self-read of '$var' carries its frame symbol " *
            "'$(d.sym)' with coefficient $(d.coef), not 1, so it does not name a position " *
            "relative to the cell being written (esm-spec §4.3.1.1)."
    elseif k === :not_earlier
        return "index $i of a causal self-read of '$var' names the cell being " *
            "written, or a later one, on axis '$(d.sym)'. A causal self-reference reads " *
            "strictly EARLIER positions; no sweep order can satisfy a same-cell or " *
            "forward read (esm-spec §4.3.1.1)."
    elseif k === :two_axes
        return "a causal self-read of '$var' is offset on more than one axis. A " *
            "recurrence folds along exactly ONE axis; every other index must be the " *
            "bare frame symbol (esm-spec §4.3.1.1)."
    end
    return "a read of the stacked recurrence group '$var' does not select a member " *
        "with a constant (esm-spec §4.3.1.2)."
end

# The `recurrence_axis` a lag defect reports: the frame symbol where the
# defect is an axis (a second offset axis, a non-earlier read), else nothing.
_lag_defect_axis(d::_LagDefect) = d.kind in (:two_axes, :not_earlier) ? d.sym : nothing


# One self-read the structural walk found: its index arguments, the symbol
# bounds in scope where it was found, and whether it was reached ONLY through a
# construct that cannot be restricted to one cell.
struct _RecurrenceSelfRead
    args::Vector{ASTExpr}
    env::Dict{String, Tuple{Int, Int}}
    unsequenceable::Bool
    # The variable read: the defined variable itself, or (esm-spec §4.3.1.2) a
    # peer in its recurrence group.
    target::String
end

# The frame symbol of a stacked recurrence group's member axis (esm-spec
# §4.3.1.2). Reserved: the build-time recurrence check admits a constant index on
# an axis of this name, and only there. Never authored — it exists only in the
# stacked reduction `_stack_recurrence_groups` (tree_walk/recurrence_group.jl)
# builds.
const RECURRENCE_MEMBER_SYM = "__esm_recurrence_member"

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
function _collect_recurrence_self_reads!(
        e::ASTExpr, var::AbstractString, index_sets::AbstractDict,
        env::Vector{Pair{String, Tuple{Int, Int}}},
        blocked::Bool,
        out::Vector{_RecurrenceSelfRead},
        bare::Ref{Bool}
    )
    return _collect_recurrence_self_reads!(e, [String(var)], index_sets, env, blocked, out, bare)
end

# The same walk over several names at once — a recurrence group's members
# (esm-spec §4.3.1.2) — recording which one each read names.
#
# With the template table `tt`, a template reference is read as its expansion
# (esm-spec §9.6.4 rule 2) without building it: its instance body is walked
# once per instance through its frame (`_tpl_recurrence_reads`) and its reads
# reused at every use; a parameter sentinel in a body is its binding, read
# where it was bound, and a read found in a body reports its subscripts as the
# caller spells them (`_tpl_ground`). `fr` is the frame `e` is read in.
function _collect_recurrence_self_reads!(
        e::ASTExpr, vars::Vector{String}, index_sets::AbstractDict,
        env::Vector{Pair{String, Tuple{Int, Int}}},
        blocked::Bool,
        out::Vector{_RecurrenceSelfRead},
        bare::Ref{Bool};
        tt = nothing, fr = nothing
    )
    if tt !== nothing && _tpl_is_call(e)
        sub = _tpl_frame_or_nothing(tt, e::OpExpr, fr)
        if sub !== nothing
            body = _tpl_recurrence_reads(tt, sub, vars, index_sets)
            body.bare && (bare[] = true)
            outer = Dict{String, Tuple{Int, Int}}(env)
            for r in body.reads
                push!(
                    out, _RecurrenceSelfRead(
                        r.args, merge(outer, r.env), blocked || r.unsequenceable, r.target
                    )
                )
            end
            # An element call's subscripts, as `index(<array>, subscripts…)`.
            for x in _tpl_out_bindings(e::OpExpr)
                _collect_recurrence_self_reads!(x, vars, index_sets, env, blocked, out, bare; tt, fr)
            end
            return out
        end
    end
    if !(e isa OpExpr)
        if e isa VarExpr
            if fr !== nothing && _tpl_is_sentinel(e.name)
                b, bf = _tpl_arg(fr, e.name)
                return _collect_recurrence_self_reads!(b, vars, index_sets, env, blocked, out, bare; tt, fr = bf)
            end
            # A name a body does not read from its caller is the body's own.
            fr === nothing && e.name in vars && (bare[] = true)
        end
        return out
    end
    pushed = 0
    if e.op == "faq" && e.ranges !== nothing
        for sym in sort!(collect(keys(e.ranges)))
            b = _recurrence_symbol_bounds(e.ranges[sym], index_sets)
            b === nothing && continue
            push!(env, String(sym) => b)
            pushed += 1
        end
    end
    head, head_fr = isempty(e.args) ? (nothing, nothing) : _tpl_leaf(e.args[1], fr)
    is_self_index = e.op == "index" && head isa VarExpr && head_fr === nothing &&
        (head::VarExpr).name in vars
    if is_self_index
        snapshot = Dict{String, Tuple{Int, Int}}(env)
        args = fr === nothing ? e.args[2:end] : ASTExpr[_tpl_ground(tt, a, fr) for a in e.args[2:end]]
        push!(out, _RecurrenceSelfRead(args, snapshot, blocked, (head::VarExpr).name))
    end
    # A `makearray` REGION VALUE (`values`) is evaluated once for the whole
    # region, so a self-read inside one cannot be sequenced: §4.3.2's region
    # order fixes which write WINS, not which cell is EVALUATED when.
    blocked_children = blocked || _recurrence_op_blocks_cell_restriction(e.op)
    for (j, a) in enumerate(e.args)
        (is_self_index && j == 1) && continue
        _collect_recurrence_self_reads!(a, vars, index_sets, env, blocked_children, out, bare; tt, fr)
    end
    for side in (e.expr_body, e.filter, e.key, e.lower, e.upper)
        side === nothing && continue
        _collect_recurrence_self_reads!(side, vars, index_sets, env, blocked_children, out, bare; tt, fr)
    end
    if e.values !== nothing
        for v in e.values
            _collect_recurrence_self_reads!(v, vars, index_sets, env, true, out, bare; tt, fr)
        end
    end
    resize!(env, length(env) - pushed)
    return out
end

# The causal reads of `vars` in the body of the template instance `sub`, read
# once per instance (per name list) through its frame: each read's bounds are
# the body's own (the caller's are merged in at each use), and `unsequenceable`
# says whether the body itself puts it under a whole-operand op.
function _tpl_recurrence_reads(tt, sub, vars::Vector{String}, index_sets::AbstractDict)
    memo = _tpl_memo(tt, sub, :recurrence_reads, () -> Dict{Vector{String}, Any}())
    return get!(memo, copy(vars)) do
        reads = _RecurrenceSelfRead[]
        bare = Ref(false)
        _collect_recurrence_self_reads!(
            sub.body, vars, index_sets, Pair{String, Tuple{Int, Int}}[], false, reads, bare;
            tt, fr = sub
        )
        (; reads, bare = bare[])
    end
end

# The variable an equation DEFINES, if its LHS names one: a bare variable, or
# the §4.3 indexed-`faq` LHS form `faq{expr: index(V, k…)}`. A
# DERIVATIVE LHS (`D(u)`) defines no array algebraically — a stencil read of `u`
# at `i−1` there is a gather on the solver's state vector, not a
# self-reference — so it deliberately yields `nothing`.
function _recurrence_lhs_target(lhs::ASTExpr)
    s = _lhs_shape(lhs)
    s.bare && return (s.name, nothing)
    s.indexed_faq || return nothing
    return (s.name, s.frame)
end

# ── One definition's well-foundedness, shared by the validator and the build ──

# Why a recurrence definition is not well founded, or cannot be swept cell by
# cell (esm-spec §4.3.1.1, §4.3.1.2). `kind` is one of
#   `:bare`              — the defined variable is also read whole;
#   `:unsequenceable`    — a causal read sits under a construct that evaluates
#                          its operand whole;
#   `:no_frame`          — the equation declares no cell frame to sweep;
#   `:no_symbolic_index` — the frame has no symbolic index to fold along;
#   `:lag`               — one read's lag analysis failed (`lag`);
#   `:same_cell`         — a read of the defined variable at the cell being
#                          written;
#   `:peer_unproven`     — a read of a group peer not provably strictly earlier
#                          on frame axis `axis`;
#   `:axes_disagree`     — two reads fold along the frame axes `axis` and `axis2`.
# `target` is the variable the offending read names, `idx_names` the frame.
struct _RecurrenceProblem
    kind::Symbol
    lag::Union{Nothing, _LagDefect}
    target::String
    axis::Int
    axis2::Int
    idx_names::Vector{String}
end
_RecurrenceProblem(kind::Symbol; lag = nothing, target = "", axis = 0, axis2 = 0, idx_names = String[]) =
    _RecurrenceProblem(kind, lag, target, axis, axis2, idx_names)

# The error code a problem carries, at validation and at build alike.
_recurrence_problem_code(p::_RecurrenceProblem) =
    p.kind in (:unsequenceable, :no_frame, :no_symbolic_index) ?
    ERROR_CODES.RECURRENCE_UNSUPPORTED_FORM : ERROR_CODES.RECURRENCE_NOT_WELLFOUNDED

# What a definition's causal reads decide when they are well founded: the one
# frame axis they fold along (0 when every read is at the cell being written),
# the largest proved upper bound on a lag along it over the reads whose lag has
# one (a read with none adds nothing, so the value bounds every read only when
# `lag_proven`), whether every read was proved strictly earlier, and the group
# peers read at the cell being written (esm-spec §4.3.1.2 rule 1).
struct _RecurrenceAxis
    axis::Int
    max_lag::Int
    lag_proven::Bool
    same_cell::Vector{String}
end

"""
    _recurrence_reads_verdict(reads, var, idx_names, frame_env; member_sym = nothing)
        -> Union{_RecurrenceAxis, _RecurrenceProblem}

The well-foundedness of the definition of `var` over the frame `idx_names`
from its causal reads (`_RecurrenceSelfRead`s, in the order they were found),
each analysed by `_recurrence_read_lag` against `frame_env` and its own
in-scope bounds (esm-spec §4.3.1.1, §4.3.1.2): every read well founded, a read
of `var` itself offset on some axis, a read of a group peer either at the cell
being written or provably strictly earlier, and every offset read along one
axis. The first read that breaks a rule decides the problem. `member_sym` is a
stacked group's member axis, where a same-cell read selects an earlier member
(`RECURRENCE_MEMBER_SYM`).
"""
function _recurrence_reads_verdict(
        reads, var::AbstractString, idx_names::Vector{String},
        frame_env::Dict{String, Tuple{Int, Int}};
        member_sym::Union{Nothing, String} = nothing
    )::Union{_RecurrenceAxis, _RecurrenceProblem}
    axis = 0
    max_lag = 0
    lag_proven = true
    same_cell = String[]
    stacked = member_sym !== nothing && member_sym in idx_names
    for read in reads
        lag = _recurrence_read_lag(
            read.args, idx_names, merge(frame_env, read.env); member_sym = member_sym
        )
        lag isa _LagDefect &&
            return _RecurrenceProblem(:lag; lag = lag, target = read.target, idx_names = idx_names)
        lag_proven &= lag.proven
        max_lag = max(max_lag, lag.lag_hi)
        if lag.axis == 0
            # A read of a PEER at the cell being written is an ordering WITHIN
            # the cell; the group check rejects it only if such reads form a
            # cycle (esm-spec §4.3.1.2 rule 1). In a stacked group it is a read
            # of an earlier member, published in within-cell order.
            if read.target != var
                push!(same_cell, read.target)
                continue
            end
            stacked && continue
            return _RecurrenceProblem(:same_cell; target = read.target, idx_names = idx_names)
        end
        read.target != var && !lag.proven && return _RecurrenceProblem(
            :peer_unproven; target = read.target, axis = lag.axis, idx_names = idx_names
        )
        axis == 0 && (axis = lag.axis)
        axis == lag.axis || return _RecurrenceProblem(
            :axes_disagree; target = read.target, axis = axis, axis2 = lag.axis,
            idx_names = idx_names
        )
    end
    return _RecurrenceAxis(axis, max_lag, lag_proven, sort!(unique(same_cell)))
end

# ── A group member's frame, shared by the validator and the build ───────────

# One recurrence definition's cell frame, for the §4.3.1.2 comparison across a
# group's members: the defined variable, the index of its equation, its output
# indices, each axis's range as `_recurrence_frame_sig` gives it, the
# recurrence axis (`nothing` when no read is offset), and the peers it reads at
# the cell being written.
struct _RecurrenceFrame
    var::String
    eq::Int
    idx_names::Vector{String}
    ranges_sig::Vector{Any}
    axis::Union{Nothing, Int}
    same_cell::Vector{String}
end

# Each frame axis's range for the frame comparison: its bounds when an
# interval or a dense index set proves them (`_recurrence_symbol_bounds`), the
# authored spec otherwise, `nothing` for an axis with no declared range. So
# `{from: lev}` and `[1, 4]` over a 4-element `lev` are one frame.
function _recurrence_frame_sig(idx_names::Vector{String}, ranges, index_sets::AbstractDict)
    sig = Any[]
    for n in idx_names
        spec = ranges === nothing ? nothing : get(ranges, n, nothing)
        b = spec === nothing ? nothing : _recurrence_symbol_bounds(spec, index_sets)
        push!(sig, (spec === nothing || b !== nothing) ? b : repr(spec))
    end
    return sig
end

# Whether member frame `f` sweeps the frame `ref` does: the same output
# indices, the same ranges, and (when `f` folds at all) the same axis.
_recurrence_frames_agree(f::_RecurrenceFrame, ref::_RecurrenceFrame) =
    f.idx_names == ref.idx_names && f.ranges_sig == ref.ranges_sig &&
    (f.axis === nothing || f.axis == ref.axis)

"""
    _recurrence_group_verdict(frames) -> NamedTuple

The §4.3.1.2 checks over a group's member frames, in equation order: `ref`,
the first member that folds along an axis (`nothing` when none does);
`mismatch`, the first member whose frame does not agree with `ref`'s (or, with
no `ref`, the first member's); `order`, the within-cell order of the members
(rule 1: a member another reads at the cell being written comes first, ties in
equation order), or `nothing` when those reads form a `cycle`.
"""
function _recurrence_group_verdict(frames::Vector{_RecurrenceFrame})
    ref = findfirst(f -> f.axis !== nothing, frames)
    k0 = something(ref, 1)
    mismatch = isempty(frames) ? nothing :
        findfirst(f -> !_recurrence_frames_agree(f, frames[k0]), frames)
    n = length(frames)
    same_cell(i, j) = frames[j].var in frames[i].same_cell
    order = Int[]
    while length(order) < n
        nxt = findfirst(
            i -> !(i in order) &&
                all(j -> j == i || !same_cell(i, j) || j in order, 1:n), 1:n
        )
        nxt === nothing && break
        push!(order, nxt)
    end
    cycle = nothing
    if length(order) < n
        adj = Dict{String, Vector{String}}(f.var => f.same_cell for f in frames)
        cycle = _find_cycle(adj, sort!(collect(keys(adj))))
        order = nothing
    end
    return (; ref, mismatch, order, cycle)
end

# The `faq` that declares an equation's cell frame: the indexed-`faq` LHS, when
# the LHS is that form and names its indices, else the RHS when it is a `faq`.
# `rhs` is the right-hand side as read (a reference's instance body, see
# `_recurrence_equation_frame`).
function _recurrence_frame_faq(eq::Equation, lhs_idx, rhs::ASTExpr = eq.rhs)
    lhs_idx !== nothing && return eq.lhs::OpExpr
    return (rhs isa OpExpr && (rhs::OpExpr).op == "faq") ? (rhs::OpExpr) : nothing
end

"""
    _recurrence_equation_frame(eq, i, var, lhs_idx, vars, index_sets)
        -> Union{Nothing, _RecurrenceFrame, _RecurrenceProblem}

The static analysis of equation `i`, `eq`, which defines `var` (with
`lhs_idx` the indexed-`faq` LHS's indices, or `nothing` for a bare LHS), whose
causal reads are the `index` reads of the names `vars` — `var` itself, then
its §4.3.1.2 group peers. `nothing` when the RHS reads none of them, which is
every equation of a document that does not use the construct; else the
definition's frame, or the first problem found. With the template table
`templates`, a template reference in the RHS is read as its expansion, through
its frame (`_collect_recurrence_self_reads!`); an RHS that is one reference
declares the frame its instance body declares.
"""
function _recurrence_equation_frame(
        eq::Equation, i::Int, var::AbstractString, lhs_idx,
        vars::Vector{String}, index_sets::AbstractDict; templates = nothing
    )::Union{Nothing, _RecurrenceFrame, _RecurrenceProblem}
    env = Pair{String, Tuple{Int, Int}}[]
    reads = _RecurrenceSelfRead[]
    bare = Ref(false)
    _collect_recurrence_self_reads!(eq.rhs, vars, index_sets, env, false, reads, bare; tt = templates)
    isempty(reads) && return nothing
    bare[] && return _RecurrenceProblem(:bare; target = String(var))
    any(r -> r.unsequenceable, reads) && return _RecurrenceProblem(:unsequenceable)

    # The cell frame: the indexed-`faq` LHS's own indices, else the RHS
    # aggregate's.
    rhs = eq.rhs
    if templates !== nothing && _tpl_is_call(rhs)
        sub = _tpl_frame_or_nothing(templates, rhs::OpExpr, nothing)
        sub === nothing || (rhs = sub.body)
    end
    rhs_agg = (rhs isa OpExpr && (rhs::OpExpr).op == "faq") ? (rhs::OpExpr) : nothing
    frame_agg = _recurrence_frame_faq(eq, lhs_idx, rhs)
    raw_idx = frame_agg === nothing ? nothing : frame_agg.output_idx
    raw_idx === nothing && return _RecurrenceProblem(:no_frame; target = String(var))
    idx_names = String[string(s) for s in raw_idx]
    (isempty(idx_names) || any(n -> tryparse(Int, n) !== nothing, idx_names)) &&
        return _RecurrenceProblem(:no_symbolic_index; idx_names = idx_names)

    frame_env = Dict{String, Tuple{Int, Int}}()
    if rhs_agg !== nothing && rhs_agg.ranges !== nothing
        for (sym, spec) in rhs_agg.ranges
            b = _recurrence_symbol_bounds(spec, index_sets)
            b === nothing || (frame_env[String(sym)] = b)
        end
    end
    v = _recurrence_reads_verdict(reads, var, idx_names, frame_env)
    v isa _RecurrenceProblem && return v
    # The ranges are the frame-declaring `faq`'s: the indexed-`faq` LHS's own
    # when the LHS is that form, else the RHS aggregate's.
    return _RecurrenceFrame(
        String(var), i, idx_names,
        _recurrence_frame_sig(idx_names, frame_agg.ranges, index_sets),
        v.axis == 0 ? nothing : v.axis, v.same_cell
    )
end

# The validator's message for problem `p` in the definition of `var`, and the
# `recurrence_axis` detail it reports.
function _recurrence_problem_message(p::_RecurrenceProblem, var::AbstractString)
    k = p.kind
    idx_names = p.idx_names
    if k === :bare
        return "'$var' is read bare inside its own defining equation as well as through " *
            "`index`. A bare read names the whole array, which does not exist while the " *
            "recurrence sweeps it (esm-spec §4.3.1.1).", nothing
    elseif k === :unsequenceable
        return "a causal self-read of '$var' is reached only through a construct that " *
            "evaluates its operand whole — a `makearray` region value, or a " *
            "`reshape`/`transpose`/`concat`/`broadcast` operand — so no cell-by-cell sweep " *
            "can supply it. A `makearray`'s region order fixes which write WINS, not the " *
            "order cells are EVALUATED in (esm-spec §4.3.1.1, §4.3.2); write the recurrence " *
            "as one `faq` with the base case as an `ifelse` guard in the body.", nothing
    elseif k === :no_frame
        return "the definition of '$var' reads '$var' at another position, but the equation " *
            "declares no cell frame to sweep: its RHS is not a `faq` over the " *
            "variable's axes and its LHS is not the indexed-`faq` form " *
            "`faq{expr: index($var, k…)}` (esm-spec §4.3.1.1).", nothing
    elseif k === :no_symbolic_index
        return "the recurrence definition of '$var' has no symbolic output index to fold " *
            "along ($(idx_names)); a literal singleton dimension cannot be a recurrence " *
            "axis (esm-spec §4.3.1.1).", nothing
    elseif k === :lag
        lag = p.lag::_LagDefect
        return _lag_defect_message(lag, var), _lag_defect_axis(lag)
    elseif k === :same_cell
        return "a causal read of '$(p.target)' in the definition of '$var' is at the same " *
            "cell on every axis, so it defines '$var' in terms of a value at the cell " *
            "being written rather than of an earlier position (esm-spec §4.3.1.1, " *
            "§4.3.1.2).", nothing
    elseif k === :peer_unproven
        ax = idx_names[p.axis]
        return "the read of '$(p.target)' in the definition of '$var' — a peer in its " *
            "recurrence group — is not provably strictly earlier on axis " *
            "'$ax'. A read of a PEER must be strictly earlier for every " *
            "value of its lag (esm-spec §4.3.1.2): unlike a self-read, whose same-cell " *
            "values simply have not been published, a same-position read of another " *
            "variable would make the result depend on which member is evaluated first.",
            ax
    end
    return "the causal self-reads of '$var' disagree on the recurrence axis: one " *
        "folds along '$(idx_names[p.axis])' and another along '$(idx_names[p.axis2])'. " *
        "A definition folds along exactly one axis (esm-spec §4.3.1.1).",
        idx_names[p.axis2]
end

# Check ONE equation (number `i`). Emits nothing when the RHS contains no
# self-read, which is every equation in every document that does not use the
# construct. Returns the definition's frame for the group comparison, or
# `nothing`.
function _check_recurrence_equation!(
        errors::Vector{StructuralError}, file::EsmFile,
        eq::Equation, i::Int, field_path::String,
        array_shaped::Set{String};
        group::Union{Nothing, Set{String}} = nothing, templates = nothing
    )
    target = _recurrence_lhs_target(eq.lhs)
    target === nothing && return nothing
    var, lhs_idx = target
    var in array_shaped || return nothing

    # The names whose `index` reads are causal reads here: `var`, plus — for a
    # member of a §4.3.1.2 recurrence group — every peer.
    vars = String[var]
    group === nothing || append!(vars, sort!([g for g in group if g != var]))
    r = _recurrence_equation_frame(eq, i, var, lhs_idx, vars, file.index_sets; templates)
    if r isa _RecurrenceProblem
        msg, axis = _recurrence_problem_message(r, var)
        _report!(
            errors, _recurrence_problem_code(r), field_path, msg,
            Dict{String, Any}("variable" => var, "recurrence_axis" => axis)
        )
        return nothing
    end
    return r
end


# ===========================================================================
# Build-time recognition — the seam between a recurrence and a CYCLE
# ===========================================================================
#
# `_resolve_observed` (tree_walk/build_classify.jl) collapses observed-into-observed
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
    recurrence_self_reference_kind(name, body; templates = nothing) -> Symbol

How `body` refers to `name`: `:indexed` (at least one `index(name, …)` read, so
the equation is a recurrence CANDIDATE), `:bare` (named whole and never through
`index`, so it is not one), or `:none`. With the template table `templates`, a
template reference is read as its expansion, its body once per instance
through its frame (`_tpl_step`), each parameter where the body reads it.
"""
function recurrence_self_reference_kind(name::AbstractString, body::ASTExpr; templates = nothing)::Symbol
    indexed = Ref(false)
    bare = Ref(false)
    _walk_self_reference!(body, name, indexed, bare, Set{Tuple{UInt, UInt}}(), templates, nothing)
    indexed[] && return :indexed
    bare[] && return :bare
    return :none
end

function _walk_self_reference!(
        e::ASTExpr, name::AbstractString,
        indexed::Ref{Bool}, bare::Ref{Bool}, seen::Set{Tuple{UInt, UInt}},
        tt = nothing, fr = nothing
    )
    _tpl_step((x, xf) -> _walk_self_reference!(x, name, indexed, bare, seen, tt, xf), tt, e, fr) &&
        return nothing
    if e isa VarExpr
        # A name a template body does not read from its caller is its own.
        fr === nothing && e.name == name && (bare[] = true)
        return nothing
    end
    e isa OpExpr || return nothing
    # A shared sub-DAG answers the same both times: walk each node once (per
    # template frame), or a structurally shared body costs one walk per path.
    k = (objectid(e), fr === nothing ? UInt(0) : objectid(fr))
    k in seen && return nothing
    push!(seen, k)
    # POSITIONAL, not identity-based: hash-consing shares leaf nodes, so the
    # `VarExpr` at `args[1]` may be the very same object as a bare read
    # elsewhere in the tree, and skipping "that object" would skip both.
    head, head_fr = isempty(e.args) ? (nothing, nothing) : _tpl_leaf(e.args[1], fr)
    self_head = e.op == "index" && head isa VarExpr && head_fr === nothing &&
        (head::VarExpr).name == name
    self_head && (indexed[] = true)
    for j in eachindex(e.args)
        (self_head && j == 1) && continue
        _walk_self_reference!(e.args[j], name, indexed, bare, seen, tt, fr)
    end
    for side in (e.expr_body, e.filter, e.key, e.lower, e.upper)
        side === nothing || _walk_self_reference!(side, name, indexed, bare, seen, tt, fr)
    end
    if e.values !== nothing
        for v in e.values
            _walk_self_reference!(v, name, indexed, bare, seen, tt, fr)
        end
    end
    if e.bindings !== nothing
        for k in sort!(collect(keys(e.bindings)))
            _walk_self_reference!(e.bindings[k], name, indexed, bare, seen, tt, fr)
        end
    end
    if e.ranges !== nothing
        for k in sort!(collect(keys(e.ranges)))
            v = e.ranges[k]
            v isa AbstractVector || continue
            for x in v
                x isa ASTExpr && _walk_self_reference!(x, name, indexed, bare, seen, tt, fr)
            end
        end
    end
    return nothing
end
