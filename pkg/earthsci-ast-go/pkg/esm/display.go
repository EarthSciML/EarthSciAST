package esm

import (
	"encoding/json"
	"fmt"
	"math"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"unicode/utf8"
)

// chemicalElements contains all 118 chemical element symbols for element-aware tokenizer
var chemicalElements = map[string]bool{
	// Period 1
	"H": true, "He": true,
	// Period 2
	"Li": true, "Be": true, "B": true, "C": true, "N": true, "O": true, "F": true, "Ne": true,
	// Period 3
	"Na": true, "Mg": true, "Al": true, "Si": true, "P": true, "S": true, "Cl": true, "Ar": true,
	// Period 4
	"K": true, "Ca": true, "Sc": true, "Ti": true, "V": true, "Cr": true, "Mn": true, "Fe": true,
	"Co": true, "Ni": true, "Cu": true, "Zn": true, "Ga": true, "Ge": true, "As": true, "Se": true,
	"Br": true, "Kr": true,
	// Period 5
	"Rb": true, "Sr": true, "Y": true, "Zr": true, "Nb": true, "Mo": true, "Tc": true, "Ru": true,
	"Rh": true, "Pd": true, "Ag": true, "Cd": true, "In": true, "Sn": true, "Sb": true, "Te": true,
	"I": true, "Xe": true,
	// Period 6
	"Cs": true, "Ba": true, "La": true, "Ce": true, "Pr": true, "Nd": true, "Pm": true, "Sm": true,
	"Eu": true, "Gd": true, "Tb": true, "Dy": true, "Ho": true, "Er": true, "Tm": true, "Yb": true,
	"Lu": true, "Hf": true, "Ta": true, "W": true, "Re": true, "Os": true, "Ir": true, "Pt": true,
	"Au": true, "Hg": true, "Tl": true, "Pb": true, "Bi": true, "Po": true, "At": true, "Rn": true,
	// Period 7
	"Fr": true, "Ra": true, "Ac": true, "Th": true, "Pa": true, "U": true, "Np": true, "Pu": true,
	"Am": true, "Cm": true, "Bk": true, "Cf": true, "Es": true, "Fm": true, "Md": true, "No": true,
	"Lr": true, "Rf": true, "Db": true, "Sg": true, "Bh": true, "Hs": true, "Mt": true, "Ds": true,
	"Rg": true, "Cn": true, "Nh": true, "Fl": true, "Mc": true, "Lv": true, "Ts": true, "Og": true,
}

// ToUnicode converts an expression to Unicode string with chemical subscripts and operator precedence
func ToUnicode(target Expression) string {
	return formatExpression(target, FmtUnicode)
}

// ToLatex converts an expression to LaTeX string with chemical subscripts and operator precedence
func ToLatex(target Expression) string {
	return formatExpression(target, FmtLatex)
}

// ToAscii converts an expression to a plain-text string using the ascii render
// format (function-call notation, no Unicode symbols in the operator layer).
func ToAscii(target Expression) string {
	return formatExpression(target, FmtAscii)
}

// formatExpression is the internal function that handles different output formats
func formatExpression(target any, format string) string {
	switch expr := target.(type) {
	case float64:
		return formatNumber(expr, format)
	case int:
		return formatNumber(float64(expr), format)
	case int64:
		return formatNumber(float64(expr), format)
	case json.Number:
		// Structural-op sub-fields (expr/lower/upper/bounds/…) are not run
		// through the args normalizer, so numeric literals remain json.Number.
		if f, err := expr.Float64(); err == nil {
			return formatNumber(f, format)
		}
		return string(expr)
	case bool:
		if expr {
			return "true"
		}
		return "false"
	case string:
		return formatVariable(expr, format)
	case ExprNode:
		return formatExprNode(expr, format)
	case *ExprNode:
		return formatExprNode(*expr, format)
	case map[string]any:
		// A raw op-node object (an un-normalized nested expression). Re-decode
		// it into an ExprNode so all structural fields are populated, then render.
		if b, err := json.Marshal(expr); err == nil {
			if e, err := UnmarshalExpression(b); err == nil {
				if _, isMap := e.(map[string]any); !isMap {
					return formatExpression(e, format)
				}
			}
		}
		return fmt.Sprintf("%v", target)
	case []any:
		// A bare array literal (e.g. a const array reaching the recursion).
		parts := make([]string, len(expr))
		for i, v := range expr {
			parts[i] = formatExpression(v, format)
		}
		return "[" + strings.Join(parts, ", ") + "]"
	default:
		return fmt.Sprintf("%v", target)
	}
}

// formatNumber formats numeric values with scientific notation when appropriate
func formatNumber(num float64, format string) string {
	if num == 0 {
		return "0"
	}

	// Handle scientific notation for very large or very small numbers
	abs := math.Abs(num)
	if abs >= 1e4 || abs < 0.01 {
		// Calculate exponent manually for better control
		exp := int(math.Floor(math.Log10(abs)))
		mantissa := num / math.Pow(10, float64(exp))

		switch format {
		case FmtUnicode:
			expStr := formatSuperscript(exp)
			mantissaStr := fmt.Sprintf("%.3g", mantissa)
			// Replace regular minus with unicode minus for negative mantissa
			if strings.HasPrefix(mantissaStr, "-") {
				mantissaStr = "−" + mantissaStr[1:]
			}
			return fmt.Sprintf("%s×10%s", mantissaStr, expStr)
		case FmtLatex:
			return fmt.Sprintf("%.3g \\times 10^{%d}", mantissa, exp)
		default:
			return fmt.Sprintf("%.2g", num)
		}
	}

	result := fmt.Sprintf("%g", num)
	// Replace regular minus with unicode minus in unicode format
	if format == FmtUnicode && strings.HasPrefix(result, "-") {
		result = "−" + result[1:]
	}
	return result
}

