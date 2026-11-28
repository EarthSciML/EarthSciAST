# esm 2.5.0: the deprecated `initialization_equations` block read as `ic`
# equations at the wire boundary (esm-spec §11.4.4), and the shape check of an
# `ic` node's argument (esm-spec §4.2, `ic`).
#
# A model that carries `initialization_equations` loses the field. When some
# equation of the model has a time derivative on its left-hand side, each
# initialization equation is rewritten — every reference to an unknown `w`
# (bare, scoped or the array of an `index`) becomes `ic(w)`, every time
# derivative `D(w)` of one becomes `ic(D(w))` — and appended to `equations` in
# the field's order. A model with no time derivative has no run to start: each
# `v ~ e` with `v` a bare unknown becomes `guesses[v] = e` (an existing entry is
# kept), and any other equation is refused with `deprecated_field`. Both report
# the warning `deprecated_field`, merged into the document's one warning for
# that code (`_rewrite_old_spellings!`).

# The fields of a raw expression node that hold expressions (esm-spec
# §11.4.4: the migration reaches "wherever it sits in the expression, the
# arguments an operator call binds included"), the same set `map_children`
# walks on a typed node. `bindings` is a name → expression map; every other one
# is an expression or an array of them.
const _RAW_EXPRESSION_FIELDS = ("args", "expr", "filter", "values", "bindings", "lower", "upper", "key")

# Each expression child of the raw node `e`, in field order.
function _raw_foreach_child(f, e)
    for k in _RAW_EXPRESSION_FIELDS
        v = _raw_get(e, k)
        v === nothing && continue
        if k == "bindings"
            _is_object(v) && foreach(f, values(v))
        elseif _is_array(v)
            foreach(f, v)
        else
            f(v)
        end
    end
    return nothing
end

# Whether the raw expression `e` holds an `op` node anywhere: `D(x)`, or a
# `faq` whose body is `D(index(x, i))`.
function _raw_mentions_op(e, op::String)::Bool
    _is_array(e) && return any(x -> _raw_mentions_op(x, op), e)
    _is_object(e) || return false
    _raw_get(e, "op") == op && return true
    found = false
    _raw_foreach_child(e) do x
        found = found || _raw_mentions_op(x, op)
    end
    return found
end

# The raw model at the scoped path `segs` below `model`'s subsystems, or nothing.
function _raw_subsystem(model, segs)
    m = model
    for s in segs
        subs = _raw_get(m, "subsystems")
        _is_object(subs) || return nothing
        m = _raw_get(subs, s)
        _is_object(m) || return nothing
    end
    return m
end

# The declared `type` of the variable `name` of the raw `model`, or `nothing`.
function _raw_var_type(model, name::AbstractString)
    vars = _raw_get(model, "variables")
    v = _is_object(vars) ? _raw_get(vars, String(name)) : nothing
    return _is_object(v) ? _raw_get(v, "type") : nothing
end

_raw_is_unknown_var(model, name::AbstractString) = _raw_var_type(model, name) == "unknown"

# The declared kind of `name` (bare or dot-scoped) seen from `model`:
# `"unknown"` or `"parameter"` for a model variable, `"species"` or
# `"parameter"` for a reaction system's, `nothing` when it names none. A local
# name is the model's own; a scoped one resolves below `model`'s subsystems,
# else from the document root.
function _raw_name_kind(doc, model, name::AbstractString)
    occursin('.', name) || return _raw_var_type(model, name)
    segs = split(name, '.')
    leaf = String(segs[end])
    sub = _raw_subsystem(model, segs[1:(end - 1)])
    k = sub === nothing ? nothing : _raw_var_type(sub, leaf)
    k === nothing || return k
    models = _raw_get(doc, "models")
    root = _is_object(models) ? _raw_get(models, String(segs[1])) : nothing
    if _is_object(root)
        m = _raw_subsystem(root, segs[2:(end - 1)])
        k = m === nothing ? nothing : _raw_var_type(m, leaf)
        k === nothing || return k
    end
    rss = _raw_get(doc, "reaction_systems")
    if _is_object(rss) && length(segs) == 2
        rs = _raw_get(rss, String(segs[1]))
        for (field, kind) in (("species", "species"), ("parameters", "parameter"))
            d = _is_object(rs) ? _raw_get(rs, field) : nothing
            _is_object(d) && _raw_get(d, leaf) !== nothing && return kind
        end
    end
    return nothing
