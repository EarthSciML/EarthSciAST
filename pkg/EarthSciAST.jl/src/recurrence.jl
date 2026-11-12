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
            n for (n, v) in model.variables if _recurrence_is_array_shape(v.shape)
        )
        isempty(array_shaped) && continue
        # esm-spec §4.3.1.2: a recurrence group's members count their peers'
        # `index` reads as causal reads, and their frames are compared once
        # every member has one.
        groups = recurrence_groups(model)
        frames = Tuple{Int, String, Any}[]
        for (i, eq) in enumerate(model.equations)
            t = _recurrence_lhs_target(eq.lhs)
            g = t === nothing ? nothing :
                something(findfirst(gr -> t[1] in gr, groups), 0)
            group = (g === nothing || g == 0) ? nothing : groups[g]
            frame = _check_recurrence_equation!(
                errors, file, eq,
                "/models/$model_name/equations/$(i - 1)/rhs",
                array_shaped; group = group
            )
            (frame !== nothing && group !== nothing) && push!(frames, (i, t[1], frame))
        end
        for g in groups
            members = filter(f -> f[2] in g, frames)
            ref = findfirst(f -> f[3][3] !== nothing, members)
            ref === nothing && continue
            _, first_var, first_frame = members[ref]
            mismatch = false
            for (i, var, frame) in members
                (
                    frame[1] == first_frame[1] && frame[2] == first_frame[2] &&
                        (frame[3] === nothing || frame[3] == first_frame[3])
                ) && continue
                mismatch = true
                push!(
                    errors, StructuralError(
                        "/models/$model_name/equations/$(i - 1)/rhs",
                        "'$var' and '$first_var' read each other as a recurrence group, but " *
                            "'$var' does not sweep the same frame: every member shares one " *
                            "cell frame — the same `output_idx`, the same ranges — and one " *
                            "recurrence axis (esm-spec §4.3.1.2).",
                        ERROR_CODES.RECURRENCE_GROUP_AXIS_MISMATCH,
                        Dict{String, Any}("variable" => var, "group" => sort!(collect(g)))
                    )
                )
                break
            end
            mismatch && continue
            # Rule 1: the same-cell reads between members must admit an order.
            adj = Dict{String, Vector{String}}(f[2] => f[3][4] for f in members)
            cycle = _first_observed_cycle(adj)
            if cycle !== nothing
                at = members[findfirst(f -> f[2] in cycle, members)]
                push!(
                    errors, StructuralError(
                        "/models/$model_name/equations/$(at[1] - 1)/rhs",
                        "the members of a recurrence group read one another at the cell being " *
                            "written in a cycle (" * join(cycle, " -> ") * "), so no order " *
                            "within the cell satisfies them. Reads between members at the same " *
                            "position must be acyclic (esm-spec §4.3.1.2 rule 1).",
                        ERROR_CODES.RECURRENCE_NOT_WELLFOUNDED,
                        Dict{String, Any}("variable" => at[2], "cycle" => cycle)
                    )
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
        e::ASTExpr, var::AbstractString, file::EsmFile,
        env::Vector{Pair{String, Tuple{Int, Int}}},
        blocked::Bool,
        out::Vector{_RecurrenceSelfRead},
        bare::Ref{Bool}
    )
    return _collect_recurrence_self_reads!(e, [String(var)], file, env, blocked, out, bare)
end

# The same walk over several names at once — a recurrence group's members
# (esm-spec §4.3.1.2) — recording which one each read names.
function _collect_recurrence_self_reads!(
        e::ASTExpr, vars::Vector{String}, file::EsmFile,
        env::Vector{Pair{String, Tuple{Int, Int}}},
        blocked::Bool,
        out::Vector{_RecurrenceSelfRead},
        bare::Ref{Bool}
    )
    if !(e isa OpExpr)
        e isa VarExpr && e.name in vars && (bare[] = true)
        return out
    end
    pushed = 0
    if e.op == "faq" && e.ranges !== nothing
        for sym in sort!(collect(keys(e.ranges)))
            b = _recurrence_symbol_bounds(e.ranges[sym], file)
            b === nothing && continue
            push!(env, String(sym) => b)
            pushed += 1
        end
    end
    is_self_index = e.op == "index" && !isempty(e.args) &&
        e.args[1] isa VarExpr && (e.args[1]::VarExpr).name in vars
    if is_self_index
        snapshot = Dict{String, Tuple{Int, Int}}(env)
        push!(
            out, _RecurrenceSelfRead(
                e.args[2:end], snapshot, blocked, (e.args[1]::VarExpr).name
            )
        )
    end
    # A `makearray` REGION VALUE (`values`) is evaluated once for the whole
    # region, so a self-read inside one cannot be sequenced: §4.3.2's region
    # order fixes which write WINS, not which cell is EVALUATED when.
    blocked_children = blocked || _recurrence_op_blocks_cell_restriction(e.op)
    for (j, a) in enumerate(e.args)
        (is_self_index && j == 1) && continue
        _collect_recurrence_self_reads!(a, vars, file, env, blocked_children, out, bare)
    end
    for side in (e.expr_body, e.filter, e.key, e.lower, e.upper)
        side === nothing && continue
        _collect_recurrence_self_reads!(side, vars, file, env, blocked_children, out, bare)
    end
    if e.values !== nothing
        for v in e.values
            _collect_recurrence_self_reads!(v, vars, file, env, true, out, bare)
        end
    end
    resize!(env, length(env) - pushed)
    return out
