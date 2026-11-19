# Expansion of surviving `apply_expression_template` references on the typed
# tree (esm-spec §9.6.4 rule 2), with the template instantiation cache.

# ===========================================================================
# Typed-IR reference expansion (esm-spec §9.6.4 rule 2 on the typed AST)
# ===========================================================================

"""
    _expand_expr_refs(e::ASTExpr, reg) -> ASTExpr

Fully expand every surviving `apply_expression_template` `OpExpr` in the typed
expression `e` against the component registry `reg` (name → raw decl), to a
fixpoint. Sound (a reference denotes its expansion, §9.6.4 rule 2): the
apply node is round-tripped to its raw form, the raw `_substitute` splices the
bindings into the template body (handling variable AND scalar-field param sites),
and the result is re-parsed and re-expanded — so nested references (in the body
OR in the bindings) are expanded too. Non-apply nodes recurse via `map_children`
(apply nodes are the only `bindings`-bearing nodes, so `map_children` not
descending into `bindings` is exactly right here). This is the per-node `Expand`
fallback the tree-walk build uses and the Expand-at-entry the MTK build uses.
"""
_expand_expr_refs(e::VarExpr, reg) = e
_expand_expr_refs(e::NumExpr, reg) = e
_expand_expr_refs(e::IntExpr, reg) = e
_expand_expr_refs(e::OpExpr, reg) = _expand_expr_refs(e, reg, nothing)

# `sites`-recording variants (compile-once template tier, RFC out-of-line-
# expression-templates §7.7): when `sites` is an `IdDict`, every apply node's
# EXPANSION ROOT — the freshly parsed, fully expanded subtree that replaces it —
# is recorded `root => apply node`, at every nesting level. The tree-walk build's
# affine stencil compiler treats each recorded root as a compilation boundary
# (one compiled body per use site × region class) while every other consumer
# sees the plain Option-A expanded tree. `sites === nothing` records nothing.
const _TemplateSites = Union{Nothing, IdDict{OpExpr, OpExpr}}

# Expansion memo: the recursive expansion of an `apply_expression_template`
# node is a pure function of (template name, unexpanded bindings, registry),
# and the registry is fixed for one memo, so two structurally identical apply
# sites expand to structurally equal subtrees. Keying `(name, canonical
# bindings)` → expanded root lets the second site reuse the first's expansion
# instead of serializing, substituting, re-parsing and recursing again (a
# template that recurs at every equation, with nested sub-templates, would
# otherwise re-expand per parent).
#
# Returning the same object for two sites makes the expanded equation set a
# DAG, the one interning (`_intern_model`) would produce anyway. Its identity
# consumers are DAG-safe: the stencil compiler reads `sites` only as a
# `haskey` boundary set, so a shared root is still a boundary, and
# `_translate_sites_lockstep!` keeps a `seen` set. The expanded output is the
# same with or without the memo; `nothing` is the per-site re-expansion, for a
# caller that wants the sharing measured rather than assumed.
#
# The memo also carries the per-template INSTANTIATION cache (`_TplSkel`): each
# template is substituted, parsed and expanded ONCE per memo with a sentinel
# variable standing for every parameter, and each call site is then the typed
# substitution of its bindings into that cached tree. See `_TplSkel`.
#
# A cache may serve several expansions against one registry (the build's
# front-door pre-passes and its compile-once entry share one): `roots` keeps,
# for each memoized expansion, every site root recorded while it was expanded,
# so a later hit records them all in its caller's `sites`, as the first
# expansion did.
mutable struct _ExpandCache
    bind::Dict{Tuple{String, String}, OpExpr}
    roots::IdDict{OpExpr, Vector{Pair{OpExpr, OpExpr}}}
    reg::Any                       # the registry the cache was filled from
    skel::Dict{String, Any}        # template name => `_TplSkel`, or `nothing` (ineligible)
    building::Vector{Set{String}}  # per skeleton under construction: params whose image is a nested root
    # The nodes the unlowered-operator gate (`_reject_unlowered_operators`) has
    # passed, as equation left and right sides: the front door and the build
    # entry gate the same expansions.
    gate_lhs::IdDict{OpExpr, Nothing}
    gate_rhs::IdDict{OpExpr, Nothing}
    # The build's call predicate (`_tpl_is_called`, templates/frames.jl): a
    # reference it accepts is kept (its bindings expanded) and compiled as a
    # call; `nothing` expands every reference.
    keep::Any
