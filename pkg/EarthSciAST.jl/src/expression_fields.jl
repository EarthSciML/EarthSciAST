# ===========================================================================
# expression_fields.jl — a walker over the expression-bearing fields of a
# model. It calls `f(expr, path, registry)` on the root of every field, with
# `path` the field's JSON pointer as written in the document: variable update
# rules, equations, initialization equations, guesses, events and inline-test
# references, recursing into subsystems.
# ===========================================================================

function _foreach_update_expression(f, rules, path::String, reg)
    rules === nothing && return nothing
    for (i, r) in enumerate(rules)
        p = _update_rule_path(path, rules, i)
        r.when === nothing || f(r.when, "$(p)/when", reg)
        r.expression === nothing || f(r.expression, "$(p)/expression", reg)
        if r.from !== nothing && r.from.unit_conversion isa ASTExpr
            f(r.from.unit_conversion, "$(p)/from/unit_conversion", reg)
        end
    end
    return nothing
end

function _foreach_equation_expression(f, eqs, path::String, reg)
    for (i, eq) in enumerate(eqs)
        f(eq.lhs, "$(path)/$(i - 1)/lhs", reg)
        f(eq.rhs, "$(path)/$(i - 1)/rhs", reg)
    end
    return nothing
end

function _foreach_affect_expression(f, affects, path::String, reg)
    affects === nothing && return nothing
    for (i, a) in enumerate(affects)
        f(a.rhs, "$(path)/$(i - 1)/rhs", reg)
    end
    return nothing
end

function _foreach_event_expression(f, cevs, devs, path::String, reg)
    for (i, ev) in enumerate(cevs)
        p = "$(path)/continuous_events/$(i - 1)"
        for (j, c) in enumerate(ev.conditions)
            f(c, "$(p)/conditions/$(j - 1)", reg)
        end
        _foreach_affect_expression(f, ev.affects, "$(p)/affects", reg)
        _foreach_affect_expression(f, ev.affect_neg, "$(p)/affect_neg", reg)
    end
    for (i, ev) in enumerate(devs)
        p = "$(path)/discrete_events/$(i - 1)"
        ev.trigger isa ConditionTrigger && f(ev.trigger.expression, "$(p)/trigger/expression", reg)
        _foreach_affect_expression(f, ev.affects, "$(p)/affects", reg)
    end
    return nothing
end

function _foreach_test_expression(f, tests, path::String, reg)
    for (i, t) in enumerate(tests)
        for (j, a) in enumerate(t.assertions)
            a.reference isa ASTExpr &&
                f(a.reference, "$(path)/tests/$(i - 1)/assertions/$(j - 1)/reference", reg)
        end
    end
    return nothing
end

function _foreach_model_expression(f, m::Model, path::String, reg)
    for (vname, var) in m.variables
        _foreach_update_expression(f, var.update, "$(path)/variables/$(vname)", reg)
    end
    _foreach_equation_expression(f, m.equations, "$(path)/equations", reg)
    _foreach_equation_expression(
        f, m.initialization_equations,
        "$(path)/initialization_equations", reg
    )
    for (gname, g) in m.guesses
        g isa ASTExpr && f(g, "$(path)/guesses/$(gname)", reg)
    end
    _foreach_event_expression(f, m.continuous_events, m.discrete_events, path, reg)
    _foreach_test_expression(f, m.tests, path, reg)
    for (sname, sub) in m.subsystems
        sub isa Model || continue
        _foreach_model_expression(f, sub, "$(path)/subsystems/$(sname)", reg)
    end
    return nothing
end
