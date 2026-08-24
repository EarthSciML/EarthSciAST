# ========================================================================
# pushdown_rewrite.jl — Phase 4: the AUTOMATIC projection-pushdown DESUGAR.
#
# A pre-build model-transform pass that recognises the ISRM-shaped
# `+`-semiring "apply a provider-backed full-domain array to a sparsely
# supported binned factor" pattern in a CLEAN model, and AUTO-GENERATES the
# four hand-authored Phase-2b constructs (derived IndexSet + `distinct`
# producer + member_factor + gated_select) so the existing 2b pipeline then
# runs unchanged. The author writes NO derived set, NO producer, and NO
# gated_select — only the natural math.
#
# This is a NARROW desugarer (a pattern recogniser), NOT a general optimizer.
# It fires ONLY when the reduction's semiring is the additive `(+, 0)` monoid
# (`_aggregate_oplus_identity == ("+", 0.0)`); a `max_product` / `min_sum` /
# etc. aggregate of the SAME shape is left untouched (the soundness guard).
#
# Hooked in the AbstractDict front door (`build_evaluator(esm; …)`), opt-in
# behind the `pushdown_rewrite=true` kwarg, BEFORE `coerce_esm_file` so both
# the typed value-invention path and the impl re-parse see the generated
# constructs. Off by default so every existing test is byte-identical.
# ========================================================================

"""
    desugar_pushdown(esm::AbstractDict; model_name=nothing) -> AbstractDict

Recognise the projection-pushdown pattern in `esm`'s named model and, when it
matches, return a NEW document with the four Phase-2b constructs desugared in
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
function desugar_pushdown(esm::AbstractDict; model_name=nothing)
    # IDEMPOTENCY GUARD: a document that already carries the rewrite's
    # provenance record (`metadata.x_esd.pushdown`) has been desugared — the
    # generated constructs (compact E over the derived set, cell-gather rect
    # observeds) would otherwise re-match the pattern and stack a second
    # `pd_support__pd_support__…` layer. This makes the pass safe to request
    # from BOTH `prepare` (which must run it before flattening/provider
    # classification) and the `build_evaluator` front door.
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
function pushdown_diagnostics(esm::AbstractDict; model_name=nothing)
    _pushdown_record(esm) === nothing || return Dict{String,Any}[]
    an = _pd_analyze(esm, model_name)
    return an === nothing ? Dict{String,Any}[] : an.diagnostics
end

# The ONE detection entry point shared by `desugar_pushdown` (which then emits)
# and `pushdown_diagnostics` (which only reports). Returns `nothing` when no
# model is selected; otherwise the plan (`nothing` ⇒ the pattern did not match),
# the residual diagnostics, the model name, and the component template registry
# the emission side needs to expand references with.
function _pd_analyze(esm::AbstractDict, model_name)
    file = coerce_esm_file(esm)
    m = _select_model_or_nothing(file, model_name)
    m === nothing && return nothing
    mname = _pd_model_name(file, model_name)
    mname === nothing && return nothing
    reg = _pd_registry(file, mname)
    plan, diags = _pd_detect(m, _pd_detection_defs(m, reg), file.index_sets)
    return (plan = plan, diagnostics = diags, mname = mname, registry = reg)
end

"""
    _pushdown_record(doc) -> Union{Nothing,AbstractDict}

The rewrite's provenance record `metadata.x_esd.pushdown` written by
[`desugar_pushdown`](@ref) (see `_pd_apply`), or `nothing` when `doc` carries
none. This is the record the engine reads BACK to derive provider gates —
callers no longer hand-author gate dicts (`esm_problem(...; pushdown_rewrite=true)`
+ `providers`)."""
function _pushdown_record(doc::AbstractDict)
    md = get(doc, "metadata", nothing)
    md isa AbstractDict || return nothing
    xe = get(md, "x_esd", nothing)
    xe isa AbstractDict || return nothing
    rec = get(xe, "pushdown", nothing)
    return rec isa AbstractDict ? rec : nothing
end

_pd_model_name(file, model_name) = model_name !== nothing ? String(model_name) :
    (file.models !== nothing && length(file.models) == 1 ?
     String(first(keys(file.models))) : nothing)

# ---- detection-time template-reference expansion (esm-spec §9.6.4 rule 2) --
#
# Under Option B (§9.6.4) `load` PRESERVES `apply_expression_template`
# references: they ride to the build boundary where `_build_evaluator_impl`
# expands them with site recording (the ~50x node-lowering win, simulate.jl).
# `prepare` therefore hands `desugar_pushdown` a document whose binning body may
# be a surviving reference rather than the containment `ifelse` the recogniser
# looks for.
#
# §9.6.4 rule 4 ("patterns do not see through surviving references") governs the
# §9.6.3 REWRITE-RULE ENGINE. `desugar_pushdown` is a different consumer, and
# rule 2 governs it: a reference DENOTES its expansion, every consumer MAY
# expand, and observable behavior must be as if evaluated on `Expand(tree)`.
# Whether the pushdown fires MUST NOT depend on whether the author factored the
# binning body through a template — so detection runs on the EXPANDED view.
#
# Emission does NOT: `_pd_apply` edits the call site's `bindings` (and the
# aggregate's own `ranges`/`args`/`shape`/`join`), never the shared template
# body, so the body stays shared and singly-lowered and Option B survives the
# rewrite. `_pd_assert_rects_rebound` is the post-condition that proves it.

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

# The `name` of the first surviving reference in `e` (pre-order), for the
# residual diagnostic; `nothing` when `e` carries none.
function _pd_first_apply_name(e)
    e isa OpExpr || return nothing
    e.op == APPLY_EXPRESSION_TEMPLATE_OP && return e.name
    for c in child_exprs(e)
        r = _pd_first_apply_name(c)
        r === nothing || return r
    end
    return nothing
end

"""
    _pd_detection_defs(model, reg) -> Dict{String,ASTExpr}

