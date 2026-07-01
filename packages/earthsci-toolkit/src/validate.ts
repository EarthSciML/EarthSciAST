/**
 * ESM Format validation wrapper for cross-language conformance testing.
 *
 * Provides a standardized validation interface that matches the format expected
 * by the conformance test runner across all language implementations.
 */

import { validateSchema, load, type SchemaError } from './parse.js';
import {
    validateUnits,
    checkDimensions,
    parseUnit,
    isDimensionless,
    dimsEqual,
    type UnitWarning,
    type CanonicalDims,
    type ParsedUnit,
} from './units.js';
import type {
    EsmFile,
    Model,
    ReactionSystem,
    Expression,
    ExpressionNode,
    CouplingEntry,
    CouplingOperatorCompose,
    CouplingCouple,
    CouplingOperatorApply,
    DiscreteEvent,
    ContinuousEvent,
    AffectEquation,
    FunctionalAffect,
    Reaction,
    StoichiometryEntry,
    SubsystemRef,
} from './types.js';

/**
 * Validation error with structured details
 */
export interface ValidationError {
    path: string;
    message: string;
    code: string;
    details: Record<string, any>;
}

/**
 * Structured validation result
 */
export interface ValidationResult {
    is_valid: boolean;
    schema_errors: ValidationError[];
    structural_errors: ValidationError[];
    unit_warnings: UnitWarning[];
}

/**
 * Structural error type matching the format specification
 */
export interface StructuralError {
    path: string;
    message: string;
    code: string;
    details: Record<string, any>;
}

/**
 * Extract all variable references from an expression
 */
function extractVariableReferences(expr: Expression): string[] {
    const variables: string[] = [];

    function visit(node: Expression): void {
        if (typeof node === 'string') {
            // String references are variable names
            variables.push(node);
        } else if (typeof node === 'number') {
            // Numbers are literals, no variables
            return;
        } else if (node && typeof node === 'object' && 'op' in node) {
            // Expression node - recursively visit arguments
            const exprNode = node as ExpressionNode;
            if (exprNode.args) {
                for (const arg of exprNode.args) {
                    visit(arg);
                }
            }
        }
    }

    visit(expr);
    return Array.from(new Set(variables)); // Remove duplicates
}

/**
 * Collect the binder-introduced index / contraction symbols in an expression:
 * the loop variables of an aggregate (`output_idx` and `ranges` keys) and the
 * element positions of an `index` node (`index(array, i, j)` binds `i`, `j`).
 * These name iteration positions, not declared variables, so reference
 * integrity must not flag them as undefined. Traversal mirrors
 * `extractVariableReferences` (descends `args`) so every symbol that function
 * can surface as a candidate reference is captured here.
 */
function collectIndexSymbols(expr: Expression): Set<string> {
    const symbols = new Set<string>();

    function visit(node: Expression): void {
        if (!node || typeof node !== 'object' || !('op' in node)) return;
        const exprNode = node as ExpressionNode;

        if (exprNode.op === 'aggregate') {
            const agg = exprNode as any;
            for (const idx of agg.output_idx || []) {
                if (typeof idx === 'string') symbols.add(idx);
            }
            if (agg.ranges && typeof agg.ranges === 'object') {
                for (const key of Object.keys(agg.ranges)) symbols.add(key);
            }
        }

        if (exprNode.op === 'index' && exprNode.args) {
            // index(array, pos1, pos2, ...): positions after the array head are
            // index expressions; bare-name positions are bound index symbols.
            for (let i = 1; i < exprNode.args.length; i++) {
                const pos = exprNode.args[i];
                if (typeof pos === 'string') symbols.add(pos);
            }
        }

        if (exprNode.args) {
            for (const arg of exprNode.args) visit(arg);
        }
    }

    visit(expr);
    return symbols;
}

/**
 * The variable a derivative differentiates. Either a bare name (`D(v)`) or the
 * array head of an `index` node (`D(index(v, i...))`) — the aggregate-IR form
 * that differentiates a single element of an arrayed state variable.
 */
function derivativeTargetVariable(arg: Expression): string | undefined {
    if (typeof arg === 'string') return arg;
    if (arg && typeof arg === 'object' && 'op' in arg) {
        const node = arg as ExpressionNode;
        if (node.op === 'index' && node.args && node.args.length > 0) {
            const head = node.args[0];
            if (typeof head === 'string') return head;
        }
    }
    return undefined;
}

/**
 * The variable an equation LHS assigns to, peeling derivative, element-index,
 * and aggregate-output wrappers down to the underlying name. Used to credit a
 * relational / algebraic equation (e.g. the aggregate-IR `index(v, i) =
 * aggregate(...)` produced by skolem / distinct / rank) that defines a state
 * variable without a time derivative.
 */
function lhsAssignmentTarget(lhs: Expression): string | undefined {
    if (typeof lhs === 'string') return lhs;
    if (lhs && typeof lhs === 'object' && 'op' in lhs) {
        const node = lhs as ExpressionNode;
        switch (node.op) {
            case 'D':
            case 'index':
                return node.args && node.args.length > 0
                    ? lhsAssignmentTarget(node.args[0])
                    : undefined;
            case 'aggregate':
                return (node as any).expr !== undefined
                    ? lhsAssignmentTarget((node as any).expr as Expression)
                    : undefined;
            default:
                return undefined;
        }
    }
    return undefined;
}

/**
 * Count D(var, t) derivatives in an expression.
 *
 * Recognises the aggregate-IR derivative forms in addition to the bare
 * `D(v)`: an `index`-wrapped derivative `D(index(v, i))`, and a derivative
 * carried in an aggregate's contracted body (`aggregate(output_idx:[i],
 * expr: D(index(v, i)))`), whose `D` lives under `expr` rather than `args`.
 */
function countDerivatives(expr: Expression): { [variable: string]: number } {
    const derivatives: { [variable: string]: number } = {};

    function visit(node: Expression): void {
        if (typeof node === 'object' && node && 'op' in node) {
            const exprNode = node as ExpressionNode;
            if (exprNode.op === 'D' && exprNode.args && exprNode.args.length >= 1) {
                const target = derivativeTargetVariable(exprNode.args[0]);
                if (target !== undefined) {
                    derivatives[target] = (derivatives[target] || 0) + 1;
                }
            }
            // Recursively visit all arguments
            if (exprNode.args) {
                for (const arg of exprNode.args) {
                    visit(arg);
                }
            }
            // An aggregate carries its contracted body (and any LHS derivative)
            // in `expr`, not `args` — descend there too.
            if ('expr' in exprNode && (exprNode as any).expr !== undefined) {
                visit((exprNode as any).expr as Expression);
            }
        }
    }

    visit(expr);
    return derivatives;
}

