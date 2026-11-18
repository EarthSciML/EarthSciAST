# tree_walk/build_caller_data.jl — the caller's data: supplied scalars, inline array data, key
# canonicalization, the parameter scope and partition, the parameter-read sink,
# the const-array registry and the live forcing buffers.

# A SCALAR parameter whose value arrives as data under its exact name: a
# one-cell `param_arrays` buffer (a discrete provider's, read live through a
# gather) or a one-cell `const_arrays` entry (a const provider's field, folded to
# a literal by `_resolve_indices`). Returns that one-cell array, the live buffer
# first, or `nothing`. The right-hand side reads the data, never a `p` slot, so
# the partition gives the parameter none: a `p` slot holding the declared
# default would be a value nothing reads, and `remake(prob; p = …)` on it would
# change nothing. It is classed `:const_folded` / `:forcing` instead, like a
# shaped parameter backed by the same registries, and its build-time value (an
# `ic` fold, `inspect.params`) is the data's.
function _scalar_supplied_data(name, const_arrays::AbstractDict, param_arrays::AbstractDict)
    for reg in (param_arrays, const_arrays)
        a = get(reg, name, nothing)
        a isa AbstractArray && length(a) == 1 && return a
    end
    return nothing
end

# A SCALAR parameter whose data, under its exact name, holds more than one
# value. `shape: []` declares a scalar (esm-spec §4.3.4), so its data must be
# one value; a parameter declared without a shape takes its data's shape, which
# `esm_problem` decides before the build (`_adopt_data_shapes`), so one reaching
# here unshaped came through a build entry that bypassed that. Either way the
# build would read neither the data nor a value it could name, so it is refused.
function _refuse_array_data_for_scalar(
        name, v::ModelVariable, const_arrays::AbstractDict, param_arrays::AbstractDict
    )
    for reg in (param_arrays, const_arrays)
        a = get(reg, name, nothing)
        (a isa AbstractArray && length(a) != 1) || continue
        why = v.shape === nothing ?
            "it declares no `shape`, and only `esm_problem` adopts a shape from data; " *
            "declare the shape, or build through `esm_problem`" :
            "it declares `shape: []`, a scalar, which takes one value"
        throw(
            TreeWalkError(
                "E_TREEWALK_UNSUPPORTED_SHAPE",
                "parameter '$(name)': its data has size $(size(a)), but $(why) (esm-spec §4.3.4)"
            )
        )
    end
    return nothing
end

# An explicit `parameter_overrides` value for a SCALAR parameter that is also
# given data (`_scalar_supplied_data`). Const data: the override is the caller
# speaking for this run and outranks it, exactly as it outranks const data for a
# shaped parameter (`_register_inline_array_parameters`), so it replaces the
# one-cell array the build folds. A live buffer: the run rewrites it at every
# refresh, so the override could hold only until the first one; refused rather
# than half-applied. Without this the parameter has no `p` slot, so the override
# was never read and the run silently used the provider's value. Every alias of
# the data (the caller's spelling of a provider key) is replaced with it.
function _scalar_overrides_over_supplied(
        model::Model, const_arrays::AbstractDict, param_arrays::AbstractDict,
        overrides::AbstractDict
    )
    out = nothing
    for (rawname, ov) in overrides
        ov isa Number || continue
        name = String(rawname)
        v = get(model.variables, name, nothing)
        v !== nothing && v.type == ParameterVariable && !_is_array_shape(v.shape) || continue
        a = _scalar_supplied_data(name, const_arrays, param_arrays)
        a === nothing && continue
        a === get(param_arrays, name, nothing) && throw(
            SimulateError(
                "parameter_overrides: '$(name)' is fed by a live forcing buffer (a " *
                    "discrete provider or a `param_arrays` entry) that the run rewrites at " *
                    "each refresh, so an override of it cannot hold; pass one or the other " *
                    "(esm-spec §6.6.2)",
                ERROR_CODES.OVERRIDE_KEY_CONFLICT
            )
        )
        out === nothing && (out = Dict{String, Any}(String(k) => x for (k, x) in const_arrays))
        # Every key holding this very array: the data may sit under the
        # caller's spelling beside the build's name (`_put_provider_const!`),
        # and a consumer reading that spelling must see the override too.
        replaced = fill(Float64(ov), size(a))
        for (k, x) in out
            x === a && (out[k] = replaced)
        end
        out[name] = replaced
    end
    return out === nothing ? const_arrays : out
end