end
_ExpandCache(
    bind::Dict{Tuple{String, String}, OpExpr} = Dict{Tuple{String, String}, OpExpr}();
    keep = nothing
) =
    _ExpandCache(
    bind, IdDict{OpExpr, Vector{Pair{OpExpr, OpExpr}}}(), nothing, Dict{String, Any}(), Set{String}[],
    IdDict{OpExpr, Nothing}(), IdDict{OpExpr, Nothing}(), keep
)

# Bind `memo` to `reg`: what it holds from another registry is dropped.
function _cache_for!(memo::_ExpandCache, reg)
    memo.reg === reg && return memo
    if memo.reg !== nothing
        empty!(memo.bind); empty!(memo.roots); empty!(memo.skel)
    end
    memo.reg = reg
    return memo
end
# The entry points also take a bare bindings memo.
_expand_cache(m::Union{Nothing, _ExpandCache}) = m
_expand_cache(m::Dict{Tuple{String, String}, OpExpr}) = _ExpandCache(m)

const _ExpandMemo = Union{Nothing, _ExpandCache}

# `task_local_storage` key: while `true`, `_expand_expr_refs` marks the root of
# each expansion it makes with its template's name (`OpExpr.template_origin`),
# for the elementwise lift (esm-spec §9.6.11). Set at a mount, whose leaf's
# references are expanded at load, and by the lift itself. Each of those
# callers passes a memo of its own, so an unmarked cached expansion is never
# served where a marked one is wanted.
const _MARK_TEMPLATE_ORIGINS_KEY = :earthsciast_mark_template_origins

_marking_template_origins() = get(task_local_storage(), _MARK_TEMPLATE_ORIGINS_KEY, false)::Bool

# The key a raw-JSON expansion made while marking (`_expand_refs_walk`, at a
# mount) carries its template's name under, until the expression parser turns it
# into `OpExpr.template_origin`. Load provenance: no document writes it, and
# serialization never emits `template_origin`.
const _TEMPLATE_ORIGIN_WIRE_KEY = "__esm_template_origin"

# The JSON-pointer path of the first `_TEMPLATE_ORIGIN_WIRE_KEY` in `node`, or
# `nothing`.
_template_origin_key_path(node) = _find_json_path(n -> haskey(n, _TEMPLATE_ORIGIN_WIRE_KEY), node)

# Refuse an authored document that spells `_TEMPLATE_ORIGIN_WIRE_KEY`: the key
# is load provenance, and the schema admits no such property, so an authored
# one fails the schema check as it does in every binding. Runs on each file as
# authored, before a mount splices in content the load itself marked, which the
# schema check below then reads through `_strip_template_origins`.
function _reject_authored_template_origins(raw)
    path = _template_origin_key_path(raw)
    path === nothing && return nothing
    err = SchemaError(
        isempty(path) ? "/" : path,
        "Additional property '$(_TEMPLATE_ORIGIN_WIRE_KEY)' is not allowed: it is " *
            "load provenance, which no document carries (esm-spec §9.6.11)",
        "additionalProperties"
    )
    throw(SchemaValidationError(_format_schema_errors([err]), [err]))
end

# `node` without any `_TEMPLATE_ORIGIN_WIRE_KEY`: the document as authored and
# expanded, for the schema check, which the private key would fail. Copies only
# the containers on a path to a mark; returns `node` itself when it holds none.
# Every authored file was refused above if it spelled the key, so what this
# removes is only the load's own marks.
_strip_template_origins(node) =
    _rewrite_json(node; leaves = false) do rw, n
    haskey(n, _TEMPLATE_ORIGIN_WIRE_KEY) || return _JSON_DESCEND
    return _rewrite_json_children(rw, n; drop = _TEMPLATE_ORIGIN_WIRE_KEY)
