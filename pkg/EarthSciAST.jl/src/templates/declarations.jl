# Expression-template declarations (esm-spec §9.6.1, §9.7.3): validation of a
# component's `expression_templates` block and the template body-reference graph.

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

function _assert_no_nested_apply(body, template_name::String, path::String)
    if _is_array(body)
        for (i, child) in enumerate(body)
            _assert_no_nested_apply(child, template_name, "$path/$(i - 1)")
        end
        return
    end
    return if _is_object(body)
        op = _raw_get(body, "op")
        op_str = op === nothing ? "" : string(op)
        if op_str == APPLY_EXPRESSION_TEMPLATE_OP
            throw(
                ExpressionTemplateError(
                    ERROR_CODES.APPLY_EXPRESSION_TEMPLATE_INVALID_DECLARATION,
                    "expression_templates.$(template_name): `match` contains an 'apply_expression_template' node at $path; match patterns MUST NOT reference templates (esm-spec §9.7.3)"
                )
            )
        end
        for (k, v) in pairs(body)
            _assert_no_nested_apply(v, template_name, "$path/$(string(k))")
        end
    end
end

function _validate_templates(templates::AbstractDict{String, Any}, scope::String)
    for (name, decl) in templates
        if !_is_object(decl)
            throw(
                ExpressionTemplateError(
                    ERROR_CODES.APPLY_EXPRESSION_TEMPLATE_INVALID_DECLARATION,
                    "$scope.expression_templates.$name: entry must be an object with params + body"
                )
            )
        end
        # `params` MAY be empty (esm-spec §9.6.1, 0.8.0): a zero-parameter
        # template is a named constant fragment (common in library files).
        params = _raw_get(decl, "params")
        if params === nothing || !_is_array(params)
            throw(
                ExpressionTemplateError(
                    ERROR_CODES.APPLY_EXPRESSION_TEMPLATE_INVALID_DECLARATION,
                    "$scope.expression_templates.$name: 'params' must be an array of strings"
                )
            )
        end
        seen = Set{String}()
        for p in params
            if !(p isa AbstractString) || isempty(p)
                throw(
                    ExpressionTemplateError(
                        ERROR_CODES.APPLY_EXPRESSION_TEMPLATE_INVALID_DECLARATION,
                        "$scope.expression_templates.$name: param names must be non-empty strings"
                    )
                )
            end
            ps = string(p)
            if ps in seen
                throw(
                    ExpressionTemplateError(
                        ERROR_CODES.APPLY_EXPRESSION_TEMPLATE_INVALID_DECLARATION,
                        "$scope.expression_templates.$name: param '$ps' is declared twice"
                    )
                )
            end
            push!(seen, ps)
        end
        body = _raw_get(decl, "body")
        if body === nothing
            throw(
                ExpressionTemplateError(
                    ERROR_CODES.APPLY_EXPRESSION_TEMPLATE_INVALID_DECLARATION,
                    "$scope.expression_templates.$name: 'body' is required"
                )
            )
        end
        # A body MAY reference other match-less in-scope templates via
        # apply_expression_template nodes (esm-spec §9.7.3); those are checked
        # (acyclic, depth <= MAX_TEMPLATE_EXPANSION_DEPTH) at registration by
        # `_check_template_body_graph` and are not inlined.

        # esm-spec §9.6: an optional `match` pattern turns the entry into an
        # auto-applied rewrite rule. The pattern is an Expression in which the
        # declared params are wildcards; it MUST NOT contain nested
        # apply_expression_template ops. Nontermination is NOT checked
        # statically any more — the bounded fixpoint (`MAX_REWRITE_PASSES`,
        # esm-spec §9.6.3) is the authoritative guard, so a self-reintroducing
        # rule is rejected at load time (`rewrite_rule_nonterminating`) only when
        # it actually fails to converge within the pass bound.
        match = _raw_get(decl, "match")
        if match !== nothing
            _assert_no_nested_apply(match, name, "/match")
        end

        # esm-spec §9.6.1 (0.8.0): an optional `where` block adds static
        # match-scoping constraints on the captured params. Structural
        # validation only, here; the unknown-index-set check runs at rule
        # REGISTRATION in the consuming component (where the merged
        # `index_sets` registry is in scope) — see `_registered_where`.
        whr = _raw_get(decl, "where")
        if whr !== nothing
            match === nothing && throw(
                ExpressionTemplateError(
                    ERROR_CODES.APPLY_EXPRESSION_TEMPLATE_INVALID_DECLARATION,
                    "$scope.expression_templates.$name: 'where' is only admissible " *
                        "alongside 'match' — constraints scope an auto-applied rewrite " *
                        "rule, not a named fragment (esm-spec §9.6.1)"
                )
            )
            (_is_object(whr) && !isempty(collect(pairs(whr)))) ||
                throw(
                ExpressionTemplateError(
                    ERROR_CODES.APPLY_EXPRESSION_TEMPLATE_INVALID_DECLARATION,
                    "$scope.expression_templates.$name: 'where' must be a " *
                        "non-empty object mapping declared params to constraint objects"
                )
            )
            for (p, cobj) in pairs(whr)
                ps = string(p)
                ps in seen || throw(
                    ExpressionTemplateError(
                        ERROR_CODES.APPLY_EXPRESSION_TEMPLATE_INVALID_DECLARATION,
                        "$scope.expression_templates.$name: 'where' constrains '$ps', " *
                            "which is not a declared param (esm-spec §9.6.1)"
                    )
                )
                _is_object(cobj) || throw(
                    ExpressionTemplateError(
                        ERROR_CODES.APPLY_EXPRESSION_TEMPLATE_INVALID_DECLARATION,
                        "$scope.expression_templates.$name: where.$ps must be a " *
                            "constraint object (v1 admits exactly the 'shape' kind)"
                    )
                )
                ckeys = Set{String}(string(k) for (k, _) in pairs(cobj))
                ckeys == Set(["shape"]) || throw(
                    ExpressionTemplateError(
                        ERROR_CODES.APPLY_EXPRESSION_TEMPLATE_INVALID_DECLARATION,
                        "$scope.expression_templates.$name: where.$ps carries " *
                            "constraint kind(s) $(join(sort(collect(ckeys)), ", ")); the " *
                            "v1 constraint vocabulary is exactly {shape} (esm-spec §9.6.1)"
                    )
                )
                shp = _raw_get(cobj, "shape")
                (_is_array(shp) && !isempty(shp)) || throw(
                    ExpressionTemplateError(
                        ERROR_CODES.APPLY_EXPRESSION_TEMPLATE_INVALID_DECLARATION,
                        "$scope.expression_templates.$name: where.$ps.shape must be a " *
                            "non-empty array of index-set names"
                    )
                )
                for s in shp
                    (s isa AbstractString && !isempty(string(s))) ||
                        throw(
                        ExpressionTemplateError(
                            ERROR_CODES.APPLY_EXPRESSION_TEMPLATE_INVALID_DECLARATION,
                            "$scope.expression_templates.$name: where.$ps.shape " *
                                "entries must be non-empty strings"
                        )
                    )
                end
            end
        end
    end
    return