# A shaped parameter that reached the partition with no value: no `default`,
# no override, no caller array and no live forcing buffer. esm-spec §10.10 makes
# "a parameter with neither a default nor a supplied value" an error when a
# problem is built, so this is a construction error naming the parameter, what
# the document says feeds it, and the channels that would supply it.
function _missing_data_error(name::AbstractString, v::ModelVariable)
    shaped = _is_array_shape(v.shape)
    shape = shaped ? " (shape [$(join(v.shape, ", "))])" : ""
    # A declared default that never reached the const-array channel: its shape
    # did not resolve to extents when the default was broadcast.
    v.default === nothing || return TreeWalkError(
        "E_TREEWALK_UNSUPPORTED_SHAPE",
        "the shaped parameter '$(name)'$(shape) declares a `default`, but its shape does " *
            "not resolve to extents where the default is broadcast over it (an index set " *
            "with no known size); supply its array in `const_arrays` instead"
    )
    feeds = String[]
    for u in something(v.update, ParameterUpdate[])
        if u.from !== nothing
            push!(
                feeds, "the data source '$(something(u.source, "?"))' " *
                    "(file_variable '$(u.from.file_variable)')"
            )
        elseif u.handler !== nothing
            push!(
                feeds, "the registered handler '$(u.handler.handler_id)' " *
                    "(update kind '$(u.kind)'), which writes it only when it fires"
            )
        end
    end
    fed = isempty(feeds) ? "Nothing in the document gives it a value." :
        "The document feeds it from $(join(feeds, " and ")), and no data for it " *
        "was supplied at construction."
    how = isempty(feeds) ?
        (
            shaped ?
            "pass its array to `esm_problem` as `const_arrays = Dict(\"$(name)\" => array)`, " *
            "or declare a `default` on it" :
            "pass it to `esm_problem` as `p = Dict(\"$(name)\" => value)`, or declare a " *
            "`default` on it"
        ) :
        "pass a provider for it in `providers`, or its array as " *
        "`const_arrays = Dict(\"$(name)\" => array)` (a constant snapshot) or " *
        "`param_arrays` (a live buffer the caller refreshes), or declare a `default` on it"
    return TreeWalkError(
        "E_TREEWALK_MISSING_DATA",
        "no data supplied for the $(shaped ? "shaped " : "")parameter '$(name)'$(shape), which declares no " *
            "`default`. $(fed) A parameter with neither a default nor a supplied value is an " *
            "error when a problem is built (esm-spec §10.10). To supply it, $(how)."
    )
end

# ---- Stage: inline array data (esm-spec §6.3 / §6.6.2) ----------------------
# A SHAPED variable may carry its whole field inline, as a row-major nested JSON
# array on its `default` or in a test's `parameter_overrides` /
# `initial_conditions`. `_coerce_inline_value` (types.jl) has already turned
# such a value into a dense `Array{Float64,N}`; these two stages route it to the
# channel the build already reads it from.

# Every SHAPED parameter whose resolved value the DOCUMENT supplies, merged into
# the const-array registry. Precedence follows §6.6.2: an explicit
# `parameter_overrides` entry wins over everything, then a caller-supplied
# `const_arrays` entry (loaded data beats a document default), then the declared
# `default`. Returns the ORIGINAL registry object when nothing was added, so a
# document with no inline array data builds byte-identically.
#
# The value is inline array data, or a SCALAR — which esm-spec §6.3 gives the
# same meaning, "the one value applies to every element" — BROADCAST over the
# declared grid. The broadcast is what a shaped UNKNOWN's scalar `default`
# already gets from `_build_u0` (one value into every cell of the state vector);
# without it here, `_partition_variables` reaches a shaped parameter backed by
# neither `const_arrays` nor `param_arrays` and throws
# `E_TREEWALK_UNSUPPORTED_SHAPE` on a document the spec says is valid
# (EarthSciML/EarthSciAST#219). A LIVE forcing buffer (`param_arrays`) owns its
# name, so broadcasting a DECLARED scalar never displaces one; an explicit
# override is the caller speaking for this run and outranks both registries,
# exactly as the array spelling of that override already does.
# The array of a shaped parameter `name` holding `x` at every element of its
# extents `exts`; a program's re-lowering reuses its build's (`_ProgramMemo`).
_broadcast_parameter(name, x::Float64, exts) =
    _memo_get(_range_spec_now(), :inline, (String(name), x, Tuple(exts))) do
    fill(x, Tuple(exts))
end