/**
 * Resolve scoped variable reference like "Model.Subsystem.var"
 */
function resolveScopedReference(reference: string, esmFile: EsmFile): boolean {
    const parts = reference.split('.');
    if (parts.length < 2) {
        return false; // Not a scoped reference
    }

    const [systemName, ...pathParts] = parts;
    const variableName = pathParts.pop()!;

    // Try to find in models
    if (esmFile.models && esmFile.models[systemName]) {
        let current: Model = esmFile.models[systemName];

        // Navigate through subsystems
        for (const pathPart of pathParts) {
            if (!current.subsystems || !current.subsystems[pathPart]) {
                return false;
            }
            current = current.subsystems[pathPart];
        }

        // Check if variable exists
        return current.variables && variableName in current.variables;
    }

    // Try to find in reaction systems
    if (esmFile.reaction_systems && esmFile.reaction_systems[systemName]) {
        let current: ReactionSystem = esmFile.reaction_systems[systemName];

        // Navigate through subsystems
        for (const pathPart of pathParts) {
            if (!current.subsystems || !current.subsystems[pathPart]) {
                return false;
            }
            current = current.subsystems[pathPart];
        }

        // Check if species or parameter exists
        return (current.species && variableName in current.species) ||
               (current.parameters && variableName in current.parameters);
    }

    return false;
}

/**
 * Check equation-unknown balance for a model
 */
function validateEquationBalance(model: Model, modelPath: string): StructuralError[] {
    const errors: StructuralError[] = [];

    // Count state variables
    const stateVariables = Object.entries(model.variables || {})
        .filter(([_, variable]) => variable.type === 'state')
        .map(([name, _]) => name);

    // Count equations driving each state variable. A normal ODE contributes a
    // D(var,t) derivative; an aggregate LHS contributes the derivative carried
    // in its contracted body. A relational / algebraic equation with no time
    // derivative (the aggregate-IR `index(v, i) = aggregate(...)` form emitted
    // by skolem / distinct / rank) instead credits the state variable its LHS
    // assigns to, so element-defined state still balances the unknown count.
    const derivativeCounts: { [variable: string]: number } = {};

    for (const equation of model.equations || []) {
        const lhsDerivatives = countDerivatives(equation.lhs);
        if (Object.keys(lhsDerivatives).length > 0) {
            for (const [variable, count] of Object.entries(lhsDerivatives)) {
                derivativeCounts[variable] = (derivativeCounts[variable] || 0) + count;
            }
        } else {
            const target = lhsAssignmentTarget(equation.lhs);
            if (target !== undefined && stateVariables.includes(target)) {
                derivativeCounts[target] = (derivativeCounts[target] || 0) + 1;
            }
        }
    }

    const odeEquationCount = Object.values(derivativeCounts).reduce((sum, count) => sum + count, 0);

    if (stateVariables.length !== odeEquationCount) {
        const missingEquations = stateVariables.filter(varName => !(varName in derivativeCounts));

        errors.push({
            path: modelPath,
            code: 'equation_count_mismatch',
            message: `Number of ODE equations (${odeEquationCount}) does not match number of state variables (${stateVariables.length})`,
            details: {
                state_variables: stateVariables,
                ode_equations: odeEquationCount,
                missing_equations_for: missingEquations
            }
        });
    }

    return errors;
}

/**
 * Check reference integrity for a model
 */
function validateReferenceIntegrity(model: Model, modelPath: string, esmFile: EsmFile): StructuralError[] {
    const errors: StructuralError[] = [];
    const declaredVariables = new Set(Object.keys(model.variables || {}));
    // Declared index sets are a legitimate, non-variable identifier namespace
    // (RFC semiring-faq-unified-ir §5.2). An `aggregate` may name an index set
    // as a positional operand — the value-invention form
    // `aggregate(args:["faces"], ...)` enumerates over the `faces` set itself
    // (the mesh-edge enumeration of ess-my4.3.10 / §7.3). Such a name is not a
    // declared variable, so credit the document-scoped `index_sets` keys here,
    // exactly as the binder symbols below credit aggregate range / `index`
    // positions (the aggregate-aware fix of ess-my4.1.7). A genuinely-undefined
    // reference still matches neither set and is flagged. As of v0.8.0 the
    // `index_sets` registry is a single, document-level field shared by every
    // model (a sibling of `models` / `domain`), not a per-model field.
    const declaredIndexSets = new Set(Object.keys(esmFile.index_sets || {}));

    // Check equations
    for (let i = 0; i < (model.equations || []).length; i++) {
        const equation = model.equations![i];
        const equationPath = `${modelPath}/equations/${i}`;

        // Binder-introduced index / contraction symbols (aggregate ranges and
        // output indices, `index` element positions) are iteration positions,
        // not declared variables — collect them so they are not flagged as
        // undefined references below.
        const boundSymbols = new Set<string>([
            ...collectIndexSymbols(equation.lhs),
            ...collectIndexSymbols(equation.rhs),
        ]);

        // Check LHS variables
        const lhsVars = extractVariableReferences(equation.lhs);
        for (const varRef of lhsVars) {
            if (varRef.includes('.')) {
                // Scoped reference
                if (!resolveScopedReference(varRef, esmFile)) {
                    errors.push({
                        path: `${equationPath}/lhs`,
                        code: 'unresolved_scoped_ref',
                        message: `Scoped reference "${varRef}" cannot be resolved`,
                        details: { reference: varRef }
                    });
                }
            } else {
                // Local reference
                if (!declaredVariables.has(varRef) && !declaredIndexSets.has(varRef) && !boundSymbols.has(varRef)) {
                    errors.push({
                        path: `${equationPath}/lhs`,
                        code: 'undefined_variable',
                        message: `Variable "${varRef}" referenced in equation is not declared`,
                        details: { variable: varRef }
                    });
                }
            }
        }

        // Check RHS variables
        const rhsVars = extractVariableReferences(equation.rhs);
        for (const varRef of rhsVars) {
            if (varRef.includes('.')) {
                // Scoped reference
                if (!resolveScopedReference(varRef, esmFile)) {
                    errors.push({
                        path: `${equationPath}/rhs`,
                        code: 'unresolved_scoped_ref',
                        message: `Scoped reference "${varRef}" cannot be resolved`,
                        details: { reference: varRef }
                    });
                }
            } else {
                // Local reference
                if (!declaredVariables.has(varRef) && !declaredIndexSets.has(varRef) && !boundSymbols.has(varRef)) {
                    errors.push({
                        path: `${equationPath}/rhs`,
                        code: 'undefined_variable',
                        message: `Variable "${varRef}" referenced in equation is not declared`,
                        details: { variable: varRef }
                    });
                }
            }
        }
    }

    // Check observed variables have expressions
    for (const [varName, variable] of Object.entries(model.variables || {})) {
        if (variable.type === 'observed' && !variable.expression) {
            errors.push({
                path: `${modelPath}/variables/${varName}`,
                code: 'missing_observed_expr',
                message: `Observed variable "${varName}" is missing its expression field`,
                details: { variable: varName }
            });
        }
    }

    return errors;
}