end

# Whether `name` names an unknown (a model's, or a reaction system's species)
# seen from `model`.
_raw_names_unknown(doc, model, name::AbstractString)::Bool =
    _raw_name_kind(doc, model, name) in ("unknown", "species")

_raw_ic(arg) = (d = OrderedDict{String, Any}(); d["op"] = "ic"; d["args"] = Any[arg]; d)

# `e` with every unknown reference `w` read as `ic(w)` and every `D(w)` as
# `ic(D(w))` (esm-spec §11.4.4). Fields other than the operands are kept.
function _raw_ic_migrate(e, isunk)
    if e isa AbstractString
        return isunk(String(e)) ? _raw_ic(String(e)) : e
    elseif _is_object(e)
        op = _raw_get(e, "op")
        # A starting value already written is left alone.
        op == "ic" && return e
        w = _raw_get(e, "wrt")
        if op == "D" && (w === nothing || w == "t")
            a = _raw_get(e, "args")
            if _is_array(a) && length(a) == 1 && a[1] isa AbstractString && isunk(String(a[1]))
                return _raw_ic(e)
            end
        end
        out = OrderedDict{String, Any}()
        for (k, v) in pairs(e)
            ks = String(k)
            out[ks] = if !(ks in _RAW_EXPRESSION_FIELDS)
                v
            elseif ks == "bindings"
                _is_object(v) ?
                    OrderedDict{String, Any}(String(n) => _raw_ic_migrate(x, isunk) for (n, x) in pairs(v)) : v
            elseif _is_array(v)
                Any[_raw_ic_migrate(x, isunk) for x in v]
            else
                _raw_ic_migrate(v, isunk)
            end
        end
        return out
    end
    return e
end

# The parameter `k` of the raw `model` an old initial condition sets (esm-spec
# §11.4.4 "An initial condition of a parameter"): `lhs` is `k` or `ic(k)`, `k` a
# declared parameter of the model; `nothing` otherwise. `bare` admits the bare
# spelling (an `initialization_equations` entry).
function _raw_parameter_ic_target(model, lhs; bare::Bool)
    name = if bare && lhs isa AbstractString
        String(lhs)
    elseif _is_object(lhs) && _raw_get(lhs, "op") == "ic"
        a = _raw_get(lhs, "args")
        (_is_array(a) && length(a) == 1 && a[1] isa AbstractString) ? String(a[1]) : nothing
    else
        nothing
    end
    return (name !== nothing && _raw_var_type(model, name) == "parameter") ? name : nothing
end

# Move the old initial condition `eq` (at `ptr`) of the parameter `k` into `k`'s
# `default`: the value replaces a declared one. Its right-hand side must be a
# number.
function _raw_parameter_ic_to_default!(model, k::String, eq, ptr::String)
    rhs = _raw_get(eq, "rhs")
    (rhs isa Real && !(rhs isa Bool)) || throw(
        ParseError(
            "[ic_invalid_argument] $(ptr): the initial condition of the parameter '$(k)' " *
                "is read as its `default` (esm-spec §11.4.4), which takes a number; its " *
                "right-hand side is not one.";
            code = ERROR_CODES.IC_INVALID_ARGUMENT, path = ptr
        )
    )
    _raw_get(model, "variables")[k]["default"] = rhs
    return nothing
end

