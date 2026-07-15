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
		// JSON cannot express non-finite numbers as literals, so they arrive as
		// the strings "Infinity" / "-Infinity" / "NaN"; render them as numbers.
		switch expr {
		case "Infinity":
			return formatNumber(math.Inf(1), format)
		case "-Infinity":
			return formatNumber(math.Inf(-1), format)
		case "NaN":
			return formatNumber(math.NaN(), format)
		}
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

// formatNumber formats numeric values per the cross-language rendering contract
// (tests/display/RENDERING_CONTRACT.md "Number formatting"): non-finite values
// render as symbols; magnitudes below 0.01 or at/above 10000 use scientific
// notation with a full-precision, round-tripping mantissa; the unicode sign is
// U+2212 while latex/ascii use ASCII '-'; ascii puts no '+' on a positive
// exponent.
func formatNumber(num float64, format string) string {
	uni := format == FmtUnicode || format == FmtUnicodeSpaced

	// Non-finite values are RENDERED, not stringified.
	if math.IsNaN(num) {
		if format == FmtLatex {
			return "\\text{NaN}"
		}
		return "NaN"
	}
	if math.IsInf(num, 1) {
		switch {
		case uni:
			return "∞"
		case format == FmtLatex:
			return "\\infty"
		default:
			return "inf"
		}
	}
	if math.IsInf(num, -1) {
		switch {
		case uni:
			return "−∞"
		case format == FmtLatex:
			return "-\\infty"
		default:
			return "-inf"
		}
	}

	if num == 0 {
		return "0"
	}

	abs := math.Abs(num)
	if abs < 0.01 || abs >= 10000 {
		// Scientific notation. Use the shortest round-trip exponential so the
		// mantissa never loses precision (0.009999 → 9.999, not 1.0).
		es := strconv.FormatFloat(num, 'e', -1, 64) // e.g. "9.999e-03", "-1.8e-12"
		eIdx := strings.IndexByte(es, 'e')
		mantissa := es[:eIdx]
		exp, _ := strconv.Atoi(strings.TrimPrefix(es[eIdx+1:], "+"))
		// A whole-number mantissa shows ".0" (1 → 1.0) so 10000 prints 1.0×10⁴.
		if !strings.Contains(mantissa, ".") {
			mantissa += ".0"
		}
		switch {
		case uni:
			if strings.HasPrefix(mantissa, "-") {
				mantissa = "−" + mantissa[1:]
			}
			return mantissa + "×10" + formatSuperscript(exp)
		case format == FmtLatex:
			return mantissa + " \\times 10^{" + strconv.Itoa(exp) + "}"
		default:
			return mantissa + "e" + strconv.Itoa(exp)
		}
	}

	// Plain decimal (shortest round-trip; never exponent form in this window).
	result := strconv.FormatFloat(num, 'f', -1, 64)
	if uni && strings.HasPrefix(result, "-") {
		result = "−" + result[1:]
	}
	return result
}

// greekNamesCanonical lists the 24 lowercase Greek names in canonical order.
// No name is a prefix of another, so a name match at a given position is unique.
var greekNamesCanonical = []string{
	"alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta",
	"iota", "kappa", "lambda", "mu", "nu", "xi", "omicron", "pi", "rho",
	"sigma", "tau", "upsilon", "phi", "chi", "psi", "omega",
}

// greekNameToChar maps a Greek name to its lowercase Unicode char; the two
// reverse maps drive char→name (ascii) and char→command (latex) conversion.
var (
	greekNameToChar  = map[string]rune{}
	greekCharToName  = map[rune]string{}
	greekCharToLatex = map[rune]string{}
)

func init() {
	lower := []rune("αβγδεζηθικλμνξοπρστυφχψω")
	for i, name := range greekNamesCanonical {
		greekNameToChar[name] = lower[i]
		greekCharToName[lower[i]] = name
		greekCharToLatex[lower[i]] = "\\" + name
	}
}

// isGreekLetterKey reports whether v is a lowercase Greek name (e.g. "phi") or a
// single lowercase Greek char — the tokens convertGreekLetters can map to a
// command, so the LaTeX variable formatter leaves them unwrapped.
func isGreekLetterKey(v string) bool {
	if _, ok := greekNameToChar[v]; ok {
		return true
	}
	if r := []rune(v); len(r) == 1 {
		_, ok := greekCharToName[r[0]]
		return ok
	}
	return false
}