/**
 * Check discrete parameters in events
 */
function validateEventConsistency(model: Model, modelPath: string): StructuralError[] {
    const errors: StructuralError[] = [];
    const declaredVariables = new Set(Object.keys(model.variables || {}));
    const declaredParameters = new Set(Object.entries(model.variables || {})
        .filter(([_, variable]) => variable.type === 'parameter')
        .map(([name, _]) => name));

    // Check discrete events
    for (let i = 0; i < (model.discrete_events || []).length; i++) {
        const event = model.discrete_events![i];
        const eventPath = `${modelPath}/discrete_events/${i}`;

        // Check discrete_parameters entries
        if (event.discrete_parameters) {
            for (const paramName of event.discrete_parameters) {
                if (!declaredParameters.has(paramName)) {
                    errors.push({
                        path: `${eventPath}/discrete_parameters`,
                        code: 'invalid_discrete_param',
                        message: `discrete_parameters entry "${paramName}" does not match a declared parameter`,
                        details: { parameter: paramName }
                    });
                }
            }
        }

        // Check affects variables
        if (event.affects) {
            for (let j = 0; j < event.affects.length; j++) {
                const affect = event.affects[j];
                if (!declaredVariables.has(affect.lhs)) {
                    errors.push({
                        path: `${eventPath}/affects/${j}/lhs`,
                        code: 'event_var_undeclared',
                        message: `Variable "${affect.lhs}" in event affects is not declared`,
                        details: { variable: affect.lhs }
                    });
                }
            }
        }

        // Check functional affect variables
        if (event.functional_affect) {
            for (const varName of event.functional_affect.read_vars || []) {
                if (!declaredVariables.has(varName)) {
                    errors.push({
                        path: `${eventPath}/functional_affect/read_vars`,
                        code: 'event_var_undeclared',
                        message: `Variable "${varName}" in functional_affect read_vars is not declared`,
                        details: { variable: varName }
                    });
                }
            }

            for (const paramName of event.functional_affect.read_params || []) {
                if (!declaredParameters.has(paramName)) {
                    errors.push({
                        path: `${eventPath}/functional_affect/read_params`,
                        code: 'event_var_undeclared',
                        message: `Parameter "${paramName}" in functional_affect read_params is not declared`,
                        details: { variable: paramName }
                    });
                }
            }
        }
    }

    // Check continuous events
    for (let i = 0; i < (model.continuous_events || []).length; i++) {
        const event = model.continuous_events![i];
        const eventPath = `${modelPath}/continuous_events/${i}`;

        // Check affects variables
        if (event.affects) {
            for (let j = 0; j < event.affects.length; j++) {
                const affect = event.affects[j];
                if (!declaredVariables.has(affect.lhs)) {
                    errors.push({
                        path: `${eventPath}/affects/${j}/lhs`,
                        code: 'event_var_undeclared',
                        message: `Variable "${affect.lhs}" in continuous event affects is not declared`,
                        details: { variable: affect.lhs }
                    });
                }
            }
        }

        // Check affect_neg variables
        if (event.affect_neg) {
            for (let j = 0; j < event.affect_neg.length; j++) {
                const affect = event.affect_neg[j];
                if (!declaredVariables.has(affect.lhs)) {
                    errors.push({
                        path: `${eventPath}/affect_neg/${j}/lhs`,
                        code: 'event_var_undeclared',
                        message: `Variable "${affect.lhs}" in continuous event affect_neg is not declared`,
                        details: { variable: affect.lhs }
                    });
                }
            }
        }
    }

    return errors;
}

/**
 * Check reaction consistency for a reaction system
 */
function validateReactionConsistency(reactionSystem: ReactionSystem, systemPath: string): StructuralError[] {
    const errors: StructuralError[] = [];
    const declaredSpecies = new Set(Object.keys(reactionSystem.species || {}));
    const declaredParameters = new Set(Object.keys(reactionSystem.parameters || {}));

    for (let i = 0; i < (reactionSystem.reactions || []).length; i++) {
        const reaction = reactionSystem.reactions![i];
        const reactionPath = `${systemPath}/reactions/${i}`;

        // Check for null-null reactions
        if (reaction.substrates === null && reaction.products === null) {
            errors.push({
                path: reactionPath,
                code: 'null_reaction',
                message: `Reaction "${reaction.id}" has both substrates: null and products: null`,
                details: { reaction_id: reaction.id }
            });
        }

        // Check substrates
        if (reaction.substrates && Array.isArray(reaction.substrates)) {
            for (let j = 0; j < reaction.substrates.length; j++) {
                const substrate = reaction.substrates[j];
                if (substrate && !declaredSpecies.has(substrate.species)) {
                    errors.push({
                        path: `${reactionPath}/substrates/${j}/species`,
                        code: 'undefined_species',
                        message: `Species "${substrate.species}" in reaction substrates is not declared`,
                        details: { species: substrate.species, reaction_id: reaction.id }
                    });
                }

                // Check stoichiometry is positive integer
                if (substrate && (!Number.isInteger(substrate.stoichiometry) || substrate.stoichiometry <= 0)) {
                    errors.push({
                        path: `${reactionPath}/substrates/${j}/stoichiometry`,
                        code: 'invalid_stoichiometry',
                        message: `Stoichiometry must be a positive integer, got ${substrate.stoichiometry}`,
                        details: { stoichiometry: substrate.stoichiometry, reaction_id: reaction.id }
                    });
                }
            }
        }

        // Check products
        if (reaction.products && Array.isArray(reaction.products)) {
            for (let j = 0; j < reaction.products.length; j++) {
                const product = reaction.products[j];
                if (product && !declaredSpecies.has(product.species)) {
                    errors.push({
                        path: `${reactionPath}/products/${j}/species`,
                        code: 'undefined_species',
                        message: `Species "${product.species}" in reaction products is not declared`,
                        details: { species: product.species, reaction_id: reaction.id }
                    });
                }

                // Check stoichiometry is positive integer
                if (product && (!Number.isInteger(product.stoichiometry) || product.stoichiometry <= 0)) {
                    errors.push({
                        path: `${reactionPath}/products/${j}/stoichiometry`,
                        code: 'invalid_stoichiometry',
                        message: `Stoichiometry must be a positive integer, got ${product.stoichiometry}`,
                        details: { stoichiometry: product.stoichiometry, reaction_id: reaction.id }
                    });
                }
            }
        }

        // Check rate expression references
        const rateVars = extractVariableReferences(reaction.rate);
        for (const varRef of rateVars) {
            if (!declaredSpecies.has(varRef) && !declaredParameters.has(varRef)) {
                errors.push({
                    path: `${reactionPath}/rate`,
                    code: 'undefined_parameter',
                    message: `Variable "${varRef}" in rate expression is not declared as species or parameter`,
                    details: { variable: varRef, reaction_id: reaction.id }
                });
            }
        }
    }

    return errors;
}