end

# `ex` marked as the root of an expansion of `name`, while marking is on.
_mark_origin(ex, name::String) =
    (ex isa OpExpr && _marking_template_origins()) ? reconstruct(ex; template_origin = name) : ex

_expand_expr_refs(e::VarExpr, reg, ::_TemplateSites, ::_ExpandMemo = nothing) = e
_expand_expr_refs(e::NumExpr, reg, ::_TemplateSites, ::_ExpandMemo = nothing) = e
_expand_expr_refs(e::IntExpr, reg, ::_TemplateSites, ::_ExpandMemo = nothing) = e
function _expand_expr_refs(
        e::OpExpr, reg, sites::_TemplateSites,
        memo::_ExpandMemo = nothing
    )
    if e.op == APPLY_EXPRESSION_TEMPLATE_OP
        name = e.name
        (name !== nothing && reg !== nothing && haskey(reg, name)) || throw(
            ExpressionTemplateError(
                ERROR_CODES.APPLY_EXPRESSION_TEMPLATE_UNKNOWN_TEMPLATE,
                "apply_expression_template references template " *
                    "'$(name === nothing ? "?" : name)' with no in-scope registry entry"
            )
        )
        # A reference the build compiles as a call stays; only the references
        # in its bindings expand.
        if memo !== nothing && memo.keep !== nothing && memo.keep(e)
            return map_children(c -> _expand_expr_refs(c, reg, sites, memo), e)
        end
        bindings_raw = Dict{String, Any}()
        if e.bindings !== nothing
            for (k, v) in e.bindings
                bindings_raw[string(k)] = serialize_expression(v)
            end
        end
        # Canonical bindings key: name-sorted `k=serialized(v)` pairs. The same
        # serialization feeds `_substitute` below, so the key captures exactly
        # what determines the expansion (two sites collide iff they substitute
        # identically). Only built when the memo is live.
        if memo === nothing
            substituted = _substitute(_raw_get(reg[name], "body"), bindings_raw)
            ex = _mark_origin(_expand_expr_refs(expression_from_json(substituted), reg, sites, memo), name::String)
            _record_site!(sites, memo, ex, e)
            return ex
        end
        _cache_for!(memo, reg)
        bkey = join(
            sort!(String[k * "\0" * _stable_json(v) for (k, v) in bindings_raw]),
            "\x01"
        )
        # A marked expansion is never served where an unmarked one is wanted.
        _marking_template_origins() && (bkey = "\x02" * bkey)
        mkey = (name::String, bkey)
        cached = get(memo.bind, mkey, nothing)
        if cached !== nothing
            if sites !== nothing
                for (r, ap) in get(memo.roots, cached, ())
                    sites[r] = ap
                end
                _record_site!(sites, memo, cached, e)
            end
            return cached
        end
        # The roots this expansion records, kept for later hits.
        col = IdDict{OpExpr, OpExpr}()
        ex = _tpl_instantiate(e, name::String, bindings_raw, reg, col, memo)
        if ex === nothing
            substituted = _substitute(_raw_get(reg[name], "body"), bindings_raw)
            ex = _expand_expr_refs(expression_from_json(substituted), reg, col, memo)
        end
        ex = _mark_origin(ex, name::String)
        _record_site!(col, memo, ex, e)
        if ex isa OpExpr
            memo.bind[mkey] = ex
            memo.roots[ex] = collect(col)
        end
        sites === nothing || merge!(sites, col)
        return ex
    end
    return map_children(c -> _expand_expr_refs(c, reg, sites, memo), e)
end

# Record `ex` as the expansion root of the apply node `e`. While a template's
# skeleton is being built, a root that is a bare parameter sentinel stands for
# that parameter's binding at every instantiation: noted on the skeleton.
function _record_site!(sites::_TemplateSites, memo::_ExpandMemo, ex, e::OpExpr)
    sites === nothing && return nothing
    if ex isa OpExpr
        sites[ex] = e
    elseif ex isa VarExpr && memo !== nothing && !isempty(memo.building) &&
            startswith(ex.name, _TPL_SENTINEL)
        push!(memo.building[end], ex.name)
    end
    return nothing
