# ========================================================================
# pushdown_rewrite.jl — the AUTOMATIC projection-pushdown DESUGAR.
#
# A pre-build model-transform pass that recognises the ISRM-shaped
# `+`-semiring "apply a provider-backed full-domain array to a sparsely
# supported binned factor" pattern in a CLEAN model, and AUTO-GENERATES the
# four constructs an author could otherwise write by hand (derived IndexSet +
# `distinct` producer + member_factor + gated_select), which the build then
# runs like authored ones. The author writes NO derived set, NO producer, and
# NO gated_select — only the natural math.
#
# This is a NARROW desugarer (a pattern recogniser), NOT a general optimizer.
# It fires ONLY when the reduction's semiring is the additive `(+, 0)` monoid
# (`_aggregate_oplus_identity == ("+", 0.0)`); a `max_product` / `min_sum` /
# etc. aggregate of the SAME shape is left untouched (the soundness guard).
#
# Run by `esm_problem(…; pushdown_rewrite = true)` on the authored document
# before it is flattened (and by the native-document build door,
# `_build_evaluator(esm; pushdown_rewrite = true)`), so value invention and the
# build both see the generated constructs. Off by default.
# ========================================================================

"""
    desugar_pushdown(esm::AbstractDict; model_name=nothing) -> AbstractDict

Recognise the projection-pushdown pattern in `esm`'s named model and, when it
matches, return a NEW document with the four constructs desugared in
(a `kind:"derived"` index set, a `distinct:true` overlap-gated producer
aggregate, a `member_factor` const parameter, and an inspectable
`gated_select` record) plus the reduction axis of the matched E / A / conc
nodes re-pointed onto the generated derived set. Returns `esm` UNCHANGED when
no model is selected, the pattern does not match, or the reduction's semiring
is not the additive `(+, 0)` monoid (the soundness guard).

The pattern (narrow):

  conc[rcv] = Σ_{s∈C} A[s,rcv] · E[s]        (a `+`-semiring aggregate)

where `A` is a provider-backed full-domain parameter shaped `[C, rcv]`, and
`E` is an observed shaped `[C]` whose own definition is a `+`-aggregate that
BINS records into cells with a containment / overlap predicate
(`E[c] = Σ_r [contains(cell_c, pt_r)] · …`) — so `E`'s support is the distinct
cells that contain ≥1 record, derivable at const time.
"""
function desugar_pushdown(esm::AbstractDict; model_name = nothing)
    # IDEMPOTENCY GUARD: a document that already carries the rewrite's
    # provenance record (`metadata.x_esd.pushdown`) has been desugared — the
    # generated constructs (compact E over the derived set, cell-gather rect
    # observeds) would otherwise re-match the pattern and stack a second
    # `pd_support__pd_support__…` layer. This makes the pass safe to request
    # from BOTH `esm_problem` (which runs it before flattening/provider
    # classification) and the `_build_evaluator` front door.
    _pushdown_record(esm) === nothing || return esm
    an = _pd_analyze(esm, model_name)
    an === nothing && return esm
    # RESIDUAL DIAGNOSTICS (CONFORMANCE_SPEC §5.5.7 "residual diagnostic"): a
    # join-shaped aggregate the recogniser could NOT read is reported here, not
    # swallowed. See `_pd_binning_refusal` for the "not a join" / "a join I could
    # not read" split, and `pushdown_diagnostics` for the inspectable form.
    for d in an.diagnostics
        @warn _pd_diagnostic_message(d)
    end
    an.plan === nothing && return esm
    return _pd_apply(esm, an.mname, an.plan, an.registry)
end

"""
    pushdown_diagnostics(esm::AbstractDict; model_name=nothing) -> Vector{Dict{String,Any}}

The residual diagnostics [`desugar_pushdown`](@ref) would emit for `esm` — one
record per aggregate that IS join-shaped (it bins records into the cells of an
index set and feeds a provider-backed rank-2 array through a `+`-semiring
mat-vec) but whose containment predicate the recogniser could not read, so the
rewrite does not fire for it and that array is fetched WHOLESALE.

Inspectable, side-effect-free counterpart of the `@warn` stream: same records,
same order (sorted by `variable`, `consumer`, `array`), stable field set
(`code`, `variable`, `consumer`, `array`, `index_set`, `reason`, `template`,
`consequence`), pinned across bindings by the `tests/conformance/pushdown/`
corpus. Empty for a document that already carries the rewrite record, for one
with no model selected, and — deliberately — for one that simply is NOT
join-shaped: "no join here" is not a defect.
"""
function pushdown_diagnostics(esm::AbstractDict; model_name = nothing)
    _pushdown_record(esm) === nothing || return Dict{String, Any}[]
    an = _pd_analyze(esm, model_name)
    return an === nothing ? Dict{String, Any}[] : an.diagnostics
end

# The ONE detection entry point shared by `desugar_pushdown` (which then emits)
# and `pushdown_diagnostics` (which only reports). Returns `nothing` when no
# model is selected; otherwise the plan (`nothing` ⇒ the pattern did not match),
# the residual diagnostics, the model name, and the component template registry
# the emission side reads template bodies from (never to expand a reference).
function _pd_analyze(esm::AbstractDict, model_name)
    file = _coerce_or_load(esm)
    m = _select_model_or_nothing(file, model_name)
    m === nothing && return nothing
    mname = _pd_model_name(file, model_name)
    mname === nothing && return nothing
    reg = _pd_registry(file, mname)
    defs = observed_definitions(m)
    plan, diags = _pd_detect(m, defs, file.index_sets; tt = _pd_template_table(reg, defs))
    return (plan = plan, diagnostics = diags, mname = mname, registry = reg)
end

"""
    _pushdown_record(doc) -> Union{Nothing,AbstractDict}

The rewrite's provenance record `metadata.x_esd.pushdown` written by
[`desugar_pushdown`](@ref) (see `_pd_apply`), or `nothing` when `doc` carries
none. This is the record `esm_problem(...; pushdown_rewrite=true)` reads back
to derive provider gates."""
function _pushdown_record(doc::AbstractDict)
    md = get(doc, "metadata", nothing)
    md isa AbstractDict || return nothing
    xe = get(md, "x_esd", nothing)
    xe isa AbstractDict || return nothing
    rec = get(xe, "pushdown", nothing)
    return rec isa AbstractDict ? rec : nothing
end

_pd_model_name(file, model_name) = model_name !== nothing ? String(model_name) :
    (
        file.models !== nothing && length(file.models) == 1 ?
        String(first(keys(file.models))) : nothing
    )

# ---- detection through template references (esm-spec §9.6.4 rule 2) -------
#
# `load` PRESERVES `apply_expression_template` references, so `esm_problem`
# hands `desugar_pushdown` a document whose binning body may be a surviving
# reference rather than the containment `ifelse` the recogniser looks for.
#
# §9.6.4 rule 4 ("patterns do not see through surviving references") governs
# the §9.6.3 REWRITE-RULE ENGINE. `desugar_pushdown` is a different consumer,
# and rule 2 governs it: a reference DENOTES its expansion. Whether the pushdown
# fires MUST NOT depend on whether the author factored the binning body through
# a template — so the pattern is matched THROUGH references, without expanding
# them: at a reference the matcher reads the template's own body in the
# reference's frame (templates/frames.jl `_tpl_frame`), and at a parameter (or
# implicit parameter) of that body it reads the call site's binding, in the
# caller's frame. A name the matcher accepts — an array or a loop symbol of the
# aggregate — must read as a name of the model's own tree (frame `nothing`): a
# name bound inside a body is the body's own and never one of them.
#
# Emission does not read bodies either: `_pd_apply` edits the call site's
# `bindings` (and the aggregate's own `ranges`/`args`/`shape`/`join`), never the
# shared template body, so the body stays shared and singly-lowered.
# `_pd_assert_rects_rebound` is the post-condition that proves it.

# The component template registry for `mname`, or `nothing` when the document
# carries no surviving references (`coerce_esm_file` fills `component_templates`
# from each component's materialized `expression_templates` block).
_pd_registry(file::EsmFile, mname::AbstractString) =
    file.component_templates === nothing ? nothing :
    get(file.component_templates, "models." * String(mname), nothing)

# Does `e` carry a surviving `apply_expression_template` reference? `child_exprs`
# traverses `bindings` VALUES too, so a reference nested in another reference's
# bindings counts.
function _pd_has_apply(e)::Bool
    e isa OpExpr || return false
    e.op == APPLY_EXPRESSION_TEMPLATE_OP && return true
    for c in child_exprs(e)
        _pd_has_apply(c) && return true
    end
    return false
end

# The template table detection reads references through: `nothing` when there
# is no registry or no definition carries a reference (every read below is then
# the plain tree read).
_pd_template_table(reg, defs::AbstractDict) =
    (reg === nothing || !any(_pd_has_apply, values(defs))) ? nothing : _TplTable(reg)

"""
    _pd_open(tt, e, fr) -> (e, fr)

`e` read in frame `fr` (`nothing`: the model's own tree), through the template
references: a parameter sentinel of a body is read as the call site's binding
in the caller's frame, and a reference as its template's body in the
reference's frame (`_tpl_frame`, one per instance). A reference that cannot be
read (an unresolvable template, a bindings mismatch — `desugar_pushdown` is
callable on a raw document that never went through `load`'s §9.6.9 call-site
checks) is returned as it is: the pass's contract is to leave a document it
cannot recognise unchanged, and `_pd_binning_refusal` reports the reference if
the definition is join-shaped. With `tt === nothing` a reference is never
entered.
"""
function _pd_open(tt, e::ASTExpr, fr)
    while true
        if fr !== nothing && e isa VarExpr && _tpl_is_sentinel(e.name)
            e, fr = _tpl_arg(fr, e.name)
        elseif tt !== nothing && _tpl_is_call(e)
            sub = try
                _tpl_frame(tt, e, fr)
            catch err
                err isa ExpressionTemplateError || rethrow()
                return (e, fr)
            end
            e, fr = sub.body, sub
        else
            return (e, fr)
        end
    end