// convertGreekLetters rewrites Greek letters in already-rendered text, mirroring
// pretty-print.ts convertGreekLetters. ascii maps each Greek char to its name;
// unicode maps a Greek NAME (not followed by an uppercase letter — a chemical
// prefix) to its char; latex maps a Greek char to its command AND a Greek name
// (not followed by an uppercase letter or '}' — already inside \mathrm{}) to its
// command. Go's regexp lacks lookahead, so the name+lookahead scan is manual.
func convertGreekLetters(text, format string) string {
	if format == FmtAscii {
		var b strings.Builder
		for _, r := range text {
			if nm, ok := greekCharToName[r]; ok {
				b.WriteString(nm)
			} else {
				b.WriteRune(r)
			}
		}
		return b.String()
	}
	latex := format == FmtLatex
	runes := []rune(text)
	var b strings.Builder
	i := 0
	for i < len(runes) {
		r := runes[i]
		if latex {
			if cmd, ok := greekCharToLatex[r]; ok {
				b.WriteString(cmd)
				i++
				continue
			}
		}
		if repl, n, ok := matchGreekName(runes, i, latex); ok {
			var next rune = -1
			if i+n < len(runes) {
				next = runes[i+n]
			}
			blocked := next >= 'A' && next <= 'Z'
			if latex {
				// GREEK_LATEX_RE lookahead (?![A-Z}]) and lookbehind
				// (?<![\\A-Za-z]): a name inside a \command or glued to a letter
				// (the `eta` in `\theta`) is left alone.
				if next == '}' {
					blocked = true
				}
				if i > 0 {
					prev := runes[i-1]
					if prev == '\\' || (prev >= 'A' && prev <= 'Z') || (prev >= 'a' && prev <= 'z') {
						blocked = true
					}
				}
			}
			if !blocked {
				b.WriteString(repl)
				i += n
				continue
			}
		}
		b.WriteRune(r)
		i++
	}
	return b.String()
}