end

# ---------------------------------------------------------------------------
# Template instantiation cache
# ---------------------------------------------------------------------------
#
# Expanding a call site the direct way serializes its bindings, substitutes
# them into the raw template body, parses the result and expands the nested
# references in it, each of which repeats the same steps one level down. All of
# that work depends on the template, not on the site, except where a parameter
# lands. A skeleton does it once per template: the body is substituted with a
# sentinel variable per parameter (a string no document can contain), parsed,
# and its nested references expanded through this same cache, so a nested
# reference's bindings carry the outer sentinels into the inner skeleton. A site
# is then instantiated by replacing the sentinels:
#
#   * a sentinel in an expression position becomes the parse of the binding's
#     serialization, expanded (what the direct route parses there);
#   * a sentinel in a `ranges` entry or in `output_idx` is re-coerced from the
#     binding's serialization by the parser's own rules;
#   * subtrees with no sentinel are shared, not copied.
#
# Parsing is context free (`expression_from_json` reads only the node), so the
# result is structurally identical to the direct route. A template whose
# sentinels land anywhere else (an op name, a `const` value, a scalar field), or
# whose skeleton cannot be built at all, is marked ineligible and every one of
# its sites takes the direct route, which raises whatever the direct route
# raises. So does a site whose binding names differ from the template's params.
const _TPL_SENTINEL = "\0esm-template-param\0"

struct _TplSkel
    root::ASTExpr
    params::Set{String}
    live::IdDict{OpExpr, Nothing}    # nodes with a sentinel at or below them
    fix::IdDict{OpExpr, Nothing}     # nodes with a sentinel in `ranges` or `output_idx`
    roots::IdDict{OpExpr, OpExpr}    # nested expansion roots => their apply nodes
    root_params::Set{String}         # sentinels that are themselves a nested root
    param_of::Dict{String, String}   # sentinel => its parameter
end

function _tpl_skeleton(name::String, reg, memo::_ExpandCache)
    _cache_for!(memo, reg)
    # A skeleton built while expansions are marked carries the marks on its
    # nested roots; one built unmarked does not.
    key = _marking_template_origins() ? "\0marked\0" * name : name
    haskey(memo.skel, key) && return memo.skel[key]
    memo.skel[key] = nothing      # a reference cycle reaching this template stays direct
    sk = _build_tpl_skeleton(name, reg, memo)
    memo.skel[key] = sk
    return sk
end

function _build_tpl_skeleton(name::String, reg, memo::_ExpandCache)
    decl = _TemplateDecl(reg[name])
    params = decl.params
    allunique(params) || return nothing
    sent = Dict{String, Any}(p => _TPL_SENTINEL * p for p in params)
    nested = IdDict{OpExpr, OpExpr}()
    push!(memo.building, Set{String}())
    # The skeleton's sentinel-keyed expansions stay out of the caller's memo.
    outer_bind = memo.bind
    memo.bind = Dict{Tuple{String, String}, OpExpr}()
    root = try
        _expand_expr_refs(expression_from_json(_substitute(decl.body, sent)), reg, nested, memo)
    catch e
        _is_resource_error(e) && rethrow()
        # The direct route raises the real diagnostic at each site.
        nothing
    finally
        root_params = pop!(memo.building)
        memo.bind = outer_bind
    end
    root === nothing && return nothing
    root_params = Set{String}(s for s in root_params if any(p -> sent[p] == s, params))
    live = IdDict{OpExpr, Nothing}()
    fix = IdDict{OpExpr, Nothing}()
    ok = _tpl_scan!(root, live, fix, IdDict{OpExpr, Bool}())
    ok === nothing && return nothing
    return _TplSkel(
        root, Set(params), live, fix, nested, root_params,
        Dict{String, String}(s => p for (p, s) in sent)
    )
end

_is_sentinel(x) = x isa AbstractString && occursin(_TPL_SENTINEL, x)
_sentinel_param(s::AbstractString) = s[(ncodeunits(_TPL_SENTINEL) + 1):end]