function _register_inline_array_parameters(
        model::Model, const_arrays::AbstractDict,
        parameter_overrides::AbstractDict,
        index_sets::AbstractDict;
        param_arrays::AbstractDict = Dict{String, Any}(),
        derived_extents::AbstractDict = _EMPTY_DERIVED_EXTENTS,
        runtime::Bool = false, live_fed::Bool = false
    )
    additions = Dict{String, Any}()
    live_additions = Dict{String, Any}()
    for (name, v) in model.variables
        v.type == ParameterVariable && _is_array_shape(v.shape) || continue
        # A live parameter (every shaped one under `runtime`, an externally fed
        # one under `live_fed`) already bound to a buffer keeps it; one the
        # caller supplied as const data becomes a buffer holding that data.
        live = runtime || (live_fed && _externally_fed(v))
        live && haskey(param_arrays, name) && continue
        ov = get(parameter_overrides, name, nothing)
        value = if is_inline_array(ov)
            ov
        elseif ov isa Number
            # A SCALAR override is tested BESIDE the array one, before either
            # default arm: §6.6.2 gives the two spellings of the §6.3 union one
            # precedence, so an override must not lose to the very `default` it
            # replaces (nor to caller-supplied data, which the array arm above
            # already outranks). Tested after it, a scalar override of a
            # parameter whose declared `default` is an inline array was silently
            # DROPPED and the default used instead.
            exts = _declared_shape_extents(v.shape, index_sets, derived_extents)
            exts === nothing && continue
            _broadcast_parameter(name, Float64(ov), exts)
        elseif haskey(const_arrays, name)
            live || continue              # caller-supplied data is authoritative
            const_arrays[name]
        elseif is_inline_array(v.default)
            v.default
        elseif v.default isa Number
            # esm-spec §6.3 broadcast of the DECLARED scalar. Skipped when a live
            # forcing buffer already carries the name, and when the shape does
            # not resolve (an unmaterialized derived set has no extent to fill) —
            # the build's own extent checks then report any real disagreement.
            haskey(param_arrays, name) && continue
            exts = _declared_shape_extents(v.shape, index_sets, derived_extents)
            exts === nothing && continue
            _broadcast_parameter(name, Float64(v.default), exts)
        else
            continue
        end
        _check_inline_shape(
            name, value, v.shape, index_sets,
            ov === nothing ? "default" : "parameter_overrides";
            derived_extents = derived_extents
        )
        (live ? live_additions : additions)[name] = value
    end
    if !isempty(live_additions)
        # A live parameter becomes a buffer (a program's forcing slot), not const
        # data: a run-time input a caller swaps and a gradient differentiates
        # against.
        for (k, v) in live_additions
            param_arrays[k] = Array{Float64}(v)
        end
        const_arrays = Dict{String, Any}(
            String(k) => v for (k, v) in const_arrays
                if !haskey(live_additions, String(k))
        )
    end
    isempty(additions) && return const_arrays
    merged = Dict{String, Any}(String(k) => v for (k, v) in const_arrays)
    for (k, v) in additions
        merged[k] = v
    end
    return merged
end

# Read every INLINE ARRAY `initial_conditions` entry as the per-cell keys
# (`u[1]`, `u[2,3]`, …) the u0 seeding reads, leaving scalar entries untouched:
# an `_InlineICs` view that holds each profile as an array rather than a key per
# cell. A per-cell key the caller wrote explicitly WINS: it is the more specific
# binding. Returns the ORIGINAL map when there is no inline profile.
function _expand_inline_array_ics(
        model::Model, initial_conditions::AbstractDict,
        index_sets::AbstractDict
    )
    any(is_inline_array(v) for (_, v) in initial_conditions) || return initial_conditions
    out = Dict{String, Any}(
        String(k) => v for (k, v) in initial_conditions
            if !is_inline_array(v)
    )
    arrays = Pair{String, Array{Float64}}[]
    for (k, v) in initial_conditions
        is_inline_array(v) || continue
        name = String(k)
        var = get(model.variables, name, nothing)
        var === nothing && throw(
            TreeWalkError(
                "E_TREEWALK_UNSUPPORTED_EQUATION",
                "initial_conditions[$(name)]: inline array data names no variable of this " *
                    "model (esm-spec §6.6.2)"
            )
        )
        _check_inline_shape(name, v, var.shape, index_sets, "initial_conditions")
        vals = Array{Float64}(undef, size(v))
        for I in CartesianIndices(v)
            vals[I] = Float64(v[I])
        end
        push!(arrays, name => vals)
    end
    return _InlineICs(out, arrays)
end

# esm-spec §6.6.2: inline array data MUST match the variable's declared `shape`
# after metaparameter folding, and a mismatch is a LOAD-TIME error. A shape that
# does not resolve against the registry (an unmaterialized derived set) is
# accepted as authored — the build's own extent checks then report any real
# disagreement.
function _check_inline_shape(
        name::AbstractString, value, shape, index_sets::AbstractDict,
        origin::AbstractString;
        derived_extents::AbstractDict = _EMPTY_DERIVED_EXTENTS
    )
    _is_array_shape(shape) || throw(
        TreeWalkError(
            "E_TREEWALK_UNSUPPORTED_SHAPE",
            "$(origin)[$(name)]: inline array data was supplied for a variable with no " *
                "declared `shape`; only a SHAPED variable takes a nested array (esm-spec §6.3)"
        )
    )
    exts = _declared_shape_extents(shape, index_sets, derived_extents)
    exts === nothing && return nothing
    size(value) == Tuple(exts) || throw(
        TreeWalkError(
            "E_TREEWALK_UNSUPPORTED_SHAPE",
            "$(origin)[$(name)]: inline array data has shape $(size(value)), which does not " *
                "match the declared shape $(Tuple(exts)) (esm-spec §6.6.2 — the array MUST match " *
                "the variable\'s declared shape after metaparameter folding)"
        )
    )
    return nothing