end

# The name `e` reads as a name of the model's own tree, or `nothing`.
function _pd_name(tt, e::ASTExpr, fr)
    x, xf = _pd_open(tt, e, fr)
    return (x isa VarExpr && xf === nothing) ? x.name : nothing
end

# The `name` of the first reference in `e` (pre-order, read through the
# references) that cannot be read, for the residual diagnostic; `nothing` when
# there is none.
function _pd_first_apply_name(tt, e::ASTExpr, fr)
    x, xf = _pd_open(tt, e, fr)
    x isa OpExpr || return nothing
    _tpl_is_call(x) && return x.name
    for c in child_exprs(x)
        r = _pd_first_apply_name(tt, c, xf)
        r === nothing || return r
    end
    return nothing
end

# ---- typed-IR leaf helpers -------------------------------------------------

"""
    _pd_cell_factors!(e, c_sym, vars, C, out, bad, tt = nothing)

Walk a binning body and record into `out` EVERY array it reads at a position on
the cell axis — not only the envelope factors of the containment predicate —
mapping each to its declared shape. Ungatherable reads land in `bad`.

The rewrite re-points the aggregate's reduction range onto the compact derived
support set, so from that moment `c_sym` counts support positions, not grid
cells. Any array still indexed by it that was NOT re-pointed then reads
full-grid values at support positions: WRONG NUMBERS, no diagnostic. `out` is
exactly the set that must be gathered.

Membership is decided by the DECLARATION, not by the subscript: an array is on
the cell axis iff its declared `shape[1]` is the cell index set `C`. That is
what keeps a flat-offset gather into a DIFFERENT axis — the
`index(Temperature, layer * N_SRC + c)` spelling a layered met read wants, whose
base is declared over the full `[all_cells]` axis — out of the map: it is not on
the cell axis, it stays full-grid, and it is still correct after the rewrite
because nothing about it moved.

Three subscript shapes on a cell-axis array, and they are not alike:

  `index(F, c)`           the whole trailing slice at cell `c` — a rank-3 ring
                          stack read as a polygon operand. Gatherable.
  `index(F, c, v, d)`     a fully-subscripted scalar read. Gatherable, and by the
                          SAME gather: the generated array keeps `F`'s rank, so
                          both spellings survive the substitution of the name.
  `index(F, <expr in c>)` arithmetic on the cell position. NOT gatherable — the
                          compact axis is a renumbering, so `c+1` means nothing
                          in it. Recorded in `bad`.

A cell-axis array indexed WITHOUT the cell symbol is deliberately left alone: it
still reads the full-grid array at a full-grid position, which the rewrite does
not disturb.
"""
function _pd_cell_factors!(
        e, c_sym::AbstractString, vars::AbstractDict,
        C::AbstractString, out::AbstractDict, bad::AbstractDict, tt = nothing
    )
    e isa ASTExpr || return nothing
    # One visit per node of the tree and per node of each template instance it
    # reaches (each instance body once, `_tpl_foreach_node`); a body's reads
    # are read through its frame.
    visit = function (node, fr)
        (node isa OpExpr && node.op == "index" && length(node.args) >= 2) || return
        F = _pd_name(tt, node.args[1], fr)
        F === nothing && return
        v = get(vars, F, nothing)
        shp = v === nothing ? nothing : v.shape
        (shp !== nothing && !isempty(shp) && String(shp[1]) == C) || return
        sub = node.args[2]
        if _pd_name(tt, sub, fr) == c_sym
            haskey(out, F) || (out[F] = String[String(x) for x in shp])
        elseif _pd_mentions_sym(tt, sub, fr, c_sym)
            haskey(bad, F) || (bad[F] = _pd_subscript_sketch(tt, sub, fr))
        end
        return
    end
    if tt === nothing
        foreach_subexpr(x -> visit(x, nothing), e)
    else
        _tpl_foreach_node(visit, tt, e)
    end
    return nothing
end

# Does `e` (read in frame `fr`) reference the loop symbol `sym` anywhere?
function _pd_mentions_sym(tt, e::ASTExpr, fr, sym::AbstractString)::Bool
    x, xf = _pd_open(tt, e, fr)
    x isa VarExpr && return xf === nothing && x.name == sym
    x isa OpExpr || return false
    for c in child_exprs(x)
        _pd_mentions_sym(tt, c, xf, sym) && return true
    end
    return false
end

# A one-line rendering of a subscript expression, for the refusal message.
function _pd_subscript_sketch(tt, e::ASTExpr, fr)
    e, fr = _pd_open(tt, e, fr)
    e isa VarExpr && return String(e.name)
    e isa NumExpr && return string(e.value)
    e isa IntExpr && return string(e.value)
    e isa OpExpr || return "?"
    if e.op == "index"
        return _pd_subscript_sketch(tt, e.args[1], fr) * "[" *
            join((_pd_subscript_sketch(tt, a, fr) for a in e.args[2:end]), ", ") * "]"
    end
    return String(e.op) * "(" * join((_pd_subscript_sketch(tt, a, fr) for a in e.args), ", ") * ")"
end

# index(F, sym) with EXACTLY one index → (F, sym); else nothing. Read in frame
# `fr` through the references (`_pd_open`).
function _pd_index_split(tt, e::ASTExpr, fr)
    e, fr = _pd_open(tt, e, fr)
    (e isa OpExpr && e.op == "index" && length(e.args) == 2) || return nothing
    f = _pd_name(tt, e.args[1], fr); s = _pd_name(tt, e.args[2], fr)
    (f === nothing || s === nothing) && return nothing
    return (f, s)
end

# index(F, sym…) with ≥1 index → (F, [syms…]); else nothing. Read as above.
function _pd_index_syms(tt, e::ASTExpr, fr)
    e, fr = _pd_open(tt, e, fr)
    (e isa OpExpr && e.op == "index" && length(e.args) >= 2) || return nothing
    f = _pd_name(tt, e.args[1], fr); f === nothing && return nothing
    syms = String[]
    for a in @view e.args[2:end]
        s = _pd_name(tt, a, fr); s === nothing && return nothing
        push!(syms, s)
    end
    return (f, syms)
end

# SHARED linear-mat-vec body predicate — also reused by the BLAS
# accelerator (`_evaluate_cellwise_blas`, inline_tests.jl). Classify an
# aggregate BODY `A[c, out…] · E[c]` — a two-factor `⊗=·` product of a
# rank-(1+|out|) array factor `A` subscripted `[c, out…]` (contracted index first,
# then the output indices in order) and a rank-1 factor `E` subscripted `[c]` —
# into `(Aname, Ename)`, or `nothing` when `body` is not that exact shape.
# `c_sym` is the contracted index and `out_syms` the ordered output indices. This
# is a PURE STRUCTURAL check on index symbols; it neither inspects factor values
# nor the semiring (callers apply the additive `(+,0)` semiring guard themselves).
#
# `tt`/`fr` read the body through template references (`_pd_open`); the
# three-argument form reads the plain tree.
_pd_matvec_factors(body, c_sym::AbstractString, out_syms::AbstractVector{<:AbstractString}) =
    _pd_matvec_factors(nothing, body, nothing, c_sym, out_syms)
function _pd_matvec_factors(
        tt, body, fr, c_sym::AbstractString,
        out_syms::AbstractVector{<:AbstractString}
    )
    body isa ASTExpr || return nothing
    body, fr = _pd_open(tt, body, fr)
    (body isa OpExpr && body.op == "*" && length(body.args) == 2) || return nothing
    isempty(out_syms) && return nothing
    parts = Any[_pd_index_syms(tt, a, fr) for a in body.args]
    any(p -> p === nothing, parts) && return nothing
    A_syms = String[String(c_sym)]
    append!(A_syms, (String(s) for s in out_syms))
    E_syms = String[String(c_sym)]
    Aname = nothing; Ename = nothing
    for p in parts
        f, syms = p
        if syms == A_syms
            Aname = f
        elseif syms == E_syms
            Ename = f
        end
    end
    (Aname === nothing || Ename === nothing) && return nothing
    return (Aname, Ename)
end

# (⊕ spelling, 0̄) for an aggregate node, or `nothing` on an unknown semiring.
# The node's ⊕ and 0̄, or `nothing` for a semiring or reducer the registry
# refuses (the rewrite then leaves the node alone, and the build reports it).
function _pd_oplus(agg::OpExpr)
    return try
        _aggregate_oplus_identity(agg.semiring, agg.reduce)
    catch err
        err isa EarthSciASTError || rethrow()
        nothing
    end
end

_pd_flip(op) = op == "<" ? ">" : op == "<=" ? ">=" : op == ">" ? "<" : "<="

# Find the condition of the first `ifelse(cond, then, else)` in a typed subtree
# read in frame `fr` through the template references (`_pd_open`): the
# condition and the frame it is read in, or `nothing`.
function _pd_find_ifelse_cond(tt, e::ASTExpr, fr)
    e, fr = _pd_open(tt, e, fr)
    e isa OpExpr || return nothing
    (e.op == "ifelse" && length(e.args) == 3) && return (e.args[1], fr)
    for a in e.args
        r = _pd_find_ifelse_cond(tt, a, fr)
        r === nothing || return r
    end
    e.expr_body === nothing || (r = _pd_find_ifelse_cond(tt, e.expr_body, fr); r === nothing || return r)
    return nothing
end