# Whether any string anywhere inside `x` (a field value of any shape) carries a
# sentinel. `ASTExpr` values are expression children and are not looked into.
function _holds_sentinel(x)::Bool
    x isa AbstractString && return _is_sentinel(x)
    x isa ASTExpr && return false
    if x isa AbstractDict
        for (k, v) in x
            (_holds_sentinel(k) || _holds_sentinel(v)) && return true
        end
        return false
    end
    if x isa AbstractVector || x isa Tuple
        for v in x
            _holds_sentinel(v) && return true
        end
        return false
    end
    x isa IndexSetRef && return _holds_sentinel(x.from) || _holds_sentinel(x.of)
    (x === nothing || x isa Number || x isa Symbol) && return false
    T = typeof(x)
    for f in fieldnames(T)
        isdefined(x, f) && _holds_sentinel(getfield(x, f)) && return true
    end
    return false
end

# Mark the skeleton nodes a site instantiation must rebuild (`live`), and the
# ones whose `ranges` / `output_idx` must be re-coerced (`fix`). Returns
# `nothing` when a sentinel sits in a position the instantiation does not
# handle (the template is then ineligible), else whether `n` is live.
_tpl_scan!(n::VarExpr, live, fix, seen) = _is_sentinel(n.name)
_tpl_scan!(n::Union{NumExpr, IntExpr}, live, fix, seen) = false
function _tpl_scan!(n::OpExpr, live, fix, seen)::Union{Nothing, Bool}
    r = get(seen, n, nothing)
    r === nothing || return r
    any_live = false
    needs_fix = false
    for (f, spec) in pairs(OPEXPR_FIELD_TABLE)
        v = getfield(n, f)
        v === nothing && continue
        if spec.kind === :expr
            l = _tpl_scan!(v, live, fix, seen)
            l === nothing && return nothing
            any_live |= l
        elseif spec.kind === :expr_vec
            for c in v
                l = _tpl_scan!(c, live, fix, seen)
                l === nothing && return nothing
                any_live |= l
            end
        elseif spec.kind === :expr_map
            _holds_sentinel(collect(keys(v))) && return nothing
            for c in values(v)
                l = _tpl_scan!(c, live, fix, seen)
                l === nothing && return nothing
                any_live |= l
            end
        elseif f === :ranges
            for (k, entry) in v
                _is_sentinel(k) && return nothing
                if entry isa AbstractVector
                    for x in entry
                        if x isa ASTExpr
                            l = _tpl_scan!(x, live, fix, seen)
                            l === nothing && return nothing
                            if l
                                any_live = true
                                # A bare sentinel bound is re-coerced; a
                                # sentinel deeper in a bound expression is an
                                # ordinary expression substitution.
                                x isa VarExpr && (needs_fix = true)
                            end
                        elseif _holds_sentinel(x)
                            return nothing
                        end
                    end
                elseif entry isa IndexSetRef
                    if _holds_sentinel(entry)
                        needs_fix = true
                    end
                else
                    _holds_sentinel(entry) && return nothing
                end
            end
        elseif f === :output_idx
            for x in v
                _holds_sentinel(x) || continue
                (x isa AbstractString && startswith(x, _TPL_SENTINEL)) || return nothing
                needs_fix = true
            end
        else
            _holds_sentinel(v) && return nothing
        end
    end
    needs_fix && (fix[n] = nothing)
    l = any_live | needs_fix
    l && (live[n] = nothing)
    seen[n] = l
    return l
end