end

# ---- Stage: canonicalize the caller's `parameter_overrides` keys ----
# esm-spec §6.6 pins `parameter_overrides` as "keyed by LOCAL parameter name"
# (`pert_amp`), but every document front-door reaches the build through
# `flatten`, which renames each parameter after its owning component
# (`SimpleClimate.pert_amp`). An exact-key lookup therefore MISSES the very
# spelling the spec tells authors to write, and — because the resolved scope
# feeds the coordinate-expression `ic` seed, the parameter NamedTuple, and
# `inspect.params` (the §6.6.5 reference / observed assertion scope) — the
# override was silently dropped: the run used the DEFAULT and the inline test
# still reported a verdict. A quiet wrong answer in the test runner, not a
# loud failure.
#
# So rewrite each caller key onto the name the build actually resolves, once,
# before any consumer sees it:
#   1. an exact parameter-name hit wins;
#   2. else a DOTTED key whose LONGEST dotted suffix is itself a parameter name
#      resolves to that parameter (`M.A` against a bare-named `Model`, `M.sub.A`
#      against a build carrying the mounted subsystem parameter as `sub.A`) —
#      PROVIDED every leading segment dropped along the way names a component or
#      subsystem the document actually declares, so a typo'd `Missng.M.pert_amp`
#      is reported rather than silently suffix-matched onto `M.pert_amp`;
#   3. else a key that is a DOTTED SUFFIX of exactly ONE parameter resolves to
#      it — `A` against the flattened `M.A` (the bare case), and equally
#      `sub.g` against the flattened `P.sub.g`, the mounted-subsystem spelling
#      a single-model build carries as `sub.g` outright. Rules 2 and 3 are the
#      two directions of one relationship: rule 2 for a key LONGER than the
#      name, rule 3 for a key SHORTER than it;
#   4. a key that is a dotted suffix of MORE THAN ONE parameter is AMBIGUOUS —
#      the caller named one local (or partially qualified) parameter that two
#      mounted components both carry — and is rejected naming the candidates,
#      never guessed at;
#   5. anything else matches no parameter and is rejected as UNKNOWN.
# Two NON-EXACT keys designating ONE parameter — `solo` (rule 3) and
# `Doc.Left.solo` (rule 2) both landing on `Left.solo`, or `A.M.g` and `B.M.g`
# both landing on `M.g` — is likewise rejected: the caller wrote two overrides
# and only one can take effect, so picking a winner would be a wrong answer
# rather than a missing one. An EXACT key is never part of a collision — rule 1
# identifies its parameter outright and wins over any suffix or bare claim.
# This is the Julia counterpart of Python's `_resolve_override` and Rust's
# `Compiled::normalize_override_keys`, so one authored test behaves identically
# in all three executing bindings — see esm-spec §6.6.2 "Unrecognized override
# keys" and CONFORMANCE_SPEC §5.15.
#
# Rules 4 and 5 used to leave the key verbatim, so an unmatched override was
# INERT: the run silently used the declared default and still reported a
# verdict. That is the same silent-wrong-answer shape this canonicalization was
# introduced to fix, one level up — the author writes an override, nothing
# happens, and the model quietly measures the configuration they thought they
# had switched off. Rust already raised `InvalidParameter` here; Julia and
# Python now match it.
function _normalize_param_override_keys(model::Model, overrides::AbstractDict)
    isempty(overrides) && return overrides
    param_names = Set{String}(
        n for (n, v) in model.variables
            if v.type == ParameterVariable
    )
    table = NameTable(param_names; namespaces = _override_namespaces(param_names; model = model))
    # `Any`-valued: esm-spec §6.6.2 admits INLINE ARRAY DATA for a SHAPED
    # parameter alongside a scalar, and the array must survive key
    # canonicalization intact (`_register_inline_array_parameters` routes it to
    # the const-array channel just below).
    normalized, unknown, ambiguous, collisions = canonicalize_keys(Any, table, overrides)
    _raise_key_failures(
        "parameter_overrides", "parameter", unknown, ambiguous, collisions;
        unknown_message = k -> "parameter_overrides: unknown parameter '$k' — " *
            "this model declares no such parameter " *
            "(known: $(isempty(param_names) ? "none" : join(sort(collect(param_names)), ", "))). " *
            "esm-spec §6.6.2 keys parameter_overrides by LOCAL parameter name."
    )
    return normalized
end