// matchGreekName reports whether a Greek name begins at runes[i] (all ASCII).
// The replacement is the command (latex) or the Unicode char (unicode); n is the
// name length in runes.
func matchGreekName(runes []rune, i int, latex bool) (repl string, n int, ok bool) {
	for _, name := range greekNamesCanonical {
		L := len(name) // ASCII ⇒ rune-length == byte-length
		if i+L > len(runes) {
			continue
		}
		match := true
		for k := 0; k < L; k++ {
			if runes[i+k] != rune(name[k]) {
				match = false
				break
			}
		}
		if match {
			if latex {
				return "\\" + name, L, true
			}
			return string(greekNameToChar[name]), L, true
		}
	}
	return "", 0, false
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

// formatVariable formats a variable-name leaf, mirroring pretty-print.ts
// formatAny's variable case: ascii applies only Greek transliteration (no
// chemical subscripts); unicode and latex apply element-aware chemical
// subscripting (formatChemical*) and then Greek conversion.
func formatVariable(varName string, format string) string {
	switch format {
	case FmtAscii:
		return convertGreekLetters(varName, FmtAscii)
	case FmtLatex:
		return convertGreekLetters(formatChemicalLatex(varName), FmtLatex)
	default: // FmtUnicode, FmtUnicodeSpaced
		// A name that already carries a LaTeX command (a backslash) is passed
		// through verbatim — chemical-subscript/Greek conversion would only
		// mangle it (\mathrm{O_3} → \mathrm_{O_₃}, \theta → \θ).
		if strings.Contains(varName, "\\") {
			return varName
		}
		return convertGreekLetters(formatChemicalUnicode(varName), FmtUnicode)
	}
}

// isDigit reports whether c is an ASCII digit.
func isDigit(c byte) bool {
	return c >= '0' && c <= '9'
}

// isASCIILetter reports whether c is an ASCII letter.
func isASCIILetter(c byte) bool {
	return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')
}

// chemToken is one token of a chemical-formula scan: a recognized element symbol
// (with the run of digits that immediately follows), or a single other byte.
type chemToken struct {
	isElement bool
	element   string
	digits    string
	other     byte
}

// scanElements is the greedy 2-char-before-1-char element tokenizer shared by
// chemical detection and unicode subscript rendering (pretty-print.ts
// scanElements).
func scanElements(s string) []chemToken {
	var toks []chemToken
	i := 0
	for i < len(s) {
		sym := ""
		if i+1 < len(s) && chemicalElements[s[i:i+2]] {
			sym = s[i : i+2]
		} else if chemicalElements[s[i:i+1]] {
			sym = s[i : i+1]
		}
		if sym != "" {
			i += len(sym)
			start := i
			for i < len(s) && isDigit(s[i]) {
				i++
			}
			toks = append(toks, chemToken{isElement: true, element: sym, digits: s[start:i]})
		} else {
			toks = append(toks, chemToken{other: s[i]})
			i++
		}
	}
	return toks
}

// hasElementPattern reports whether a name is PURELY a chemical formula: it
// contains at least one element symbol and no non-element letter (underscores
// are ignored, mirroring pretty-print.ts hasElementPattern).
func hasElementPattern(variable string) bool {
	clean := strings.ReplaceAll(variable, "_", "")
	hasElement := false
	for _, t := range scanElements(clean) {
		if t.isElement {
			hasElement = true
		} else if isASCIILetter(t.other) {
			return false
		}
	}
	return hasElement
}

// getChemicalSuffix splits a name into a non-element prefix and an element-
// bearing suffix (pretty-print.ts getChemicalSuffix). Underscore forms are tried
// first (k_NO_O3 → k / NO_O3), then every character split (jNO2 → j / NO2).
func getChemicalSuffix(variable string) (prefix, suffix string, ok bool) {
	if strings.Contains(variable, "_") {
		parts := strings.Split(variable, "_")
		if len(parts) == 2 {
			if hasElementPattern(parts[1]) && !hasElementPattern(parts[0]) {
				return parts[0], parts[1], true
			}
		}
		if len(parts) == 3 {
			p := parts[0]
			s := strings.Join(parts[1:], "_")
			if hasElementPattern(s) && !hasElementPattern(p) {
				return p, s, true
			}
		}
	}
	runes := []rune(variable)
	for i := 1; i < len(runes); i++ {
		p := string(runes[:i])
		s := string(runes[i:])
		if hasElementPattern(s) && !hasElementPattern(p) {
			return p, s, true
		}
	}
	return "", "", false
}

// latexDigitRun matches a run of decimal digits (for LaTeX subscript conversion).
var latexDigitRun = regexp.MustCompile(`[0-9]+`)

// latexChemicalInner converts every digit run to its LaTeX subscript form
// (single digit → _D, multi-digit → _{DD}), WITHOUT a \mathrm{} wrapper.
func latexChemicalInner(formula string) string {
	return latexDigitRun.ReplaceAllStringFunc(formula, func(d string) string {
		if len(d) == 1 {
			return "_" + d
		}
		return "_{" + d + "}"
	})
}

// stripOuterMathrm peels one leading `\mathrm{` and one trailing `}`.
func stripOuterMathrm(s string) string {
	inner := s
	if strings.HasPrefix(inner, "\\mathrm{") {
		inner = inner[len("\\mathrm{"):]
	}
	if strings.HasSuffix(inner, "}") {
		inner = inner[:len(inner)-1]
	}
	return inner
}

// formatChemicalSuffixInner renders the inner content of a chemical/element-
// bearing suffix embedded in a larger variable's subscript (pretty-print.ts
// formatChemicalSuffixInner).
func formatChemicalSuffixInner(variable string) string {
	if _, _, ok := getChemicalSuffix(variable); ok {
		return stripOuterMathrm(formatChemicalLatex(variable))
	}
	if chemicalElements[variable] && !strings.ContainsAny(variable, "0123456789") {
		return variable
	}
	return latexChemicalInner(variable)
}

// endsWithDigit reports whether s ends with an ASCII digit.
func endsWithDigit(s string) bool {
	return len(s) > 0 && isDigit(s[len(s)-1])
}

// singleLetterDigits reports whether variable is a single letter (Latin or
// Greek) followed by a run of digits, and if so returns the letter and digits.
func singleLetterDigits(variable string) (letter, digits string, ok bool) {
	runes := []rune(variable)
	if len(runes) < 2 {
		return "", "", false
	}
	r0 := runes[0]
	isLetter := (r0 >= 'A' && r0 <= 'Z') || (r0 >= 'a' && r0 <= 'z') || (r0 >= 0x0391 && r0 <= 0x03C9)
	if !isLetter {
		return "", "", false
	}
	for _, r := range runes[1:] {
		if r < '0' || r > '9' {
			return "", "", false
		}
	}
	return string(r0), string(runes[1:]), true
}

// isPreformattedLatex reports whether a variable name is ALREADY LaTeX that must
// render verbatim rather than be re-wrapped (which only mangles it): a
// \mathrm{…} species, a bare control word with no group (\theta), or a name
// carrying its own {…} grouping but no command (k_{NO_O3}, j_{NO2}). A different
// \command{…} atom such as \mathbf{v} is NOT pre-formatted — it still takes the
// generic \mathrm{} wrap. Mirrors pretty-print.ts isPreformattedLatex.
func isPreformattedLatex(variable string) bool {
	if strings.HasPrefix(variable, "\\mathrm{") {
		return true
	}
	if strings.Contains(variable, "\\") {
		return !strings.Contains(variable, "{")
	}
	return strings.ContainsAny(variable, "{}")
}

// hasLowercaseLetter reports whether s contains an ASCII lowercase letter.
func hasLowercaseLetter(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] >= 'a' && s[i] <= 'z' {
			return true
		}
	}
	return false
}