// greekUnicode maps Greek letter names to their Unicode symbols.
var greekUnicode = map[string]string{
	"alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε",
	"zeta": "ζ", "eta": "η", "theta": "θ", "iota": "ι", "kappa": "κ",
	"lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ", "omicron": "ο",
	"pi": "π", "rho": "ρ", "sigma": "σ", "tau": "τ", "upsilon": "υ",
	"phi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
}

// greekLatex maps Greek letter names to their LaTeX commands.
var greekLatex = map[string]string{
	"alpha": "\\alpha", "beta": "\\beta", "gamma": "\\gamma", "delta": "\\delta",
	"epsilon": "\\epsilon", "zeta": "\\zeta", "eta": "\\eta", "theta": "\\theta",
	"iota": "\\iota", "kappa": "\\kappa", "lambda": "\\lambda", "mu": "\\mu",
	"nu": "\\nu", "xi": "\\xi", "omicron": "\\omicron", "pi": "\\pi",
	"rho": "\\rho", "sigma": "\\sigma", "tau": "\\tau", "upsilon": "\\upsilon",
	"phi": "\\phi", "chi": "\\chi", "psi": "\\psi", "omega": "\\omega",
}

// latexEscape escapes LaTeX-special characters in a bare identifier / op name.
func latexEscape(name string) string {
	return strings.ReplaceAll(name, "_", "\\_")
}

// opDisplayName renders an operator / function name for display: an upright,
// latex-escaped \mathrm{…} in latex, and the bare name in every other format.
func opDisplayName(name, format string) string {
	if format == FmtLatex {
		return "\\mathrm{" + latexEscape(name) + "}"
	}
	return name
}

// formatVariable formats variable names, mirroring the cross-language rendering
// contract (tests/display/RENDERING_CONTRACT.md): chemical species get
// element-aware subscripts; Greek letter names render as symbols/commands;
// single-character identifiers stay italic (bare); multi-character non-chemical
// identifiers render upright (\mathrm{…}, underscores escaped) in LaTeX.
func formatVariable(varName string, format string) string {
	// A bare element symbol without digits (e.g. "S", "P", "B", "He") is a
	// plain variable name, NOT a chemical formula — render it verbatim in every
	// format (matches the cross-language rendering contract).
	if chemicalElements[varName] && !strings.ContainsAny(varName, "0123456789") {
		return varName
	}

	// Chemical species: element-aware subscripting.
	if isChemicalSpecies(varName) {
		formatted := formatChemicalSubscripts(varName, format)
		if format == FmtLatex {
			return "\\mathrm{" + formatted + "}"
		}
		return formatted
	}

	switch format {
	case FmtUnicode:
		if sym, ok := greekUnicode[varName]; ok {
			return sym
		}
		return varName
	case FmtLatex:
		if cmd, ok := greekLatex[varName]; ok {
			return cmd
		}
		if utf8.RuneCountInString(varName) <= 1 {
			return varName
		}
		return "\\mathrm{" + latexEscape(varName) + "}"
	default:
		return varName
	}
}

// isChemicalSpecies reports whether a variable name contains at least one
// element-symbol token (using the shared greedy tokenizer).
func isChemicalSpecies(name string) bool {
	return tokenizeChemical(name, nil, nil)
}

// isDigit reports whether c is an ASCII digit.
func isDigit(c byte) bool {
	return c >= '0' && c <= '9'
}

// tokenizeChemical walks name as a chemical formula with a greedy tokenizer that
// prefers a 2-character element symbol over a 1-character one. For each
// recognized element it calls onElement with the symbol and its trailing digit
// run; every other byte is passed to onOther (either callback may be nil). It
// returns whether any element symbol was recognized. Both chemical detection
// (isChemicalSpecies) and unicode subscript rendering (formatChemicalSubscripts)
// share this single walker.
func tokenizeChemical(name string, onElement func(symbol, digits string), onOther func(b byte)) bool {
	i := 0
	hasElement := false
	for i < len(name) {
		symLen := 0
		if i+1 < len(name) && chemicalElements[name[i:i+2]] {
			symLen = 2
		} else if chemicalElements[name[i:i+1]] {
			symLen = 1
		}

		if symLen == 0 {
			if onOther != nil {
				onOther(name[i])
			}
			i++
			continue
		}

		symbol := name[i : i+symLen]
		i += symLen
		start := i
		for i < len(name) && isDigit(name[i]) {
			i++
		}
		if onElement != nil {
			onElement(symbol, name[start:i])
		}
		hasElement = true
	}
	return hasElement
}