[`observed_definitions`](@ref) with every surviving `apply_expression_template`
reference EXPANDED against `reg` — the `Expand(tree)` view the pattern matcher
must see (§9.6.4 rule 2). From esm 1.0.0 an observed unknown's body is its
defining EQUATION's right-hand side, so this — not the variable table — is what
the detector matches against; `_pd_detect` still reads `model.variables` for the
shapes and types beside it. Returns the definition map UNCHANGED (no copy) when
there is no registry or no reference to expand, so a template-free document
takes the byte-identical pre-existing path.

Expansion is DETECTION-ONLY: the returned bodies are never emitted. A reference
that fails to expand (an unresolvable template — `desugar_pushdown` is callable
on a raw document that never went through `load`'s §9.6.9 call-site checks) is
left in place rather than raised: the pass's contract is to leave a document it
cannot recognise unchanged, and the surviving reference is then reported by
`_pd_binning_refusal` if the definition is join-shaped.
"""
function _pd_detection_defs(model::Model, reg)
    defs = observed_definitions(model)
    reg === nothing && return defs
    any(_pd_has_apply, values(defs)) || return defs
    out = Dict{String,ASTExpr}(defs)
    # Shared expansion memo: two sites with the same (template, bindings) reuse
    # one expansion. Rule 2 requires exactly that they be structurally identical
    # with bit-equal constants, and this walk is read-only, so the sharing is
    # unobservable — the same guarantee `_expand_model_refs!` relies on.
    memo = _expand_memo_disabled() ? nothing : Dict{Tuple{String,String},OpExpr}()
    for (name, ex) in defs
        _pd_has_apply(ex) || continue
        lowered = try
            _expand_expr_refs(ex, reg, nothing, memo)
        catch err
            err isa ExpressionTemplateError || rethrow()
            continue
        end
        lowered === ex || (out[name] = lowered)
    end
    return out
end

# ---- typed-IR leaf helpers -------------------------------------------------
_pd_varname(e) = e isa VarExpr ? e.name : nothing

"""
    _pd_cell_factors!(e, c_sym, vars, C, out, bad)

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
function _pd_cell_factors!(e, c_sym::AbstractString, vars::AbstractDict,
                           C::AbstractString, out::AbstractDict, bad::AbstractDict)
    e isa OpExpr || return nothing
    if e.op == "index" && length(e.args) >= 2
        F = _pd_varname(e.args[1])
        if F !== nothing
            v = get(vars, F, nothing)
            shp = v === nothing ? nothing : v.shape
            if shp !== nothing && !isempty(shp) && String(shp[1]) == C
                sub = e.args[2]
                if _pd_varname(sub) == c_sym
                    haskey(out, F) || (out[F] = String[String(x) for x in shp])
                elseif _pd_mentions_sym(sub, c_sym)
                    haskey(bad, F) || (bad[F] = _pd_subscript_sketch(sub))
                end
            end
        end
    end
    for c in child_exprs(e)
        _pd_cell_factors!(c, c_sym, vars, C, out, bad)
    end
    return nothing
end

# Does `e` reference the loop symbol `sym` anywhere?
function _pd_mentions_sym(e, sym::AbstractString)::Bool
    _pd_varname(e) == sym && return true
    e isa OpExpr || return false
    for c in child_exprs(e)
        _pd_mentions_sym(c, sym) && return true
    end
    return false
end

# A one-line rendering of a subscript expression, for the refusal message.
function _pd_subscript_sketch(e)
    n = _pd_varname(e); n === nothing || return String(n)
    e isa NumExpr && return string(e.value)
    e isa IntExpr && return string(e.value)
    e isa OpExpr || return "?"
    if e.op == "index"
        return _pd_subscript_sketch(e.args[1]) * "[" *
               join((_pd_subscript_sketch(a) for a in e.args[2:end]), ", ") * "]"
    end
    return String(e.op) * "(" * join((_pd_subscript_sketch(a) for a in e.args), ", ") * ")"
end

# index(F, sym) with EXACTLY one index → (F, sym); else nothing.
function _pd_index_split(e)
    (e isa OpExpr && e.op == "index" && length(e.args) == 2) || return nothing
    f = _pd_varname(e.args[1]); s = _pd_varname(e.args[2])
    (f === nothing || s === nothing) && return nothing
    return (f, s)
end

# index(F, sym…) with ≥1 index → (F, [syms…]); else nothing.
function _pd_index_syms(e)
    (e isa OpExpr && e.op == "index" && length(e.args) >= 2) || return nothing
    f = _pd_varname(e.args[1]); f === nothing && return nothing
    syms = String[]
    for a in @view e.args[2:end]
        s = _pd_varname(a); s === nothing && return nothing
        push!(syms, s)
    end
    return (f, syms)
end

# SHARED linear-mat-vec body predicate — also reused by the wall2 Phase D BLAS
# accelerator (`_evaluate_cellwise_blas`, pde_inline_tests.jl). Classify an
# aggregate BODY `A[c, out…] · E[c]` — a two-factor `⊗=·` product of a
# rank-(1+|out|) array factor `A` subscripted `[c, out…]` (contracted index first,
# then the output indices in order) and a rank-1 factor `E` subscripted `[c]` —
# into `(Aname, Ename)`, or `nothing` when `body` is not that exact shape.
# `c_sym` is the contracted index and `out_syms` the ordered output indices. This
# is a PURE STRUCTURAL check on index symbols; it neither inspects factor values
# nor the semiring (callers apply the additive `(+,0)` semiring guard themselves).
function _pd_matvec_factors(body, c_sym::AbstractString,
                            out_syms::AbstractVector{<:AbstractString})
    (body isa OpExpr && body.op == "*" && length(body.args) == 2) || return nothing
    isempty(out_syms) && return nothing
    parts = Any[_pd_index_syms(a) for a in body.args]
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
_pd_oplus(agg::OpExpr) =
    try _aggregate_oplus_identity(agg.semiring, agg.reduce) catch; nothing end

_pd_flip(op) = op == "<" ? ">" : op == "<=" ? ">=" : op == ">" ? "<" : "<="

# Find the condition of the first `ifelse(cond, then, else)` in a typed subtree.
function _pd_find_ifelse_cond(e)
    e isa OpExpr || return nothing
    (e.op == "ifelse" && length(e.args) == 3) && return e.args[1]
    for a in e.args
        r = _pd_find_ifelse_cond(a)
        r === nothing || return r
    end
    e.expr_body === nothing || (r = _pd_find_ifelse_cond(e.expr_body); r === nothing || return r)
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
function _pd_parse_containment(pred, c_sym::AbstractString, r_sym::AbstractString)
    pred isa OpExpr || return nothing
    comps = pred.op in ("and", "*") ? pred.args : ASTExpr[pred]
    bounds = Dict{String,Dict{Symbol,String}}()
    rec_order = String[]
    for cmp in comps
        (cmp isa OpExpr && cmp.op in ("<", "<=", ">", ">=") && length(cmp.args) == 2) || return nothing
        s1 = _pd_index_split(cmp.args[1]); s2 = _pd_index_split(cmp.args[2])
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
        haskey(bounds, Fp) || (push!(rec_order, Fp); bounds[Fp] = Dict{Symbol,String}())
        haskey(bounds[Fp], kind) && return nothing       # one bound of each kind per factor
        bounds[Fp][kind] = Fc
    end
    nbound(P) = length(bounds[P])
    if length(rec_order) == 2 && all(P -> nbound(P) == 2, rec_order)
        Px, Py = rec_order[1], rec_order[2]
        return (src_env = String[Px, Py],
                tgt_env = String[bounds[Px][:min], bounds[Py][:min],
                                 bounds[Px][:max], bounds[Py][:max]])
    elseif length(rec_order) == 4 && all(P -> nbound(P) == 1, rec_order)
        # A record factor carrying a LOWER cell bound (`cmin ≤ r`) is that
        # axis's record MAXIMUM, and vice versa — the AABB test compares each
        # side's min against the other side's max.
        his = String[P for P in rec_order if haskey(bounds[P], :min)]
        los = String[P for P in rec_order if haskey(bounds[P], :max)]
        (length(his) == 2 && length(los) == 2) || return nothing
        return (src_env = String[los[1], los[2], his[1], his[2]],
                tgt_env = String[bounds[his[1]][:min], bounds[his[2]][:min],
                                 bounds[los[1]][:max], bounds[los[2]][:max]])
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
# supplied by the caller from `observed_definitions`: from esm 1.0.0 a variable
# carries no expression of its own, so a non-observed variable simply has no
# definition to pass and never reaches here.
function _pd_detect_binning(ev::ModelVariable, agg::Union{ASTExpr,Nothing},
                            out_set::AbstractString;
                            out_is_cell::Union{Bool,Nothing}=nothing)
    (ev.shape !== nothing && length(ev.shape) == 1 && ev.shape[1] == out_set) || return nothing
    (agg isa OpExpr && _is_aggregate_op(agg.op)) || return nothing
    oz = _pd_oplus(agg); oz === nothing && return nothing
    (oz[1] == "+" && oz[2] == 0.0) || return nothing              # SEMIRING GUARD
    oi = agg.output_idx
    (oi !== nothing && length(oi) == 1) || return nothing
    out_sym = String(oi[1])
    ranges = agg.ranges === nothing ? Dict{String,Any}() : agg.ranges
    length(ranges) == 2 || return nothing
    (haskey(ranges, out_sym) && ranges[out_sym] isa IndexSetRef &&
     ranges[out_sym].from == out_set) || return nothing
    in_sym = nothing
    for k in keys(ranges); k == out_sym && continue; in_sym = k; end
    (in_sym !== nothing && ranges[in_sym] isa IndexSetRef) || return nothing
    in_set = String(ranges[in_sym].from)
    body = agg.expr_body
    body isa OpExpr || return nothing
    pred = _pd_find_ifelse_cond(body)
    pred === nothing && return nothing
    # For a POINT-IN-RECT predicate exactly one of the two assignments parses —
    # `_pd_parse_containment` demands the record side yield two coordinates each
    # with a min AND a max cell bound, which the rect side cannot do. An
    # ENVELOPE-OVERLAP predicate is SYMMETRIC and parses BOTH ways, so the
    # predicate alone no longer says which symbol is the cell. `out_is_cell`
    # lets a caller that already knows say so: the forward arm's cell set comes
    # from the mat-vec array's first axis, and mirrors are collected only after
    # `C`/`R` are fixed. Left `nothing` (the point case, and the forward arm's
    # unhinted call) the out-as-cell reading is preferred, as before.
    if out_is_cell !== false
        env = _pd_parse_containment(pred, out_sym, in_sym)
        env === nothing || return (c_sym = out_sym, r_sym = in_sym,
                                   C = String(out_set), R = in_set, out_is_cell = true,
                                   src_env = env.src_env, tgt_env = env.tgt_env)
    end
    out_is_cell === true && return nothing
    env = _pd_parse_containment(pred, in_sym, out_sym)
    env === nothing && return nothing
    return (c_sym = in_sym, r_sym = out_sym, C = in_set, R = String(out_set),
            out_is_cell = false, src_env = env.src_env, tgt_env = env.tgt_env)
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
# pass that `prepare` runs over whole documents it does not own. Promoting "I did
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
`ev`'s DEFINING EQUATION RHS from the detection view, exactly as
`_pd_detect_binning` received it; `nothing` (a variable that is not an observed
unknown, so has no definition) is never join-shaped.

`nothing` means `ev` is simply not join-shaped — no diagnostic is warranted.
Otherwise `(reason, template)`:

  * `("surviving_template_reference", name)` — the body carries no containment
    `ifelse` because it is (or hides) a surviving `apply_expression_template`
    reference that could not be expanded for matching;
  * `("predicate_unparsed", nothing)` — a containment `ifelse` was found but it
    did not read as a containment — point-in-rect or envelope
    overlap — in EITHER orientation.
"""
function _pd_binning_refusal(ev::ModelVariable, agg::Union{ASTExpr,Nothing},
                             out_set::AbstractString)
    (ev.shape !== nothing && length(ev.shape) == 1 && ev.shape[1] == out_set) || return nothing
    (agg isa OpExpr && _is_aggregate_op(agg.op)) || return nothing
    oz = _pd_oplus(agg); oz === nothing && return nothing
    (oz[1] == "+" && oz[2] == 0.0) || return nothing
    oi = agg.output_idx
    (oi !== nothing && length(oi) == 1) || return nothing
    out_sym = String(oi[1])
    ranges = agg.ranges === nothing ? Dict{String,Any}() : agg.ranges
    length(ranges) == 2 || return nothing
    (haskey(ranges, out_sym) && ranges[out_sym] isa IndexSetRef &&
     ranges[out_sym].from == out_set) || return nothing
    in_sym = nothing
    for k in keys(ranges); k == out_sym && continue; in_sym = k; end
    (in_sym !== nothing && ranges[in_sym] isa IndexSetRef) || return nothing
    body = agg.expr_body
    body isa OpExpr || return nothing
    pred = _pd_find_ifelse_cond(body)
    if pred === nothing
        tname = _pd_first_apply_name(body)
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

# The MIRRORED-orientation binning aggregates of a model: per-RECORD observeds
# `P[r] = Σ_{c∈C} [contains(cell_c, pt_r)] · …` over the plan's cell set `C` and
# record set `R`. Returned as `(name, src_env, tgt_env)` triples, sorted by name
# so the emitted document is identical across bindings and hash seeds.
#
# A mirror needs NOTHING but the gate — see the note on the mirrored arm in
# `_pd_apply`. Its cell axis stays the FULL `C`, so its envelope factors are the
# document's own const-array rects, unrewritten.
function _pd_mirror_specs(model::Model, obs_defs::AbstractDict,
                          C::AbstractString, R::AbstractString, forward_names)
    out = Tuple{String,Vector{String},Vector{String}}[]
    for (name, defn) in obs_defs
        name in forward_names && continue
        v = model.variables[name]
        bind = _pd_detect_binning(v, defn, R; out_is_cell=false)
        bind === nothing && continue
        (!bind.out_is_cell && bind.C == C && bind.R == R) || continue
        # Never stack a second gate on an aggregate that already declares a join.
        (defn isa OpExpr && (defn::OpExpr).join !== nothing) && continue
        push!(out, (name, bind.src_env, bind.tgt_env))
    end
    sort!(out; by = t -> t[1])
    return out
end

# Detect the pushdown pattern across a model's observeds. `obs_defs` is the
# DETECTION view (`_pd_detection_defs`): the observed definitions with surviving
# template references expanded, so a binning body factored through a template
# matches exactly as its expansion would. `model` supplies the declarations
# beside it — shapes and types, which no expansion touches. Returns
# `(plan, diagnostics)` — `plan` `nothing` when nothing matches / the semiring
# guard fails, `diagnostics` the residual "a join I could not read" records
# (see `_pd_binning_refusal`).
function _pd_detect(model::Model, obs_defs::AbstractDict, index_sets::AbstractDict)
    vars = model.variables
    diags = Dict{String,Any}[]
    conc_specs = Tuple{String,String}[]        # (conc name, reduction symbol)
    A_names = String[]                          # provider-backed arrays to gate
    # (E name, cell output symbol, gate src_env, gate tgt_env)
    E_specs = Tuple{String,String,Vector{String},Vector{String}}[]
    # EVERY array any binning body reads on the cell axis, name => declared
    # shape, and the ungatherable ones. The envelope factors are a SUBSET: a
    # binning body is free to read the cell's geometry, its area, its ring
    # stack, and all of them ride the same re-pointing (`_pd_cell_factors!`).
    cell_factors = OrderedDict{String,Vector{String}}()
    cell_bad = OrderedDict{String,String}()
    C = nothing; rcv_set = nothing; R = nothing
    src_env = nothing; tgt_env = nothing
    rep_ename = nothing; rep_csym = nothing; rep_rsym = nothing

    for (cname, agg) in obs_defs
        (agg isa OpExpr && _is_aggregate_op(agg.op)) || continue
        oz = _pd_oplus(agg); oz === nothing && continue
        (oz[1] == "+" && oz[2] == 0.0) || continue                # SEMIRING GUARD
        oi = agg.output_idx
        (oi !== nothing && length(oi) == 1) || continue
        rcv_sym = String(oi[1])
        ranges = agg.ranges === nothing ? Dict{String,Any}() : agg.ranges
        length(ranges) == 2 || continue
        haskey(ranges, rcv_sym) || continue
        s_sym = nothing
        for k in keys(ranges); k == rcv_sym && continue; s_sym = k; end
        s_sym === nothing && continue
        (ranges[s_sym] isa IndexSetRef && ranges[rcv_sym] isa IndexSetRef) || continue
        c_set = ranges[s_sym].from; r_set = ranges[rcv_sym].from
        facs = _pd_matvec_factors(agg.expr_body, s_sym, String[rcv_sym])
        facs === nothing && continue
        Aname, Ename = facs
        av = get(vars, Aname, nothing)
        (av !== nothing && av.type == ParameterVariable && av.shape !== nothing &&
         length(av.shape) == 2 && av.shape[1] == c_set && av.shape[2] == r_set) || continue
        ev = get(vars, Ename, nothing); ev === nothing && continue
        edef = get(obs_defs, Ename, nothing)
        bind = _pd_detect_binning(ev, edef, c_set)
        if bind === nothing || !bind.out_is_cell                  # FORWARD arm only
            # `ev` is the rank-1 factor of a `+`-mat-vec against a
            # provider-backed `[c_set, r_set]` array: the join position. If it is
            # ALSO binning-shaped but unreadable, say so — silence here is the
            # 330 GB fetch that surfaces hours later as a memory failure.
            if bind === nothing
                why = _pd_binning_refusal(ev, edef, String(c_set))
                why === nothing || push!(diags, Dict{String,Any}(
                    "code" => "pushdown_join_unrecognised",
                    "variable" => String(Ename), "consumer" => String(cname),
                    "array" => String(Aname), "index_set" => String(c_set),
                    "reason" => why[1], "template" => why[2],
                    "consequence" => _PD_UNGATED_CONSEQUENCE))
            end
            continue
        end

        if C === nothing
            C = c_set; rcv_set = r_set; R = bind.R
            src_env = bind.src_env; tgt_env = bind.tgt_env
            rep_ename = Ename; rep_csym = bind.c_sym; rep_rsym = bind.r_sym
        else
            (c_set == C && r_set == rcv_set) || continue          # narrow: one cell set
        end
        push!(conc_specs, (cname, s_sym))
        Aname in A_names || push!(A_names, Aname)
        if !any(e -> e[1] == Ename, E_specs)
            push!(E_specs, (Ename, bind.c_sym, bind.src_env, bind.tgt_env))
            # Collected on the DETECTION view, like every other pattern read: a
            # body factored through a template must yield the same gather set as
            # its longhand twin (esm-spec §9.6.4 rule 2). Emission still edits
            # the authored body / call-site bindings, and
            # `_pd_assert_rects_rebound` proves the substitution landed.
            _pd_cell_factors!(edef, bind.c_sym, vars, String(c_set),
                              cell_factors, cell_bad)
        end
    end
    # Deterministic, deduplicated diagnostic order: `vars` is a hash-ordered
    # Dict, and the same E can be reached from several `conc` consumers.
    sort!(diags; by = d -> (d["variable"], d["consumer"], d["array"]))
    unique!(d -> (d["variable"], d["consumer"], d["array"]), diags)
    isempty(conc_specs) && return (nothing, diags)
    # Deterministic plan order (Phase 3, cross-language goldens): `vars` is a
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
    mirror_specs = _pd_mirror_specs(model, obs_defs, C, R,
                                    Set{String}(e[1] for e in E_specs))
    return ((C = C, rcv_set = rcv_set, R = R, conc_specs = conc_specs,
             A_names = A_names, E_specs = E_specs, mirror_specs = mirror_specs,
             src_env = src_env, tgt_env = tgt_env,
             cell_factors = cell_factors, cell_bad = cell_bad,
             rep_ename = rep_ename, rep_csym = rep_csym, rep_rsym = rep_rsym), diags)
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

# Find the condition of the first dict-form `ifelse` node.
function _pd_dict_find_ifelse_cond(node)
    if node isa AbstractDict
        if get(node, "op", nothing) == "ifelse"
            a = get(node, "args", nothing)
            a isa AbstractVector && length(a) == 3 && return a[1]
        end
        for (_, v) in node
            r = _pd_dict_find_ifelse_cond(v)
            r === nothing || return r
        end
    elseif node isa AbstractVector
        for x in node
            r = _pd_dict_find_ifelse_cond(x)
            r === nothing || return r
        end
    end
    return nothing
end

_pd_ix(f, idx...) = Dict{String,Any}("op" => "index", "args" => Any[f, idx...])

# One dict-form `join.overlap` clause (§5.5.6 wire form). `eps` is always 0.0:
# the rewrite derives the envelopes from an EXACT rectangle-containment
# predicate that stays on as the narrow `filter`, so no FP slack is wanted.
_pd_overlap_clause(src_env, tgt_env) =
    Dict{String,Any}("overlap" => Dict{String,Any}(
        "src_env" => Any[String(f) for f in src_env],
        "tgt_env" => Any[String(f) for f in tgt_env],
        "eps" => 0.0))

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

POST-CONDITION of the forward arm's rect re-pointing, discharged on the EXPANDED
form of the rewritten aggregate `expr` (esm-spec §9.6.4 rule 2: what the
evaluator sees is `Expand(tree)`).

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
function _pd_assert_rects_rebound(expr, Ename::AbstractString,
                                  rectmap::AbstractDict, reg)
    isempty(rectmap) && return
    view = reg === nothing ? expr :
        _expand_all(_to_ordered(deepcopy(expr)), reg, "pushdown_rewrite")
    stale = _pd_collect_stale_rects!(view, rectmap, Set{String}())
    isempty(stale) && return
    names = sort!(collect(stale))
    throw(ExpressionTemplateError(
        ERROR_CODES.TEMPLATE_BODY_REFERENCES_PUSHDOWN_REWRITTEN_VARIABLE,
        "projection-pushdown desugar: the binning aggregate '$(Ename)' still reads " *
        "'$(join(names, "', '"))' after its reduction axis was re-pointed onto the " *
        "generated derived support set. Those references live in an expression-template " *
        "BODY, not in the call site's `bindings`, so the rewrite — which edits call " *
        "sites only, to keep the template body shared and singly-lowered " *
        "(esm-spec §9.6.4 Option B) — cannot re-point them, and they would index the " *
        "compact per-support cell gathers with full-grid positions. Bind the value " *
        "through the template's params, or write the binning body longhand."))
end

"""
    _pd_definitions(eqs) -> Dict{String,Int}

Each name DEFINED by a bare-variable-LHS equation, mapped to that equation's
position in `eqs`.

esm 1.0.0 moved an observed unknown's defining right-hand side out of
`variables[v]["expression"]` and into the model's `equations` (esm-spec §6.3.1),
so the desugar reads and rewrites a definition through this index exactly where
it used to reach into the declaration. The FIRST definition of a name wins,
matching the classification.
"""
function _pd_definitions(eqs)
    idx = Dict{String,Int}()
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
function _pd_defining_rhs(eqs, defs::Dict{String,Int}, name::AbstractString)
    i = get(defs, String(name), nothing)
    i === nothing && error("pushdown desugar: '$(name)' has no defining equation " *
                           "(an observed unknown is defined by a bare-variable-LHS " *
                           "equation, esm-spec 6.3.1)")
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
    defs = Tuple{String,Any}[]
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
function _pd_gather_defn(F::AbstractString, shape::AbstractVector,
                         setname::AbstractString, mfactor::AbstractString,
                         index_sets, C::AbstractString)
    decl = Dict{String,Any}("type" => "unknown",
                            "shape" => Any[setname; Any[String(t) for t in shape[2:end]]...])
    syms = String["pd_t" * string(i - 1) for i in 1:(length(shape) - 1)]
    ranges = Dict{String,Any}("c" => Dict{String,Any}("from" => setname))
    for (sym, t) in zip(syms, shape[2:end])
        (index_sets isa AbstractDict && haskey(index_sets, String(t))) || error(
            "projection-pushdown desugar: cannot gather '$(F)' onto the derived " *
            "support set of '$(C)'. Its declared shape is $(shape), whose trailing " *
            "entry '$(t)' is not a named index set, so the generated gather has no " *
            "range to iterate it over. Declare the array's trailing axes as index " *
            "sets, or keep the value off the cell axis.")
        ranges[sym] = Dict{String,Any}("from" => String(t))
    end
    defn = Dict{String,Any}(
        "op" => "aggregate", "output_idx" => Any[Any["c"]; Any[s for s in syms]...],
        "ranges" => ranges, "args" => Any[F, mfactor],
        "expr" => _pd_ix(F, _pd_ix(mfactor, "c"), syms...))
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
function _pd_refuse_ungatherable(bad::AbstractDict, C::AbstractString,
                                 setname::AbstractString)
    isempty(bad) && return nothing
    detail = join(("'$(F)' at [$(bad[F])]" for F in sort(collect(keys(bad)))), "; ")
    error("projection-pushdown desugar: the binning aggregate reads a cell-axis " *
          "array at a COMPUTED cell position ($(detail)). The rewrite re-points the " *
          "reduction onto the derived support set '$(setname)', which renumbers " *
          "'$(C)' — support position i is grid cell member_factor[i], and no " *
          "arithmetic on i survives that renumbering. A gather can carry `F[c]`, " *
          "and `F[c, …]`, but not `F[f(c)]`. Index the array with the bare cell " *
          "symbol, or move the value off the '$(C)' axis (declare it over the axis " *
          "it is really indexed by, so it stays full-grid and is left alone).")
end

# Apply the desugar to the raw document, returning a NEW mutable dict tree.
# `reg` is the component template registry (`nothing` when the document carries
# no surviving `apply_expression_template` references) — needed to read the
# containment predicate out of a body that was factored through a template, and
# to discharge the `_pd_assert_rects_rebound` post-condition.
function _pd_apply(esm, mname::AbstractString, plan, reg=nothing)
    d = _to_ordered(esm)                        # fresh, mutable, string-keyed
    C = plan.C
    setname = "pd_support__" * C
    faqid   = "pd_faq__" * C
    memvar  = "pd_members__" * C
    mfactor = "pd_member_factor__" * C
    cellgath(F) = "pd_cell__" * C * "__" * F

    # The gather set is the envelope factors PLUS every other array a binning
    # body reads on the cell axis. Envelopes lead, so a document whose bodies
    # read nothing else emits exactly what it emitted before; the rest follow in
    # sorted order, and emission below re-sorts anyway.
    cell_shapes = plan.cell_factors
    _pd_refuse_ungatherable(plan.cell_bad, C, setname)
    rects = String[]                            # rect factors, [xmin,ymin,xmax,ymax] order
    for F in plan.tgt_env; F in rects || push!(rects, F); end
    for F in sort(collect(keys(cell_shapes))); F in rects || push!(rects, F); end
    rectmap = Dict{String,String}(F => cellgath(F) for F in rects)

    # --- derived index set ---
    haskey(d, "index_sets") || (d["index_sets"] = OrderedDict{String,Any}())
    d["index_sets"][setname] = Dict{String,Any}(
        "kind" => "derived", "from_faq" => faqid, "member_factor" => mfactor)

    mv = d["models"][mname]["variables"]

    # esm 1.0.0: a definition is an EQUATION, so the equations array is fetched
    # (and created when absent) before any read, and indexed by defined name.
    eqs = get(d["models"][mname], "equations", nothing)
    if !(eqs isa AbstractVector)
        eqs = Any[]
        d["models"][mname]["equations"] = eqs
    end
    defs = _pd_definitions(eqs)

    # --- producer filter comparisons, deep-copied from the representative E
    #     BEFORE E is rewritten (they must keep full-grid rect factor refs) ---
    repexpr = _pd_defining_rhs(eqs, defs, plan.rep_ename)
    ifcond = _pd_dict_find_ifelse_cond(get(repexpr, "expr", nothing))
    if ifcond === nothing
        # The body is factored through a template. Read the predicate off the
        # EXPANDED body (§9.6.4 rule 2) — the producer wants the FULL-GRID rect
        # references, which is exactly what the pre-rewrite expansion yields. The
        # expansion is a scratch value: nothing of it is emitted except these
        # comparisons, so the document's template block and call sites are
        # untouched. Template-free documents never reach this branch, so their
        # emitted filter is byte-identical to before.
        ifcond = reg === nothing ? nothing :
            _pd_dict_find_ifelse_cond(_expand_all(_to_ordered(deepcopy(get(repexpr, "expr", nothing))),
                                                  reg, "pushdown_rewrite"))
    end
    ifcond === nothing && error("pushdown desugar: representative E lost its containment ifelse")
    comps = get(ifcond, "op", nothing) in ("and", "*") ? ifcond["args"] : Any[ifcond]
    prod_filter = Dict{String,Any}("op" => "*", "args" => Any[_to_ordered(c) for c in comps])

    # --- member unknown + member_factor param ---
    # The member buffer is an `unknown`: the generated producer equation below
    # DEFINES it, and that equation is what makes it one (esm-spec §6.3.1).
    mv[memvar]  = Dict{String,Any}("type" => "unknown", "shape" => Any[setname])
    mv[mfactor] = Dict{String,Any}("type" => "parameter", "default" => 0.0, "shape" => Any[setname])

    # --- per-rect cell-gather observeds: cell_F[c] = index(F, index(member_factor, c)) ---
    # Declaration and DEFINING EQUATION, emitted in sorted name order so the
    # rewritten document does not depend on `rects`' construction order.
    for F in sort(rects)
        shape = get(cell_shapes, F, nothing)
        if shape === nothing
            sh = get(mv, F, nothing)
            shape = (sh isa AbstractDict && get(sh, "shape", nothing) isa AbstractVector) ?
                String[String(x) for x in sh["shape"]] : String[C]
        end
        decl, defn = _pd_gather_defn(F, shape, setname, mfactor,
                                     get(d, "index_sets", nothing), C)
        mv[cellgath(F)] = decl
        push!(eqs, Dict{String,Any}("lhs" => cellgath(F), "rhs" => defn))
    end

    # --- gate the provider-backed arrays onto the derived axis ---
    for A in plan.A_names
        mv[A]["shape"] = Any[setname, plan.rcv_set]
    end

    # --- rewrite E: axis → derived set, rect factors → cell gathers, + GATE ---
    # The rewritten `E` still reduces over the FULL record axis, so without a
    # gate it visits |support|·|records| pairs — 1520·43650 on isrm.esm. Attach
    # the SAME overlap clause the producer carries, re-pointed at the generated
    # cell gathers, and the enumeration driver (§5.5.6) walks one candidate
    # partner list per output cell instead. The clause is derived, not authored:
    # its envelopes are exactly the ones `_pd_parse_containment` read out of this
    # aggregate's own containment predicate.
    for (Ename, csym, e_src, e_tgt) in plan.E_specs
        # DEEP-COPY before the in-place rect rewrite. `_to_ordered` is
        # identity-MEMOIZED, so a document built in memory keeps whatever
        # subtree sharing its author created — and the ISRM-shaped fixtures
        # share one `contains(...)` predicate object across every aggregate that
        # bins. Rewriting E's rects in place would then reach through the shared
        # node into a variable that is NOT being re-pointed (a mirrored
        # per-record aggregate, say) and leave it gathering the compact cell
        # buffers with full-grid indices. Copying first confines the rewrite to
        # this variable; the emitted JSON is unchanged (sharing is not a
        # document-level property).
        expr = deepcopy(_pd_defining_rhs(eqs, defs, Ename))
        eqs[defs[Ename]]["rhs"] = expr
        expr["ranges"][csym]["from"] = setname
        _pd_rewrite_rects!(expr, rectmap)
        haskey(expr, "args") && (expr["args"] = Any[get(rectmap, string(s), s) for s in expr["args"]])
        mv[Ename]["shape"] = Any[setname]
        haskey(expr, "join") || (expr["join"] = Any[_pd_overlap_clause(
            e_src, String[get(rectmap, F, F) for F in e_tgt])])
        _pd_assert_rects_rebound(expr, Ename, rectmap, reg)
    end

    # --- MIRRORED orientation: gate only ---
    # A per-record binning aggregate `P[r] = Σ_{c∈C} [contains(cell_c, pt_r)]·…`
    # is the same join read the other way round. It gets ONLY the gate — no
    # derived index set, no `distinct` producer, no `member_factor`, no provider
    # gating — because it wants the FULL record axis: every record must produce a
    # value, and a record outside the grid must come out as the semiring identity
    # (the driver leaves such a position with no term and 0̄ is emitted). There is
    # nothing to compact, so a mirrored VALUE-INVENTION would derive a support set
    # nobody reads. Its envelopes stay the document's own const-array factors
    # (the cell axis is not re-pointed), so the mirror also needs no rect gathers.
    for (Pname, p_src, p_tgt) in plan.mirror_specs
        pexpr = deepcopy(_pd_defining_rhs(eqs, defs, Pname))   # see the deep-copy note above
        eqs[defs[Pname]]["rhs"] = pexpr
        haskey(pexpr, "join") || (pexpr["join"] = Any[_pd_overlap_clause(p_src, p_tgt)])
    end

    # --- restrict the conc reductions to the derived axis ---
    for (cname, ssym) in plan.conc_specs
        _pd_defining_rhs(eqs, defs, cname)["ranges"][ssym]["from"] = setname
    end

    # --- generated `distinct` producer (reuses E's containment + geometry) ---
    producer = Dict{String,Any}(
        "lhs" => _pd_ix(memvar, "m"),
        "rhs" => Dict{String,Any}(
            "op" => "aggregate", "output_idx" => Any["m"],
            "ranges" => Dict{String,Any}(
                plan.rep_rsym => Dict{String,Any}("from" => plan.R),
                plan.rep_csym => Dict{String,Any}("from" => C)),
            "expr" => Dict{String,Any}("op" => "true", "args" => Any[]),
            "distinct" => true, "semiring" => "bool_and_or", "id" => faqid,
            "join" => Any[_pd_overlap_clause(plan.src_env, plan.tgt_env)],
            "filter" => prod_filter,
            "key" => Dict{String,Any}("op" => "skolem", "label" => "cell",
                                      "args" => Any[plan.rep_csym]),
            "args" => Any[unique(vcat(plan.src_env, plan.tgt_env))...]))
    pushfirst!(eqs, producer)
    _pd_canonicalize_equations!(d["models"][mname])

    # --- inspectable pushdown provenance / gated_select record ---
    # Stashed under `metadata.x_esd` — the spec's free-form extension point
    # (esm-spec §3) — so the transformed document still round-trips `load`'s
    # schema validation (a top-level key would not). The `gated_select` mirrors
    # the `data_sources.<name>.metadata.x_esd.gated_select` a real gated
    # provider is built from (see `provider_gate_spec`): the runtime gate for
    # this model's provider-backed arrays, gating the cell axis by the derived
    # support set.
    md = get!(d, "metadata", OrderedDict{String,Any}())
    xesd = get!(md, "x_esd", OrderedDict{String,Any}())
    xesd["pushdown"] = Dict{String,Any}(
        "derived_set" => setname, "producer_id" => faqid,
        "member_factor" => mfactor, "member_var" => memvar,
        "gated_select" => Dict{String,Any}(
            "gated_by" => setname, "applies_to" => Any[plan.A_names...],
            "gated_axis" => 0))
    return d
end

# ============================================================================
# RECORD-DERIVED PROVIDER GATING (Phase 1, clean consolidation).
#
# `desugar_pushdown` records `metadata.x_esd.pushdown.gated_select` — which
# derived set gates which model arrays on which axis — but until Phase 1
# NOTHING read that record back: callers hand-implemented `provider_gate_spec`
# or hand-authored gate dicts. These helpers close the loop for `prepare`:
# given the REWRITTEN (pre-flatten) document and the caller's public
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
From esm 1.0.0 that is a direct match: a source is not a coupling endpoint, so a
provider is keyed by the consuming parameter's own flattened name
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
    gates = Dict{String,Any}()
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
        gates[k] = Dict{String,Any}("axes" => axes, "applies_to" => Any[local_name])
    end
    return gates
end

# Flattened parameter name ⇒ the `data_sources` key its `update` names
# (esm-spec §8.5). Walks `models` and their `subsystems` under the same dotted
# prefixes `flatten` builds.
function _pushdown_data_bindings(doc::AbstractDict)
    out = Dict{String,String}()
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
function _pushdown_gate_axes(doc::AbstractDict, loader::AbstractString,
                             gset::AbstractString, gaxis::Int, mrank::Int)
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
                push!(axes, Dict{String,Any}("gated_by" => String(gset)))
                gpos = nonfixed
                nonfixed += 1
            elseif ax isa AbstractDict && haskey(ax, "fixed")
                fx = ax["fixed"]
                fi = fx isa AbstractVector ? Int(first(fx)) : Int(fx)
                push!(axes, Dict{String,Any}("fixed" => Any[fi]))
            else
                push!(axes, "all")
                nonfixed += 1
            end
        end
        gpos == gaxis || throw(RefreshError(
            "data_sources.$loader gated_select template puts the gated axis at " *
            "non-fixed position $gpos, but the rewrite record gates model axis " *
            "$gaxis — the loader template and the rewritten arrays disagree"))
        return axes
    end
    (0 <= gaxis < mrank) || throw(RefreshError(
        "rewrite record gated_axis $gaxis out of range for rank-$mrank gated arrays"))
    axes = Any[fill("all", mrank)...]
    axes[gaxis + 1] = Dict{String,Any}("gated_by" => String(gset))
    return axes
end

"""
    _inject_pushdown_aliases!(dst, run_doc, coupling_pairs) -> dst

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
function _inject_pushdown_aliases!(dst::AbstractDict, run_doc::AbstractDict,
                                   coupling_pairs::AbstractVector)
    for (frm, to) in coupling_pairs
        haskey(dst, frm) && !haskey(dst, to) && (dst[to] = dst[frm])
    end
    models = get(run_doc, "models", nothing)
    models isa AbstractDict || return dst
    vnames = String[]
    for (_, m) in models
        m isa AbstractDict || continue
        mv = get(m, "variables", nothing)
        mv isa AbstractDict || continue
        append!(vnames, (String(k) for k in keys(mv)))
    end
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
# BEFORE `_prepare_run_doc` flattens them away, for `_inject_pushdown_aliases!`.
function _pushdown_coupling_pairs(doc::AbstractDict)
    out = Pair{String,String}[]
    cp = get(doc, "coupling", nothing)
    cp isa AbstractVector || return out
    for c in cp
        (c isa AbstractDict && get(c, "type", nothing) == "variable_map") || continue
        frm = String(get(c, "from", "")); to = String(get(c, "to", ""))
        (isempty(frm) || isempty(to)) || push!(out, frm => to)
    end
    return out
end