end

"""
Maximum template-body reference-chain depth (counted in templates along the
longest chain, so a 33-template chain is rejected) before a file is rejected
with `template_body_expansion_too_deep` (esm-spec §9.7.3). Pinned identically
across all bindings.
"""
const MAX_TEMPLATE_EXPANSION_DEPTH = 32

# ---------------------------------------------------------------------------
# Registration-time body composition (esm-spec §9.7.3)
# ---------------------------------------------------------------------------

# The `name` of every `apply_expression_template` node in a template body
# (document order) — the §9.7.3 body-reference edges.
function _collect_apply_names!(out::Vector{String}, x)
    _walk_json(x) do _, n
        _is_array(n) && return _may_hold_object(n)
        _is_object(n) || return true
        op = _raw_get(n, "op")
        if op !== nothing && string(op) == APPLY_EXPRESSION_TEMPLATE_OP
            nm = _raw_get(n, "name")
            nm !== nothing && push!(out, string(nm))
        end
        return true
    end
    return out
end

"""
    _check_template_body_graph(templates, scope)

Registration-time body checking (esm-spec §9.7.3):
template bodies MAY reference other in-scope MATCH-LESS templates via
`apply_expression_template` nodes. Builds the body-reference graph, rejects
cycles (`apply_expression_template_recursive_body`), references to undeclared
or `match`-bearing templates (`apply_expression_template_unknown_template`),
and chains deeper than `MAX_TEMPLATE_EXPANSION_DEPTH` templates
(`template_body_expansion_too_deep`).

Bodies are not inlined: the references are preserved and denote their
expansion (§9.6.4 rule 2). Target-bearing flags (§9.6.4 rule 3) are computed
separately by [`_template_target_bearing`](@ref). This runs BEFORE the §9.6.3
fixpoint ever consults a `match` rule.
"""
function _check_template_body_graph(templates::AbstractDict{String, Any}, scope::String)
    isempty(templates) && return
    refs = Dict{String, Vector{String}}()
    for (name, decl) in templates
        body = _raw_get(decl, "body")
        refs[name] = _collect_apply_names!(String[], body)
    end
    any(!isempty, values(refs)) || return

    for name in sort(collect(keys(refs)))
        for r in refs[name]
            tdecl = get(templates, r, nothing)
            tdecl === nothing && throw(
                ExpressionTemplateError(
                    ERROR_CODES.APPLY_EXPRESSION_TEMPLATE_UNKNOWN_TEMPLATE,
                    "$scope.expression_templates.$name: body references undeclared template '$r' (esm-spec §9.7.3)"
                )
            )
            if _raw_get(tdecl, "match") !== nothing
                throw(
                    ExpressionTemplateError(
                        ERROR_CODES.APPLY_EXPRESSION_TEMPLATE_UNKNOWN_TEMPLATE,
                        "$scope.expression_templates.$name: body references '$r', a `match` " *
                            "rewrite rule — only match-less templates are invocable by name (esm-spec §9.7.3)"
                    )
                )
            end
        end
    end

    # DFS over the reference graph: cycle detection and the chain-depth bound.
    state = Dict{String, Int}()   # 1 = on stack, 2 = done
    depth = Dict{String, Int}()   # templates on the longest chain from this node
    chain = String[]
    function visit(name::String)::Int
        st = get(state, name, 0)
        if st == 1
            cyc = vcat(chain[findfirst(==(name), chain):end], [name])
            throw(
                ExpressionTemplateError(
                    ERROR_CODES.APPLY_EXPRESSION_TEMPLATE_RECURSIVE_BODY,
                    "$scope.expression_templates: template-body reference cycle " *
                        "$(join(cyc, " -> ")) (esm-spec §9.7.3)"
                )
            )
        end
        st == 2 && return depth[name]
        state[name] = 1
        push!(chain, name)
        d = 1
        for r in refs[name]
            d = max(d, 1 + visit(r))
        end
        pop!(chain)
        state[name] = 2
        depth[name] = d
        d > MAX_TEMPLATE_EXPANSION_DEPTH && throw(
            ExpressionTemplateError(
                ERROR_CODES.TEMPLATE_BODY_EXPANSION_TOO_DEEP,
                "$scope.expression_templates.$name: body-reference chain of $d templates " *
                    "exceeds MAX_TEMPLATE_EXPANSION_DEPTH=$MAX_TEMPLATE_EXPANSION_DEPTH (esm-spec §9.7.3)"
            )
        )
        return d
    end
    for name in sort(collect(keys(refs)))
        visit(name)
    end

    # The bodies keep their `apply_expression_template` references; `Expand`
    # (§9.6.4 rule 2) or the eager pre-pass (§9.6.4 rule 3) consume them later.
    return
end
