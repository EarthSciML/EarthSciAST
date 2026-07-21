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
    file = coerce_esm_file(esm)
    m = _select_model_or_nothing(file, model_name)
    m === nothing && return esm
    mname = _pd_model_name(file, model_name)
    mname === nothing && return esm
    plan = _pd_detect(m, file.index_sets)
    plan === nothing && return esm
    return _pd_apply(esm, mname, plan)
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

# Is `ev` a binning aggregate `E[c] = Σ_r [contains(cell_c, pt_r)] · …` over the
# cell set `C`? Returns the binding (`c_sym`, `r_sym`, record set `R`, and the
# parsed overlap envelopes) or `nothing`.
function _pd_detect_binning(ev::ModelVariable, C::AbstractString)
    ev.type == ObservedVariable || return nothing
    (ev.shape !== nothing && length(ev.shape) == 1 && ev.shape[1] == C) || return nothing
    agg = ev.expression
    (agg isa OpExpr && _is_aggregate_op(agg.op)) || return nothing
    oz = _pd_oplus(agg); oz === nothing && return nothing
    (oz[1] == "+" && oz[2] == 0.0) || return nothing              # SEMIRING GUARD
    oi = agg.output_idx
    (oi !== nothing && length(oi) == 1) || return nothing
    c_sym = String(oi[1])
    ranges = agg.ranges === nothing ? Dict{String,Any}() : agg.ranges
    length(ranges) == 2 || return nothing
    (haskey(ranges, c_sym) && ranges[c_sym] isa IndexSetRef && ranges[c_sym].from == C) || return nothing
    r_sym = nothing
    for k in keys(ranges); k == c_sym && continue; r_sym = k; end
    (r_sym !== nothing && ranges[r_sym] isa IndexSetRef) || return nothing
    body = agg.expr_body
    body isa OpExpr || return nothing
    pred = _pd_find_ifelse_cond(body)
    pred === nothing && return nothing
    env = _pd_parse_containment(pred, c_sym, r_sym)
    env === nothing && return nothing
    return (c_sym = c_sym, r_sym = r_sym, R = ranges[r_sym].from,
            src_env = env.src_env, tgt_env = env.tgt_env)
end

# Detect the pushdown pattern across a model's observeds. Returns a plan
# NamedTuple, or `nothing` when nothing matches / the semiring guard fails.
function _pd_detect(model::Model, index_sets::AbstractDict)
    vars = model.variables
    conc_specs = Tuple{String,String}[]        # (conc name, reduction symbol)
    A_names = String[]                          # provider-backed arrays to gate
    E_specs = Tuple{String,String}[]            # (E name, cell output symbol)
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
        body = agg.expr_body
        (body isa OpExpr && body.op == "*" && length(body.args) == 2) || continue
        parts = Any[_pd_index_syms(a) for a in body.args]
        any(p -> p === nothing, parts) && continue
        Aname = nothing; Ename = nothing
        for p in parts
            f, syms = p
            if syms == [s_sym, rcv_sym]
                Aname = f
            elseif syms == [s_sym]
                Ename = f
            end
        end
        (Aname !== nothing && Ename !== nothing) || continue
        av = get(vars, Aname, nothing)
        (av !== nothing && av.type == ParameterVariable && av.shape !== nothing &&
         length(av.shape) == 2 && av.shape[1] == c_set && av.shape[2] == r_set) || continue
        ev = get(vars, Ename, nothing); ev === nothing && continue
        bind = _pd_detect_binning(ev, c_set)
        bind === nothing && continue

        if C === nothing
            C = c_set; rcv_set = r_set; R = bind.R
            src_env = bind.src_env; tgt_env = bind.tgt_env
            rep_ename = Ename; rep_csym = bind.c_sym; rep_rsym = bind.r_sym
        else
            (c_set == C && r_set == rcv_set) || continue          # narrow: one cell set
        end
        push!(conc_specs, (cname, s_sym))
        Aname in A_names || push!(A_names, Aname)
        any(e -> e[1] == Ename, E_specs) || push!(E_specs, (Ename, bind.c_sym))
    end
    isempty(conc_specs) && return nothing
    return (C = C, rcv_set = rcv_set, R = R, conc_specs = conc_specs,
            A_names = A_names, E_specs = E_specs, src_env = src_env, tgt_env = tgt_env,
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

    # --- rewrite E: axis → derived set, rect factors → cell gathers ---
    for (Ename, csym) in plan.E_specs
        expr = mv[Ename]["expression"]
        expr["ranges"][csym]["from"] = setname
        _pd_rewrite_rects!(expr, rectmap)
        haskey(expr, "args") && (expr["args"] = Any[get(rectmap, string(s), s) for s in expr["args"]])
        mv[Ename]["shape"] = Any[setname]
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
            "join" => Any[Dict{String,Any}("overlap" => Dict{String,Any}(
                "src_env" => Any[plan.src_env...], "tgt_env" => Any[plan.tgt_env...],
                "eps" => 0.0))],
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