/**
 * Build a unit-binding map for a single reaction system covering its species
 * and parameters. Mirrors the binding environment used by validateUnits but
 * scoped to one system so dimensional checks see the author-declared units
 * for each symbol.
 */
function buildReactionSystemUnitBindings(
    reactionSystem: ReactionSystem,
): Map<string, ParsedUnit> {
    const bindings = new Map<string, ParsedUnit>();
    if ('species' in reactionSystem && reactionSystem.species) {
        for (const [name, species] of Object.entries(reactionSystem.species)) {
            if (species && species.units) {
                bindings.set(name, parseUnit(species.units));
            }
        }
    }
    if ('parameters' in reactionSystem && reactionSystem.parameters) {
        for (const [name, param] of Object.entries(reactionSystem.parameters)) {
            if (param && param.units) {
                bindings.set(name, parseUnit(param.units));
            }
        }
    }
    return bindings;
}

/**
 * Split a unit string like "mol/L" into ("mol", "L") or "mol/(L*s)" into
 * ("mol", "L*s"). The split is on the first top-level '/'. If no '/' appears,
 * the whole string is the numerator. Matches Go's splitUnitNumDen so the
 * expected_rate_units payloads line up byte-for-byte across bindings.
 */
function splitUnitNumDen(s: string): [string, string] {
    const trimmed = s.trim();
    if (trimmed === '') return ['', ''];
    let depth = 0;
    for (let i = 0; i < trimmed.length; i++) {
        const c = trimmed[i];
        if (c === '(') depth++;
        else if (c === ')') depth--;
        else if (c === '/' && depth === 0) {
            const num = trimmed.slice(0, i).trim();
            let den = trimmed.slice(i + 1).trim();
            if (den.startsWith('(') && den.endsWith(')')) {
                den = den.slice(1, -1);
            }
            return [num, den];
        }
    }
    return [trimmed, ''];
}

/**
 * Render a unit factor raised to an integer power. Parenthesizes compound
 * factors when the exponent is not 1. Mirrors Go's powerFactor.
 */
function powerFactor(s: string, n: number): string {
    const t = s.trim();
    if (t === '') return '';
    if (n === 1) return t;
    if (/[*/]/.test(t)) return `(${t})^${n}`;
    return `${t}^${n}`;
}

/**
 * Compose the canonical expected rate-unit string from the reference species
 * unit string and total reaction order: rate_units = species_units^(1-order) / s.
 * Matches the contract in tests/invalid/expected_errors.json and the Go
 * formatExpectedRateUnits helper so cross-binding details stay identical.
 *
 *   ("mol/L", 2) → "L/(mol*s)"
 *   ("mol/L", 1) → "1/s"
 *   ("mol/L", 0) → "mol/(L*s)"
 *   ("mol/m^3", 2) → "m^3/(mol*s)"
 */
function formatExpectedRateUnits(speciesUnits: string, totalOrder: number): string {
    let exp = 1 - totalOrder;
    if (exp === 0) return '1/s';
    let [num, den] = splitUnitNumDen(speciesUnits);
    if (exp < 0) {
        [num, den] = [den, num];
        exp = -exp;
    }
    let numStr = powerFactor(num, exp);
    const denFactors: string[] = [];
    const df = powerFactor(den, exp);
    if (df !== '') denFactors.push(df);
    denFactors.push('s');
    if (numStr === '') numStr = '1';
    if (denFactors.length === 1) return `${numStr}/${denFactors[0]}`;
    return `${numStr}/(${denFactors.join('*')})`;
}

/**
 * If the rate expression is a bare variable reference (species or parameter
 * name), return its declared unit string. Otherwise returns the empty string.
 * Matches Go's rateVarName + unit lookup so rate_units details align across
 * bindings for the bare-variable case that the cross-binding fixture uses.
 */
function rateUnitStringFromExpression(
    rate: Expression,
    reactionSystem: ReactionSystem,
): string {
    if (typeof rate !== 'string') return '';
    const param = (reactionSystem.parameters || {})[rate];
    if (param && param.units) return param.units;
    const species = (reactionSystem.species || {})[rate];
    if (species && species.units) return species.units;
    return '';
}

/**
 * Enforce the mass-action dimensional constraint for reaction rates from
 * spec §7.4: rate dimensions must equal concentration^(1-total_order)/time,
 * where the reference concentration unit is the first substrate's declared
 * units. Mirrors validate_reaction_system_dimensions in Julia and
 * validateReactionRateUnits in Go.
 *
 * Skipped when the first substrate is dimensionless (mol/mol, ppm, …)
 * because atmospheric-chemistry rate expressions commonly bake a
 * number-density factor into the rate constant, making the
 * stoichiometric-order convention ambiguous there.
 */