# Parse a containment predicate — an `and`/`*` of comparisons, each between a
# factor subscripted by `c_sym` and a factor subscripted by `r_sym` — into the
# §5.5.6 overlap-gate envelopes `(src_env, tgt_env)`, where `src_env` is the
# `r_sym` side and `tgt_env` the `c_sym` side. TWO predicate shapes are read,
# distinguished by how many DISTINCT `r_sym`-side factors appear and how many
# `c_sym`-side bounds each one carries:
#
#   POINT-IN-RECT     2 factors, each with a min AND a max bound
#                     src_env = [Px, Py]                     (point coordinates)
#                     tgt_env = [xmin, ymin, xmax, ymax]     (the rect bounds)
#
#   ENVELOPE-OVERLAP  4 factors, each with EXACTLY ONE bound — the AABB test
#                     `cxmin ≤ rxmax ∧ rxmin ≤ cxmax ∧ cymin ≤ rymax ∧ rymin ≤ cymax`
#                     src_env = [rxmin, rymin, rxmax, rymax]
#                     tgt_env = [cxmin, cymin, cxmax, cymax]
#
# Either way a bound's KIND comes from the ORIENTATION of its comparison, not
# from the authored order: `Fc < Fp` (after normalising the cell factor to the
# left) makes `Fc` a LOWER bound of `Fp`, `Fp < Fc` an upper one. So the four
# comparisons may be written in any order and either direction.
#
# **Which factors share an axis is decided by appearance order, and that choice
# is free.** In the envelope shape the predicate is a perfect matching between
# the four cell factors and the four record factors, and NOTHING in it says
# which two comparisons are the x-axis pair — `(cxmin≤rxmax, rxmin≤cxmax)` and
# `(cxmin≤rxmax, rymin≤cymax)` are structurally indistinguishable groupings. It
# does not matter: §5.5.6's broad phase is the CONJUNCTION of the same four
# inequalities whichever grouping is chosen, because each emitted inequality
# pairs an envelope entry with the partner it was matched to here. Any pairing
# that puts one lower and one upper bound in each axis therefore re-emits
# exactly the authored predicate; the axis LABELS are a relabelling the AABB
# test is invariant under. Appearance order is used because it is deterministic.
#
# Returns `nothing` (⇒ no match) on any other shape.
#
# `pred` is read in frame `fr` through the template references (`_pd_open`).
function _pd_parse_containment(tt, pred, fr, c_sym::AbstractString, r_sym::AbstractString)
    pred isa ASTExpr || return nothing
    pred, fr = _pd_open(tt, pred, fr)
    pred isa OpExpr || return nothing
    comps = pred.op in ("and", "*") ? pred.args : ASTExpr[pred]
    bounds = Dict{String, Dict{Symbol, String}}()
    rec_order = String[]
    for cmp0 in comps
        cmp, cf = _pd_open(tt, cmp0, fr)
        (cmp isa OpExpr && cmp.op in ("<", "<=", ">", ">=") && length(cmp.args) == 2) || return nothing
        s1 = _pd_index_split(tt, cmp.args[1], cf); s2 = _pd_index_split(tt, cmp.args[2], cf)
        (s1 === nothing || s2 === nothing) && return nothing
        f1, sym1 = s1; f2, sym2 = s2
        local Fc, Fp, cell_on_left
        if sym1 == c_sym && sym2 == r_sym
            Fc, Fp, cell_on_left = f1, f2, true
        elseif sym1 == r_sym && sym2 == c_sym
            Fc, Fp, cell_on_left = f2, f1, false
        else
            return nothing
        end
        opn = cell_on_left ? cmp.op : _pd_flip(cmp.op)   # normalise to `Fc <opn> Fp`
        kind = opn in ("<", "<=") ? :min : :max          # Fc is a lower/upper bound of Fp
        haskey(bounds, Fp) || (push!(rec_order, Fp); bounds[Fp] = Dict{Symbol, String}())
        haskey(bounds[Fp], kind) && return nothing       # one bound of each kind per factor
        bounds[Fp][kind] = Fc
    end
    nbound(P) = length(bounds[P])
    if length(rec_order) == 2 && all(P -> nbound(P) == 2, rec_order)
        Px, Py = rec_order[1], rec_order[2]
        return (
            src_env = String[Px, Py],
            tgt_env = String[
                bounds[Px][:min], bounds[Py][:min],
                bounds[Px][:max], bounds[Py][:max],
            ],
        )
    elseif length(rec_order) == 4 && all(P -> nbound(P) == 1, rec_order)
        # A record factor carrying a LOWER cell bound (`cmin ≤ r`) is that
        # axis's record MAXIMUM, and vice versa — the AABB test compares each
        # side's min against the other side's max.
        his = String[P for P in rec_order if haskey(bounds[P], :min)]
        los = String[P for P in rec_order if haskey(bounds[P], :max)]
        (length(his) == 2 && length(los) == 2) || return nothing
        return (
            src_env = String[los[1], los[2], his[1], his[2]],
            tgt_env = String[
                bounds[his[1]][:min], bounds[his[2]][:min],
                bounds[los[1]][:max], bounds[los[2]][:max],
            ],
        )
    end
    return nothing
end

# Is `ev` a BINNING aggregate — a `+`-semiring reduction over TWO 1-D index
# sets whose body carries a containment predicate between CELL-indexed and
# RECORD-indexed factors (either shape `_pd_parse_containment` reads)? BOTH
# orientations are recognised (§5.5.6 "recognised desugar patterns"):
#
#   FORWARD  E[c] = Σ_r [contains(cell_c, rec_r)] · …    (the cell axis is output)
#   MIRROR   P[r] = Σ_c [contains(cell_c, rec_r)] · …    (the record axis is output)
#
# The gate is IDENTICAL either way — the enumeration driver binds its two
# symbols from the join clause's declared envelopes and knows nothing about
# cells vs records, and the aggregate's own `output_idx` decides the result's
# orientation. So the guards here are on the aggregate's SHAPE, not on which
# axis is which: `out_set` is the index set the observed is shaped on, and the
# single other range supplies the opposite side.
#
# For a POINT-IN-RECT predicate the predicate itself also says which symbol is
# the cell — it carries the four rect BOUND factors, against the record's two
# point coordinates. An ENVELOPE-OVERLAP predicate is symmetric and says no such
# thing, so a caller that knows passes `out_is_cell`.
#
# Returns `(c_sym, r_sym, C, R, out_is_cell, src_env, tgt_env)` or `nothing`.
# `agg` is the observed unknown's DEFINING EQUATION RHS (esm-spec §6.3.1),
# supplied by the caller from `observed_definitions`: a variable
# carries no expression of its own, so a non-observed variable simply has no
# definition to pass and never reaches here.
# The shape every pushdown read starts from: a `+`-semiring `faq` (0̄ = 0) with
# one output index and exactly two ranges, both over named index sets.
# `(out_sym, in_sym, out_set, in_set)`, or `nothing`.
function _pd_join_shape(agg)
    (agg isa OpExpr && _is_faq_op(agg.op)) || return nothing
    oz = _pd_oplus(agg); oz === nothing && return nothing
    (oz[1] == "+" && oz[2] == 0.0) || return nothing              # SEMIRING GUARD
    oi = agg.output_idx
    (oi !== nothing && length(oi) == 1) || return nothing
    out_sym = String(oi[1])
    ranges = agg.ranges === nothing ? Dict{String, Any}() : agg.ranges
    (length(ranges) == 2 && haskey(ranges, out_sym)) || return nothing
    in_sym = ""
    for k in keys(ranges)
        k == out_sym || (in_sym = String(k))
    end
    (ranges[out_sym] isa IndexSetRef && ranges[in_sym] isa IndexSetRef) || return nothing
    return (;
        out_sym, in_sym, out_set = String(ranges[out_sym].from),
        in_set = String(ranges[in_sym].from),
    )
end

# A rank-1 variable over `out_set` defined by a join-shaped aggregate whose
# output range is `out_set`: the aggregate's join shape, else `nothing`.
function _pd_binning_shape(
        ev::ModelVariable, agg::Union{ASTExpr, Nothing}, out_set::AbstractString
    )
    (ev.shape !== nothing && length(ev.shape) == 1 && ev.shape[1] == out_set) || return nothing
    js = _pd_join_shape(agg)
    (js !== nothing && js.out_set == out_set) || return nothing
    return js
end

function _pd_detect_binning(
        ev::ModelVariable, agg::Union{ASTExpr, Nothing},
        out_set::AbstractString;
        out_is_cell::Union{Bool, Nothing} = nothing, tt = nothing
    )
    js = _pd_binning_shape(ev, agg, out_set)
    js === nothing && return nothing
    out_sym, in_sym, in_set = js.out_sym, js.in_sym, js.in_set
    body = (agg::OpExpr).expr_body
    body isa ASTExpr || return nothing
    found = _pd_find_ifelse_cond(tt, body, nothing)
    found === nothing && return nothing
    pred, pfr = found
    # For a POINT-IN-RECT predicate exactly one of the two assignments parses —
    # `_pd_parse_containment` demands the record side yield two coordinates each
    # with a min AND a max cell bound, which the rect side cannot do. An
    # ENVELOPE-OVERLAP predicate is SYMMETRIC and parses BOTH ways, so the
    # predicate alone does not say which symbol is the cell. `out_is_cell`
    # lets a caller that already knows say so: the forward arm's cell set comes
    # from the mat-vec array's first axis, and mirrors are collected only after
    # `C`/`R` are fixed. Left `nothing` (the point case, and the forward arm's
    # unhinted call) the out-as-cell reading is preferred.
    if out_is_cell !== false
        env = _pd_parse_containment(tt, pred, pfr, out_sym, in_sym)
        env === nothing || return (
            c_sym = out_sym, r_sym = in_sym,
            C = String(out_set), R = in_set, out_is_cell = true,
            src_env = env.src_env, tgt_env = env.tgt_env,
        )
    end
    out_is_cell === true && return nothing
    env = _pd_parse_containment(tt, pred, pfr, in_sym, out_sym)
    env === nothing && return nothing
    return (
        c_sym = in_sym, r_sym = out_sym, C = in_set, R = String(out_set),
        out_is_cell = false, src_env = env.src_env, tgt_env = env.tgt_env,
    )