// formatChemicalSubscripts renders a chemical formula's digit runs as subscripts.
// It is only called for names already confirmed as chemical species. In latex,
// a digit run following any letter becomes _{…}; in the other formats, digits
// following a recognized element symbol become Unicode subscripts.
func formatChemicalSubscripts(name string, format string) string {
	if format == FmtLatex {
		// Chemical formula: convert digits to subscripts using regex.
		re := regexp.MustCompile(`([A-Za-z])([0-9]+)`)
		return re.ReplaceAllString(name, `${1}_{${2}}`)
	}

	// Element-aware subscript conversion for the unicode / ascii formats.
	result := strings.Builder{}
	tokenizeChemical(name,
		func(symbol, digits string) {
			result.WriteString(symbol)
			result.WriteString(formatSubscript(digits))
		},
		func(b byte) { result.WriteByte(b) },
	)
	return result.String()
}

// subscriptRunes maps ASCII digits to their Unicode subscript characters.
var subscriptRunes = map[rune]rune{
	'0': '₀', '1': '₁', '2': '₂', '3': '₃', '4': '₄',
	'5': '₅', '6': '₆', '7': '₇', '8': '₈', '9': '₉',
}

// superscriptRunes maps ASCII digits and signs to Unicode superscript characters.
var superscriptRunes = map[rune]rune{
	'0': '⁰', '1': '¹', '2': '²', '3': '³', '4': '⁴',
	'5': '⁵', '6': '⁶', '7': '⁷', '8': '⁸', '9': '⁹',
	'-': '⁻', '+': '⁺',
}

// formatSubscript converts numbers to Unicode subscript characters
func formatSubscript(num string) string {
	result := strings.Builder{}
	for _, char := range num {
		if sub, ok := subscriptRunes[char]; ok {
			result.WriteRune(sub)
		} else {
			result.WriteRune(char)
		}
	}
	return result.String()
}

// formatSuperscript converts numbers to Unicode superscript characters
func formatSuperscript(num int) string {
	numStr := fmt.Sprintf("%d", num)
	result := strings.Builder{}
	for _, char := range numStr {
		if sup, ok := superscriptRunes[char]; ok {
			result.WriteRune(sup)
		} else {
			result.WriteRune(char)
		}
	}
	return result.String()
}

// formatExprNode formats an expression node with proper precedence and parentheses
func formatExprNode(node ExprNode, format string) string {
	op := node.Op
	args := node.Args

	// Closed structural / array-query tier (esm-spec §4.2) whose defining data
	// lives in fields other than `args`, plus `integral`. See
	// tests/display/RENDERING_CONTRACT.md and tests/display/structural_ops.json.
	if s, ok := formatStructuralOp(node, format); ok {
		return s
	}

	switch op {
	case "+":
		if len(args) < 2 {
			return op + "(...)"
		}

		parts := make([]string, len(args))
		for i, arg := range args {
			parts[i] = formatExpression(arg, format)
		}

		return strings.Join(parts, " + ")

	case "-":
		if len(args) == 1 {
			// Unary minus
			arg := formatExpression(args[0], format)
			switch format {
			case FmtUnicode:
				return "−" + arg
			case FmtLatex:
				return "-" + arg
			default:
				return "-" + arg
			}
		}
		// Binary subtraction - format as a + (-b)
		if len(args) == 2 {
			left := formatExpression(args[0], format)
			right := formatExpression(args[1], format)

			// Check if we need to add parentheses around the right argument
			if node, ok := args[1].(ExprNode); ok && needsParenthesesForSubtraction(node) {
				right = "(" + right + ")"
			}

			switch format {
			case FmtUnicode:
				return left + " − " + right
			case FmtLatex:
				return left + " - " + right
			default:
				return left + " - " + right
			}
		}

	case "*":
		return formatMultiplication(args, format)

	case "/":
		return formatDivision(args, format)

	case "^":
		return formatExponentiation(args, format)

	case "D":
		return formatDerivative(args, node.Wrt, format)

	case "abs":
		if len(args) == 1 {
			arg := formatExpression(args[0], format)
			switch format {
			case FmtUnicode, FmtLatex:
				return "|" + arg + "|"
			default:
				return "abs(" + arg + ")"
			}
		}

	case "exp":
		// Guard args[0] for malformed nodes; fall through to the generic
		// function-call fallback (like abs) when arity is wrong.
		if len(args) >= 1 {
			arg := formatExpression(args[0], format)
			switch format {
			case FmtUnicode:
				return "exp(" + arg + ")"
			case FmtLatex:
				if shouldUseExpLeft(args[0]) {
					return "\\exp\\left(" + arg + "\\right)"
				}
				return "\\exp(" + arg + ")"
			default:
				return "exp(" + arg + ")"
			}
		}

	case "ifelse":
		if len(args) >= 3 {
			condition := formatExpression(args[0], format)
			trueVal := formatExpression(args[1], format)
			falseVal := formatExpression(args[2], format)

			switch format {
			case FmtLatex:
				return fmt.Sprintf("\\begin{cases} %s & \\text{if } %s \\\\ %s & \\text{otherwise} \\end{cases}",
					trueVal, condition, falseVal)
			default:
				return fmt.Sprintf("ifelse(%s, %s, %s)", condition, trueVal, falseVal)
			}
		}

	case "Pre":
		// Guard args[0] for malformed nodes; fall through to the generic
		// function-call fallback (like abs) when arity is wrong.
		if len(args) >= 1 {
			arg := formatExpression(args[0], format)
			switch format {
			case FmtLatex:
				return "\\mathrm{Pre}(" + arg + ")"
			default:
				return "Pre(" + arg + ")"
			}
		}

	// Comparison operators
	case ">", "<", ">=", "<=", "==", "!=":
		if len(args) >= 2 {
			left := formatExpression(args[0], format)
			right := formatExpression(args[1], format)
			return left + " " + op + " " + right
		}

	}

	// Generic fallback: function-call notation for open-tier rewrite sugar
	// (grad/div/laplacian) and any unknown user op. Only `args` are shown; any
	// non-`args` fields (e.g. grad's `dim`) are NOT rendered.
	// unicode/ascii: name(a0, a1, …);  latex: \mathrm{ESC(name)}(a0, a1, …).
	argStrs := make([]string, len(args))
	for i, arg := range args {
		argStrs[i] = formatExpression(arg, format)
	}
	inner := strings.Join(argStrs, ", ")
	if format == FmtLatex {
		return "\\mathrm{" + latexEscape(op) + "}(" + inner + ")"
	}
	return op + "(" + inner + ")"
}