function validateReactionRateUnits(
    reactionSystem: ReactionSystem,
    systemPath: string,
): StructuralError[] {
    const errors: StructuralError[] = [];
    if (!reactionSystem.reactions) return errors;

    const bindings = buildReactionSystemUnitBindings(reactionSystem);
    const speciesMap = reactionSystem.species || {};

    for (let i = 0; i < reactionSystem.reactions.length; i++) {
        const reaction = reactionSystem.reactions[i];
        if (!reaction || !reaction.substrates || reaction.substrates.length === 0) continue;

        const firstSubstrate = reaction.substrates[0];
        const firstSpecies = speciesMap[firstSubstrate.species];
        if (!firstSpecies || !firstSpecies.units) continue;

        const concUnit = parseUnit(firstSpecies.units);
        if (isDimensionless(concUnit)) continue;

        let resolvable = true;
        let totalOrder = 0;
        for (const sub of reaction.substrates) {
            if (!sub || !bindings.has(sub.species)) {
                resolvable = false;
                break;
            }
            if (typeof sub.stoichiometry === 'number') {
                totalOrder += sub.stoichiometry;
            }
        }
        if (!resolvable) continue;

        const rateResult = checkDimensions(reaction.rate, bindings);
        if (rateResult.warnings.some(w => w.includes('Unknown variable'))) continue;

        const expectedPower = 1 - totalOrder;
        const expectedDims: CanonicalDims = {};
        for (const [k, v] of Object.entries(concUnit.dims)) {
            if (v == null) continue;
            expectedDims[k as keyof CanonicalDims] = v * expectedPower;
        }
        const sKey = 's' as keyof CanonicalDims;
        expectedDims[sKey] = (expectedDims[sKey] ?? 0) - 1;

        if (dimsEqual(rateResult.dimensions.dims, expectedDims)) continue;

        errors.push({
            path: `${systemPath}/reactions/${i}`,
            code: 'unit_inconsistency',
            message: 'Reaction rate expression has incompatible units for reaction stoichiometry',
            details: {
                reaction_id: reaction.id,
                rate_units: rateUnitStringFromExpression(reaction.rate, reactionSystem),
                expected_rate_units: formatExpectedRateUnits(firstSpecies.units, totalOrder),
                reaction_order: totalOrder,
            },
        });
    }

    return errors;
}

/**
 * Well-known physical constants whose declared units can be dimensionally
 * verified against a canonical form. Conservative on purpose — names chosen
 * to minimize collision with common non-constant uses (e.g., no `c` for
 * speed of light, which conflicts with concentration). Mirrors Python's
 * `_KNOWN_PHYSICAL_CONSTANTS` (gt-j91l / gt-3tgv).
 */
const KNOWN_PHYSICAL_CONSTANTS: Array<{
    name: string;
    canonical: string;
    description: string;
}> = [
    { name: 'R', canonical: 'J/(mol*K)', description: 'ideal gas constant' },
    { name: 'k_B', canonical: 'J/K', description: 'Boltzmann constant' },
    { name: 'N_A', canonical: '1/mol', description: 'Avogadro constant' },
];

/**
 * Return true if the expression tree references a variable by exact name
 * (string leaf match).
 */
function expressionReferencesName(expr: Expression | undefined, name: string): boolean {
    if (expr === undefined || expr === null) return false;
    if (typeof expr === 'string') return expr === name;
    if (typeof expr === 'number') return false;
    if (typeof expr === 'object' && 'op' in expr) {
        const node = expr as ExpressionNode;
        if (node.args) {
            for (const arg of node.args) {
                if (expressionReferencesName(arg, name)) return true;
            }
        }
    }
    return false;
}

/**
 * Flag parameters whose name matches a well-known physical constant but whose
 * declared units are dimensionally incompatible with the canonical form (e.g.,
 * `R` declared as `kcal/mol` — missing temperature — instead of `J/(mol*K)`).
 * Reports at the first observed-variable usage site in the same model;
 * otherwise at the declaration. Mirrors Python's
 * `parse._check_physical_constant_units`.
 */
function validatePhysicalConstantUnits(model: Model, modelPath: string): StructuralError[] {
    const errors: StructuralError[] = [];
    const variables = model.variables || {};

    for (const { name, canonical, description } of KNOWN_PHYSICAL_CONSTANTS) {
        const declaration = variables[name];
        if (!declaration) continue;
        if (declaration.type !== 'parameter') continue;
        const declared = declaration.units;
        if (!declared) continue;

        const declaredUnit = parseUnit(declared);
        const canonicalUnit = parseUnit(canonical);
        if (dimsEqual(declaredUnit.dims, canonicalUnit.dims)) continue;

        let usageName: string | undefined;
        for (const [otherName, otherVar] of Object.entries(variables)) {
            if (otherVar.type !== 'observed') continue;
            if (expressionReferencesName(otherVar.expression, name)) {
                usageName = otherName;
                break;
            }
        }
        const targetName = usageName ?? name;
        errors.push({
            path: `${modelPath}/variables/${targetName}`,
            code: 'unit_inconsistency',
            message: 'Physical constant used with incorrect dimensional analysis',
            details: {
                constant_name: name,
                constant_description: description,
                declared_units: declared,
                canonical_units: canonical,
            },
        });
    }
    return errors;
}

const AFFINE_TEMP_UNITS = new Set(['C', 'degC', 'Celsius']);

function isAffineTempUnit(u: string): boolean {
    return AFFINE_TEMP_UNITS.has(u.trim());
}

/**
 * Flag observed variables whose expression has the shape `<numeric> * <var>`
 * (or `<var> * <numeric>`) when the declared output units and the source
 * variable's units are dimensionally compatible but the numeric literal
 * disagrees with the correct linear scale factor. Mirrors Python's
 * parse._check_conversion_factor_consistency (gt-nvdv) and Go's
 * checkConversionFactorConsistency (gt-abh1). Affine conversions
 * (e.g., degC→K) are excluded.
 */