end

# ---- residual diagnostics --------------------------------------------------
#
# A pattern recogniser that declines SILENTLY is indistinguishable from one that
# fired — until, hours later, an ungated provider fetch runs the machine out of
# memory. These helpers make the residue loud, while keeping the two cases apart:
#
#   NOT A JOIN            — a `+`-aggregate with no containment predicate is a
#                           legitimately dense factor. Nothing to gate, no
#                           diagnostic. Firing here would cry wolf on every
#                           ordinary reduction in every document.
#   A JOIN I CANNOT READ  — the aggregate bins records into cells of the SAME
#                           set that indexes a provider-backed rank-2 array it
#                           feeds, but the containment predicate could not be
#                           recovered. THAT is reported.
#
# WARNING, not error, and deliberately so. `desugar_pushdown`'s contract — spelled
# in CONFORMANCE_SPEC §5.5.7 and asserted by the conformance adapters — is that a
# document it does not recognise comes back byte-identical; it is an OPTIMISATION
# pass that `esm_problem` runs over whole documents it does not own. Promoting "I did
# not recognise this" to a hard error would make an unrecognised-but-correct
# document unrunnable, and the recogniser is narrow enough (2-D rectangles, one
# cell set) that honest near-misses exist. The residue is a PERFORMANCE defect:
# the numbers stay right, the fetch gets big. A warning names it at the moment it
# is decided instead of at the memory failure.
#
# The one hard ERROR in this pass is `_pd_assert_rects_rebound`: there the rewrite
# HAS fired and a rect factor could not be re-pointed, which would make the
# gathered cell factors read full-grid positions — wrong NUMBERS, not slow ones.

const _PD_UNGATED_CONSEQUENCE =
    "the provider-backed array is fetched WHOLESALE — no derived support set " *
    "is produced and no gate is emitted"

"""
    _pd_binning_refusal(ev, agg, out_set) -> Union{Nothing,Tuple{String,Union{Nothing,String}}}

Why [`_pd_detect_binning`](@ref) refused `ev`, for a caller that has ALREADY
established `ev` sits in the join position (it is the rank-1 factor of a
`+`-semiring mat-vec against a provider-backed `[out_set, …]` array). `agg` is
`ev`'s DEFINING EQUATION RHS, read through its references with `tt`, exactly as
`_pd_detect_binning` received it; `nothing` (a variable that is not an observed
unknown, so has no definition) is never join-shaped.

`nothing` means `ev` is simply not join-shaped — no diagnostic is warranted.
Otherwise `(reason, template)`:

  * `("surviving_template_reference", name)` — the body carries no containment
    `ifelse` because it is (or hides) a surviving `apply_expression_template`
    reference that could not be read for matching;
  * `("predicate_unparsed", nothing)` — a containment `ifelse` was found but it
    did not read as a containment — point-in-rect or envelope
    overlap — in EITHER orientation.
"""
function _pd_binning_refusal(
        ev::ModelVariable, agg::Union{ASTExpr, Nothing},
        out_set::AbstractString; tt = nothing
    )
    _pd_binning_shape(ev, agg, out_set) === nothing && return nothing
    body = (agg::OpExpr).expr_body
    body isa ASTExpr || return nothing
    pred = _pd_find_ifelse_cond(tt, body, nothing)
    if pred === nothing
        tname = _pd_first_apply_name(tt, body, nothing)
        tname === nothing && return nothing        # no predicate at all ⇒ dense
        return ("surviving_template_reference", String(tname))
    end
    return ("predicate_unparsed", nothing)
end

"""
    _pd_diagnostic_message(d) -> String

The human-readable rendering of one `pushdown_diagnostics` record: what was
recognised, what could not be read, and what it costs.
"""
function _pd_diagnostic_message(d::AbstractDict)
    tpl = get(d, "template", nothing)
    why = get(d, "reason", "") == "surviving_template_reference" ?
        "its body carries a surviving `apply_expression_template` reference" *
        (tpl === nothing ? "" : " to '$(tpl)'") *
        " that could not be expanded for matching" :
        "its containment predicate did not read as a point-in-rectangle " *
        "containment (four cell-indexed rect bounds against two record-indexed " *
        "point coordinates) nor as an envelope-overlap one (four bounds on each side)"
    return "projection-pushdown desugar: '$(d["variable"])' is join-shaped — it bins " *
        "records into the cells of index set '$(d["index_set"])' and feeds the " *
        "provider-backed array '$(d["array"])' through '$(d["consumer"])' — but " *
        why * ", so the rewrite does NOT fire for it and " *
        _PD_UNGATED_CONSEQUENCE * ". Bind the containment's factors through the " *
        "template's params, or write the predicate longhand."
end

# One forward binning aggregate the rewrite re-points onto the derived set:
# `E[c] = Σ_r [contains(cell_c, pt_r)]·…`, its cell output symbol, and the
# envelopes of its gate (record side `src_env`, cell side `tgt_env`).
struct _PdBinning
    name::String
    cell_sym::String
    src_env::Vector{String}
    tgt_env::Vector{String}
end

# A mirrored per-record binning aggregate, which gets only the gate.
struct _PdMirror
    name::String
    src_env::Vector{String}
    tgt_env::Vector{String}
end

# What `_pd_detect` found and `_pd_apply` emits. `C` is the cell set, `R` the
# record set and `rcv_set` the provider arrays' second axis; `forward[1]` is
# the representative binning, whose predicate becomes the producer's filter and
# whose record symbol is `rep_rsym`.
struct _PdPlan
    C::String
    rcv_set::String
    R::String
    # (consumer, its reduction symbol over `C`)
    conc_specs::Vector{Tuple{String, String}}
    # The provider-backed arrays to gate.
    A_names::Vector{String}
    forward::Vector{_PdBinning}
    mirrors::Vector{_PdMirror}
    # Every array a binning body reads on the cell axis, name => declared
    # shape, and the ones that cannot be gathered, name => why.
    cell_factors::OrderedDict{String, Vector{String}}
    cell_bad::OrderedDict{String, String}
    rep_rsym::String
end

# The MIRRORED-orientation binning aggregates of a model: per-RECORD observeds
# `P[r] = Σ_{c∈C} [contains(cell_c, pt_r)] · …` over the plan's cell set `C` and
# record set `R`. Returned as `(name, src_env, tgt_env)` triples, sorted by name
# so the emitted document is identical across bindings and hash seeds.
#
# A mirror needs NOTHING but the gate — see the note on the mirrored arm in
# `_pd_apply`. Its cell axis stays the FULL `C`, so its envelope factors are the
# document's own const-array rects, unrewritten.
function _pd_mirror_specs(
        model::Model, obs_defs::AbstractDict,
        C::AbstractString, R::AbstractString, forward_names; tt = nothing
    )
    out = _PdMirror[]
    for (name, defn) in obs_defs
        name in forward_names && continue
        v = model.variables[name]
        bind = _pd_detect_binning(v, defn, R; out_is_cell = false, tt)
        bind === nothing && continue
        (!bind.out_is_cell && bind.C == C && bind.R == R) || continue
        # Never stack a second gate on an aggregate that already declares a join.
        (defn isa OpExpr && (defn::OpExpr).join !== nothing) && continue
        push!(out, _PdMirror(name, bind.src_env, bind.tgt_env))
    end
    sort!(out; by = m -> m.name)
    return out
end