func formatMultiplication(args []any, format string) string {
	if len(args) < 2 {
		return "*(...)"
	}

	parts := make([]string, len(args))
	for i, arg := range args {
		formatted := formatExpression(arg, format)

		// Add parentheses if needed for addition/subtraction terms
		if node, ok := arg.(ExprNode); ok && isAdditiveNode(node) {
			formatted = "(" + formatted + ")"
		}

		parts[i] = formatted
	}

	switch format {
	case FmtUnicode:
		return strings.Join(parts, "·")
	case FmtLatex:
		return strings.Join(parts, " \\cdot ")
	default:
		return strings.Join(parts, " * ")
	}
}

func formatDivision(args []any, format string) string {
	if len(args) != 2 {
		return "/(...)"
	}

	left := formatExpression(args[0], format)
	right := formatExpression(args[1], format)

	switch format {
	case FmtLatex:
		return "\\frac{" + left + "}{" + right + "}"
	default:
		// Add parentheses if the right side is complex
		if node, ok := args[1].(ExprNode); ok && isArithmeticNode(node) {
			right = "(" + right + ")"
		}
		return left + "/" + right
	}
}

func formatExponentiation(args []any, format string) string {
	if len(args) != 2 {
		return "^(...)"
	}

	base := formatExpression(args[0], format)
	exp := formatExpression(args[1], format)

	// Add parentheses to base if it's a complex expression
	if node, ok := args[0].(ExprNode); ok && isArithmeticNode(node) {
		base = "(" + base + ")"
	}

	switch format {
	case FmtUnicode:
		if exp == "2" {
			return base + "²"
		} else if exp == "3" {
			return base + "³"
		} else if numExp, ok := args[1].(float64); ok && numExp == math.Trunc(numExp) {
			// Only integer-valued exponents get a superscript; a fractional
			// exponent (e.g. x^2.5) must not be truncated to x².
			return base + formatSuperscript(int(numExp))
		}
		return base + "^" + exp
	case FmtLatex:
		return base + "^{" + exp + "}"
	default:
		return base + "^" + exp
	}
}

// ToUnicodeSpaced converts an expression to Unicode string with spaced multiplication
// for better readability in model summary displays.
func ToUnicodeSpaced(target Expression) string {
	result := formatExpression(target, FmtUnicode)
	// Replace "·" with " · " for better readability in model summaries
	return strings.ReplaceAll(result, "·", " · ")
}

// ModelSummary returns a structured model summary display showing all models,
// reaction systems, data loaders, coupling, domain, and solver as specified in Section 6.3
func ModelSummary(esm *ESMFile) string {
	result := strings.Builder{}

	// Header: ESM version and metadata
	fmt.Fprintf(&result, "ESM v%s: %s\n", esm.ESM, esm.Metadata.Name)
	if esm.Metadata.Description != nil {
		fmt.Fprintf(&result, "  \"%s\"\n", *esm.Metadata.Description)
	}
	if len(esm.Metadata.Authors) > 0 {
		fmt.Fprintf(&result, "  Authors: %s\n", strings.Join(esm.Metadata.Authors, ", "))
	}
	result.WriteString("\n")

	summarizeReactionSystems(&result, esm)
	summarizeModels(&result, esm)
	summarizeDataLoaders(&result, esm)
	summarizeCoupling(&result, esm)
	summarizeDomain(&result, esm)

	return strings.TrimSpace(result.String())
}

// formatSpeciesList renders a reaction's substrate or product list, prefixing a
// stoichiometric coefficient only when it is not 1, joined with " + ".
func formatSpeciesList(items []SubstrateProduct) string {
	names := make([]string, len(items))
	for i, item := range items {
		if item.Stoichiometry == 1 {
			names[i] = ToUnicode(item.Species)
		} else {
			names[i] = fmt.Sprintf("%s%s", formatStoich(item.Stoichiometry), ToUnicode(item.Species))
		}
	}
	return strings.Join(names, " + ")
}

