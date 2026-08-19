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
    file = coerce_esm_file(esm)
    m = _select_model_or_nothing(file, model_name)
    m === nothing && return esm
    mname = _pd_model_name(file, model_name)
    mname === nothing && return esm
    plan = _pd_detect(m, file.index_sets)
    plan === nothing && return esm
    return _pd_apply(esm, mname, plan)
end

"""
    _pushdown_record(doc) -> Union{Nothing,AbstractDict}

The rewrite's provenance record `metadata.x_esd.pushdown` written by
[`desugar_pushdown`](@ref) (see `_pd_apply`), or `nothing` when `doc` carries
none. This is the record the engine reads BACK to derive provider gates —
callers no longer hand-author gate dicts (`prepare(...; pushdown_rewrite=true)`
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

# ---- typed-IR leaf helpers -------------------------------------------------
_pd_varname(e) = e isa VarExpr ? e.name : nothing

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

# Parse a rectangle-containment predicate — an `and`/`*` of comparisons, each
# between a CELL-indexed rect factor (`c_sym`) and a RECORD-indexed point factor
# (`r_sym`) — into the overlap-gate envelopes:
#   src_env = [Px, Py]                         (the two point coordinates)
#   tgt_env = [xmin, ymin, xmax, ymax]         (the rect bound factors)
# derived from each comparison's orientation (a lower vs upper bound), so the
# broad-phase envelope is correct regardless of the authored comparison order.
# Returns `nothing` (⇒ no match) unless there are exactly two point coordinates,
# each with BOTH a min and a max cell bound.
function _pd_parse_containment(pred, c_sym::AbstractString, r_sym::AbstractString)
    pred isa OpExpr || return nothing
    comps = pred.op in ("and", "*") ? pred.args : ASTExpr[pred]
    bounds = Dict{String,Dict{Symbol,String}}()
    point_order = String[]
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
        haskey(bounds, Fp) || (push!(point_order, Fp); bounds[Fp] = Dict{Symbol,String}())
        bounds[Fp][kind] = Fc
    end
    length(point_order) == 2 || return nothing
    Px, Py = point_order[1], point_order[2]
    for P in (Px, Py)
        (haskey(bounds[P], :min) && haskey(bounds[P], :max)) || return nothing
    end
    return (src_env = String[Px, Py],
            tgt_env = String[bounds[Px][:min], bounds[Py][:min],
                             bounds[Px][:max], bounds[Py][:max]])
end

# Is `ev` a BINNING aggregate — a `+`-semiring reduction over TWO 1-D index
# sets whose body carries a rectangle-containment predicate between a
# CELL-indexed rect factor and a RECORD-indexed point factor? BOTH orientations
# are recognised (§5.5.6 "recognised desugar patterns"):
#
#   FORWARD  E[c] = Σ_r [contains(cell_c, pt_r)] · …    (the cell axis is output)
#   MIRROR   P[r] = Σ_c [contains(cell_c, pt_r)] · …    (the record axis is output)
#
# The gate is IDENTICAL either way — the enumeration driver binds its two
# symbols from the join clause's declared envelopes and knows nothing about
# cells vs records, and the aggregate's own `output_idx` decides the result's
# orientation. So the guards here are on the aggregate's SHAPE, not on which
# axis is which: `out_set` is the index set the observed is shaped on, the
# single other range supplies the opposite side, and the CONTAINMENT PREDICATE
# itself says which symbol is the cell (it carries the four rect BOUND factors)
# and which is the record (the two point coordinates).
#
# Returns `(c_sym, r_sym, C, R, out_is_cell, src_env, tgt_env)` or `nothing`.
function _pd_detect_binning(ev::ModelVariable, out_set::AbstractString)
    ev.type == ObservedVariable || return nothing
    (ev.shape !== nothing && length(ev.shape) == 1 && ev.shape[1] == out_set) || return nothing
    agg = ev.expression
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
    # Exactly one of the two assignments parses: `_pd_parse_containment` demands
    # each comparison put the cell symbol on one side and the record symbol on
    # the other, and that the record side yield exactly two coordinates each
    # with a min AND a max cell bound.
    env = _pd_parse_containment(pred, out_sym, in_sym)
    env === nothing || return (c_sym = out_sym, r_sym = in_sym,
                               C = String(out_set), R = in_set, out_is_cell = true,
                               src_env = env.src_env, tgt_env = env.tgt_env)
    env = _pd_parse_containment(pred, in_sym, out_sym)
    env === nothing && return nothing
    return (c_sym = in_sym, r_sym = out_sym, C = in_set, R = String(out_set),
            out_is_cell = false, src_env = env.src_env, tgt_env = env.tgt_env)
end

# The MIRRORED-orientation binning aggregates of a model: per-RECORD observeds
# `P[r] = Σ_{c∈C} [contains(cell_c, pt_r)] · …` over the plan's cell set `C` and
# record set `R`. Returned as `(name, src_env, tgt_env)` triples, sorted by name
# so the emitted document is identical across bindings and hash seeds.
#
# A mirror needs NOTHING but the gate — see the note on the mirrored arm in
# `_pd_apply`. Its cell axis stays the FULL `C`, so its envelope factors are the
# document's own const-array rects, unrewritten.
function _pd_mirror_specs(model::Model, C::AbstractString, R::AbstractString,
                          forward_names)
    out = Tuple{String,Vector{String},Vector{String}}[]
    for (name, v) in model.variables
        name in forward_names && continue
        bind = _pd_detect_binning(v, R)
        bind === nothing && continue
        (!bind.out_is_cell && bind.C == C && bind.R == R) || continue
        # Never stack a second gate on an aggregate that already declares a join.
        (v.expression isa OpExpr && (v.expression::OpExpr).join !== nothing) && continue
        push!(out, (name, bind.src_env, bind.tgt_env))
    end
    sort!(out; by = t -> t[1])
    return out
end

# Detect the pushdown pattern across a model's observeds. Returns a plan
# NamedTuple, or `nothing` when nothing matches / the semiring guard fails.
function _pd_detect(model::Model, index_sets::AbstractDict)
    vars = model.variables
    conc_specs = Tuple{String,String}[]        # (conc name, reduction symbol)
    A_names = String[]                          # provider-backed arrays to gate
    # (E name, cell output symbol, gate src_env, gate tgt_env)
    E_specs = Tuple{String,String,Vector{String},Vector{String}}[]
    C = nothing; rcv_set = nothing; R = nothing
    src_env = nothing; tgt_env = nothing
    rep_ename = nothing; rep_csym = nothing; rep_rsym = nothing

    for (cname, cv) in vars
        cv.type == ObservedVariable || continue
        agg = cv.expression
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
        bind = _pd_detect_binning(ev, c_set)
        (bind === nothing || !bind.out_is_cell) && continue       # FORWARD arm only

        if C === nothing
            C = c_set; rcv_set = r_set; R = bind.R
            src_env = bind.src_env; tgt_env = bind.tgt_env
            rep_ename = Ename; rep_csym = bind.c_sym; rep_rsym = bind.r_sym
        else
            (c_set == C && r_set == rcv_set) || continue          # narrow: one cell set
        end
        push!(conc_specs, (cname, s_sym))
        Aname in A_names || push!(A_names, Aname)
        any(e -> e[1] == Ename, E_specs) ||
            push!(E_specs, (Ename, bind.c_sym, bind.src_env, bind.tgt_env))
    end
    isempty(conc_specs) && return nothing
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
    mirror_specs = _pd_mirror_specs(model, C, R, Set{String}(e[1] for e in E_specs))
    return (C = C, rcv_set = rcv_set, R = R, conc_specs = conc_specs,
            A_names = A_names, E_specs = E_specs, mirror_specs = mirror_specs,
            src_env = src_env, tgt_env = tgt_env,
            rep_ename = rep_ename, rep_csym = rep_csym, rep_rsym = rep_rsym)
end

# ---- dict-form emission ----------------------------------------------------

# In-place: rewrite every `index(F, …)` whose factor `F` is a key of `rectmap`
# to `index(rectmap[F], …)` throughout a dict-form AST subtree.
function _pd_rewrite_rects!(node, rectmap::AbstractDict)
    if node isa AbstractDict
        if get(node, "op", nothing) == "index"
            a = get(node, "args", nothing)
            if a isa AbstractVector && !isempty(a) && a[1] isa AbstractString &&
               haskey(rectmap, a[1])
                a[1] = rectmap[a[1]]
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

# Apply the desugar to the raw document, returning a NEW mutable dict tree.
function _pd_apply(esm, mname::AbstractString, plan)
    d = _to_ordered(esm)                        # fresh, mutable, string-keyed
    C = plan.C
    setname = "pd_support__" * C
    faqid   = "pd_faq__" * C
    memvar  = "pd_members__" * C
    mfactor = "pd_member_factor__" * C
    cellgath(F) = "pd_cell__" * C * "__" * F

    rects = String[]                            # rect factors, [xmin,ymin,xmax,ymax] order
    for F in plan.tgt_env; F in rects || push!(rects, F); end
    rectmap = Dict{String,String}(F => cellgath(F) for F in rects)

    # --- derived index set ---
    haskey(d, "index_sets") || (d["index_sets"] = OrderedDict{String,Any}())
    d["index_sets"][setname] = Dict{String,Any}(
        "kind" => "derived", "from_faq" => faqid, "member_factor" => mfactor)

    mv = d["models"][mname]["variables"]

    # --- producer filter comparisons, deep-copied from the representative E
    #     BEFORE E is rewritten (they must keep full-grid rect factor refs) ---
    repexpr = mv[plan.rep_ename]["expression"]
    ifcond = _pd_dict_find_ifelse_cond(get(repexpr, "expr", nothing))
    ifcond === nothing && error("pushdown desugar: representative E lost its containment ifelse")
    comps = get(ifcond, "op", nothing) in ("and", "*") ? ifcond["args"] : Any[ifcond]
    prod_filter = Dict{String,Any}("op" => "*", "args" => Any[_to_ordered(c) for c in comps])

    # --- member state var + member_factor param ---
    mv[memvar]  = Dict{String,Any}("type" => "state", "shape" => Any[setname])
    mv[mfactor] = Dict{String,Any}("type" => "parameter", "default" => 0.0, "shape" => Any[setname])

    # --- per-rect cell-gather observeds: cell_F[c] = index(F, index(member_factor, c)) ---
    for F in rects
        mv[cellgath(F)] = Dict{String,Any}(
            "type" => "observed", "shape" => Any[setname],
            "expression" => Dict{String,Any}(
                "op" => "aggregate", "output_idx" => Any["c"],
                "ranges" => Dict{String,Any}("c" => Dict{String,Any}("from" => setname)),
                "args" => Any[F, mfactor],
                "expr" => _pd_ix(F, _pd_ix(mfactor, "c"))))
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
        expr = deepcopy(mv[Ename]["expression"])
        mv[Ename]["expression"] = expr
        expr["ranges"][csym]["from"] = setname
        _pd_rewrite_rects!(expr, rectmap)
        haskey(expr, "args") && (expr["args"] = Any[get(rectmap, string(s), s) for s in expr["args"]])
        mv[Ename]["shape"] = Any[setname]
        haskey(expr, "join") || (expr["join"] = Any[_pd_overlap_clause(
            e_src, String[get(rectmap, F, F) for F in e_tgt])])
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
        pexpr = deepcopy(mv[Pname]["expression"])       # see the deep-copy note above
        mv[Pname]["expression"] = pexpr
        haskey(pexpr, "join") || (pexpr["join"] = Any[_pd_overlap_clause(p_src, p_tgt)])
    end

    # --- restrict the conc reductions to the derived axis ---
    for (cname, ssym) in plan.conc_specs
        mv[cname]["expression"]["ranges"][ssym]["from"] = setname
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
    eqs = get(d["models"][mname], "equations", nothing)
    if !(eqs isa AbstractVector)
        eqs = Any[]
        d["models"][mname]["equations"] = eqs
    end
    push!(eqs, producer)

    # --- inspectable pushdown provenance / gated_select record ---
    # Stashed under `metadata.x_esd` — the spec's free-form extension point
    # (esm-spec §3) — so the transformed document still round-trips `load`'s
    # schema validation (a top-level key would not). The `gated_select` mirrors
    # the `data_loaders.<name>.metadata.x_esd.gated_select` a real gated
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

A provider is GATED when its key names a `data_loaders` variable (`"<Loader>"`
or `"<Loader>.<var>"`) that a coupling `variable_map` routes onto one of the
record's `applies_to` model arrays. The gate's per-NATIVE-axis `axes` come from
the loader's own `metadata.x_esd.gated_select.axes` template when it declares
one (the record's GENERATED set name — `pd_support__*` — replacing whatever set
the template names, since the template predates the rewrite), else from the
model array's rank with `gated_by` at the record's `gated_axis`. `applies_to`
carries the LOADER-variable tails, whose `_const_factor_aliases` expansion
covers the post-flatten `"<Loader>.<var>"` spelling the run equations gather.

Empty when `doc` carries no record, no coupling routes a provider onto a gated
array, or `providers === nothing` — record-derived gating is a coupling-scoped
mechanism; a provider outside it falls back to `provider_gate_spec`.
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

    # coupling: "<Loader>.<var>" => the gated model array's LOCAL (tail) name.
    fed = Dict{String,String}()
    cp = get(doc, "coupling", nothing)
    if cp isa AbstractVector
        for c in cp
            (c isa AbstractDict && get(c, "type", nothing) == "variable_map") || continue
            frm = String(get(c, "from", "")); to = String(get(c, "to", ""))
            (isempty(frm) || isempty(to) || !occursin('.', frm)) && continue
            String(split(to, '.')[end]) in applies && (fed[frm] = to)
        end
    end
    isempty(fed) && return gates

    mrank = _pushdown_gated_rank(doc, applies)
    for k0 in keys(providers)
        k = String(k0)
        if haskey(fed, k)                              # "<Loader>.<var>" provider
            loader = String(split(k, '.'; limit=2)[1])
            lvars = String[String(split(k, '.'; limit=2)[2])]
        else                                           # whole-loader provider?
            loader = k
            lvars = sort!(String[String(split(f, '.'; limit=2)[2])
                                 for f in keys(fed)
                                 if String(split(f, '.'; limit=2)[1]) == k])
            isempty(lvars) && continue
        end
        axes = _pushdown_gate_axes(doc, loader, gset, gaxis, mrank)
        gates[k] = Dict{String,Any}("axes" => axes, "applies_to" => Any[lvars...])
    end
    return gates
end

# Rank of the (rewritten) gated model arrays — the fallback native rank when a
# loader declares no axes template. After `_pd_apply` every applies_to array is
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

# Per-NATIVE-axis gate `axes` for `loader`: the loader's declared
# `metadata.x_esd.gated_select.axes` template with the GENERATED set name
# substituted into its `gated_by` slot (validated: the gated axis must sit at
# `gaxis` among the non-fixed axes, or the record and template disagree about
# which native axis is gated); else a rank-`mrank` all-axes gate with
# `gated_by` at `gaxis`.
function _pushdown_gate_axes(doc::AbstractDict, loader::AbstractString,
                             gset::AbstractString, gaxis::Int, mrank::Int)
    tpl = nothing
    loaders = get(doc, "data_loaders", nothing)
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
            "data_loaders.$loader gated_select template puts the gated axis at " *
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

Alias-key injection for the `prepare` pushdown path (same-object references,
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