// formatChemicalLatex is the LaTeX variable/chemical subscript formatter
// (pretty-print.ts formatChemicalLatex).
func formatChemicalLatex(variable string) string {
	// A trailing ionic charge is a superscript (Ca^{2+}), not a subscript.
	if body, charge, ok := splitCharge(variable); ok && hasElementPattern(body) {
		return formatChemicalLatex(body) + "^{" + charge + "}"
	}
	// A name that is already LaTeX passes through untouched.
	if isPreformattedLatex(variable) {
		return variable
	}

	hasElements := hasElementPattern(variable)

	if prefix, suffix, ok := getChemicalSuffix(variable); ok {
		if strings.Contains(suffix, "_") {
			segments := strings.Split(suffix, "_")
			shouldSplit := endsWithDigit(segments[0]) || utf8.RuneCountInString(prefix) > 1
			if shouldSplit {
				var result string
				if utf8.RuneCountInString(prefix) == 1 && isASCIILetter(prefix[0]) {
					result = prefix
				} else {
					result = "\\mathrm{" + prefix + "}"
				}
				for _, seg := range segments {
					if hasElementPattern(seg) {
						result += "_{\\mathrm{" + latexChemicalInner(seg) + "}}"
					} else {
						result += "_\\mathrm{" + seg + "}"
					}
				}
				return result
			}
		}
		innerContent := formatChemicalSuffixInner(suffix)
		formattedPrefix := prefix
		if utf8.RuneCountInString(prefix) > 1 {
			formattedPrefix = "\\mathrm{" + prefix + "}"
		}
		return formattedPrefix + "_{\\mathrm{" + innerContent + "}}"
	}

	if hasElements {
		if chemicalElements[variable] && !strings.ContainsAny(variable, "0123456789") {
			return variable
		}
		return "\\mathrm{" + latexChemicalInner(variable) + "}"
	}

	// Regular (non-chemical) variable.
	// A Greek letter (name or char) is returned as-is so convertGreekLetters can
	// map it to its command (phi → \phi), rather than wrapping it in \mathrm{}.
	if isGreekLetterKey(variable) {
		return variable
	}
	if letter, digits, ok := singleLetterDigits(variable); ok {
		if len(digits) == 1 {
			return letter + "_" + digits
		}
		return letter + "_{" + digits + "}"
	}
	if utf8.RuneCountInString(variable) == 1 {
		return variable
	}
	if strings.Contains(variable, "_") {
		parts := strings.Split(variable, "_")
		anyChemical := false
		for _, p := range parts {
			if hasElementPattern(p) {
				anyChemical = true
				break
			}
		}
		if anyChemical {
			base := parts[0]
			var result string
			if utf8.RuneCountInString(base) == 1 && isASCIILetter(base[0]) {
				result = base
			} else if hasElementPattern(base) {
				result = formatChemicalLatex(base)
			} else {
				result = "\\mathrm{" + base + "}"
			}
			for i := 1; i < len(parts); i++ {
				part := parts[i]
				if hasElementPattern(part) {
					result += "_{\\mathrm{" + latexChemicalInner(part) + "}}"
				} else {
					result += "_\\mathrm{" + part + "}"
				}
			}
			return result
		}
		return "\\mathrm{" + latexEscape(variable) + "}"
	}
	// A symbol with no lowercase letters (e.g. "RT", "-E") is a math variable,
	// not a descriptive name — leave it italic rather than \mathrm{}-wrapping it.
	if !hasLowercaseLetter(variable) {
		return variable
	}
	return "\\mathrm{" + variable + "}"
}

// chargeDigitsSign / chargeSignDigits / chargeBareSign detect a trailing ion
// charge: digits-then-sign ("Ca2+"), sign-then-digits ("SO4-2"), or a bare sign
// ("Na+"). The charge always renders magnitude-then-sign.
var (
	chargeDigitsSign = regexp.MustCompile(`^(.+?)([0-9]+)([+-])$`)
	chargeSignDigits = regexp.MustCompile(`^(.+?)([+-])([0-9]+)$`)
	chargeBareSign   = regexp.MustCompile(`^(.+?)([+-])$`)
)

// splitCharge peels a trailing ion charge from a formula, returning the body and
// the charge (magnitude then sign, e.g. "2+" / "2-" / "+"). Mirrors
// pretty-print.ts splitCharge. The charge renders as a superscript, never a
// count subscript.
func splitCharge(formula string) (body, charge string, ok bool) {
	if m := chargeDigitsSign.FindStringSubmatch(formula); m != nil {
		return m[1], m[2] + m[3], true
	}
	if m := chargeSignDigits.FindStringSubmatch(formula); m != nil {
		return m[1], m[3] + m[2], true
	}
	if m := chargeBareSign.FindStringSubmatch(formula); m != nil {
		return m[1], m[2], true
	}
	return formula, "", false
}