// summarizeReactionSystems writes the "Reaction Systems" section (systems sorted
// by name for deterministic output).
func summarizeReactionSystems(b *strings.Builder, esm *ESMFile) {
	if len(esm.ReactionSystems) == 0 {
		return
	}
	b.WriteString("  Reaction Systems:\n")
	for _, name := range sortedKeys(esm.ReactionSystems) {
		rs := esm.ReactionSystems[name]
		fmt.Fprintf(b, "    %s (%d species, %d parameters, %d reactions)\n",
			name, len(rs.Species), len(rs.Parameters), len(rs.Reactions))

		for _, reaction := range rs.Reactions {
			b.WriteString("      ")
			b.WriteString(reaction.ID)
			b.WriteString(": ")
			b.WriteString(formatSpeciesList(reaction.Substrates))
			b.WriteString(" → ")
			b.WriteString(formatSpeciesList(reaction.Products))
			b.WriteString("    rate: ")
			b.WriteString(ToUnicodeSpaced(reaction.Rate))
			b.WriteString("\n")
		}
	}
	b.WriteString("\n")
}

// summarizeModels writes the "Models" section (models sorted by name).
func summarizeModels(b *strings.Builder, esm *ESMFile) {
	if len(esm.Models) == 0 {
		return
	}
	b.WriteString("  Models:\n")
	for _, name := range sortedKeys(esm.Models) {
		model := esm.Models[name]
		paramCount := 0
		for _, variable := range model.Variables {
			if variable.Type == VarTypeParameter {
				paramCount++
			}
		}
		equationCount := len(model.Equations)
		fmt.Fprintf(b, "    %s (%d parameters, %d equation", name, paramCount, equationCount)
		if equationCount != 1 {
			b.WriteString("s")
		}
		b.WriteString(")\n")

		for _, equation := range model.Equations {
			b.WriteString("      ")
			b.WriteString(ToUnicodeSpaced(equation.LHS))
			b.WriteString(" = ")
			b.WriteString(ToUnicodeSpaced(equation.RHS))
			b.WriteString("\n")
		}
	}
	b.WriteString("\n")
}

// summarizeDataLoaders writes the "Data Loaders" section (loaders and their
// variable names both sorted).
func summarizeDataLoaders(b *strings.Builder, esm *ESMFile) {
	if len(esm.DataLoaders) == 0 {
		return
	}
	b.WriteString("  Data Loaders:\n")
	for _, name := range sortedKeys(esm.DataLoaders) {
		loader := esm.DataLoaders[name]
		varNames := sortedKeys(loader.Variables)
		fmt.Fprintf(b, "    %s: %s (%s)\n", name,
			strings.Join(varNames, ", "), loader.Kind)
	}
	b.WriteString("\n")
}

// summarizeCoupling writes the "Coupling" section in declaration order.
func summarizeCoupling(b *strings.Builder, esm *ESMFile) {
	if len(esm.Coupling) == 0 {
		return
	}
	b.WriteString("  Coupling:\n")
	for i, coupling := range esm.Coupling {
		fmt.Fprintf(b, "    %d. ", i+1)

		switch c := coupling.(type) {
		case OperatorComposeCoupling:
			fmt.Fprintf(b, "operator_compose: %s + %s", c.Systems[0], c.Systems[1])
		case VariableMapCoupling:
			fmt.Fprintf(b, "variable_map: %s → %s", c.From, c.To)
		case CouplingCouple:
			fmt.Fprintf(b, "couple: %s ↔ %s", c.Systems[0], c.Systems[1])
		case OperatorApplyCoupling:
			fmt.Fprintf(b, "operator_apply: %s", c.Operator)
		case CallbackCoupling:
			fmt.Fprintf(b, "callback: %s", c.CallbackID)
		case EventCoupling:
			fmt.Fprintf(b, "event: %s (%s)", c.Name, c.EventType)
		case CouplingImport:
			fmt.Fprintf(b, "coupling_import: %s", c.Ref)
		default:
			b.WriteString("unknown coupling type")
		}
		b.WriteString("\n")
	}
	b.WriteString("\n")
}

// summarizeDomain writes the "Domain" section (temporal extent only).
func summarizeDomain(b *strings.Builder, esm *ESMFile) {
	if esm.Domain == nil {
		return
	}
	parts := make([]string, 0)
	if esm.Domain.Temporal != nil {
		temporal := esm.Domain.Temporal
		// Extract just the date parts for brevity
		start := strings.Split(temporal.Start, "T")[0]
		end := strings.Split(temporal.End, "T")[0]
		parts = append(parts, fmt.Sprintf("%s to %s", start, end))
	}
	fmt.Fprintf(b, "  Domain: %s\n", strings.Join(parts, ", "))
}

func formatDerivative(args []any, wrt *string, format string) string {
	if len(args) != 1 || wrt == nil {
		return "D(...)"
	}

	variable := formatExpression(args[0], format)
	timeVar := *wrt

	switch format {
	case FmtUnicode:
		return "∂" + variable + "/∂" + timeVar
	case FmtLatex:
		formattedVar := formatExpression(args[0], format)
		return "\\frac{\\partial " + formattedVar + "}{\\partial " + timeVar + "}"
	default:
		return "D(" + variable + ")/D" + timeVar
	}
}