# Detect the pushdown pattern across a model's observeds. `obs_defs` are the
# observed definitions (`observed_definitions`), read through their template
# references with the table `tt` (`_pd_open`; `nothing` when they carry none),
# so a binning body factored through a template matches exactly as its
# expansion would. `model` supplies the declarations beside them — shapes and
# types. Returns
# `(plan, diagnostics)` — `plan` `nothing` when nothing matches / the semiring
# guard fails, `diagnostics` the residual "a join I could not read" records
# (see `_pd_binning_refusal`).
function _pd_detect(model::Model, obs_defs::AbstractDict, index_sets::AbstractDict; tt = nothing)
    vars = model.variables
    diags = Dict{String, Any}[]
    conc_specs = Tuple{String, String}[]        # (conc name, reduction symbol)
    A_names = String[]                          # provider-backed arrays to gate
    forward = _PdBinning[]
    # EVERY array any binning body reads on the cell axis, name => declared
    # shape, and the ungatherable ones. The envelope factors are a SUBSET: a
    # binning body is free to read the cell's geometry, its area, its ring
    # stack, and all of them ride the same re-pointing (`_pd_cell_factors!`).
    cell_factors = OrderedDict{String, Vector{String}}()
    cell_bad = OrderedDict{String, String}()
    C = nothing; rcv_set = nothing; R = nothing; rep_rsym = nothing

    for (cname, agg) in obs_defs
        js = _pd_join_shape(agg)
        js === nothing && continue
        rcv_sym, s_sym, c_set, r_set = js.out_sym, js.in_sym, js.in_set, js.out_set
        facs = _pd_matvec_factors(tt, (agg::OpExpr).expr_body, nothing, s_sym, String[rcv_sym])
        facs === nothing && continue
        Aname, Ename = facs
        av = get(vars, Aname, nothing)
        (
            av !== nothing && av.type == ParameterVariable && av.shape !== nothing &&
                length(av.shape) == 2 && av.shape[1] == c_set && av.shape[2] == r_set
        ) || continue
        ev = get(vars, Ename, nothing); ev === nothing && continue
        edef = get(obs_defs, Ename, nothing)
        bind = _pd_detect_binning(ev, edef, c_set; tt)
        if bind === nothing || !bind.out_is_cell                  # FORWARD arm only
            # `ev` is the rank-1 factor of a `+`-mat-vec against a
            # provider-backed `[c_set, r_set]` array: the join position. If it is
            # ALSO binning-shaped but unreadable, say so — silence here means an
            # unpruned fetch that surfaces hours later as a memory failure.
            if bind === nothing
                why = _pd_binning_refusal(ev, edef, String(c_set); tt)
                why === nothing || push!(
                    diags, Dict{String, Any}(
                        "code" => "pushdown_join_unrecognised",
                        "variable" => String(Ename), "consumer" => String(cname),
                        "array" => String(Aname), "index_set" => String(c_set),
                        "reason" => why[1], "template" => why[2],
                        "consequence" => _PD_UNGATED_CONSEQUENCE
                    )
                )
            end
            continue
        end

        if C === nothing
            C = c_set; rcv_set = r_set; R = bind.R; rep_rsym = bind.r_sym
        else
            (c_set == C && r_set == rcv_set) || continue          # narrow: one cell set
        end
        push!(conc_specs, (cname, s_sym))
        Aname in A_names || push!(A_names, Aname)
        if !any(b -> b.name == Ename, forward)
            push!(forward, _PdBinning(Ename, bind.c_sym, bind.src_env, bind.tgt_env))
            # Read through the references, like every other pattern read: a
            # body factored through a template must yield the same gather set as
            # its longhand twin (esm-spec §9.6.4 rule 2). Emission still edits
            # the authored body / call-site bindings, and
            # `_pd_assert_rects_rebound` proves the substitution landed.
            _pd_cell_factors!(
                edef, bind.c_sym, vars, String(c_set),
                cell_factors, cell_bad, tt
            )
        end
    end
    # Deterministic, deduplicated diagnostic order: `vars` is a hash-ordered
    # Dict, and the same E can be reached from several `conc` consumers.
    sort!(diags; by = d -> (d["variable"], d["consumer"], d["array"]))
    unique!(d -> (d["variable"], d["consumer"], d["array"]), diags)
    isempty(conc_specs) && return (nothing, diags)
    # Deterministic plan order (cross-language goldens): `vars` is a
    # hash-ordered Dict, so the collection order of `A_names` above is a Julia
    # implementation detail. It leaks into the emitted document only through
    # `gated_select.applies_to` (everything else the plan orders is either
    # per-name or copied from the representative E, hence document-determined).
    # Sort it so the rewritten document — and the conformance goldens — are
    # identical across bindings and hash seeds. Consumers are membership-based
    # (`_pushdown_provider_gates`, `_fetch_gated_providers`), so order is inert.
    sort!(A_names)
    # MIRRORED-orientation binning aggregates (`P[r] = Σ_c […]`) over the SAME
    # cell/record sets. They are collected only once the forward pattern has
    # fixed `C`/`R`: the mirror is a rider on the rewrite, never its trigger.
    mirrors = _pd_mirror_specs(model, obs_defs, C, R, Set{String}(b.name for b in forward); tt)
    return (
        _PdPlan(
            C, rcv_set, R, conc_specs, A_names, forward, mirrors,
            cell_factors, cell_bad, rep_rsym
        ), diags,
    )
end

# ---- dict-form emission ----------------------------------------------------

# In-place: rewrite every `index(F, …)` whose factor `F` is a key of `rectmap`
# to `index(rectmap[F], …)` throughout a dict-form AST subtree.
#
# This walk descends EVERY dict value, `bindings` included, so a rect factor that
# reaches the binning body through an `apply_expression_template` call site is
# reached at the CALL SITE — which is exactly where the rewrite must land, so the
# shared template body stays untouched and singly-lowered (esm-spec §9.6.4
# Option B). Two binding spellings carry a rect factor and both are handled:
# a subscripted binding (`{"F": index(src_W, "c")}`) by the `index` arm above,
# and a BARE FACTOR-NAME binding (`{"F": "src_W"}`, substituted into the body's
# own `index(F, c)`) by the `bindings` arm below. A bare string is rewritten ONLY
# inside `bindings` — elsewhere a string is an `output_idx` entry, a range key, a
# scalar field or a template `name`, none of which are variable references.
function _pd_rewrite_rects!(node, rectmap::AbstractDict)
    if node isa AbstractDict
        if get(node, "op", nothing) == "index"
            a = get(node, "args", nothing)
            if a isa AbstractVector && !isempty(a) && a[1] isa AbstractString &&
                    haskey(rectmap, a[1])
                a[1] = rectmap[a[1]]
            end
        end
        if get(node, "op", nothing) == APPLY_EXPRESSION_TEMPLATE_OP
            b = get(node, "bindings", nothing)
            if b isa AbstractDict
                for k in collect(keys(b))
                    v = b[k]
                    v isa AbstractString && haskey(rectmap, v) && (b[k] = rectmap[v])
                end
            end
        end
        for (_, v) in node
            _pd_rewrite_rects!(v, rectmap)
        end
    elseif node isa AbstractVector
        for x in node
            _pd_rewrite_rects!(x, rectmap)
        end
    end
    return node
end

# The producer filter of the first dict-form `ifelse` node in `node` (pre-order),
# written in `node`'s own scope, or `nothing` when there is none: the
# comparisons of its condition (an `and`/`*` of them, or the one condition) as
# a `*`, deep-copied. An `ifelse` inside the body of a template `T` that a
# reference names (`reg`, the component registry) is not copied out of the
# body: the comparisons become the body of the DERIVED template `T__pd_filter`
# (registered in `derived`), written in `T`'s parameters, and the filter in
# `node`'s scope is a reference to it with the parameters it reads bound as
# the reference binds them. A containment nested several templates deep gets
# one derived template per template on the way, each body a reference to the
# next. No reference is expanded.
function _pd_filter_in(node, reg, derived::AbstractDict)
    if node isa AbstractDict
        op = get(node, "op", nothing)
        if op == "ifelse"
            a = get(node, "args", nothing)
            if a isa AbstractVector && length(a) == 3
                c = a[1]
                comps = (c isa AbstractDict && get(c, "op", nothing) in ("and", "*")) ?
                    c["args"] : Any[c]
                return OrderedDict{String, Any}(
                    "op" => "*", "args" => Any[_to_ordered(deepcopy(x)) for x in comps]
                )
            end
        elseif op == APPLY_EXPRESSION_TEMPLATE_OP && reg !== nothing
            name = get(node, "name", nothing)
            if name isa AbstractString && haskey(reg, name)
                decl = _TemplateDecl(reg[name])
                f = _pd_filter_in(decl.body, reg, derived)
                f === nothing || return _pd_filter_ref(String(name), decl.params, f, node, derived)
            end
        end
        for (_, v) in node
            r = _pd_filter_in(v, reg, derived)
            r === nothing || return r
        end
    elseif node isa AbstractVector
        for x in node
            r = _pd_filter_in(x, reg, derived)
            r === nothing || return r
        end
    end
    return nothing
end

# The derived template `<name>__pd_filter` with body `f` (written in the
# parameters of template `name`, declared `params`), registered in `derived`,
# and the reference to it at `call` (a reference to `name`): the parameters `f`
# reads, in declared order, each bound to `call`'s binding of it.
function _pd_filter_ref(name::String, params, f, call::AbstractDict, derived::AbstractDict)
    used = String[p for p in params if _pd_reads_param(f, p)]
    dname = name * "__pd_filter"
    derived[dname] = OrderedDict{String, Any}("params" => Any[used...], "body" => f)
    b = get(call, "bindings", nothing)
    bindings = OrderedDict{String, Any}(
        p => _to_ordered(deepcopy(b[p])) for p in used if b isa AbstractDict && haskey(b, p)
    )
    return OrderedDict{String, Any}(
        "op" => APPLY_EXPRESSION_TEMPLATE_OP, "name" => dname, "args" => Any[],
        "bindings" => bindings
    )
end

# Does the dict-form body `n` read the parameter `p`: a string leaf `p`
# anywhere but a reference's `name` (where template substitution, `_substitute`,
# puts a binding)?
function _pd_reads_param(n, p::AbstractString)::Bool
    n isa AbstractString && return n == p
    if n isa AbstractDict
        apply = get(n, "op", nothing) == APPLY_EXPRESSION_TEMPLATE_OP
        return any(kv -> !(apply && kv[1] == "name") && _pd_reads_param(kv[2], p), pairs(n))
    end
    n isa AbstractVector && return any(x -> _pd_reads_param(x, p), n)
    return false
end

# Register the derived filter templates in the model's `expression_templates`
# block. A name already declared there with a different declaration is refused
# rather than overwritten.
function _pd_register_derived!(model::AbstractDict, derived::AbstractDict, reg)
    isempty(derived) && return nothing
    blk = get(model, "operators", nothing)
    if !(blk isa AbstractDict)
        blk = OrderedDict{String, Any}()
        model["operators"] = blk
    end
    for (k, v) in derived
        old = get(blk, k, nothing)
        old === nothing && reg !== nothing && (old = get(reg, k, nothing))
        (old === nothing || _to_ordered(old) == v) || error(
            "projection-pushdown desugar: the derived producer-filter template '$(k)' " *
                "would replace a template of that name the document already declares"
        )
        blk[k] = v
    end
    return nothing
end

_pd_ix(f, idx...) = Dict{String, Any}("op" => "index", "args" => Any[f, idx...])

# One dict-form `join.overlap` clause (§5.5.6 wire form). `eps` is always 0.0:
# the rewrite derives the envelopes from an EXACT rectangle-containment
# predicate that stays on as the narrow `filter`, so no FP slack is wanted.
_pd_overlap_clause(src_env, tgt_env) =
    Dict{String, Any}(
    "overlap" => Dict{String, Any}(
        "src_env" => Any[String(f) for f in src_env],
        "tgt_env" => Any[String(f) for f in tgt_env],
        "eps" => 0.0
    )
)