function _migrate_init_model!(doc, model, at::String, sites::Vector{String}, legacy::Bool)
    _is_object(model) || return nothing
    # Below esm 2.5.0, `ic(k) ~ v` of a parameter in `equations` (§11.4.4).
    eqk = _node_key(model, "equations")
    eqs = eqk === nothing ? Any[] : model[eqk]
    if legacy && _is_array(eqs)
        drop = Int[]
        for (i, eq) in enumerate(eqs)
            k = _raw_parameter_ic_target(model, _raw_get(eq, "lhs"); bare = false)
            k === nothing && continue
            ptr = _pointer(at, "equations", i)
            _raw_parameter_ic_to_default!(model, k, eq, ptr)
            push!(sites, string(ptr, " (initial condition of a parameter)"))
            push!(drop, i)
        end
        isempty(drop) || deleteat!(eqs, drop)
    end
    key = _node_key(model, "initialization_equations")
    if key !== nothing
        init = model[key]
        delete!(model, key)
        if _is_array(init) && !isempty(init)
            push!(sites, string(at, "/initialization_equations (initialization_equations)"))
            # A parameter's initial condition becomes its default, in any version.
            rest = Tuple{Int, Any}[]
            for (i, eq) in enumerate(init)
                k = _raw_parameter_ic_target(model, _raw_get(eq, "lhs"); bare = true)
                if k === nothing
                    push!(rest, (i, eq))
                else
                    _raw_parameter_ic_to_default!(model, k, eq, _pointer(at, "initialization_equations", i))
                end
            end
            has_d = _is_array(eqs) && any(eq -> _raw_mentions_op(_raw_get(eq, "lhs"), "D"), eqs)
            if isempty(rest)
                # Only parameters' initial conditions: nothing is left to read.
            elseif has_d
                isunk = n -> _raw_names_unknown(doc, model, n)
                for (_, eq) in rest
                    neq = OrderedDict{String, Any}()
                    for (k, v) in pairs(eq)
                        ks = String(k)
                        neq[ks] = (ks == "lhs" || ks == "rhs") ? _raw_ic_migrate(v, isunk) : v
                    end
                    push!(eqs, neq)
                end
                eqk === nothing && (model["equations"] = eqs)
            else
                gk = _node_key(model, "guesses")
                guesses = gk === nothing ? OrderedDict{String, Any}() : model[gk]
                for (i, eq) in rest
                    lhs = _raw_get(eq, "lhs")
                    if !(lhs isa AbstractString && _raw_is_unknown_var(model, lhs))
                        throw(
                            ParseError(
                                "[deprecated_field] $(_pointer(at, "initialization_equations", i)): " *
                                    "the model has no time derivative, so its initialization " *
                                    "equations are starting points for its solve and are read as " *
                                    "`guesses` (esm-spec §11.4.4); this one's left-hand side is not a " *
                                    "bare unknown, so it has no reading as a starting point. Write a " *
                                    "`guesses` entry instead.";
                                code = ERROR_CODES.DEPRECATED_FIELD,
                                path = _pointer(at, "initialization_equations", i)
                            )
                        )
                    end
                    haskey(guesses, String(lhs)) || (guesses[String(lhs)] = _raw_get(eq, "rhs"))
                end
                gk === nothing && (model["guesses"] = guesses)
            end
        end
    end
    subs = _raw_get(model, "subsystems")
    if _is_object(subs)
        for (n, s) in pairs(subs)
            _migrate_init_model!(doc, s, _pointer(at, "subsystems", String(n)), sites, legacy)
        end
    end
    return nothing
end

"""
    _migrate_initialization_equations!(doc) -> Vector{String}

esm-spec §11.4.4: every model's deprecated `initialization_equations` read as
`ic` equations (or `guesses`, for a model with no time derivative), and a
pre-2.5.0 initial condition of a parameter read as its `default`, in place.
Returns the sites, `<pointer>/initialization_equations (initialization_equations)`
and `<pointer> (initial condition of a parameter)`.
Idempotent: the field does not survive.
"""
function _migrate_initialization_equations!(doc)::Vector{String}
    sites = String[]
    _is_object(doc) || return sites
    models = _raw_get(doc, "models")
    _is_object(models) || return sites
    legacy = _declares_before_2_5(doc)
    for (name, m) in pairs(models)
        _migrate_init_model!(doc, m, _pointer("", "models", String(name)), sites, legacy)
    end
    return sites