// ============================================================================
// Structural / array-query op rendering (esm-spec §4.2).
//
// These ops carry their defining data in fields OTHER than `args`. The
// rendering here mirrors the reference TypeScript implementation
// (pkg/earthsci-ast-ts/src/pretty-print.ts) and MUST byte-match the
// shared fixtures in tests/display/structural_ops.json. See
// tests/display/RENDERING_CONTRACT.md for the exact per-op rules.
//
// Go exposes only the unicode and latex formats (there is no ToAscii); the
// ascii branches below exist for completeness and internal reuse.
// ============================================================================

// isOpNodeValue reports whether a value is an operator node (ExprNode or a raw
// {"op": …} object) rather than a leaf.
func isOpNodeValue(v any) bool {
	switch x := v.(type) {
	case ExprNode, *ExprNode:
		return true
	case map[string]any:
		_, ok := x["op"]
		return ok
	}
	return false
}

// wrapIfOpValue renders a sub-expression, parenthesizing it only when it is an
// operator node (a leaf is never wrapped).
func wrapIfOpValue(v any, format string) string {
	s := formatExpression(v, format)
	if isOpNodeValue(v) {
		return "(" + s + ")"
	}
	return s
}

// plainScalar returns the bare textual form of a raw scalar (index name, axis,
// output selector, manifold, …) — mirrors JS String(): identifiers and enum
// labels render verbatim, with no variable/greek formatting.
func plainScalar(v any) string {
	switch x := v.(type) {
	case nil:
		return ""
	case string:
		return x
	case json.Number:
		return string(x)
	case bool:
		return strconv.FormatBool(x)
	case int:
		return strconv.Itoa(x)
	case int64:
		return strconv.FormatInt(x, 10)
	case float64:
		return strconv.FormatFloat(x, 'g', -1, 64)
	default:
		return fmt.Sprintf("%v", x)
	}
}

// formatConstValue renders a `const` node's literal payload: a scalar number or
// a nested array, indistinguishable from a bare literal.
func formatConstValue(v any, format string) string {
	switch x := v.(type) {
	case []any:
		parts := make([]string, len(x))
		for i, e := range x {
			parts[i] = formatConstValue(e, format)
		}
		return "[" + strings.Join(parts, ", ") + "]"
	case json.Number:
		if f, err := x.Float64(); err == nil {
			return formatNumber(f, format)
		}
		return string(x)
	case float64:
		return formatNumber(x, format)
	case int:
		return formatNumber(float64(x), format)
	case int64:
		return formatNumber(float64(x), format)
	case string:
		return x
	case bool:
		return strconv.FormatBool(x)
	default:
		return fmt.Sprintf("%v", x)
	}
}

// formatStructBound renders a structural integer bound (region / shape / perm /
// range entry): a plain integer or symbolic dimension, or a metaparameter
// Expression node rendered recursively.
func formatStructBound(v any, format string) string {
	if isOpNodeValue(v) {
		return formatExpression(v, format)
	}
	return plainScalar(v)
}

// joinArgList renders each arg via the recursive formatter and joins with ", ".
func joinArgList(args []any, format string) string {
	parts := make([]string, len(args))
	for i, a := range args {
		parts[i] = formatExpression(a, format)
	}
	return strings.Join(parts, ", ")
}

// aggregateSymbolTable maps a reduction family to its {unicode, latex, ascii}
// big-operator symbols.
var aggregateSymbolTable = map[string][3]string{
	"plus":  {"Σ", "\\sum", "sum"},
	"times": {"Π", "\\prod", "prod"},
	"max":   {"max", "\\max", "max"},
	"min":   {"min", "\\min", "min"},
	"bool":  {"⋁", "\\bigvee", "any"},
}

// aggregateSymbol returns the big-operator symbol for an aggregate reduction;
// a present `semiring` supersedes `reduce`.
func aggregateSymbol(semiring, reduce, format string) string {
	var fam string
	if semiring != "" {
		switch semiring {
		case "max_product", "max_sum":
			fam = "max"
		case "min_sum":
			fam = "min"
		case "bool_and_or":
			fam = "bool"
		default:
			fam = "plus"
		}
	} else {
		switch reduce {
		case "*":
			fam = "times"
		case "max":
			fam = "max"
		case "min":
			fam = "min"
		default:
			fam = "plus"
		}
	}
	t := aggregateSymbolTable[fam]
	switch format {
	case FmtUnicode:
		return t[0]
	case FmtLatex:
		return t[1]
	default:
		return t[2]
	}
}

// formatRange renders a single range value: an array [a,b]→"a:b" / [a,s,b]→
// "a:s:b", or an index-set reference { "from": F, "of": […] }.
func formatRange(v any, format string) string {
	switch x := v.(type) {
	case []any:
		parts := make([]string, len(x))
		for i, e := range x {
			parts[i] = formatStructBound(e, format)
		}
		return strings.Join(parts, ":")
	case map[string]any:
		if from, ok := x["from"]; ok {
			fromStr := plainScalar(from)
			if of, ok := x["of"].([]any); ok && len(of) > 0 {
				ofParts := make([]string, len(of))
				for i, o := range of {
					ofParts[i] = plainScalar(o)
				}
				return fromStr + "(" + strings.Join(ofParts, ", ") + ")"
			}
			return fromStr
		}
		return fmt.Sprintf("%v", x)
	default:
		return plainScalar(v)
	}
}