# Does a dict-form subtree carry an `apply_expression_template` reference?
function _pd_dict_has_apply(node)::Bool
    if node isa AbstractDict
        get(node, "op", nothing) == APPLY_EXPRESSION_TEMPLATE_OP && return true
        return any(_pd_dict_has_apply, values(node))
    elseif node isa AbstractVector
        return any(_pd_dict_has_apply, node)
    end
    return false
end

# Collect into `out` every factor name `F ∈ keys(rectmap)` that still appears in
# an `index(F, …)` position of a dict-form subtree — i.e. every occurrence
# `_pd_rewrite_rects!` targets but did not reach.
function _pd_collect_stale_rects!(node, rectmap::AbstractDict, out::Set{String})
    if node isa AbstractDict
        if get(node, "op", nothing) == "index"
            a = get(node, "args", nothing)
            if a isa AbstractVector && !isempty(a) && a[1] isa AbstractString &&
                    haskey(rectmap, a[1])
                push!(out, String(a[1]))
            end
        end
        for (_, v) in node
            _pd_collect_stale_rects!(v, rectmap, out)
        end
    elseif node isa AbstractVector
        for x in node
            _pd_collect_stale_rects!(x, rectmap, out)
        end
    end
    return out
end

"""
    _pd_assert_rects_rebound(expr, Ename, rectmap, reg)

POST-CONDITION of the forward arm's rect re-pointing, discharged on what the
rewritten aggregate `expr` reads (esm-spec §9.6.4 rule 2: a reference denotes
its expansion): its own `index` reads, and those of every template body it
reaches, each read through its frame (`_tpl_foreach_node`, the base of each
read through the call site's bindings) — never an expanded copy.

`E`'s reduction axis now ranges over the COMPACT derived support set, so every
rect reference in its body must have become the corresponding `pd_cell__*`
gather. The rewrite achieves that by editing the call site — `index` factors and
`bindings` values — which is what keeps the shared template body untouched. A
rect factor named FREE inside a template body is therefore unreachable: rewriting
it would mean rewriting the shared body, corrupting every other call site
(the generated producer `filter` among them, which must keep full-grid
references). Left alone it would index a compact per-support gather with
full-grid positions — WRONG NUMBERS, silently. So this is a hard error, and its
remedy is the one `flatten.jl`'s
`template_body_references_coupling_rewritten_variable` already prescribes: bind
the value through the template's params.
"""
function _pd_assert_rects_rebound(
        expr, Ename::AbstractString,
        rectmap::AbstractDict, reg
    )
    isempty(rectmap) && return
    stale = _pd_collect_stale_rects!(expr, rectmap, Set{String}())
    if reg !== nothing && _pd_dict_has_apply(expr)
        tt = _TplTable(reg)
        _tpl_foreach_node(tt, expression_from_json(expr)) do node, fr
            fr === nothing && return       # the tree's own reads: collected above
            (node isa OpExpr && node.op == "index" && !isempty(node.args)) || return
            F = _pd_name(tt, node.args[1], fr)
            (F !== nothing && haskey(rectmap, F)) && push!(stale, F)
            return
        end
    end
    isempty(stale) && return
    names = sort!(collect(stale))
    throw(
        ExpressionTemplateError(
            ERROR_CODES.OPERATOR_BODY_REFERENCES_PUSHDOWN_REWRITTEN_VARIABLE,
            "projection-pushdown desugar: the binning aggregate '$(Ename)' still reads " *
                "'$(join(names, "', '"))' after its reduction axis was re-pointed onto the " *
                "generated derived support set. Those references live in an expression-template " *
                "BODY, not in the call site's `bindings`, so the rewrite — which edits call " *
                "sites only, to keep the template body shared and singly-lowered " *
                "(esm-spec §9.6.4 Option B) — cannot re-point them, and they would index the " *
                "compact per-support cell gathers with full-grid positions. Bind the value " *
                "through the template's params, or write the binning body longhand."
        )
    )
end

"""
    _pd_definitions(eqs) -> Dict{String,Int}

Each name DEFINED by a bare-variable-LHS equation, mapped to that equation's
position in `eqs`.

An observed unknown's defining right-hand side lives in the model's `equations`
(esm-spec §6.3.1), so the desugar reads and rewrites a definition through this
index. The FIRST definition of a name wins, matching the classification.
"""
function _pd_definitions(eqs)
    idx = Dict{String, Int}()
    eqs isa AbstractVector || return idx
    for (i, eq) in enumerate(eqs)
        eq isa AbstractDict || continue
        lhs = get(eq, "lhs", nothing)
        lhs isa AbstractString || continue
        haskey(idx, String(lhs)) || (idx[String(lhs)] = i)
    end
    return idx
end

"""
    _pd_defining_rhs(eqs, defs, name) -> Any

The defining right-hand side of `name`, erroring with the desugar's own message
rather than a bare `KeyError` when the model does not define it.
"""
function _pd_defining_rhs(eqs, defs::Dict{String, Int}, name::AbstractString)
    i = get(defs, String(name), nothing)
    i === nothing && error(
        "pushdown desugar: '$(name)' has no defining equation " *
            "(an observed unknown is defined by a bare-variable-LHS " *
            "equation, esm-spec 6.3.1)"
    )
    return eqs[i]["rhs"]
end

"""
    _pd_canonicalize_equations!(model)

Order the rewritten model's `equations` deterministically: every equation whose
LHS is NOT a bare variable keeps its relative order and comes first (the
generated `distinct` producer is the only such equation the desugar adds), then
the bare-variable DEFINITIONS sorted by the name they define.

Equation order carries no semantics — classification is a property of the
equation SET, which `tests/conformance/classification/observed_chain` pins — but
the rewrite appends definitions while walking a `Dict`, so without a canonical
order the emitted document would vary with Julia's hash seed. The shared
`tests/conformance/pushdown/` goldens are committed in exactly this order.
"""
function _pd_canonicalize_equations!(model::AbstractDict)
    eqs = get(model, "equations", nothing)
    eqs isa AbstractVector || return model
    others = Any[]
    defs = Tuple{String, Any}[]
    for eq in eqs
        lhs = eq isa AbstractDict ? get(eq, "lhs", nothing) : nothing
        if lhs isa AbstractString
            push!(defs, (String(lhs), eq))
        else
            push!(others, eq)
        end
    end
    sort!(defs; by = first)
    model["equations"] = Any[others...; (e for (_, e) in defs)...]
    return model
end

"""
    _pd_gather_defn(F, shape, setname, mfactor, index_sets, C) -> (decl, defn)

The `(variable declaration, defining aggregate)` for one per-support cell gather
`pd_cell__C__F`, RANK-PRESERVING.

Rank 1 — the envelope factors — emits exactly what it always did:

    pd_cell__C__F[c] = F[member_factor[c]]

Rank k keeps every trailing axis, so a `[cells, vertex, xy]` ring stack comes out
as a `[support, vertex, xy]` ring stack and every use of it survives the rename
unchanged — the sliced polygon-operand form `index(F, c)` and the
fully-subscripted scalar form alike:

    pd_cell__C__F[c, t0, t1] = F[member_factor[c], t0, t1]

This is a map, not a reduction: every range appears in `output_idx`. The trailing
loop symbols are named `pd_t0…` rather than reusing the document's own, because
the gather is generated in its own scope and a collision with an authored symbol
would be a silent capture.
"""
function _pd_gather_defn(
        F::AbstractString, shape::AbstractVector,
        setname::AbstractString, mfactor::AbstractString,
        index_sets, C::AbstractString
    )
    decl = Dict{String, Any}(
        "type" => "unknown",
        "shape" => Any[setname; Any[String(t) for t in shape[2:end]]...]
    )
    syms = String["pd_t" * string(i - 1) for i in 1:(length(shape) - 1)]
    ranges = Dict{String, Any}("c" => Dict{String, Any}("from" => setname))
    for (sym, t) in zip(syms, shape[2:end])
        (index_sets isa AbstractDict && haskey(index_sets, String(t))) || error(
            "projection-pushdown desugar: cannot gather '$(F)' onto the derived " *
                "support set of '$(C)'. Its declared shape is $(shape), whose trailing " *
                "entry '$(t)' is not a named index set, so the generated gather has no " *
                "range to iterate it over. Declare the array's trailing axes as index " *
                "sets, or keep the value off the cell axis."
        )
        ranges[sym] = Dict{String, Any}("from" => String(t))
    end
    defn = Dict{String, Any}(
        "op" => "faq", "output_idx" => Any[Any["c"]; Any[s for s in syms]...],
        "ranges" => ranges, "args" => Any[F, mfactor],
        "expr" => _pd_ix(F, _pd_ix(mfactor, "c"), syms...)
    )
    return (decl, defn)
end

"""
    _pd_refuse_ungatherable(bad, C, setname)

Refuse, loudly, when a binning body reads a cell-axis array at a computed cell
position. See [`_pd_cell_factors!`](@ref) for why it cannot be re-pointed.

A hard error, not a warning, and not a silent decline. The pattern HAS matched:
an aggregate reading a cell-axis array at `c+1` cannot be gated at all without
renumbering arithmetic the compact axis does not admit, and emitting the rewrite
anyway is the silent-wrong-numbers failure this pass exists to prevent.
"""
function _pd_refuse_ungatherable(
        bad::AbstractDict, C::AbstractString,
        setname::AbstractString
    )
    isempty(bad) && return nothing
    detail = join(("'$(F)' at [$(bad[F])]" for F in sort(collect(keys(bad)))), "; ")
    error(
        "projection-pushdown desugar: the binning aggregate reads a cell-axis " *
            "array at a COMPUTED cell position ($(detail)). The rewrite re-points the " *
            "reduction onto the derived support set '$(setname)', which renumbers " *
            "'$(C)' — support position i is grid cell member_factor[i], and no " *
            "arithmetic on i survives that renumbering. A gather can carry `F[c]`, " *
            "and `F[c, …]`, but not `F[f(c)]`. Index the array with the bare cell " *
            "symbol, or move the value off the '$(C)' axis (declare it over the axis " *
            "it is really indexed by, so it stays full-grid and is left alone)."
    )