# ---- Stage: canonicalize the caller's `const_arrays` keys ----
# A caller's `const_arrays` entry for a SHAPED parameter is the same binding as
# an inline-array `parameter_overrides` entry for it — both land on the
# const-array channel — so its key is resolved by the same esm-spec §6.6.2
# rules: the model-local spelling `lat` designates the flattened `Deg.lat`
# exactly as it does for an override. An exact key alone missed that parameter:
# with no `default` the build refused the document
# (`E_TREEWALK_UNSUPPORTED_SHAPE`, the parameter backed by nothing), and with
# one it silently used the default instead of the caller's array. Rust's build
# pipeline resolves such a key the same way.
#
# The registry also carries arrays that are not a parameter's value at all — a
# loader field, a coordinate table, a synthetic build array — so a key that
# designates no shaped parameter is left as it is, never reported as unknown.
# A key that is a dotted suffix of more than one shaped parameter is ambiguous,
# and two non-exact keys designating one parameter collide; both are rejected
# as they are for `parameter_overrides`. An exact key always wins. The resolved
# name is ADDED beside the caller's key, which stays, so a consumer that reads
# the caller's spelling still finds it.
function _normalize_const_array_keys(model::Model, const_arrays::AbstractDict)
    isempty(const_arrays) && return const_arrays
    shaped = Set{String}(
        n for (n, v) in model.variables
            if v.type == ParameterVariable && _is_array_shape(v.shape)
    )
    isempty(shaped) && return const_arrays
    table = NameTable(shaped; namespaces = _override_namespaces(shaped; model = model))
    claims = Dict{String, Vector{String}}()
    for rawk in keys(const_arrays)
        k = String(rawk)
        haskey(model.variables, k) && continue    # an exact name
        r = resolve_key(table, k)
        r.how === :unknown && continue             # designates no shaped parameter
        r.how === :ambiguous && throw(
            SimulateError(_override_ambiguous_message("const_arrays", k, r.candidates), ERROR_CODES.OVERRIDE_KEY_AMBIGUOUS)
        )
        haskey(const_arrays, r.name) && continue   # the exact key wins
        push!(get!(claims, r.name, String[]), k)
    end
    isempty(claims) && return const_arrays
    merged = Dict{String, Any}(String(k) => v for (k, v) in const_arrays)
    for name in sort!(collect(keys(claims)))
        ks = claims[name]
        length(ks) == 1 || throw(
            SimulateError(
                _override_collision_message("const_arrays", "parameter", name, sort!(ks)), ERROR_CODES.OVERRIDE_KEY_CONFLICT
            )
        )
        merged[name] = merged[ks[1]]
    end
    return merged
end

# The COMPONENT / SUBSYSTEM names a rule-2 override key may spell in its LEADING
# segments (esm-spec §6.6.2 rule 2, §4.6).
#
# Every non-final dotted segment of a build-resolved name is a namespace the
# build itself carries (`Left.gain` ⇒ `Left`; `M.sub.A` ⇒ `M`, `sub`). `model`
# and `model_name` supply the namespaces the NAMES cannot show: an unmounted
# subsystem's own name, and — on the raw single-model front door, whose
# variables are BARE — the enclosing model's name, which is exactly what makes
# `M.A` a legal spelling of `A`. The Python (`namespace_scope`) and Rust
# (`namespace_scope`) mirrors derive the same set.
function _override_namespaces(
        names::AbstractSet{String};
        model::Union{Nothing, Model} = nothing,
        model_name = nothing
    )
    ns = Set{String}()
    for n in names
        parts = split(n, '.')
        for i in 1:(length(parts) - 1)
            push!(ns, String(parts[i]))
        end
    end
    model_name === nothing || push!(ns, String(model_name))
    model === nothing || _collect_subsystem_names!(ns, model)
    return ns
end

function _collect_subsystem_names!(ns::Set{String}, model::Model)
    for (sname, sub) in model.subsystems
        push!(ns, String(sname))
        sub isa Model && _collect_subsystem_names!(ns, sub)
    end
    return ns
end

# Rule 2: the LONGEST dotted suffix of a dotted key `k` — every `<segment>.`
# prefix dropped in turn, most-qualified first — that is itself a known name,
# PROVIDED every segment dropped along the way names a component or subsystem in
# `namespaces`. `nothing` for a bare key, when no suffix is known, or when a
# leading segment names nothing. `M.sub.A` tries `sub.A` then `A` when `M` and
# `sub` are real (`M.A` against a bare-named single-model system; `M.sub.A`
# against a build carrying the mounted subsystem parameter as `sub.A` — the §4.6
# fully-qualified spelling of a name the build holds in a shorter form), while
# `Doc.Left.solo` in a document with no component `Doc` is rejected rather than
# re-pointed at `Left.solo`.
function _dotted_suffix_hit(
        names::AbstractSet{String}, namespaces::AbstractSet{String},
        k::AbstractString
    )
    rest = String(k)
    while (i = findfirst('.', rest)) !== nothing
        head = rest[1:prevind(rest, i)]
        head in namespaces || return nothing
        rest = rest[nextind(rest, i):end]
        rest in names && return rest
    end
    return nothing
end

_bare_param_name(name::AbstractString) =
    (i = findlast('.', name)) === nothing ? String(name) : String(name[nextind(name, i):end])