// formatRangesClause renders the ` where {…}` clause shared by aggregate and
// argmin/argmax (keys sorted).
func formatRangesClause(ranges map[string]any, format string) string {
	inSym := "∈"
	switch format {
	case FmtLatex:
		inSym = " \\in "
	case FmtAscii:
		inSym = " in "
	}
	keys := make([]string, 0, len(ranges))
	for k := range ranges {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	parts := make([]string, len(keys))
	for i, k := range keys {
		parts[i] = k + inSym + formatRange(ranges[k], format)
	}
	if format == FmtLatex {
		return " \\text{ where } \\{" + strings.Join(parts, ", ") + "\\}"
	}
	return " where {" + strings.Join(parts, ", ") + "}"
}

// formatAggregate renders an `aggregate` node per the rendering contract.
func formatAggregate(node ExprNode, format string) string {
	outParts := make([]string, len(node.OutputIdx))
	for i, o := range node.OutputIdx {
		outParts[i] = plainScalar(o)
	}
	outIdx := strings.Join(outParts, ", ")

	exprStr := ""
	if node.Expr != nil {
		exprStr = formatExpression(node.Expr, format)
	}
	semiring := ""
	if node.Semiring != nil {
		semiring = *node.Semiring
	}
	reduce := "+"
	if node.Reduce != nil {
		reduce = *node.Reduce
	}
	sym := aggregateSymbol(semiring, reduce, format)

	var out string
	if format == FmtLatex {
		out = sym + "_{" + outIdx + "} (" + exprStr + ")"
	} else {
		out = sym + "[" + outIdx + "] (" + exprStr + ")"
	}

	if len(node.Ranges) > 0 {
		out += formatRangesClause(node.Ranges, format)
	}
	if len(node.Join) > 0 {
		clauses := make([]string, 0, len(node.Join))
		for _, c := range node.Join {
			cm, ok := c.(map[string]any)
			if !ok {
				continue
			}
			onRaw, _ := cm["on"].([]any)
			pairs := make([]string, 0, len(onRaw))
			for _, p := range onRaw {
				pp, ok := p.([]any)
				if !ok || len(pp) < 2 {
					continue
				}
				pairs = append(pairs, plainScalar(pp[0])+"="+plainScalar(pp[1]))
			}
			clauses = append(clauses, strings.Join(pairs, ", "))
		}
		out += " join(" + strings.Join(clauses, "; ") + ")"
	}
	if node.Filter != nil {
		out += " if " + formatExpression(node.Filter, format)
	}
	if node.Distinct != nil && *node.Distinct {
		out += " distinct"
	}
	if node.Key != nil {
		out += " key=" + formatExpression(node.Key, format)
	}
	if semiring != "" && semiring != "sum_product" {
		out += " [semiring=" + semiring + "]"
	}
	return out
}

// formatArgWitness renders an `argmin` / `argmax` node per the rendering contract.
func formatArgWitness(node ExprNode, format string) string {
	arg := ""
	if node.Arg != nil {
		arg = *node.Arg
	}
	exprStr := ""
	if node.Expr != nil {
		exprStr = formatExpression(node.Expr, format)
	}
	var out string
	if format == FmtLatex {
		out = "\\mathrm{" + node.Op + "}_{" + arg + "} (" + exprStr + ")"
	} else {
		out = node.Op + "[" + arg + "] (" + exprStr + ")"
	}
	if len(node.Ranges) > 0 {
		out += formatRangesClause(node.Ranges, format)
	}
	return out
}

// formatStructuralOp renders the closed structural / array-query tier
// (esm-spec §4.2) plus `integral`. It returns (rendered, true) when it handles
// the op, or ("", false) to defer to the scalar-op dispatch or the generic
// fallback (open-tier sugar grad/div/laplacian and unknown user ops).
func formatStructuralOp(node ExprNode, format string) (string, bool) {
	op := node.Op
	args := node.Args

	switch op {
	case "const":
		return formatConstValue(node.Value, format), true

	case "true":
		return "true", true

	case "fn":
		name := ""
		if node.Name != nil {
			name = *node.Name
		}
		inner := joinArgList(args, format)
		return opDisplayName(name, format) + "(" + inner + ")", true

	case "enum":
		if len(args) < 2 {
			return "", false
		}
		label := plainScalar(args[0]) + "." + plainScalar(args[1])
		return opDisplayName(label, format), true

	case "index":
		if len(args) == 0 {
			return "", false
		}
		idx := make([]string, 0, len(args)-1)
		for _, a := range args[1:] {
			idx = append(idx, formatExpression(a, format))
		}
		return wrapIfOpValue(args[0], format) + "[" + strings.Join(idx, ", ") + "]", true

	case "broadcast":
		if node.Fn == nil {
			return "", false
		}
		return formatExprNode(ExprNode{Op: *node.Fn, Args: args}, format), true

	case "integral":
		if len(args) == 0 {
			return "", false
		}
		f := formatExpression(args[0], format)
		v := "x"
		if node.Var != nil {
			v = *node.Var
		}
		lo := ""
		if node.Lower != nil {
			lo = formatExpression(node.Lower, format)
		}
		hi := ""
		if node.Upper != nil {
			hi = formatExpression(node.Upper, format)
		}
		switch format {
		case FmtLatex:
			return "\\int_{" + lo + "}^{" + hi + "} " + f + " \\, d" + v, true
		case FmtUnicode:
			return "∫[" + lo + ", " + hi + "] " + f + " d" + v, true
		default:
			return "integral(" + f + ", " + v + ", " + lo + ", " + hi + ")", true
		}

	case "table_lookup":
		table := ""
		if node.Table != nil {
			table = *node.Table
		}
		eq := "="
		if format == FmtLatex {
			eq = " = "
		}
		keys := make([]string, 0, len(node.TableAxes))
		for k := range node.TableAxes {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		parts := make([]string, len(keys))
		for i, k := range keys {
			parts[i] = k + eq + formatExpression(node.TableAxes[k], format)
		}
		outStr := ""
		if node.Output != nil {
			outStr = ":" + plainScalar(node.Output)
		}
		return opDisplayName(table, format) + "[" + strings.Join(parts, ", ") + "]" + outStr, true

	case "apply_expression_template":
		name := ""
		if node.Name != nil {
			name = *node.Name
		}
		eq := "="
		if format == FmtLatex {
			eq = " = "
		}
		keys := make([]string, 0, len(node.Bindings))
		for k := range node.Bindings {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		parts := make([]string, len(keys))
		for i, k := range keys {
			parts[i] = k + eq + formatExpression(node.Bindings[k], format)
		}
		inner := strings.Join(parts, ", ")
		switch format {
		case FmtLatex:
			return "\\mathrm{" + latexEscape(name) + "}\\langle " + inner + " \\rangle", true
		case FmtUnicode:
			return name + "⟨" + inner + "⟩", true
		default:
			return name + "<" + inner + ">", true
		}

	case "makearray":
		parts := make([]string, 0, len(node.Regions))
		for i, region := range node.Regions {
			dims := make([]string, len(region))
			for j, dim := range region {
				lo, hi := "", ""
				if len(dim) > 0 {
					lo = formatStructBound(dim[0], format)
				}
				if len(dim) > 1 {
					hi = formatStructBound(dim[1], format)
				}
				dims[j] = lo + ":" + hi
			}
			val := "?"
			if i < len(node.Values) {
				val = formatExpression(node.Values[i], format)
			}
			parts = append(parts, "["+strings.Join(dims, ", ")+"] = "+val)
		}
		return opDisplayName("makearray", format) + "(" + strings.Join(parts, ", ") + ")", true

	case "reshape":
		if len(args) == 0 {
			return "", false
		}
		shape := make([]string, len(node.Shape))
		for i, s := range node.Shape {
			shape[i] = formatStructBound(s, format)
		}
		return opDisplayName("reshape", format) + "(" + formatExpression(args[0], format) + ", [" + strings.Join(shape, ", ") + "])", true

	case "transpose":
		if len(args) == 0 {
			return "", false
		}
		if len(node.Perm) > 0 {
			perm := make([]string, len(node.Perm))
			for i, p := range node.Perm {
				perm[i] = formatStructBound(p, format)
			}
			return opDisplayName("transpose", format) + "(" + formatExpression(args[0], format) + ", [" + strings.Join(perm, ", ") + "])", true
		}
		switch format {
		case FmtLatex:
			return wrapIfOpValue(args[0], format) + "^{T}", true
		case FmtUnicode:
			return wrapIfOpValue(args[0], format) + "ᵀ", true
		default:
			return "transpose(" + formatExpression(args[0], format) + ")", true
		}

	case "concat":
		inner := joinArgList(args, format)
		axis := "0"
		if node.Axis != nil {
			axis = plainScalar(node.Axis)
		}
		return opDisplayName("concat", format) + "(" + inner + ", axis=" + axis + ")", true

	case "intersect_polygon", "polygon_intersection_area":
		inner := joinArgList(args, format)
		manifold := ""
		if node.Manifold != nil {
			manifold = *node.Manifold
		}
		return opDisplayName(op, format) + "(" + inner + ", manifold=" + manifold + ")", true

	case "aggregate":
		return formatAggregate(node, format), true

	case "argmin", "argmax":
		return formatArgWitness(node, format), true
	}

	return "", false
}

// Helper functions for specific formatting decisions

// isAdditiveNode reports whether an operator node is an addition or a binary
// subtraction — the terms that need parenthesizing inside a product or on the
// right of a subtraction.
func isAdditiveNode(node ExprNode) bool {
	return node.Op == "+" || (node.Op == "-" && len(node.Args) == 2)
}

// isArithmeticNode reports whether an operator node is any of + - * / — the
// terms that need parenthesizing inside a quotient or as an exponent base.
func isArithmeticNode(node ExprNode) bool {
	return node.Op == "+" || node.Op == "-" || node.Op == "*" || node.Op == "/"
}

func needsParenthesesForSubtraction(node ExprNode) bool {
	return isAdditiveNode(node)
}

func shouldUseExpLeft(arg any) bool {
	// Use \left( \right) for complex expressions in exp()
	if node, ok := arg.(ExprNode); ok {
		return node.Op == "/" || node.Op == "+" || node.Op == "-"
	}
	return false
}