// formatChemicalUnicode is the unicode variable/chemical subscript formatter
// (pretty-print.ts formatChemicalUnicode), extended with ion-charge superscripts.
func formatChemicalUnicode(variable string) string {
	// A trailing ionic charge is a superscript (Ca²⁺), not a subscript.
	if body, charge, ok := splitCharge(variable); ok && hasElementPattern(body) {
		return formatChemicalUnicode(body) + formatSuperscriptStr(charge)
	}

	if !hasElementPattern(variable) {
		if prefix, suffix, ok := getChemicalSuffix(variable); ok {
			chemicalPart := formatChemicalUnicode(suffix)
			if !strings.Contains(variable, "_") {
				return prefix + chemicalPart
			}
			return prefix + "_" + chemicalPart
		}
		if strings.Contains(variable, "_") {
			parts := strings.Split(variable, "_")
			anyChemical := false
			for _, p := range parts {
				if hasElementPattern(p) {
					anyChemical = true
					break
				}
			}
			if anyChemical {
				for i, p := range parts {
					if hasElementPattern(p) {
						parts[i] = formatChemicalUnicode(p)
					}
				}
				return strings.Join(parts, "_")
			}
		}
		return variable
	}

	// Pure chemical formula (any ionic charge already peeled above).
	var b strings.Builder
	for _, t := range scanElements(variable) {
		switch {
		case t.isElement:
			b.WriteString(t.element)
			b.WriteString(formatSubscript(t.digits))
		case isDigit(t.other):
			b.WriteString(formatSubscript(string(t.other)))
		default:
			b.WriteByte(t.other)
		}
	}
	return b.String()
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

// formatSuperscript converts an integer to Unicode superscript characters.
func formatSuperscript(num int) string {
	return formatSuperscriptStr(strconv.Itoa(num))
}

// formatSuperscriptStr converts each digit/sign character of s to its Unicode
// superscript form (others copied verbatim).
func formatSuperscriptStr(s string) string {
	result := strings.Builder{}
	for _, char := range s {
		if sup, ok := superscriptRunes[char]; ok {
			result.WriteRune(sup)
		} else {
			result.WriteRune(char)
		}
	}
	return result.String()
}

// formatExprNode formats a scalar operator node with precedence-aware
// parenthesization, mirroring pretty-print.ts formatExpressionNode + OP_RENDERERS
// (plus the F-7 corrections: `^` is right-associative so a left-nested power is
// parenthesized, and `D`'s operator operand is parenthesized). Structural ops go
// through formatStructuralOp; open-tier sugar (grad/div/laplacian) and unknown
// ops through the generic function-call fallback.
func formatExprNode(node ExprNode, format string) string {
	op := node.Op
	args := node.Args

	if s, ok := formatStructuralOp(node, format); ok {
		return s
	}

	uni := format == FmtUnicode || format == FmtUnicodeSpaced

	// raw renders a child with no parenthesization; arg adds precedence-aware
	// parentheses (isRight marks a right operand of a binary op).
	raw := func(a any) string { return formatExpression(a, format) }
	arg := func(a any, isRight bool) string {
		s := formatExpression(a, format)
		if needsParentheses(op, len(args), a, isRight) {
			return "(" + s + ")"
		}
		return s
	}

	switch op {
	case "+":
		if len(args) == 2 {
			// Simplify a + (-b) → a − b via a synthetic binary-minus node so the
			// subtraction formatting lives in one place.
			if rn, ok := asExprNode(args[1]); ok && rn.Op == "-" && len(rn.Args) == 1 {
				return formatExprNode(ExprNode{Op: "-", Args: []any{args[0], rn.Args[0]}}, format)
			}
			return arg(args[0], false) + " + " + arg(args[1], true)
		}
		if len(args) >= 3 {
			parts := make([]string, len(args))
			for i, a := range args {
				parts[i] = arg(a, false)
			}
			return strings.Join(parts, " + ")
		}

	case "-":
		if len(args) == 1 {
			if uni {
				return "−" + arg(args[0], false)
			}
			return "-" + arg(args[0], false)
		}
		if len(args) == 2 {
			sep := " - "
			if uni {
				sep = " − "
			}
			return arg(args[0], false) + sep + arg(args[1], true)
		}

	case "*":
		if len(args) >= 2 {
			sep := mulSeparator(format)
			// In LaTeX, a product whose operands are already-typeset factors
			// (e.g. \mathrm{O_3}) is written by implicit juxtaposition (a space);
			// a product of plain symbols uses \cdot to stay unambiguous.
			if format == FmtLatex && anyBackslashStringArg(args) {
				sep = " "
			}
			if len(args) == 2 {
				return arg(args[0], false) + sep + arg(args[1], true)
			}
			parts := make([]string, len(args))
			for i, a := range args {
				parts[i] = arg(a, false)
			}
			return strings.Join(parts, sep)
		}

	case "/":
		if len(args) == 2 {
			if format == FmtLatex {
				return "\\frac{" + raw(args[0]) + "}{" + raw(args[1]) + "}"
			}
			sep := "/"
			if format == FmtAscii {
				sep = " / "
			}
			return arg(args[0], false) + sep + arg(args[1], true)
		}

	case "^":
		if len(args) == 2 {
			if format == FmtLatex {
				return arg(args[0], false) + "^{" + raw(args[1]) + "}"
			}
			if uni {
				if v, ok := numericValueOf(args[1]); ok && !math.IsInf(v, 0) && v == math.Trunc(v) {
					return arg(args[0], false) + formatSuperscript(int(v))
				}
			}
			return arg(args[0], false) + "^" + arg(args[1], true)
		}

	case "D":
		if len(args) == 1 && node.Wrt != nil {
			w := *node.Wrt
			switch {
			case uni:
				return "∂" + dOperand(args[0], format) + "/∂" + w
			case format == FmtLatex:
				return "\\frac{\\partial " + dOperand(args[0], format) + "}{\\partial " + w + "}"
			default:
				return "D(" + raw(args[0]) + ")/D" + w
			}
		}

	case ">", "<", ">=", "<=", "==", "=", "!=":
		if len(args) == 2 {
			return arg(args[0], false) + " " + comparisonSymbol(op, format) + " " + arg(args[1], true)
		}

	case "and":
		if len(args) == 2 {
			sym := "and"
			switch {
			case uni:
				sym = "∧"
			case format == FmtLatex:
				sym = "\\land"
			}
			return arg(args[0], false) + " " + sym + " " + arg(args[1], true)
		}

	case "or":
		if len(args) == 2 {
			return arg(args[0], false) + " " + orSymbol(format) + " " + arg(args[1], true)
		}
		if len(args) >= 3 {
			sep := " or "
			switch {
			case uni:
				sep = " ∨ "
			case format == FmtLatex:
				sep = " \\lor "
			}
			parts := make([]string, len(args))
			for i, a := range args {
				parts[i] = arg(a, false)
			}
			return strings.Join(parts, sep)
		}

	case "not":
		if len(args) == 1 {
			switch {
			case uni:
				return "¬" + arg(args[0], false)
			case format == FmtLatex:
				return "\\neg " + arg(args[0], false)
			default:
				return "not " + arg(args[0], false)
			}
		}

	case "exp", "sin", "cos", "tan", "sinh", "cosh", "tanh":
		if len(args) == 1 {
			if format == FmtLatex {
				la := raw(args[0])
				if strings.Contains(la, "\\frac") {
					return "\\" + op + "\\left(" + la + "\\right)"
				}
				return "\\" + op + "(" + la + ")"
			}
			return op + "(" + arg(args[0], false) + ")"
		}

	case "asin", "acos", "atan":
		if len(args) == 1 {
			switch {
			case uni:
				return "arc" + op[1:] + "(" + arg(args[0], false) + ")"
			case format == FmtLatex:
				return "\\arc" + op[1:] + "(" + raw(args[0]) + ")"
			default:
				return op + "(" + arg(args[0], false) + ")"
			}
		}

	case "asinh", "acosh", "atanh":
		if len(args) == 1 {
			switch {
			case uni:
				return op[1:] + "⁻¹(" + arg(args[0], false) + ")"
			case format == FmtLatex:
				return "\\" + op[1:] + "^{-1}(" + raw(args[0]) + ")"
			default:
				return op + "(" + arg(args[0], false) + ")"
			}
		}

	case "log":
		if len(args) == 1 {
			switch {
			case uni:
				return "ln(" + arg(args[0], false) + ")"
			case format == FmtLatex:
				return "\\ln(" + raw(args[0]) + ")"
			default:
				return "log(" + arg(args[0], false) + ")"
			}
		}

	case "log10":
		if len(args) == 1 {
			switch {
			case uni:
				return "log₁₀(" + arg(args[0], false) + ")"
			case format == FmtLatex:
				return "\\log_{10}(" + raw(args[0]) + ")"
			default:
				return "log10(" + arg(args[0], false) + ")"
			}
		}

	case "sqrt":
		if len(args) == 1 {
			switch {
			case uni:
				if isOpNodeValue(args[0]) {
					return "√(" + raw(args[0]) + ")"
				}
				return "√" + raw(args[0])
			case format == FmtLatex:
				return "\\sqrt{" + raw(args[0]) + "}"
			default:
				return "sqrt(" + arg(args[0], false) + ")"
			}
		}

	case "abs":
		if len(args) == 1 {
			switch {
			case uni:
				return "|" + arg(args[0], false) + "|"
			case format == FmtLatex:
				return "|" + raw(args[0]) + "|"
			default:
				return "abs(" + arg(args[0], false) + ")"
			}
		}

	case "floor":
		if len(args) == 1 {
			switch {
			case uni:
				return "⌊" + arg(args[0], false) + "⌋"
			case format == FmtLatex:
				return "\\lfloor " + raw(args[0]) + " \\rfloor"
			default:
				return "floor(" + arg(args[0], false) + ")"
			}
		}

	case "ceil":
		if len(args) == 1 {
			switch {
			case uni:
				return "⌈" + arg(args[0], false) + "⌉"
			case format == FmtLatex:
				return "\\lceil " + raw(args[0]) + " \\rceil"
			default:
				return "ceil(" + arg(args[0], false) + ")"
			}
		}

	case "sign":
		if len(args) == 1 {
			switch {
			case uni:
				return "sgn(" + arg(args[0], false) + ")"
			case format == FmtLatex:
				return "\\mathrm{sgn}(" + raw(args[0]) + ")"
			default:
				return "sign(" + arg(args[0], false) + ")"
			}
		}

	case "min":
		if len(args) == 2 {
			if format == FmtLatex {
				return "\\min(" + raw(args[0]) + ", " + raw(args[1]) + ")"
			}
			return "min(" + arg(args[0], false) + ", " + arg(args[1], false) + ")"
		}

	case "max":
		if len(args) == 2 {
			if format == FmtLatex {
				return "\\max(" + raw(args[0]) + ", " + raw(args[1]) + ")"
			}
			return "max(" + arg(args[0], false) + ", " + arg(args[1], false) + ")"
		}
		if len(args) >= 3 {
			parts := make([]string, len(args))
			for i, a := range args {
				parts[i] = raw(a)
			}
			list := strings.Join(parts, ", ")
			if format == FmtLatex {
				return "\\max(" + list + ")"
			}
			return "max(" + list + ")"
		}

	case "atan2":
		if len(args) == 2 {
			if format == FmtLatex {
				return "\\mathrm{atan2}(" + raw(args[0]) + ", " + raw(args[1]) + ")"
			}
			return "atan2(" + arg(args[0], false) + ", " + arg(args[1], false) + ")"
		}

	case "Pre":
		if len(args) == 1 {
			if format == FmtLatex {
				return "\\mathrm{Pre}(" + raw(args[0]) + ")"
			}
			return "Pre(" + arg(args[0], false) + ")"
		}

	case "ifelse":
		if len(args) == 3 {
			if format == FmtLatex {
				return "\\begin{cases} " + raw(args[1]) + " & \\text{if } " + raw(args[0]) +
					" \\\\ " + raw(args[2]) + " & \\text{otherwise} \\end{cases}"
			}
			return "ifelse(" + arg(args[0], false) + ", " + arg(args[1], false) + ", " + arg(args[2], false) + ")"
		}
	}

	// Generic fallback: function-call notation for open-tier rewrite sugar
	// (grad/div/laplacian) and any unknown user op. Only `args` are shown; any
	// non-`args` fields (e.g. grad's `dim`) are NOT rendered.
	argStrs := make([]string, len(args))
	for i, a := range args {
		argStrs[i] = raw(a)
	}
	inner := strings.Join(argStrs, ", ")
	if format == FmtLatex {
		return "\\mathrm{" + latexEscape(op) + "}(" + inner + ")"
	}
	return op + "(" + inner + ")"
}

// anyBackslashStringArg reports whether any arg is a raw string carrying a
// backslash (an already-typeset LaTeX factor), which selects space (implicit)
// multiplication in LaTeX.
func anyBackslashStringArg(args []any) bool {
	for _, a := range args {
		if s, ok := a.(string); ok && strings.Contains(s, "\\") {
			return true
		}
	}
	return false
}

// mulSeparator returns the multiplication operator string for a format.
func mulSeparator(format string) string {
	switch format {
	case FmtUnicodeSpaced:
		// Spacing is applied at the operator so it never touches a "·" inside a
		// rendered leaf (e.g. a hydrate chemical formula).
		return " · "
	case FmtUnicode:
		return "·"
	case FmtLatex:
		return " \\cdot "
	default:
		return " * "
	}
}

// comparisonSymbol returns the infix symbol for a comparison op per format.
func comparisonSymbol(op, format string) string {
	uni := format == FmtUnicode || format == FmtUnicodeSpaced
	switch op {
	case ">=":
		switch {
		case uni:
			return "≥"
		case format == FmtLatex:
			return "\\geq"
		}
		return ">="
	case "<=":
		switch {
		case uni:
			return "≤"
		case format == FmtLatex:
			return "\\leq"
		}
		return "<="
	case "==", "=":
		if format == FmtAscii {
			return "=="
		}
		return "="
	case "!=":
		switch {
		case uni:
			return "≠"
		case format == FmtLatex:
			return "\\neq"
		}
		return "!="
	}
	return op // ">" and "<" are identical in every format
}

// orSymbol returns the binary logical-or symbol per format.
func orSymbol(format string) string {
	switch {
	case format == FmtUnicode || format == FmtUnicodeSpaced:
		return "∨"
	case format == FmtLatex:
		return "\\lor"
	default:
		return "or"
	}
}

// dOperand renders a derivative's operand, parenthesizing it when it is an
// operator node (F-7: ∂(x + y)/∂t, never ∂x + y/∂t).
func dOperand(a any, format string) string {
	s := formatExpression(a, format)
	if isOpNodeValue(a) {
		return "(" + s + ")"
	}
	return s
}

// ToUnicodeSpaced converts an expression to a Unicode string identical to
// ToUnicode except that the multiplication operator renders as " · " (spaced)
// for readability in model-summary displays. The spacing is produced at the
// operator during formatting (FmtUnicodeSpaced), not by a post-hoc string
// replace, so a "·" inside a rendered leaf (e.g. a hydrate chemical formula) is
// never disturbed.
func ToUnicodeSpaced(target Expression) string {
	return formatExpression(target, FmtUnicodeSpaced)
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
	case FmtUnicode, FmtUnicodeSpaced:
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
		case FmtUnicode, FmtUnicodeSpaced:
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
		case FmtUnicode, FmtUnicodeSpaced:
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
		case FmtUnicode, FmtUnicodeSpaced:
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

// ============================================================================
// Precedence and parenthesization (mirrors op-registry.ts + pretty-print.ts).
// ============================================================================

// functionPrecedence is the precedence of a function-call / unknown op (binds
// tightest). Higher precedence binds tighter.
const functionPrecedence = 8

// loosestPrecedence is opPrecedence("or") — inside a function call or unary
// minus, only a child at or below this precedence is parenthesized.
const loosestPrecedence = 1

// opPrecedenceTable holds the infix precedence of every operator that renders
// infix; every other op (function call, structural, unknown) binds tightest.
var opPrecedenceTable = map[string]int{
	"+": 4, "-": 4, "*": 5, "/": 5, "^": 7,
	">": 3, "<": 3, ">=": 3, "<=": 3, "==": 3, "!=": 3, "=": 3,
	"and": 2, "or": 1, "not": 6,
}

// registeredFunctionCallOps are the registered scalar ops that render as a
// function call (no infix precedence) — mirrors op-registry.ts isFunctionCallOp.
// Unknown ops (grad/div/laplacian) are deliberately absent.
var registeredFunctionCallOps = map[string]bool{
	"exp": true, "log": true, "log10": true, "sqrt": true, "abs": true,
	"sin": true, "cos": true, "tan": true, "asin": true, "acos": true,
	"atan": true, "atan2": true, "sinh": true, "cosh": true, "tanh": true,
	"asinh": true, "acosh": true, "atanh": true, "min": true, "max": true,
	"floor": true, "ceil": true, "sign": true, "ifelse": true, "Pre": true,
	"D": true,
}

func opPrecedence(op string) int {
	if p, ok := opPrecedenceTable[op]; ok {
		return p
	}
	return functionPrecedence
}

func isFunctionCallOp(op string) bool {
	return registeredFunctionCallOps[op]
}

// needsParentheses reports whether child needs parentheses inside a parent op.
// It mirrors pretty-print.ts needsParentheses, with the F-7 correction that a
// LEFT operand of the right-associative `^` at equal precedence is parenthesized
// ((a^b)^c, not a^b^c).
func needsParentheses(parentOp string, parentArgc int, child any, isRight bool) bool {
	childOp, ok := opNodeOp(child)
	if !ok {
		return false // number / string leaf never needs parentheses
	}
	parentPrec := opPrecedence(parentOp)
	childPrec := opPrecedence(childOp)

	// Function arguments sit inside the call's own parentheses — only the
	// loosest-binding (logical-or) child is parenthesized.
	if isFunctionCallOp(parentOp) {
		return childPrec <= loosestPrecedence
	}
	// Unary minus is likewise lenient.
	if parentOp == "-" && parentArgc == 1 {
		return childPrec <= loosestPrecedence
	}
	if childPrec < parentPrec {
		return true
	}
	if childPrec > parentPrec {
		return false
	}
	// Same precedence: a right operand of a non-associative op is parenthesized,
	// and (F-7) so is a LEFT operand of the right-associative `^`.
	if isRight && (parentOp == "-" || parentOp == "/" || parentOp == "^") {
		return true
	}
	if !isRight && parentOp == "^" {
		return true
	}
	return false
}

// opNodeOp returns the operator name of an operator-node value (ExprNode,
// *ExprNode, or a raw {"op": …} map), or ok=false for a leaf.
func opNodeOp(v any) (string, bool) {
	switch x := v.(type) {
	case ExprNode:
		return x.Op, true
	case *ExprNode:
		if x != nil {
			return x.Op, true
		}
	case map[string]any:
		if op, ok := x["op"].(string); ok {
			return op, true
		}
	}
	return "", false
}

// numericValueOf extracts a float64 from a numeric leaf (int64/int/float64/
// json.Number), reporting ok=false for anything else.
func numericValueOf(v any) (float64, bool) {
	switch x := v.(type) {
	case float64:
		return x, true
	case int:
		return float64(x), true
	case int64:
		return float64(x), true
	case json.Number:
		if f, err := x.Float64(); err == nil {
			return f, true
		}
	}
	return 0, false
}