# Every PROPER dotted suffix of `name`, longest first: `A.sub.g` gives
# `["sub.g", "g"]`, a bare `g` gives `String[]`. These are the spellings
# esm-spec §6.6.2 rule 3 admits for the name — the trailing segment is merely
# the shortest of them. The Python (`dotted_suffixes`) and Rust
# (`dotted_suffixes`) mirrors enumerate the same list.
function _dotted_suffixes(name::AbstractString)
    out = String[]
    rest = String(name)
    while (i = findfirst('.', rest)) !== nothing
        rest = rest[nextind(rest, i):end]
        push!(out, rest)
    end
    return out
end

# ---- Stage: scalar parameter scope (load-time constants) ----
# Each scalar parameter's RESOLVED value: `parameter_overrides` if given,
# else the model default (else 0.0). These are load-time CONSTANTS, so they
# are bindable into the build-time cellwise evaluation (coordinate-expression
# `ic` seeding, and — via `inspect.params` — the §6.6.5 observed/reference
# assertions), while STATE stays out of scope. Computed before the ic fold so
# the same map feeds both the seed path and the parameter NamedTuple.
function _resolve_param_scope(
        model::Model, param_names::Vector{String},
        parameter_overrides::AbstractDict;
        supplied::AbstractDict = _EMPTY_PARAMS,
        supplied_live::AbstractDict = _EMPTY_PARAMS
    )
    param_scope = Dict{String, Float64}()
    for name in param_names
        v = model.variables[name]
        param_scope[name] = if haskey(parameter_overrides, name)
            Float64(parameter_overrides[name])
        elseif v.default !== nothing
            Float64(v.default)
        elseif v.distribution !== nothing || haskey(supplied, name) ||
                haskey(supplied_live, name)
            0.0   # drawn at setup, or read from the caller's / a provider's data
        else
            # esm-spec §10.10: neither a default nor a supplied value.
            throw(_missing_data_error(name, v))
        end
    end
    return param_scope
end

# ---- Build-time parameter READS: the structural/numeric discriminator -------
#
# A parameter is STRUCTURAL iff its value is consumed at BUILD time — where it
# can decide the SHAPE of the problem (a value-invention index-set extent, i.e.
# `length(u)`; a setup-geometry array's dimensions; a binning quantization; the
# u0 an `ic()` fold produces). The declared `"type": "parameter"` says nothing
# about this: every parameter is declared the same way. WHERE THE VALUE IS
# CONSUMED is the discriminator, so this records consumption rather than
# analysing the document a second time — if a name is read at build, it is
# structural, by construction.
#
# The recording is a dynamically scoped sink installed around each build-time
# consumer (`_ic_start_scope`, `_fold_scalar_ics`, `_fold_field_ics!`,
# `_materialize_geometry_setup`, `_derive_binning_coords`,
# `materialize_value_invention`) and read by the three
# places a NAME is actually resolved to a build-time VALUE:
#
#   * `_compile(::VarExpr, …)` (compile.jl) — the general build-time cell
#     pipeline. Both name arms record: `evaluate_expr` binds the parameter scope
#     as pseudo-STATE (`var_map`), while `_eval_cellwise` /
#     `_try_field_ic_fastpath` bind it as `param_syms`.
#   * `_geo_compile(::VarExpr, …)` (geometry_compile.jl) — the setup-time
#     geometry compiler, which folds a scalar `env` entry to a literal.
#   * `_vi_param` (value_invention.jl) — the relational engine's own evaluator.
#
# Recording at the RESOLUTION site (not at the dict) is what makes it precise:
# every one of those consumers materializes the WHOLE parameter scope into a
# NamedTuple/vector before compiling, so a read-recording Dict would report
# every parameter as structural. Only the compiler knows which names the
# expression actually mentions.
#
# The sink is `nothing` outside those scopes — in particular during the ODE RHS
# compile, where a parameter read is a RUNTIME read of `p` and therefore
# NUMERIC, the exact opposite conclusion.
#
# The sink lives on the build state (`_BuildState.param_reads`, compiler.jl), so
# a build records only its own reads. `_PARAM_SINKS_OPEN` counts the scopes open
# on any task; while it is zero a resolution site skips the task-local lookup.
# It decides nothing on its own: a nonzero count only sends the site to its own
# build's sink, which is `nothing` outside a scope.
const _PARAM_SINKS_OPEN = Threads.Atomic{Int}(0)

@inline function _record_param_read(name)
    _PARAM_SINKS_OPEN[] == 0 && return nothing
    s = _build_state().param_reads
    s === nothing || push!(s, String(name))
    return nothing
end

# Run `f` with build-time name resolutions recorded into `sink`. Save/restore
# (not clear-on-exit) so a nested scope cannot clobber an outer one's sink.
function _with_param_reads(f, sink::Union{Nothing, Set{String}})
    sink === nothing && return f()
    st = _build_state()
    prev = st.param_reads
    st.param_reads = sink
    Threads.atomic_add!(_PARAM_SINKS_OPEN, 1)
    try
        return f()
    finally
        Threads.atomic_sub!(_PARAM_SINKS_OPEN, 1)
        st.param_reads = prev
    end