end

# The names the rewrite generates for cell set `C`.
struct _PdNames
    support_set::String     # the derived index set
    producer_id::String     # its `distinct` producer
    member_var::String      # the producer's output
    member_factor::String   # the set's member factor
end
_PdNames(C::AbstractString) = _PdNames(
    "pd_support__" * C, "pd_faq__" * C, "pd_members__" * C, "pd_member_factor__" * C
)
_pd_cell_gather_name(C::AbstractString, F::AbstractString) = "pd_cell__" * C * "__" * F

# Emit the rewrite of `esm`'s model `mname` for `plan`, in order: the rect
# factors to gather; the derived index set; the producer filter, read from the
# representative binning before any binning is rewritten (it keeps the
# full-grid rect references); the member unknown and factor; the cell gathers;
# the gated provider arrays; the forward binnings re-pointed and gated; the
# mirrors gated; the consumers restricted; the producer; the provenance record.
# `reg` is the component template registry (`nothing` when the document carries
# no surviving template reference), which reads a predicate factored through a
# template. Returns the rewritten document; `esm` is not modified.
function _pd_apply(esm, mname::AbstractString, plan::_PdPlan, reg = nothing)
    d = _to_ordered(esm)                        # fresh, mutable, string-keyed
    C = plan.C
    names = _PdNames(C)
    _pd_refuse_ungatherable(plan.cell_bad, C, names.support_set)
    rects = _pd_rect_factors(plan)
    rectmap = Dict{String, String}(F => _pd_cell_gather_name(C, F) for F in rects)

    haskey(d, "index_sets") || (d["index_sets"] = OrderedDict{String, Any}())
    d["index_sets"][names.support_set] = Dict{String, Any}(
        "kind" => "derived", "from_faq" => names.producer_id,
        "member_factor" => names.member_factor
    )
    mv = d["models"][mname]["variables"]
    # A definition is an equation: the equations array is fetched (and created
    # when absent) before any read, and indexed by defined name.
    eqs = get(d["models"][mname], "equations", nothing)
    if !(eqs isa AbstractVector)
        eqs = Any[]
        d["models"][mname]["equations"] = eqs
    end
    defs = _pd_definitions(eqs)

    prod_filter = _pd_producer_filter(d["models"][mname], eqs, defs, plan, reg)
    # The member buffer is an `unknown`: the generated producer equation
    # defines it (esm-spec §6.3.1).
    mv[names.member_var] = Dict{String, Any}("type" => "unknown", "shape" => Any[names.support_set])
    mv[names.member_factor] = Dict{String, Any}(
        "type" => "parameter", "default" => 0.0, "shape" => Any[names.support_set]
    )
    _pd_emit_cell_gathers!(d, mv, eqs, rects, plan, names)
    for A in plan.A_names
        mv[A]["shape"] = Any[names.support_set, plan.rcv_set]
    end
    _pd_rewrite_forward!(mv, eqs, defs, plan, names, rectmap, reg)
    _pd_gate_mirrors!(eqs, defs, plan)
    for (cname, ssym) in plan.conc_specs
        _pd_defining_rhs(eqs, defs, cname)["ranges"][ssym]["from"] = names.support_set
    end
    # `defs` holds positions in `eqs`, so the producer goes in last.
    pushfirst!(eqs, _pd_producer(plan, names, prod_filter))
    _pd_canonicalize_equations!(d["models"][mname])
    _pd_record!(d, plan, names)
    return d
end

# The rect factors to gather onto the support set: the representative's
# envelope factors first, then every other array a binning body reads on the
# cell axis, in sorted order.
function _pd_rect_factors(plan::_PdPlan)
    rects = String[]
    for F in plan.forward[1].tgt_env
        F in rects || push!(rects, F)
    end
    for F in sort(collect(keys(plan.cell_factors)))
        F in rects || push!(rects, F)
    end
    return rects
end

# The producer's filter: the comparisons of the representative binning's
# containment, with their full-grid rect references (`_pd_filter_in`). A
# containment inside a template body is the derived template
# `<template>__pd_filter`, registered in `model`'s `expression_templates`, and
# the filter is a reference to it: the body is never expanded.
function _pd_producer_filter(model::AbstractDict, eqs, defs::Dict{String, Int}, plan::_PdPlan, reg)
    repexpr = _pd_defining_rhs(eqs, defs, plan.forward[1].name)
    derived = OrderedDict{String, Any}()
    f = _pd_filter_in(get(repexpr, "expr", nothing), reg, derived)
    f === nothing && error("pushdown desugar: representative E lost its containment ifelse")
    _pd_register_derived!(model, derived, reg)
    return f
end

# The per-rect cell-gather observeds `cell_F[c] = index(F, index(member_factor, c))`,
# declaration and defining equation, in sorted name order.
function _pd_emit_cell_gathers!(d, mv, eqs, rects::Vector{String}, plan::_PdPlan, names::_PdNames)
    C = plan.C
    for F in sort(rects)
        shape = get(plan.cell_factors, F, nothing)
        if shape === nothing
            sh = get(mv, F, nothing)
            shape = (sh isa AbstractDict && get(sh, "shape", nothing) isa AbstractVector) ?
                String[String(x) for x in sh["shape"]] : String[C]
        end
        decl, defn = _pd_gather_defn(
            F, shape, names.support_set, names.member_factor,
            get(d, "index_sets", nothing), C
        )
        g = _pd_cell_gather_name(C, F)
        mv[g] = decl
        push!(eqs, Dict{String, Any}("lhs" => g, "rhs" => defn))
    end
    return nothing
end

# Each forward binning onto the support set: its cell axis, its rect factors
# re-pointed at the cell gathers, and the gate (the overlap clause its own
# predicate reads, re-pointed the same way) so the driver walks one candidate
# list per output cell instead of every (cell, record) pair. Each definition is
# deep-copied before the in-place rewrite: a document built in memory may share
# one predicate object between aggregates, and the rewrite must not reach a
# variable that is not re-pointed.
function _pd_rewrite_forward!(
        mv, eqs, defs::Dict{String, Int}, plan::_PdPlan, names::_PdNames,
        rectmap::Dict{String, String}, reg
    )
    for b in plan.forward
        expr = deepcopy(_pd_defining_rhs(eqs, defs, b.name))
        eqs[defs[b.name]]["rhs"] = expr
        expr["ranges"][b.cell_sym]["from"] = names.support_set
        _pd_rewrite_rects!(expr, rectmap)
        haskey(expr, "args") && (expr["args"] = Any[get(rectmap, string(s), s) for s in expr["args"]])
        mv[b.name]["shape"] = Any[names.support_set]
        haskey(expr, "join") || (
            expr["join"] = Any[
                _pd_overlap_clause(
                    b.src_env, String[get(rectmap, F, F) for F in b.tgt_env]
                ),
            ]
        )
        _pd_assert_rects_rebound(expr, b.name, rectmap, reg)
    end
    return nothing
end

# A mirrored per-record binning gets only the gate: it keeps the full record
# axis (every record produces a value, the semiring identity outside the grid)
# and the document's own cell-axis envelopes. Deep-copied as above.
function _pd_gate_mirrors!(eqs, defs::Dict{String, Int}, plan::_PdPlan)
    for m in plan.mirrors
        pexpr = deepcopy(_pd_defining_rhs(eqs, defs, m.name))
        eqs[defs[m.name]]["rhs"] = pexpr
        haskey(pexpr, "join") || (pexpr["join"] = Any[_pd_overlap_clause(m.src_env, m.tgt_env)])
    end
    return nothing
end

# The generated `distinct` producer of the support set: the representative's
# containment and geometry over (record, cell).
function _pd_producer(plan::_PdPlan, names::_PdNames, prod_filter)
    rep = plan.forward[1]
    return Dict{String, Any}(
        "lhs" => _pd_ix(names.member_var, "m"),
        "rhs" => Dict{String, Any}(
            "op" => "faq", "output_idx" => Any["m"],
            "ranges" => Dict{String, Any}(
                plan.rep_rsym => Dict{String, Any}("from" => plan.R),
                rep.cell_sym => Dict{String, Any}("from" => plan.C)
            ),
            "expr" => Dict{String, Any}("op" => "true", "args" => Any[]),
            "distinct" => true, "semiring" => "bool_and_or", "id" => names.producer_id,
            "join" => Any[_pd_overlap_clause(rep.src_env, rep.tgt_env)],
            "filter" => prod_filter,
            "key" => rep.cell_sym,
            "args" => Any[unique(vcat(rep.src_env, rep.tgt_env))...]
        )
    )
end

# The provenance record under `metadata.x_esd` (esm-spec §3's extension point,
# so the document still validates): the generated names and the gate of the
# provider-backed arrays, as `provider_gate_spec` reads one.
function _pd_record!(d, plan::_PdPlan, names::_PdNames)
    md = get!(d, "metadata", OrderedDict{String, Any}())
    xesd = get!(md, "x_esd", OrderedDict{String, Any}())
    xesd["pushdown"] = Dict{String, Any}(
        "derived_set" => names.support_set, "producer_id" => names.producer_id,
        "member_factor" => names.member_factor, "member_var" => names.member_var,
        "gated_select" => Dict{String, Any}(
            "gated_by" => names.support_set, "applies_to" => Any[plan.A_names...],
            "gated_axis" => 0
        )
    )
    return nothing