function validateConversionFactorConsistency(model: Model, modelPath: string): StructuralError[] {
    const errors: StructuralError[] = [];
    const variables = model.variables || {};

    for (const [vname, vdef] of Object.entries(variables)) {
        if (vdef.type !== 'observed') continue;
        if (vdef.expression === undefined || vdef.expression === null) continue;
        const lhsUnits = vdef.units;
        if (!lhsUnits) continue;

        const expr = vdef.expression;
        if (typeof expr !== 'object' || !('op' in expr)) continue;
        const node = expr as ExpressionNode;
        if (node.op !== '*' || !node.args || node.args.length !== 2) continue;

        let numeric: number | undefined;
        let varRef: string | undefined;
        for (const a of node.args) {
            if (typeof a === 'number') {
                numeric = a;
            } else if (typeof a === 'string') {
                varRef = a;
            }
        }
        if (numeric === undefined || varRef === undefined) continue;

        const src = variables[varRef];
        if (!src || !src.units) continue;
        const srcUnits = src.units;
        if (srcUnits === lhsUnits) continue;

        let srcU: ParsedUnit;
        let lhsU: ParsedUnit;
        try {
            srcU = parseUnit(srcUnits);
            lhsU = parseUnit(lhsUnits);
        } catch {
            continue;
        }
        if (!dimsEqual(srcU.dims, lhsU.dims)) continue;
        if (isAffineTempUnit(srcUnits) || isAffineTempUnit(lhsUnits)) continue;
        if (lhsU.scale === 0) continue;

        const factor = srcU.scale / lhsU.scale;
        if (factor === 0) continue;

        const tol = 1e-9 * Math.max(Math.abs(factor), 1);
        if (Math.abs(numeric - factor) <= tol) continue;

        errors.push({
            path: `${modelPath}/variables/${vname}`,
            code: 'unit_inconsistency',
            message: 'Unit conversion factor is incorrect for specified unit transformation',
            details: {
                variable: vname,
                declared_units: lhsUnits,
                source_units: srcUnits,
                declared_factor: numeric,
                expected_factor: factor,
            },
        });
    }
    return errors;
}

/**
 * Flag subsystem entries that are unresolved SubsystemRef objects.
 * The synchronous validate() function cannot resolve external file references;
 * call resolveSubsystemRefs() before validate() to inline them first.
 */
function validateSubsystemRefs(esmFile: EsmFile): StructuralError[] {
    const errors: StructuralError[] = [];
    if (esmFile.models) {
        for (const [modelName, model] of Object.entries(esmFile.models)) {
            if (!model.subsystems) continue;
            for (const [subsystemName, subsystem] of Object.entries(model.subsystems)) {
                if ('ref' in subsystem && typeof (subsystem as SubsystemRef).ref === 'string') {
                    errors.push({
                        path: `/models/${modelName}/subsystems/${subsystemName}`,
                        code: 'unresolved_subsystem_ref',
                        message: `Subsystem '${subsystemName}' is an unresolved file reference ('${(subsystem as SubsystemRef).ref}'). Call resolveSubsystemRefs() before validate().`,
                        details: { ref: (subsystem as SubsystemRef).ref },
                    });
                }
            }
        }
    }
    if (esmFile.reaction_systems) {
        for (const [systemName, system] of Object.entries(esmFile.reaction_systems)) {
            if (!system.subsystems) continue;
            for (const [subsystemName, subsystem] of Object.entries(system.subsystems)) {
                if ('ref' in subsystem && typeof (subsystem as SubsystemRef).ref === 'string') {
                    errors.push({
                        path: `/reaction_systems/${systemName}/subsystems/${subsystemName}`,
                        code: 'unresolved_subsystem_ref',
                        message: `Subsystem '${subsystemName}' is an unresolved file reference ('${(subsystem as SubsystemRef).ref}'). Call resolveSubsystemRefs() before validate().`,
                        details: { ref: (subsystem as SubsystemRef).ref },
                    });
                }
            }
        }
    }
    return errors;
}

/**
 * Flag model variables where default_units is set and the conversion from
 * default_units to units is affine (e.g., degC → K) rather than a pure
 * scale factor. Affine unit conversions are not expressible as a simple
 * default value and must use an explicit expression instead.
 */
function validateDefaultUnits(model: Model, modelPath: string): StructuralError[] {
    const errors: StructuralError[] = [];
    if (!model.variables) return errors;
    for (const [vname, vdef] of Object.entries(model.variables)) {
        const { units, default_units } = vdef;
        if (!default_units || !units || default_units === units) continue;
        if (isAffineTempUnit(default_units) || isAffineTempUnit(units)) {
            errors.push({
                path: `${modelPath}/variables/${vname}`,
                code: 'unit_inconsistency',
                message: `default_units '${default_units}' requires an affine conversion to/from '${units}'; use an expression instead of a scalar default`,
                details: { variable: vname, units, default_units },
            });
        }
    }
    return errors;
}

/**
 * Check coupling entries reference integrity
 */
function validateCouplingIntegrity(esmFile: EsmFile): StructuralError[] {
    const errors: StructuralError[] = [];

    if (!esmFile.coupling) return errors;

    // Collect all available systems
    const availableSystems = new Set([
        ...Object.keys(esmFile.models || {}),
        ...Object.keys(esmFile.reaction_systems || {}),
        ...Object.keys(esmFile.data_loaders || {}),
        ...Object.keys(esmFile.operators || {})
    ]);

    for (let i = 0; i < esmFile.coupling.length; i++) {
        const coupling = esmFile.coupling[i];
        const couplingPath = `/coupling/${i}`;

        if (coupling.type === 'operator_compose') {
            // Check systems exist
            const composeEntry = coupling as CouplingOperatorCompose;
            for (const systemName of composeEntry.systems) {
                if (!availableSystems.has(systemName)) {
                    errors.push({
                        path: `${couplingPath}/systems`,
                        code: 'undefined_system',
                        message: `Coupling entry references nonexistent system "${systemName}"`,
                        details: { system: systemName }
                    });
                }
            }
        } else if (coupling.type === 'couple') {
            // Check systems exist
            const coupleEntry = coupling as CouplingCouple;
            for (const systemName of coupleEntry.systems) {
                if (!availableSystems.has(systemName)) {
                    errors.push({
                        path: `${couplingPath}/systems`,
                        code: 'undefined_system',
                        message: `Coupling entry references nonexistent system "${systemName}"`,
                        details: { system: systemName }
                    });
                }
            }
        } else if (coupling.type === 'variable_map') {
            // Check from/to system references exist
            const vmEntry = coupling as any;
            for (const field of ['from', 'to'] as const) {
                const ref = vmEntry[field];
                if (typeof ref === 'string' && ref.includes('.')) {
                    const systemName = ref.split('.')[0];
                    if (!availableSystems.has(systemName)) {
                        errors.push({
                            path: `${couplingPath}/${field}`,
                            code: 'unresolved_scoped_ref',
                            message: `Scoped reference "${ref}" references nonexistent system "${systemName}"`,
                            details: { reference: ref, system: systemName }
                        });
                    } else {
                        // Check variable exists in the system
                        const varName = ref.split('.').slice(1).join('.');
                        const system = (esmFile.models || {})[systemName]
                            || (esmFile.reaction_systems || {})[systemName];
                        if (system) {
                            const vars = (system as any).variables || (system as any).species || {};
                            const params = (system as any).parameters || {};
                            if (!vars[varName] && !params[varName]) {
                                // Check data loaders
                                const dataLoader = (esmFile.data_loaders || {})[systemName];
                                const loaderVariables = dataLoader?.variables || {};
                                if (!loaderVariables[varName]) {
                                    errors.push({
                                        path: `${couplingPath}/${field}`,
                                        code: 'unresolved_scoped_ref',
                                        message: `Variable "${varName}" not found in system "${systemName}"`,
                                        details: { reference: ref, system: systemName, variable: varName }
                                    });
                                }
                            }
                        }
                    }
                }
            }
        } else if (coupling.type === 'operator_apply') {
            // Check operator exists
            const applyEntry = coupling as CouplingOperatorApply;
            if (applyEntry.operator && !availableSystems.has(applyEntry.operator)) {
                errors.push({
                    path: `${couplingPath}/operator`,
                    code: 'undefined_operator',
                    message: `operator_apply references nonexistent operator "${applyEntry.operator}"`,
                    details: { operator: applyEntry.operator }
                });
            }
        }
    }

    return errors;
}