# One call site through the template's skeleton, or `nothing` for the direct
# route (ineligible template, or binding names that differ from its params).
function _tpl_instantiate(
        e::OpExpr, name::String, bindings_raw::Dict{String, Any}, reg,
        sites::_TemplateSites, memo::_ExpandCache
    )
    sk = _tpl_skeleton(name, reg, memo)
    sk === nothing && return nothing
    # A nested root that is a bare parameter is, on the direct route, the
    # binding marked with the nested template's name, which the skeleton does
    # not record: such a template stays direct while marking.
    isempty(sk.root_params) || !_marking_template_origins() || return nothing
    length(bindings_raw) == length(sk.params) || return nothing
    for k in keys(bindings_raw)
        k in sk.params || return nothing
    end
    st = _TplInst(sk, bindings_raw, Dict{String, ASTExpr}(), IdDict{OpExpr, ASTExpr}(), reg, sites, memo)
    root = _tpl_subst(st, sk.root)
    if sites !== nothing
        for (r, ap) in sk.roots
            # A nested root outside the skeleton tree has no instance, and
            # recorded as itself it would name a node holding parameter
            # sentinels; only a sentinel-free one is shared as it is.
            img = haskey(sk.live, r) ? get(st.img, r, nothing) :
                (_tpl_holds_sentinel(r) ? nothing : r)
            img === nothing || _record_site!(sites, memo, img, ap)
        end
        for s in sk.root_params
            _record_site!(sites, memo, _tpl_binding(st, _sentinel_param(s)), e)
        end
    end
    return root
end

# Whether a parameter sentinel occurs anywhere in the expression `r`.
_tpl_holds_sentinel(r) = _tpl_scan!(r, IdDict{OpExpr, Nothing}(), IdDict{OpExpr, Nothing}(), IdDict{OpExpr, Bool}()) !== false

struct _TplInst
    sk::_TplSkel
    raw::Dict{String, Any}           # param => serialized binding
    typed::Dict{String, ASTExpr}     # param => parsed, expanded binding (on first use)
    img::IdDict{OpExpr, ASTExpr}     # skeleton node => its instance
    reg::Any
    sites::_TemplateSites
    memo::_ExpandCache
end

function _tpl_binding(st::_TplInst, p::String)
    v = get(st.typed, p, nothing)
    v === nothing || return v
    v = _expand_expr_refs(expression_from_json(st.raw[p]), st.reg, st.sites, st.memo)
    st.typed[p] = v
    return v
end

_tpl_subst(st::_TplInst, n::VarExpr) =
    (p = get(st.sk.param_of, n.name, nothing); p === nothing ? n : _tpl_binding(st, p))
_tpl_subst(st::_TplInst, n::Union{NumExpr, IntExpr}) = n
function _tpl_subst(st::_TplInst, n::OpExpr)
    haskey(st.sk.live, n) || return n
    r = get(st.img, n, nothing)
    r === nothing || return r
    out = map_children(c -> _tpl_subst(st, c), n)
    if haskey(st.sk.fix, n)
        out = reconstruct(
            out; ranges = _tpl_fix_ranges(st, n.ranges, out.ranges),
            output_idx = _tpl_fix_output_idx(st, n.output_idx)
        )
    end
    st.img[n] = out
    return out
end

# The serialized binding of the parameter a sentinel string names.
_tpl_raw(st::_TplInst, s::AbstractString) = st.raw[_sentinel_param(s)]

# `_coerce_ranges` applied to the entry the direct route would have parsed:
# a bare sentinel bound is the binding's serialization, every other bound is
# as the skeleton (already substituted in `inst`) has it.
function _tpl_fix_ranges(st::_TplInst, skel, inst)
    skel === nothing && return nothing
    out = Dict{String, Any}()
    for (k, v) in skel
        if v isa AbstractVector
            iv = inst[k]
            rawv = Any[
                (x isa VarExpr && startswith(x.name, _TPL_SENTINEL)) ? _tpl_raw(st, x.name) : iv[i]
                    for (i, x) in enumerate(v)
            ]
            if all(x -> x isa Number, rawv)
                out[k] = Any[Int(x) for x in rawv]
            else
                out[k] = Any[
                    x isa Number ? Int(x) :
                        ((y isa VarExpr && startswith(y.name, _TPL_SENTINEL)) ? iv[i] : x)
                        for (i, (x, y)) in enumerate(zip(rawv, v))
                ]
            end
        elseif v isa IndexSetRef
            from = _is_sentinel(v.from) ? string(_tpl_raw(st, v.from)) : v.from
            of = String[_is_sentinel(x) ? string(_tpl_raw(st, x)) : x for x in v.of]
            out[k] = IndexSetRef(from; of = of)
        else
            out[k] = inst[k]
        end
    end
    return out