end

# The variable an equation DEFINES, if its LHS names one: a bare variable, or
# the §4.3 indexed-`faq` LHS form `faq{expr: index(V, k…)}`. A
# DERIVATIVE LHS (`D(u)`) defines no array algebraically — a stencil read of `u`
# at `i−1` there is a gather on the solver's state vector, not a
# self-reference — so it deliberately yields `nothing`.
function _recurrence_lhs_target(lhs::ASTExpr)
    if lhs isa VarExpr
        return (lhs.name, nothing)
    elseif lhs isa OpExpr && lhs.op == "faq"
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
function _check_recurrence_equation!(
        errors::Vector{StructuralError}, file::EsmFile,
        eq::Equation, field_path::String,
        array_shaped::Set{String};
        group::Union{Nothing, Set{String}} = nothing
    )
    target = _recurrence_lhs_target(eq.lhs)
    target === nothing && return nothing
    var, lhs_idx = target
    var in array_shaped || return nothing

    # The names whose `index` reads are causal reads here: `var`, plus — for a
    # member of a §4.3.1.2 recurrence group — every peer.
    vars = String[var]
    group === nothing || append!(vars, sort!([g for g in group if g != var]))
    env = Pair{String, Tuple{Int, Int}}[]
    reads = _RecurrenceSelfRead[]
    bare = Ref(false)
    _collect_recurrence_self_reads!(eq.rhs, vars, file, env, false, reads, bare)
    isempty(reads) && return nothing

    push_err! = (code, message, axis) -> push!(
        errors, StructuralError(
            field_path, message, code,
            Dict{String, Any}("variable" => var, "recurrence_axis" => axis)
        )
    )

    if bare[]
        push_err!(
            ERROR_CODES.RECURRENCE_NOT_WELLFOUNDED,
            "'$var' is read bare inside its own defining equation as well as through " *
                "`index`. A bare read names the whole array, which does not exist while the " *
                "recurrence sweeps it (esm-spec §4.3.1.1).", nothing
        )
        return nothing
    end
    if any(r -> r.unsequenceable, reads)
        push_err!(
            ERROR_CODES.RECURRENCE_UNSUPPORTED_FORM,
            "a causal self-read of '$var' is reached only through a construct that " *
                "evaluates its operand whole — a `makearray` region value, or a " *
                "`reshape`/`transpose`/`concat`/`broadcast` operand — so no cell-by-cell sweep " *
                "can supply it. A `makearray`'s region order fixes which write WINS, not the " *
                "order cells are EVALUATED in (esm-spec §4.3.1.1, §4.3.2); write the recurrence " *
                "as one `faq` with the base case as an `ifelse` guard in the body.",
            nothing
        )
        return nothing
    end

    # The cell frame: the indexed-`faq` LHS's own indices, else the RHS
    # aggregate's.
    rhs_agg = (eq.rhs isa OpExpr && (eq.rhs::OpExpr).op == "faq") ?
        (eq.rhs::OpExpr) : nothing
    raw_idx = lhs_idx !== nothing ? lhs_idx :
        (rhs_agg === nothing ? nothing : rhs_agg.output_idx)
    if raw_idx === nothing
        push_err!(
            ERROR_CODES.RECURRENCE_UNSUPPORTED_FORM,
            "the definition of '$var' reads '$var' at another position, but the equation " *
                "declares no cell frame to sweep: its RHS is not a `faq` over the " *
                "variable's axes and its LHS is not the indexed-`faq` form " *
                "`faq{expr: index($var, k…)}` (esm-spec §4.3.1.1).", nothing
        )
        return nothing
    end
    idx_names = String[string(s) for s in raw_idx]
    if isempty(idx_names) || any(n -> tryparse(Int, n) !== nothing, idx_names)
        push_err!(
            ERROR_CODES.RECURRENCE_UNSUPPORTED_FORM,
            "the recurrence definition of '$var' has no symbolic output index to fold " *
                "along ($(idx_names)); a literal singleton dimension cannot be a recurrence " *
                "axis (esm-spec §4.3.1.1).", nothing
        )
        return nothing
    end

    frame_env = Dict{String, Tuple{Int, Int}}()
    if rhs_agg !== nothing && rhs_agg.ranges !== nothing
        for (sym, spec) in rhs_agg.ranges
            b = _recurrence_symbol_bounds(spec, file)
            b === nothing || (frame_env[String(sym)] = b)
        end
    end

    axis = nothing   # the one frame position every self-read must agree on
    same_cell = String[]   # §4.3.1.2 rule 1: peers read at the cell being written
    for read in reads
        if length(read.args) != length(idx_names)
            push_err!(
                ERROR_CODES.RECURRENCE_NOT_WELLFOUNDED,
                "a causal self-read of '$var' supplies $(length(read.args)) indices but " *
                    "its frame has $(length(idx_names)) axes; every self-read indexes every " *
                    "axis (esm-spec §4.3.1.1).", nothing
            )
            return nothing
        end
        env = merge(frame_env, read.env)
        lagged = nothing
        # Whether every value of the recurrence-axis lag was shown `>= 1`. A
        # self-read need not be; a PEER read must be (esm-spec §4.3.1.2).
        proven = true
        for (d, arg) in enumerate(read.args)
            sym = idx_names[d]
            aff = _recurrence_affine_in_sym(arg, sym, env)
            if aff === nothing
                push_err!(
                    ERROR_CODES.RECURRENCE_NOT_WELLFOUNDED,
                    "index $(d - 1) of a causal self-read of '$var' is not affine in its frame " *
                        "symbol '$sym'. A self-read names a position RELATIVE to the cell being " *
                        "written (`$sym - 1`, `$sym - a`, `$sym - a - 2`), which is what makes " *
                        "the recurrence axis and its direction decidable (esm-spec §4.3.1.1). " *
                        "If the offset is read from data (`$sym - index(lag, $sym)`), it has no " *
                        "direct spelling; contract it instead: either order the axis so the " *
                        "predecessor is the preceding position and the lag is the constant 1, or " *
                        "range a contracted index `a` over the lag's bounds and select the matching " *
                        "term with `ifelse(index(lag, $sym) == a, " *
                        "<term reading index($var, $sym - a)>, 0)`.",
                    nothing
                )
                return nothing
            end
            coef, konst = aff
            if coef != 1
                push_err!(
                    ERROR_CODES.RECURRENCE_NOT_WELLFOUNDED,
                    "index $(d - 1) of a causal self-read of '$var' carries its frame symbol " *
                        "'$sym' with coefficient $coef, not 1, so it does not name a position " *
                        "relative to the cell being written (esm-spec §4.3.1.1).", nothing
                )
                return nothing
            end
            # An unprovable constant part is a lag of UNKNOWN SIGN. This axis
            # IS the recurrence axis — the read is not the identity — and the
            # cells where the lag would be non-causal cannot be read at all,
            # because the sweep has not published them. Admitting it still
            # COUNTS the axis, though: two unprovable offsets are two axes.
            if konst === nothing
                if lagged !== nothing
                    push_err!(
                        ERROR_CODES.RECURRENCE_NOT_WELLFOUNDED,
                        "a causal self-read of '$var' is offset on more than one axis. A " *
                            "recurrence folds along exactly ONE axis; every other index must be " *
                            "the bare frame symbol (esm-spec §4.3.1.1).", sym
                    )
                    return nothing
                end
                lagged = d
                proven = false
                continue
            end
            clo, chi = konst
            # lag = sym - arg, so the symbol-free part's bounds invert.
            lag_lo, lag_hi = -chi, -clo
            (lag_lo == 0 && lag_hi == 0) && continue   # stays on this axis's own cell
            if lag_hi <= 0
                push_err!(
                    ERROR_CODES.RECURRENCE_NOT_WELLFOUNDED,
                    "index $(d - 1) of a causal self-read of '$var' names the cell being " *
                        "written, or a later one, on axis '$sym'. A causal self-reference reads " *
                        "strictly EARLIER positions; no sweep order can satisfy a same-cell or " *
                        "forward read (esm-spec §4.3.1.1).", sym
                )
                return nothing
            end
            if lagged !== nothing
                push_err!(
                    ERROR_CODES.RECURRENCE_NOT_WELLFOUNDED,
                    "a causal self-read of '$var' is offset on more than one axis. A " *
                        "recurrence folds along exactly ONE axis; every other index must be the " *
                        "bare frame symbol (esm-spec §4.3.1.1).", sym
                )
                return nothing
            end
            lagged = d
            proven &= lag_lo >= 1
        end
        if lagged === nothing && read.target != var
            # A read of a PEER at the cell being written is an ordering WITHIN
            # the cell; the group check rejects it only if such reads form a
            # cycle (esm-spec §4.3.1.2 rule 1).
            push!(same_cell, read.target)
            continue
        end
        if lagged === nothing
            push_err!(
                ERROR_CODES.RECURRENCE_NOT_WELLFOUNDED,
                "a causal read of '$(read.target)' in the definition of '$var' is at the same " *
                    "cell on every axis, so it defines '$var' in terms of a value at the cell " *
                    "being written rather than of an earlier position (esm-spec §4.3.1.1, " *
                    "§4.3.1.2).", nothing
            )
            return nothing
        end
        if read.target != var && !proven
            push_err!(
                ERROR_CODES.RECURRENCE_NOT_WELLFOUNDED,
                "the read of '$(read.target)' in the definition of '$var' — a peer in its " *
                    "recurrence group — is not provably strictly earlier on axis " *
                    "'$(idx_names[lagged])'. A read of a PEER must be strictly earlier for every " *
                    "value of its lag (esm-spec §4.3.1.2): unlike a self-read, whose same-cell " *
                    "values simply have not been published, a same-position read of another " *
                    "variable would make the result depend on which member is evaluated first.",
                idx_names[lagged]
            )
            return nothing
        end
        if axis === nothing
            axis = lagged
        elseif axis != lagged
            push_err!(
                ERROR_CODES.RECURRENCE_NOT_WELLFOUNDED,
                "the causal self-reads of '$var' disagree on the recurrence axis: one " *
                    "folds along '$(idx_names[axis])' and another along '$(idx_names[lagged])'. " *
                    "A definition folds along exactly one axis (esm-spec §4.3.1.1).",
                idx_names[lagged]
            )
            return nothing
        end
    end
    # The frame, for the §4.3.1.2 comparison across a group's members: output
    # indices, each axis's range as the validator resolves it (bounds when
    # provable, the authored spec otherwise), and the recurrence axis. The ranges
    # are the frame-declaring `faq`'s: the indexed-`faq` LHS's own when the LHS
    # is that form, else the RHS aggregate's.
    frame_agg = lhs_idx !== nothing ? (eq.lhs::OpExpr) : rhs_agg
    ranges_sig = Any[]
    for n in idx_names
        spec = (frame_agg === nothing || frame_agg.ranges === nothing) ? nothing :
            get(frame_agg.ranges, n, nothing)
        b = spec === nothing ? nothing : _recurrence_symbol_bounds(spec, file)
        push!(ranges_sig, b === nothing ? repr(spec) : b)
    end
    return (idx_names, ranges_sig, axis, sort!(unique(same_cell)))
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
    _walk_self_reference!(body, name, indexed, bare, Base.IdSet{OpExpr}())
    indexed[] && return :indexed
    bare[] && return :bare
    return :none