end

# ============================================================================
# RECORD-DERIVED PROVIDER GATING.
#
# `desugar_pushdown` records `metadata.x_esd.pushdown.gated_select` — which
# derived set gates which model arrays on which axis. These helpers read it
# back for `esm_problem`: given the REWRITTEN (pre-flatten) document and the caller's public
# `providers` dict, derive the engine gate (`Dict("axes"=>…, "applies_to"=>…)`,
# the `_fetch_gated_providers` format) for every provider that the document's
# coupling identifies as feeding a rewritten array.
# ============================================================================

"""
    _pushdown_provider_gates(doc, providers) -> Dict{String,Any}

Provider-key ⇒ engine gate, derived from `doc`'s rewrite record
(`metadata.x_esd.pushdown.gated_select`).

A provider is GATED when its key names a PARAMETER that a `data` update binds to
a source and whose local name is one of the record's `applies_to` model arrays.
That is a direct match: a source is not a coupling endpoint, so a provider is keyed by the consuming parameter's own flattened name
(`"<ModelPath>.<param>"`, see `providers_from_document`) and there is no
`variable_map` indirection to follow. The gate's per-NATIVE-axis `axes` come
from the bound SOURCE's `metadata.x_esd.gated_select.axes` template when it
declares one (the record's GENERATED set name — `pd_support__*` — replacing
whatever set the template names, since the template predates the rewrite), else
from the model array's rank with `gated_by` at the record's `gated_axis`.

Empty when `doc` carries no record, no provider key names a gated array, or
`providers === nothing` — record-derived gating is a rewrite-scoped mechanism; a
provider outside it falls back to `provider_gate_spec`.
"""
function _pushdown_provider_gates(doc::AbstractDict, providers)
    gates = Dict{String, Any}()
    providers === nothing && return gates
    rec = _pushdown_record(doc)
    rec === nothing && return gates
    gs = get(rec, "gated_select", nothing)
    gs isa AbstractDict || return gates
    applies = String[String(a) for a in get(gs, "applies_to", Any[])]
    gset = String(get(gs, "gated_by", ""))
    gaxis = Int(get(gs, "gated_axis", 0))
    (isempty(applies) || isempty(gset)) && return gates

    # Flattened parameter name ⇒ the `data_sources` key its update names.
    bound = _pushdown_data_bindings(doc)
    isempty(bound) && return gates

    mrank = _pushdown_gated_rank(doc, applies)
    for k0 in keys(providers)
        k = String(k0)
        haskey(bound, k) || continue
        local_name = String(split(k, '.')[end])
        local_name in applies || continue
        axes = _pushdown_gate_axes(doc, bound[k], gset, gaxis, mrank)
        gates[k] = Dict{String, Any}("axes" => axes, "applies_to" => Any[local_name])
    end
    return gates
end

# Flattened parameter name ⇒ the `data_sources` key its `update` names
# (esm-spec §8.5). Walks `models` and their `subsystems` under the same dotted
# prefixes `flatten` builds.
function _pushdown_data_bindings(doc::AbstractDict)
    out = Dict{String, String}()
    function walk(models, prefix::String)
        models isa AbstractDict || return
        for (mname0, m) in models
            m isa AbstractDict || continue
            path = isempty(prefix) ? String(mname0) : "$(prefix).$(String(mname0))"
            vars = get(m, "variables", nothing)
            if vars isa AbstractDict
                for (vname0, vd) in vars
                    vd isa AbstractDict || continue
                    u = get(vd, "update", nothing)
                    rules = u isa AbstractVector ? u : (u isa AbstractDict ? Any[u] : Any[])
                    for r in rules
                        (r isa AbstractDict && get(r, "kind", nothing) == "data") || continue
                        src = get(r, "source", nothing)
                        src isa AbstractString || continue
                        out["$(path).$(String(vname0))"] = String(src)
                        break
                    end
                end
            end
            walk(get(m, "subsystems", nothing), path)
        end
        return
    end
    walk(get(doc, "models", nothing), "")
    return out
end

# Rank of the (rewritten) gated model arrays — the fallback native rank when a
# source declares no axes template. After `_pd_apply` every applies_to array is
# `[<derived set>, <rcv>]`, so this is 2 for the ISRM shape; read it from the
# document rather than hard-coding.
function _pushdown_gated_rank(doc::AbstractDict, applies::Vector{String})
    models = get(doc, "models", nothing)
    models isa AbstractDict || return 2
    for (_, m) in models
        m isa AbstractDict || continue
        mv = get(m, "variables", nothing)
        mv isa AbstractDict || continue
        for a in applies
            v = get(mv, a, nothing)
            v isa AbstractDict || continue
            shp = get(v, "shape", nothing)
            shp isa AbstractVector && !isempty(shp) && return length(shp)
        end
    end
    return 2
end

# Per-NATIVE-axis gate `axes` for the data source `loader`: its declared
# `metadata.x_esd.gated_select.axes` template with the GENERATED set name
# substituted into its `gated_by` slot (validated: the gated axis must sit at
# `gaxis` among the non-fixed axes, or the record and template disagree about
# which native axis is gated); else a rank-`mrank` all-axes gate with
# `gated_by` at `gaxis`.
function _pushdown_gate_axes(
        doc::AbstractDict, loader::AbstractString,
        gset::AbstractString, gaxis::Int, mrank::Int
    )
    tpl = nothing
    loaders = get(doc, "data_sources", nothing)
    if loaders isa AbstractDict
        ld = get(loaders, String(loader), nothing)
        if ld isa AbstractDict
            md = get(ld, "metadata", nothing)
            xe = md isa AbstractDict ? get(md, "x_esd", nothing) : nothing
            gsel = xe isa AbstractDict ? get(xe, "gated_select", nothing) : nothing
            gsel isa AbstractDict && (tpl = get(gsel, "axes", nothing))
        end
    end
    if tpl isa AbstractVector
        axes = Any[]
        nonfixed = 0
        gpos = -1
        for ax in tpl
            if ax isa AbstractDict && haskey(ax, "gated_by")
                push!(axes, Dict{String, Any}("gated_by" => String(gset)))
                gpos = nonfixed
                nonfixed += 1
            elseif ax isa AbstractDict && haskey(ax, "fixed")
                fx = ax["fixed"]
                fi = fx isa AbstractVector ? Int(first(fx)) : Int(fx)
                push!(axes, Dict{String, Any}("fixed" => Any[fi]))
            else
                push!(axes, "all")
                nonfixed += 1
            end
        end
        gpos == gaxis || throw(
            RefreshError(
                "data_sources.$loader gated_select template puts the gated axis at " *
                    "non-fixed position $gpos, but the rewrite record gates model axis " *
                    "$gaxis — the loader template and the rewritten arrays disagree",
                ERROR_CODES.PROVIDER_GATE_INVALID
            )
        )
        return axes
    end
    (0 <= gaxis < mrank) || throw(
        RefreshError(
            "rewrite record gated_axis $gaxis out of range for rank-$mrank gated arrays",
            ERROR_CODES.PROVIDER_GATE_INVALID
        )
    )
    axes = Any[fill("all", mrank)...]
    axes[gaxis + 1] = Dict{String, Any}("gated_by" => String(gset))
    return axes
end

"""
    _inject_pushdown_aliases!(dst, run_file::EsmFile, coupling_pairs) -> dst

Alias-key injection for the `esm_problem` pushdown path (same-object references,
no copies). The flattener rewrites EQUATION references through the coupling
`variable_map` (`ISRM.SR_SOA → ISRM_SR.SOA`) but leaves the VARIABLES'
`expression` fields namespaced-only (`ISRM.emis_lon`) — and the build-front-door
consumers that run BEFORE the impl parse (`_derive_binning_coords`,
`materialize_value_invention`, `_observed_field`) read those expressions. So a
const array registered under its provider key (`"EGU_Emis.lon"`) or its bare
authored name (`"src_W"`) must ALSO resolve under:

  * the coupling `to` name (`"ISRM.emis_lon"`) for every `variable_map`
    `from` key present — the deleted consumer parameter's spelling; and
  * every flattened model-variable key whose final dotted segment matches a
    bare key (`"src_W"` ⇒ `"ISRM.src_W"`) — `_const_factor_aliases` semantics,
    applied dict-side to the caller's arrays.

Existing keys are never overwritten.
"""
function _inject_pushdown_aliases!(
        dst::AbstractDict, run_file::EsmFile,
        coupling_pairs::AbstractVector
    )
    for (frm, to) in coupling_pairs
        haskey(dst, frm) && !haskey(dst, to) && (dst[to] = dst[frm])
    end
    run_file.models === nothing && return dst
    vnames = String[v for m in values(run_file.models) for v in keys(m.variables)]
    for k in collect(keys(dst))
        ks = String(k)
        occursin('.', ks) && continue
        for v in vnames
            occursin('.', v) || continue
            String(split(v, '.')[end]) == ks && !haskey(dst, v) && (dst[v] = dst[k])
        end
    end
    return dst
end

# The coupling `variable_map` (from ⇒ to) pairs of a raw document — captured
# BEFORE `_prepare_run` flattens them away, for `_inject_pushdown_aliases!`.
function _pushdown_coupling_pairs(doc::AbstractDict)
    out = Pair{String, String}[]
    cp = get(doc, "coupling", nothing)
    cp isa AbstractVector || return out
    for c in cp
        (c isa AbstractDict && get(c, "type", nothing) == "variable_map") || continue
        frm = String(get(c, "from", "")); to = String(get(c, "to", ""))
        (isempty(frm) || isempty(to)) || push!(out, frm => to)
    end
    return out
end