end

# Whether `doc` declares an esm version below 2.5.0, where `ic(k) ~ v` of a
# parameter was how an event-modified parameter was set (esm-spec §11.4.4).
function _declares_before_2_5(doc)
    v = _raw_get(doc, "esm")
    v isa AbstractString || return false
    ver = tryparse(VersionNumber, v)
    return ver !== nothing && ver < v"2.5.0"
end

# Whether the §11.4.4 migration has anything to rewrite in `doc`: a model's
# `initialization_equations`, or, below esm 2.5.0, an `ic` node (which may be a
# parameter's initial condition).
_needs_ic_migration(doc) = _is_object(doc) && _declares_before_2_5(doc) &&
    _visit_json((_, n) -> !(_is_object(n) && _raw_get(n, "op") == "ic") ? true : _JSON_STOP, doc)

# The argument of the raw `ic` node `n`, as the name it reads, or `nothing` when
# it is malformed: one variable reference, bare or scoped, or `D` of one.
function _raw_ic_argument_name(n)
    args = _raw_get(n, "args")
    (_is_array(args) && length(args) == 1) || return nothing
    a = args[1]
    a isa AbstractString && return String(a)
    _is_object(a) && _raw_get(a, "op") == "D" || return nothing
    inner = _raw_get(a, "args")
    (_is_array(inner) && length(inner) == 1 && inner[1] isa AbstractString) || return nothing
    return String(inner[1])
end

# The raw model an expression at the pointer segments `segs` sits in
# (`/models/A/subsystems/B/…`), or `nothing` outside a model's equations.
function _raw_enclosing_model(doc, segs)
    (length(segs) >= 2 && segs[1] == "models") || return nothing
    models = _raw_get(doc, "models")
    m = _is_object(models) ? _raw_get(models, String(segs[2])) : nothing
    k = 3
    while _is_object(m) && k + 1 <= length(segs) && segs[k] == "subsystems"
        subs = _raw_get(m, "subsystems")
        m = _is_object(subs) ? _raw_get(subs, String(segs[k + 1])) : nothing
        k += 2
    end
    (_is_object(m) && k <= length(segs) && segs[k] == "equations") || return nothing
    return m
end

_raw_pointer_text(ptr) =
    string(ptr.base, ("/" * (s isa AbstractString ? _ptr_escape(s) : string(s)) for s in ptr.segs)...)

# esm-spec §4.2 (`ic`, esm 2.5.0): the argument of `ic` is a variable reference,
# bare or scoped, or `D` of one, and never a declared parameter. `ic(index(u,
# i))`, `ic(a + b)` and `ic(k)` of a parameter `k` are refused at load with
# `ic_invalid_argument`, naming the node's JSON-pointer location.
function _check_ic_arguments(doc)
    _visit_json(doc; path = "") do _, n, ptr
        (_is_object(n) && _raw_get(n, "op") == "ic") || return true
        at = _raw_pointer_text(ptr)
        name = _raw_ic_argument_name(n)
        if name === nothing
            throw(
                ParseError(
                    "[ic_invalid_argument] $(at): `ic` of " *
                        first(JSON3.write(_raw_get(n, "args")), 120) * ": the argument of " *
                        "`ic` must be one variable reference or `D` of one (esm-spec §4.2); an " *
                        "element of an array's starting value is written `index(ic(u), i)`, not " *
                        "`ic(index(u, i))`.";
                    code = ERROR_CODES.IC_INVALID_ARGUMENT, path = at
                )
            )
        end
        model = _raw_enclosing_model(doc, ptr.segs)
        if model !== nothing && _raw_name_kind(doc, model, name) == "parameter"
            throw(
                ParseError(
                    "[ic_invalid_argument] $(at): `ic` of '$(name)', a declared parameter. " *
                        "A parameter has no starting value of its own; its value is read as " *
                        "`$(name)` (esm-spec §4.2).";
                    code = ERROR_CODES.IC_INVALID_ARGUMENT, path = at
                )
            )
        end
        return true
    end
    return nothing
end