end

function _walk_self_reference!(
        e::ASTExpr, name::AbstractString,
        indexed::Ref{Bool}, bare::Ref{Bool}, seen::Base.IdSet{OpExpr}
    )
    if e isa VarExpr
        e.name == name && (bare[] = true)
        return nothing
    end
    e isa OpExpr || return nothing
    # A shared sub-DAG answers the same both times: walk each node once, or a
    # structurally shared body costs one walk per path.
    e in seen && return nothing
    push!(seen, e)
    # POSITIONAL, not identity-based: hash-consing shares leaf nodes, so the
    # `VarExpr` at `args[1]` may be the very same object as a bare read
    # elsewhere in the tree, and skipping "that object" would skip both.
    self_head = e.op == "index" && !isempty(e.args) &&
        e.args[1] isa VarExpr && (e.args[1]::VarExpr).name == name
    self_head && (indexed[] = true)
    for j in eachindex(e.args)
        (self_head && j == 1) && continue
        _walk_self_reference!(e.args[j], name, indexed, bare, seen)
    end
    for side in (e.expr_body, e.filter, e.key, e.lower, e.upper)
        side === nothing || _walk_self_reference!(side, name, indexed, bare, seen)
    end
    if e.values !== nothing
        for v in e.values
            _walk_self_reference!(v, name, indexed, bare, seen)
        end
    end
    if e.bindings !== nothing
        for k in sort!(collect(keys(e.bindings)))
            _walk_self_reference!(e.bindings[k], name, indexed, bare, seen)
        end
    end
    if e.ranges !== nothing
        for k in sort!(collect(keys(e.ranges)))
            v = e.ranges[k]
            v isa AbstractVector || continue
            for x in v
                x isa ASTExpr && _walk_self_reference!(x, name, indexed, bare, seen)
            end
        end
    end
    return nothing
end
