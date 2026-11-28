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

# Whether `lhs` (raw JSON) holds a time derivative `D` node anywhere: `D(x)`, or
# a `faq` whose body is `D(index(x, i))`.
function _raw_mentions_op(e, op::String)::Bool
    if _is_object(e)
        _raw_get(e, "op") == op && return true
        for k in ("args", "expr", "filter", "values")
            v = _raw_get(e, k)
            v === nothing && continue
            if _is_array(v)
                any(x -> _raw_mentions_op(x, op), v) && return true
            elseif _raw_mentions_op(v, op)
                return true
            end
        end
    elseif _is_array(e)
        return any(x -> _raw_mentions_op(x, op), e)
    end
    return false
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

_raw_is_unknown_var(model, name::AbstractString) = (
    vars = _raw_get(model, "variables");
    v = _is_object(vars) ? _raw_get(vars, String(name)) : nothing;
    _is_object(v) && _raw_get(v, "type") == "unknown"
)

# Whether `name` (bare or dot-scoped) names an unknown seen from `model`: a
# local unknown; a scoped one resolved below `model`'s subsystems, else from the
# document root (a model's unknown, or a reaction system's species).
function _raw_names_unknown(doc, model, name::AbstractString)::Bool
    occursin('.', name) || return _raw_is_unknown_var(model, name)
    segs = split(name, '.')
    leaf = String(segs[end])
    sub = _raw_subsystem(model, segs[1:(end - 1)])
    sub !== nothing && _raw_is_unknown_var(sub, leaf) && return true
    models = _raw_get(doc, "models")
    if _is_object(models)
        root = _raw_get(models, String(segs[1]))
        if _is_object(root)
            m = _raw_subsystem(root, segs[2:(end - 1)])
            m !== nothing && _raw_is_unknown_var(m, leaf) && return true
        end
    end
    rss = _raw_get(doc, "reaction_systems")
    if _is_object(rss) && length(segs) == 2
        rs = _raw_get(rss, String(segs[1]))
        sp = _is_object(rs) ? _raw_get(rs, "species") : nothing
        _is_object(sp) && _raw_get(sp, leaf) !== nothing && return true
    end
    return false
end

_raw_ic(arg) = (d = OrderedDict{String, Any}(); d["op"] = "ic"; d["args"] = Any[arg]; d)

# `e` with every unknown reference `w` read as `ic(w)` and every `D(w)` as
# `ic(D(w))` (esm-spec §11.4.4). Fields other than the operands are kept.
function _raw_ic_migrate(e, isunk)
    if e isa AbstractString
        return isunk(String(e)) ? _raw_ic(String(e)) : e
    elseif _is_object(e)
        op = _raw_get(e, "op")
        if op == "D"
            a = _raw_get(e, "args")
            if _is_array(a) && length(a) == 1 && a[1] isa AbstractString && isunk(String(a[1]))
                return _raw_ic(e)
            end
        end
        out = OrderedDict{String, Any}()
        for (k, v) in pairs(e)
            ks = String(k)
            if ks == "args" || ks == "values"
                out[ks] = _is_array(v) ? Any[_raw_ic_migrate(x, isunk) for x in v] : v
            elseif ks == "expr" || ks == "filter"
                out[ks] = _raw_ic_migrate(v, isunk)
            else
                out[ks] = v
            end
        end
        return out
    end
    return e
end

function _migrate_init_model!(doc, model, at::String, sites::Vector{String})
    _is_object(model) || return nothing
    key = _node_key(model, "initialization_equations")
    if key !== nothing
        init = model[key]
        delete!(model, key)
        if _is_array(init) && !isempty(init)
            push!(sites, string(at, "/initialization_equations (initialization_equations)"))
            eqk = _node_key(model, "equations")
            eqs = eqk === nothing ? Any[] : model[eqk]
            has_d = _is_array(eqs) && any(eq -> _raw_mentions_op(_raw_get(eq, "lhs"), "D"), eqs)
            if has_d
                isunk = n -> _raw_names_unknown(doc, model, n)
                for eq in init
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
                for (i, eq) in enumerate(init)
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
            _migrate_init_model!(doc, s, _pointer(at, "subsystems", String(n)), sites)
        end
    end
    return nothing
end

"""
    _migrate_initialization_equations!(doc) -> Vector{String}

esm-spec §11.4.4: every model's deprecated `initialization_equations` read as
`ic` equations (or `guesses`, for a model with no time derivative), in place.
Returns the sites, `<pointer>/initialization_equations (initialization_equations)`.
Idempotent: the field does not survive.
"""
function _migrate_initialization_equations!(doc)::Vector{String}
    sites = String[]
    _is_object(doc) || return sites
    models = _raw_get(doc, "models")
    _is_object(models) || return sites
    for (name, m) in pairs(models)
        _migrate_init_model!(doc, m, _pointer("", "models", String(name)), sites)
    end
    return sites
end

# esm-spec §4.2 (`ic`, esm 2.5.0): the argument of `ic` is a variable reference,
# bare or scoped, or `D` of one. `ic(index(u, i))` and `ic(a + b)` are malformed
# and refused at load with `ic_invalid_argument`.
function _check_ic_arguments(doc)
    _visit_json(doc) do _, n
        _is_object(n) || return true
        _raw_get(n, "op") == "ic" || return true
        args = _raw_get(n, "args")
        ok = _is_array(args) && length(args) == 1 && (
            args[1] isa AbstractString || (
                _is_object(args[1]) && _raw_get(args[1], "op") == "D" &&
                    _is_array(_raw_get(args[1], "args")) &&
                    length(_raw_get(args[1], "args")) == 1 &&
                    _raw_get(args[1], "args")[1] isa AbstractString
            )
        )
        ok || throw(
            ParseError(
                "[ic_invalid_argument] `ic` with argument $(first(string(_raw_get(n, "args")), 120)): the argument of `ic` must be one variable reference or `D` of one " *
                    "(esm-spec §4.2); an element of an array's starting value is written " *
                    "`index(ic(u), i)`, not `ic(index(u, i))`.";
                code = ERROR_CODES.IC_INVALID_ARGUMENT
            )
        )
        return true
    end
    return nothing
end