end

# ---- Stage: the parameter partition (esm differentiability plan §3 Phase 5) ----
# Every DECLARED parameter (and the discrete variables that lower like one) gets
# exactly one class:
#
#   `:numeric`      — a scalar that lands in the runtime `p`. Differentiable,
#                     and overridable at solve time by swapping `p`.
#   `:structural`   — read at BUILD time (see `_record_param_read`). Its value can
#                     change the shape of the problem, so changing it is a
#                     rebuild, not a `p` swap. Per NAME, not per use: a name
#                     read once at build is structural even if the RHS also
#                     reads it at runtime.
#   `:const_folded` — supplied as CONST DATA (a const provider / caller
#                     `const_arrays` entry), frozen into the
#                     build and inlined into the RHS. It never reaches `p`, so a
#                     derivative w.r.t. it is an unconditional zero that a
#                     finite-difference check on the declared default CONFIRMS —
#                     a wrong gradient and a wrong check agreeing silently. Named
#                     and refused explicitly for exactly that reason.
#   `:forcing`      — the live-buffer sibling of `:const_folded`: an array
#                     parameter bound to a `param_arrays` buffer a discrete
#                     provider rewrites in place at each refresh. Also never in
#                     `p`; changing it means changing the buffer, not `p`.
function _classify_parameters(
        model::Model, param_names::Vector{String},
        reads::Set{String}, const_arrays::AbstractDict,
        param_arrays::AbstractDict
    )
    classes = Dict{String, Symbol}()
    in_p = Set{String}(param_names)
    for (name, v) in model.variables
        v.type == ParameterVariable || continue
        classes[name] = if name in reads
            :structural
        elseif name in in_p
            :numeric
        elseif haskey(param_arrays, name)
            :forcing
        else
            :const_folded
        end
    end
    # A `p` slot with no declared variable behind it cannot happen (param_names
    # comes from `model.variables`), but never leave a slot unclassified: the
    # solve-time override path refuses anything it cannot name a class for.
    for name in param_names
        haskey(classes, name) || (classes[name] = name in reads ? :structural : :numeric)
    end
    # The INJECTED data channels. A document's `"type": "parameter"` field may
    # stop being a parameter variable by the time the evaluator is built: a
    # coupling `variable_map` rewires the consumer's declared field onto the
    # LOADER's variable, which flattening emits as an observed — so the declared
    # field name is gone and the one the consumer actually folds is the loader's.
    # The surviving name is still
    # something a caller may try to override — and it is exactly the case a
    # gradient lies about, since the value was frozen into the build. So class
    # every caller-supplied array by its REGISTRY, keeping only names the model
    # actually carries (a synthetic build key like `__stgfw_…` is not a
    # user-facing parameter). A declared parameter keeps the class it already
    # has: `:structural` outranks "it is also const data".
    for (regname, cls) in ((const_arrays, :const_folded), (param_arrays, :forcing))
        for (rawk, _) in regname
            k = String(rawk)
            (haskey(classes, k) || !haskey(model.variables, k)) && continue
            classes[k] = cls
        end
    end
    return classes
end

# esm-spec §6.3.1: an equation whose left-hand side names a parameter is
# invalid, and a build refuses it by name rather than drop it or let it override
# the parameter. `variables` is the flattened registry, so a scoped reference
# into a subsystem is already its qualified name.
function _refuse_parameter_definitions(equations, variables::AbstractDict)
    for eq in equations
        (eq.lhs isa OpExpr && (eq.lhs::OpExpr).op == "ic") && continue
        dn = _lhs_defined_name(eq.lhs)
        dn === nothing && continue
        v = get(variables, dn, nothing)
        (v !== nothing && v.type == ParameterVariable) || continue
        throw(
            TreeWalkError(
                ERROR_CODES.EQUATION_DEFINES_PARAMETER,
                "equation `$(first(string(eq), 200))` defines '$(dn)', which is a " *
                    "parameter; an equation defines unknowns only, and a parameter takes its " *
                    "value from its default, an override, its update or a coupling " *
                    "(esm-spec §6.3.1)"
            )
        )
    end
    return nothing
end

# Layer the build-materialized arrays over the caller's const arrays in `dest`.
# This is the ONE precedence rule for every reader of build-time storage: the
# const-array registry the right-hand side reads (`_register_const_arrays`) and
# the join-gate resolver's lookup table (`_build_partition_and_materialize`)
# both go through it, so a gate and the body it gates can never read two
# different arrays under one name.
#
#   * setup arrays OVERWRITE a caller const array of the same name (the
#     document's definition wins);
#   * const-op array observeds only FILL names no other storage holds.
function _overlay_build_time_arrays!(
        dest::AbstractDict, geom_setup_arrays, const_obs_arrays
    )
    # Each setup-materialized geometry array (per-pair area, A_ij, ring
    # stacks built from parameters, …), read via `index(area, p)` / `index(A_ij, i, j)`.
    for (k, arr) in geom_setup_arrays
        dest[k] = arr
    end
    # const-op array observeds (in-file ring stacks / source fields): an ODE reads
    # `index(F_src, i)` and a setup aggregate gathers `index(src_poly, i)`.
    for (k, arr) in const_obs_arrays
        haskey(dest, k) || (dest[k] = arr)
    end
    return dest