end

function _tpl_fix_output_idx(st::_TplInst, skel)
    skel === nothing && return nothing
    return _coerce_output_idx(Any[_is_sentinel(x) ? _tpl_raw(st, x) : x for x in skel])
end

"""
    _expand_refs!(file::EsmFile) -> EsmFile

Expand every surviving `apply_expression_template` reference in `file`'s
models and reaction systems against `file.component_templates`, IN PLACE (the
caller passes a copy when the reference-preserving original must be kept), at
every expression site [`map_expressions!`](@ref) reaches. A no-op when
`file.component_templates` is `nothing` (no references survived).
"""
function _expand_refs!(file::EsmFile)::EsmFile
    file.component_templates === nothing && return file
    ct = file.component_templates
    if file.models !== nothing
        for (cname, m) in file.models
            reg = get(ct, "models.$cname", nothing)
            reg === nothing || _expand_model_refs!(m, reg)
        end
    end
    if file.reaction_systems !== nothing
        for (cname, rs) in file.reaction_systems
            reg = get(ct, "reaction_systems.$cname", nothing)
            reg === nothing || _expand_reaction_system_refs!(rs, reg)
        end
    end
    return file
end

"""
    expanded_file(file::EsmFile) -> EsmFile

The Option-A image of `file` (esm-spec §9.6.4): every surviving
`apply_expression_template` reference expanded into the component expressions,
and the per-component registries dropped, so `save`/`to_json` emit the fused
document rather than the reference-preserving one. The third half of the
public expansion seam — [`expanded_model`](@ref) gives one `Model`,
[`expand_flattened_refs`](@ref) a `FlattenedSystem`, this the whole document.

`flatten` and the build under `esm_problem` take the reference-preserving
file directly and expand at their own boundary, so this is for a consumer that
wants the expanded DOCUMENT: an emitter, a diff against a fused golden, a
reader with no template handling of its own. `file` is not modified, and a
file with no surviving references comes back by identity.

Not for build or analysis paths: esm-spec §9.6.4 rule 2 says builders,
evaluators and analyses SHOULD NOT expand references (they analyse and compile
each template once). This is an explicit expansion utility for tools and
interchange.
"""
function expanded_file(file::EsmFile)::EsmFile
    file.component_templates === nothing && return file
    out = _expand_refs!(deepcopy(file))
    return reconstruct(out; component_templates = nothing)
end

"""
    _expand_model_refs!(model, reg; sites = nothing, memo = _ExpandCache())
    _expand_reaction_system_refs!(rs, reg; sites = nothing, memo = _ExpandCache())

Expand the surviving references at every expression site of `model` or `rs`
and of their subsystems ([`EXPRESSION_SITE_KINDS`](@ref): equations,
initialization equations, guesses, update rules, bounds, events, inline-test
references, rates, constraint equations), in place, against the component
registry `reg`. One `memo` serves every site, so structurally identical
applications expand once and share the expanded root (`_ExpandCache`); pass
`memo = nothing` to expand each site separately. `sites` records each
expansion root as `_expand_expr_refs` describes.

The containers `model` holds directly are updated in place, so a caller that
must keep the reference-preserving original passes a copy that owns them.
"""
function _expand_model_refs!(
        model::Model, reg; sites::_TemplateSites = nothing,
        memo::Union{_ExpandMemo, Dict{Tuple{String, String}, OpExpr}} = _ExpandCache()
    )
    memo = _expand_cache(memo)
    map_expressions!(e -> _expand_expr_refs(e, reg, sites, memo), model)
    return
end

function _expand_reaction_system_refs!(
        rs::ReactionSystem, reg; sites::_TemplateSites = nothing,
        memo::Union{_ExpandMemo, Dict{Tuple{String, String}, OpExpr}} = _ExpandCache()
    )
    memo = _expand_cache(memo)
    map_expressions!(e -> _expand_expr_refs(e, reg, sites, memo), rs)
    return
end