/**
 * Main structural validation function
 */
/**
 * Check for circular cross-model variable references (without explicit coupling)
 */
function validateCircularReferences(esmFile: EsmFile): StructuralError[] {
    const errors: StructuralError[] = [];
    if (!esmFile.models) return errors;

    // Build dependency graph: which models reference which other models
    const modelDeps = new Map<string, Set<string>>();

    for (const [modelName, model] of Object.entries(esmFile.models)) {
        const deps = new Set<string>();
        // Check all equations for cross-model references
        for (const equation of model.equations || []) {
            const refs = [
                ...extractVariableReferences(equation.lhs),
                ...extractVariableReferences(equation.rhs)
            ];
            for (const ref of refs) {
                if (ref.includes('.')) {
                    const targetModel = ref.split('.')[0];
                    if (targetModel !== modelName && esmFile.models[targetModel]) {
                        deps.add(targetModel);
                    }
                }
            }
        }
        modelDeps.set(modelName, deps);
    }

    // Detect cycles using DFS
    const visited = new Set<string>();
    const inStack = new Set<string>();

    function dfs(node: string, path: string[]): boolean {
        if (inStack.has(node)) {
            const cycleStart = path.indexOf(node);
            const cycle = path.slice(cycleStart).concat(node);
            errors.push({
                path: '/models',
                message: `Circular dependency detected: ${cycle.join(' → ')}`,
                code: 'circular_dependency',
                details: { cycle }
            });
            return true;
        }
        if (visited.has(node)) return false;

        visited.add(node);
        inStack.add(node);
        path.push(node);

        for (const dep of modelDeps.get(node) || []) {
            dfs(dep, [...path]);
        }

        inStack.delete(node);
        return false;
    }

    for (const modelName of modelDeps.keys()) {
        if (!visited.has(modelName)) {
            dfs(modelName, []);
        }
    }

    return errors;
}

/**
 * Validate data loader variable references in coupling entries
 */
function validateDataLoaderReferences(esmFile: EsmFile): StructuralError[] {
    const errors: StructuralError[] = [];
    if (!esmFile.coupling || !esmFile.data_loaders) return errors;

    for (let i = 0; i < esmFile.coupling.length; i++) {
        const coupling = esmFile.coupling[i];
        const couplingPath = `/coupling/${i}`;

        if (coupling.type === 'variable_map' && 'from' in coupling) {
            const from = (coupling as any).from as string;
            if (from && from.includes('.')) {
                const [sourceName, varName] = from.split('.', 2);
                // Check if source is a data loader
                if (esmFile.data_loaders[sourceName]) {
                    const loader = esmFile.data_loaders[sourceName];
                    const loaderVariables = (loader as any).variables || {};
                    if (!(varName in loaderVariables)) {
                        errors.push({
                            path: `${couplingPath}/from`,
                            message: `Data loader '${sourceName}' does not expose variable '${varName}'`,
                            code: 'undefined_data_loader_variable',
                            details: { data_loader: sourceName, variable: varName, available: Object.keys(loaderVariables) }
                        });
                    }
                }
            }
        }
    }

    return errors;
}

/**
 * Validate file_period and frequency fields in data loader temporal sections
 * are valid ISO 8601 durations
 */
function validateTemporalResolution(esmFile: EsmFile): StructuralError[] {
    const errors: StructuralError[] = [];
    if (!esmFile.data_loaders) return errors;

    // ISO 8601 duration pattern: P[nY][nM][nD][T[nH][nM][nS]]
    const iso8601DurationPattern = /^P(?:\d+Y)?(?:\d+M)?(?:\d+D)?(?:T(?:\d+H)?(?:\d+M)?(?:\d+(?:\.\d+)?S)?)?$/;
    const isValidDuration = (v: unknown): v is string =>
        typeof v === 'string' && v !== 'P' && v !== 'PT' && iso8601DurationPattern.test(v);

    const durationFields: Array<'file_period' | 'frequency'> = ['file_period', 'frequency'];

    for (const [loaderName, loader] of Object.entries(esmFile.data_loaders)) {
        const temporal = (loader as any).temporal;
        if (!temporal || typeof temporal !== 'object') continue;
        for (const field of durationFields) {
            const value = temporal[field];
            if (value !== undefined && !isValidDuration(value)) {
                errors.push({
                    path: `/data_loaders/${loaderName}/temporal/${field}`,
                    message: `Invalid ISO 8601 duration: '${value}'`,
                    code: 'invalid_temporal_duration',
                    details: { field, value }
                });
            }
        }
    }

    return errors;
}

/**
 * Promote unit validation errors to structural errors for invalid files.
 * Units warnings become errors when they indicate incompatible assignments or additions.
 */
function promoteUnitWarningsToErrors(warnings: UnitWarning[]): StructuralError[] {
    const errors: StructuralError[] = [];
    for (const warning of warnings) {
        const msg = warning.message?.toLowerCase() || '';
        // Promote dimensional mismatches and incompatible operations
        if (
            msg.includes('mismatch') ||
            msg.includes('incompatible') ||
            msg.includes('inconsistent') ||
            msg.includes('requires same dimensions') ||
            msg.includes('same dimensions')
        ) {
            errors.push({
                path: warning.location ? `/${warning.location.replace(/\./g, '/')}` : '$',
                message: warning.message,
                code: 'unit_error',
                details: { equation: warning.equation || '' }
            });
        }
    }
    return errors;
}