end

# ---- Stage: const-array registry ----
# Pre-computed constant arrays (Fornberg weights, mesh connectivity, etc.).
# Supports both 1D (Fornberg weights) and ND (connectivity matrices for
# mesh reductions). 1D entries are stored as Vector{Float64}; higher-rank
# entries as plain Array{Float64,N}. An array named in `const_array_boundaries`
# is wrapped in a BoundedConstArray so OOB stencil gathers resolve per its
# declared per-dimension policy (ess-gj4). Setup-materialized arrays (per-pair
# areas, …) and const-op array observeds are registered on top.
function _register_const_arrays(
        const_arrays::AbstractDict,
        const_array_boundaries::AbstractDict,
        geom_setup_arrays, const_obs_arrays
    )
    const_boundaries = Dict{String, Any}(String(k) => v for (k, v) in const_array_boundaries)
    registry = Dict{String, AbstractArray{Float64}}()
    spec = _range_spec_now()
    for (k, v) in const_arrays
        k_str = String(k)
        # A program's re-lowering reuses its build's copy (`_ProgramMemo`).
        arr = _memo_get(spec, :arrays, v) do
            ndims(v) == 1 ? Vector{Float64}(v) : Array{Float64}(v)
        end
        bnd = get(const_boundaries, k_str, nothing)
        registry[k_str] = bnd === nothing ? arr : _wrap_bounded_const(arr, bnd, k_str)
    end
    _overlay_build_time_arrays!(registry, geom_setup_arrays, const_obs_arrays)
    return registry
end

# ---- Stage: live forcing buffers (ess-14f.3, JL-J0 — the one engine touch) ----
#
# FEASIBILITY GATE (declarative-or-fail). A refreshable forcing read CANNOT be
# expressed over the existing runtime vocabulary the closure `f!(du,u,p,t)`
# already reads, as each candidate was checked and rejected:
#   • const_arrays   — `index(arr,…)` const-folds to a `NumExpr` literal at
#     build time (the const-array branch of `_resolve_indices`); post-build
#     mutation has zero effect. A refreshable buffer cannot ride it.
#   • scalar `p` cells (one named Float64 per cell) — keeps `p` homogeneous but
#     a NamedTuple of thousands of fields compiles pathologically AND scattered
#     named scalars cannot gather as a contiguous slice, breaking the
#     N-independent vectorized kernel. Refresh needs an `integrator.p` rebind.
#   • state `u` — live + callback-mutable, but the integrator INTEGRATES it
#     (pollutes the user's `u0`/solution + the adaptive error norm) and a
#     callback write needs `u_modified!(true)` ⇒ trajectory re-init each
#     boundary. Forcing is exogenous, not a state.
#   • an array field in the SAME `p`, read via `getfield(p, n.sym)` (the plan's
#     literal mechanism) — allocates: a runtime-symbol `getfield` on a
#     heterogeneous NamedTuple boxes the union, and regresses the EXISTING scalar
#     `_NK_PARAM` path too. "Monomorphic getfield" holds only
#     for a compile-time-literal symbol, never the tree-walk's runtime `n.sym`.
# CONCLUSION: node JUSTIFIED. Realize the read as a build-time-CAPTURED,
# by-reference flat `Vector{Float64}` aliasing the caller's dense buffer
# (`vec` shares storage; the J1 refresh callback's in-place `.=` shows
# through). `_NK_PARAM_GATHER` is the zero-alloc
# dual of the const-fold: the SAME `index` IR, rerouted by binding-time cadence
# class. No new IR op / schema field / declarative vocabulary; disjoint from
# the scalar `p`, so existing scalar reads stay byte-identical.
function _build_pgather(param_arrays::AbstractDict)
    pgather = Dict{String, _PGatherArray}()
    for (k, v) in param_arrays
        k_str = String(k)
        v isa Array{Float64} ||
            throw(
            TreeWalkError(
                "E_TREEWALK_PARAM_ARRAY_TYPE",
                "param_arrays['$(k_str)'] must be a dense Array{Float64} " *
                    "(captured by reference for live refresh), got $(typeof(v))"
            )
        )
        # `vec` of a dense Array{Float64} ALIASES its buffer — captured by
        # reference, NOT copied (unlike const_arrays), so the caller's / J1
        # callback's in-place `v .= …` refreshes what the RHS reads.
        pgather[k_str] = _PGatherArray(vec(v), collect(size(v)))
    end
    return pgather
end
