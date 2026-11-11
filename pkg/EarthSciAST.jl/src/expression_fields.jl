# ===========================================================================
# expression_fields.jl — walkers over the expression-bearing fields of a model,
# a reaction system and a coupling entry. Each calls `f(expr, path, registry)`
# on the root of every field, with `path` the field's JSON pointer: variable
# update rules, equations, initialization equations, guesses, events and
# inline-test references (recursing into subsystems); reaction rates,
# constraint equations, events, parameter update rules and inline-test
# references of reaction systems; and the expressions of `coupling` entries.
# ===========================================================================

function _foreach_update_expression(f, rules, path::String, reg)
    rules === nothing && return nothing
    for (i, r) in enumerate(rules)
        p = "$(path)/update/$(i - 1)"
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
        ev.trigger isa ConditionTrigger && f(ev.trigger.expression, "$(p)/trigger", reg)
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

function _foreach_rs_expression(f, rs::ReactionSystem, path::String, reg)
    for (i, r) in enumerate(rs.reactions)
        f(r.rate, "$(path)/reactions/$(i - 1)/rate", reg)
    end
    for p in rs.parameters
        _foreach_update_expression(f, p.update, "$(path)/parameters/$(p.name)", reg)
    end
    _foreach_equation_expression(
        f, rs.constraint_equations,
        "$(path)/constraint_equations", reg
    )
    _foreach_event_expression(f, rs.continuous_events, rs.discrete_events, path, reg)
    _foreach_test_expression(f, rs.tests, path, reg)
    for (sname, sub) in rs.subsystems
        _foreach_rs_expression(f, sub, "$(path)/subsystems/$(sname)", reg)
    end
    return nothing
end

function _foreach_coupling_expression(f, ce::CouplingEntry, path::String)
    if ce isa CouplingCouple && haskey(ce.connector, "equations")
        eqs = ce.connector["equations"]
        if eqs isa AbstractVector
            for (i, e) in enumerate(eqs)
                (e isa AbstractDict && get(e, "expression", nothing) isa ASTExpr) || continue
                f(e["expression"], "$(path)/connector/equations/$(i - 1)/expression", nothing)
            end
        end
    elseif ce isa CouplingVariableMap && ce.transform isa ASTExpr
        f(ce.transform, "$(path)/transform", nothing)
    elseif ce isa CouplingEvent
        if ce.conditions !== nothing
            for (j, c) in enumerate(ce.conditions)
                f(c, "$(path)/conditions/$(j - 1)", nothing)
            end
        end
        ce.trigger isa ConditionTrigger && f(ce.trigger.expression, "$(path)/trigger", nothing)
        _foreach_affect_expression(f, ce.affects, "$(path)/affects", nothing)
        _foreach_affect_expression(f, ce.affect_neg, "$(path)/affect_neg", nothing)
    end
    return nothing
end