function performStructuralValidation(esmFile: EsmFile): StructuralError[] {
    const errors: StructuralError[] = [];

    // Collect systems that participate in coupling — these may reference
    // variables from other systems, so equation balance and reference
    // integrity checks must be relaxed.
    const coupledSystems = new Set<string>();
    if (esmFile.coupling) {
        for (const entry of esmFile.coupling) {
            if ('systems' in entry && Array.isArray((entry as any).systems)) {
                for (const s of (entry as any).systems) {
                    coupledSystems.add(s);
                }
            }
            if ('from' in entry && typeof (entry as any).from === 'string') {
                const fromSystem = (entry as any).from.split('.')[0];
                coupledSystems.add(fromSystem);
            }
            if ('to' in entry && typeof (entry as any).to === 'string') {
                const toSystem = (entry as any).to.split('.')[0];
                coupledSystems.add(toSystem);
            }
        }
    }

    // Validate models
    if (esmFile.models) {
        for (const [modelName, model] of Object.entries(esmFile.models)) {
            const modelPath = `/models/${modelName}`;
            const isCoupled = coupledSystems.has(modelName);

            // Skip equation balance and reference integrity for coupled models,
            // as they may reference variables provided by other systems.
            if (!isCoupled) {
                errors.push(...validateEquationBalance(model, modelPath));
                errors.push(...validateReferenceIntegrity(model, modelPath, esmFile));
            }
            errors.push(...validateEventConsistency(model, modelPath));
            errors.push(...validatePhysicalConstantUnits(model, modelPath));
            errors.push(...validateConversionFactorConsistency(model, modelPath));
            errors.push(...validateDefaultUnits(model, modelPath));

            // Recursively validate subsystems
            if (model.subsystems) {
                for (const [subsystemName, subsystem] of Object.entries(model.subsystems)) {
                    const subsystemPath = `${modelPath}/subsystems/${subsystemName}`;
                    if (!isCoupled) {
                        errors.push(...validateEquationBalance(subsystem, subsystemPath));
                        errors.push(...validateReferenceIntegrity(subsystem, subsystemPath, esmFile));
                    }
                    errors.push(...validateEventConsistency(subsystem, subsystemPath));
                    errors.push(...validatePhysicalConstantUnits(subsystem, subsystemPath));
                    errors.push(...validateConversionFactorConsistency(subsystem, subsystemPath));
                }
            }
        }
    }

    // Validate reaction systems
    if (esmFile.reaction_systems) {
        for (const [systemName, reactionSystem] of Object.entries(esmFile.reaction_systems)) {
            const systemPath = `/reaction_systems/${systemName}`;

            errors.push(...validateReactionConsistency(reactionSystem, systemPath));
            errors.push(...validateReactionRateUnits(reactionSystem, systemPath));

            // Recursively validate subsystems
            if (reactionSystem.subsystems) {
                for (const [subsystemName, subsystem] of Object.entries(reactionSystem.subsystems)) {
                    const subsystemPath = `${systemPath}/subsystems/${subsystemName}`;
                    errors.push(...validateReactionConsistency(subsystem, subsystemPath));
                    errors.push(...validateReactionRateUnits(subsystem, subsystemPath));
                }
            }
        }
    }

    // Validate subsystem ref resolution
    errors.push(...validateSubsystemRefs(esmFile));

    // Validate coupling integrity
    errors.push(...validateCouplingIntegrity(esmFile));

    // Check for circular cross-model references
    errors.push(...validateCircularReferences(esmFile));

    // Validate data loader variable references in coupling
    errors.push(...validateDataLoaderReferences(esmFile));

    // Validate temporal resolution in data loaders
    errors.push(...validateTemporalResolution(esmFile));

    return errors;
}

/**
 * Convert a SchemaError to our ValidationError format
 */
function convertSchemaError(error: SchemaError): ValidationError {
    return {
        path: error.path,
        message: error.message,
        code: error.keyword,
        details: {
            keyword: error.keyword
        }
    };
}

/**
 * Validate ESM data and return structured validation result.
 *
 * @param data - ESM data as JSON string or object
 * @returns ValidationResult with validation status and errors
 */
export function validate(data: string | object): ValidationResult {
    const schema_errors: ValidationError[] = [];
    const structural_errors: ValidationError[] = [];
    let unit_warnings: UnitWarning[] = [];

    try {
        let parsedData: object;

        // Parse JSON if string
        if (typeof data === 'string') {
            try {
                parsedData = JSON.parse(data);
            } catch (e: unknown) {
                const error = e as Error;
                return {
                    is_valid: false,
                    schema_errors: [{
                        path: '$',
                        message: `Invalid JSON: ${error.message}`,
                        code: 'json_parse_error',
                        details: { error: error.message }
                    }],
                    structural_errors: [],
                    unit_warnings: []
                };
            }
        } else {
            parsedData = data;
        }

        // Validate against schema
        const schemaErrors = validateSchema(parsedData);
        schema_errors.push(...schemaErrors.map(convertSchemaError));

        // Try structural validation by loading the data
        if (schema_errors.length === 0) {
            try {
                const esmFile = load(parsedData);
                // Perform structural validation
                const structuralErrors = performStructuralValidation(esmFile);
                structural_errors.push(...structuralErrors.map(err => ({
                    path: err.path,
                    message: err.message,
                    code: err.code,
                    details: err.details
                })));

                // Perform unit validation
                unit_warnings = validateUnits(esmFile);

                // Promote unit incompatibility warnings to structural errors
                structural_errors.push(...promoteUnitWarningsToErrors(unit_warnings));
            } catch (e: unknown) {
                const error = e as Error;
                structural_errors.push({
                    path: '$',
                    message: error.message || String(e),
                    code: error.constructor.name.toLowerCase().replace('error', ''),
                    details: {
                        exception_type: error.constructor.name,
                        error: error.message || String(e)
                    }
                });
            }
        }

    } catch (e: unknown) {
        // Unexpected error
        const error = e as Error;
        return {
            is_valid: false,
            schema_errors: [{
                path: '$',
                message: `Validation failed with unexpected error: ${error.message || String(e)}`,
                code: 'unexpected_error',
                details: {
                    exception_type: error.constructor.name,
                    error: error.message || String(e)
                }
            }],
            structural_errors: [],
            unit_warnings: []
        };
    }

    return {
        is_valid: schema_errors.length === 0 && structural_errors.length === 0,
        schema_errors,
        structural_errors,
        unit_warnings
    };
}