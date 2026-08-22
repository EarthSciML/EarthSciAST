package esm

// parse_expression.go — the INVERSE of ToAscii (display.go) for authoring
// EarthSciAST expressions (esm-spec §4.2) as text. It is a direct port of the
// TypeScript reference implementation (pkg/earthsci-ast-ts/src/parse-expression.ts),
// whose module docstring is the normative spec; the cross-language contract is
// tests/conformance/expression_parse/cases.json.
//
// The concrete syntax IS what ToAscii emits, so the pair round-trips:
// ToAscii(ParseExpression(s)) == s. Precedence is sourced from opPrecedence
// (display.go) so the parser can never drift from the printer. This parser
// RECONSTRUCTS existing AST node shapes; it never invents new ones, and it
// requires no change to ToAscii.
//
// Coverage:
//   - scalar tier: arithmetic, powers, comparisons, boolean logic, elementary
//     functions, derivatives (`D(x)/Dt` and `D(x, t)`), open/user function calls;
//   - array & call-shaped tier: array literals `[…]` (`const`), indexing
//     `a[i, j]` (`index`), dotted closed-function calls `datetime.year(t)` (`fn`),
//     the `true` literal, and `integral` / `reshape` / `transpose` / `concat`;
//   - reduction & array-query tier: `aggregate` reductions
//     `sum[i] (expr) where {i in set, j in lo:hi} join(a=b) if pred distinct
//     key=k [semiring=…]` (all clause shapes), the `argmin`/`argmax`
//     arg-witnesses `argmin[g] (expr) where {…}`, template application
//     `name<binding = value, …>` (`apply_expression_template`),
//     `polygon_intersection_area(a, b, manifold=…)`, and the piecewise-region
//     array `makearray([lo:hi, …] = value, …)`.
//
// Aggregate `args` is a derived operand cache the printer doesn't emit; it is
// reconstructed best-effort (see deriveAggregateArgs) and is reprint-neutral.
// `sum` with neither an explicit `[semiring=…]` nor a `join` reconstructs as a
// plain `+` reduction — the join-less `sum_product` annotation (semantically
// identical there) is not recovered; both reprint identically.
//
// Still deferred (need dedicated surface syntax — a later pass): `table_lookup`,
// `broadcast`, `enum`, and `intersect_polygon` (its `id` field is not printed,
// so it can't round-trip). Those are refused with an *ExpressionParseError.
//
// Design rules: multiplication is ALWAYS explicit (`k * A`) — no implicit
// juxtaposition, because identifiers are multi-letter (`NO2`, `O3`, `k_photo`).
// Two known non-exactnesses trace to ToAscii, not the parser: float
// serialization (formatNumber routes through a float64), and unary-minus
// operands being under-parenthesized (`-(a+b)` and `(-a)+b` both print
// `-a + b`) — the parser matches the printer's loose convention. Because the
// printer is not injective, ParseExpression(ToAscii(ast)) is a faithful
// SEMANTIC round-trip but may normalize structure (flat vs. nested `+`; a scalar
// `const`/`fn` with a non-dotted name reprints identically to a plain
// number/op). Editors should treat text as a derived view and re-parse only
// dirtied expressions.

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"unicode/utf8"
)

// ExpressionParseError reports that an expression string could not be parsed.
// Pos is a 0-based RUNE offset into the source (not a byte offset — names such
// as `∂u_∂z` and `∇phi` are legal identifiers). Callers should match it with
// errors.As.
type ExpressionParseError struct {
	Message string
	Pos     int
}

func (e *ExpressionParseError) Error() string {
	return fmt.Sprintf("%s (at position %d)", e.Message, e.Pos)
}

// ---------------------------------------------------------------------------
// operator tables
// ---------------------------------------------------------------------------

// exprInfixOps are the binary infix operators the parser recognizes. Each one's
// precedence comes from opPrecedence at parse time, so it tracks the printer's
// table; only the token set and associativity live here. `^` is the sole
// right-associative operator (mirrors display.go's `^` handling).
var exprInfixOps = map[string]bool{
	"or": true, "and": true,
	"==": true, "!=": true, "<": true, ">": true, "<=": true, ">=": true,
	"+": true, "-": true, "*": true, "/": true, "^": true,
}

var exprRightAssocOps = map[string]bool{"^": true}

// Prefix operand minimum-precedences, sourced from the registry:
//   - unary `-` binds LOOSELY (registry precedence of `-`, = additive), so it
//     swallows a whole additive/multiplicative operand, matching how the printer
//     renders `-(Ea/(R*T))` as `-Ea / (R * T)` with no inner parens.
//   - `not` binds TIGHTLY at its registry precedence (`not p and q` is
//     `(not p) and q`).
//
// Template binding values (`name<k = value, …>`) bind at additive precedence so
// the closing `>` — a comparison operator — is never swallowed as `value > …`.
var (
	exprUnaryMinusMinPrec = opPrecedence("-")
	exprNotMinPrec        = opPrecedence("not")
	exprTemplateArgMin    = opPrecedence("+")
)

// exprStructuralRefusals are the structural ops whose defining data lives
// OUTSIDE `args` AND which have no text surface yet — refused, pending a
// dedicated syntax pass. (`integral`, `reshape`, `transpose`, `concat`, `fn`,
// `const`, `index`, `true`, `aggregate`, `apply_expression_template`,
// `polygon_intersection_area` and `makearray` DO have a surface and are
// reconstructed below; they are intentionally absent here. `intersect_polygon`
// stays refused: its `id` field is not printed, so it can't round-trip.)
var exprStructuralRefusals = map[string]bool{
	"table_lookup": true, "broadcast": true, "enum": true, "intersect_polygon": true,
}

// exprAggregateSyms are the aggregate reduction symbols ToAscii emits
// (formatAggregate). Each maps to a default `reduce` when no explicit
// `[semiring=…]` supersedes it; `sum` and `any` carry no `reduce` field
// (plain `+` / semiring-only).
var exprAggregateSyms = map[string]bool{
	"sum": true, "prod": true, "max": true, "min": true, "any": true,
}

// exprArgWitnessSyms are the arg-witness reductions (formatArgWitness):
// `argmin[g] (expr) where {…}`.
var exprArgWitnessSyms = map[string]bool{"argmin": true, "argmax": true}

// exprReduceBySym maps an aggregate symbol to its default `reduce` operator;
// an absent entry means the node carries no `reduce` field.
var exprReduceBySym = map[string]string{
	"prod": "*",
	"max":  "max",
	"min":  "min",
}

// ---------------------------------------------------------------------------
// tokenizer
// ---------------------------------------------------------------------------

type exprTokKind int

const (
	tkNum exprTokKind = iota
	tkName
	tkOp
	tkLParen
	tkRParen
	tkLBracket
	tkRBracket
	tkLBrace // aggregate `where { … }` range clause
	tkRBrace
	tkColon // range bound separator (`lo:hi`)
	tkSemi  // aggregate join-clause separator
	tkComma
	tkEq // a lone `=`, the equation separator (NOT `==`)
	tkEOF
)

type exprTok struct {
	k   exprTokKind
	s   string  // name / operator text
	n   float64 // numeric value (tkNum only)
	pos int     // 0-based RUNE offset of the token start
}

// Longest-match-first so `>=`/`<=`/`==`/`!=` beat `>`/`<`/`=`.
var exprMultiOps = map[string]bool{">=": true, "<=": true, "==": true, "!=": true}

func exprIsSingleOp(c byte) bool {
	switch c {
	case '+', '-', '*', '/', '^', '>', '<':
		return true
	}
	return false
}

var exprNumRe = regexp.MustCompile(`^(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?`)

// exprNameRe accepts Unicode letters (Greek variables like `ΔF_net`, `Φ`),
// Unicode numbers (subscript/superscript digits in names like `k₀`, `M₁`), and
// dots (qualified refs like `Emissions.NO`, and dotted closed-function names
// like `datetime.year`, which makeParsedCall turns into `fn` nodes). A leading
// digit still can't start an identifier (numbers lex first).
//
// `∂` (U+2202) and `∇` (U+2207) are also name-constituents: source variables are
// sometimes named with them (`∂u_∂z`, a discretized ∂u/∂z shear field), and
// ToAscii prints such names verbatim. Those glyphs are NOT ascii operators — the
// ascii derivative surface is `D(x)/Dt`, so `∂`/`∇` appear in ToAscii output
// ONLY inside a name, and accepting them keeps the parser its exact inverse.
// (The unicode big-operator display forms `∑ ∫ ∈ ⟨⟩` remain refused; they're
// the ToUnicode/ToLatex forms, not the ascii surface — see exprTokenize.)
var exprNameRe = regexp.MustCompile(`^[_\x{2202}\x{2207}\p{L}][\w.\x{2202}\x{2207}\p{L}\p{N}]*`)

var exprWordOps = map[string]bool{"and": true, "or": true, "not": true}

// exprRuneOffsets maps each byte offset of src (plus the one-past-the-end
// offset) to the rune offset of the rune that byte belongs to, so token
// positions are reported in runes as the cross-language contract requires.
func exprRuneOffsets(src string) []int {
	offsets := make([]int, len(src)+1)
	ri := 0
	for bi := 0; bi < len(src); {
		_, size := utf8.DecodeRuneInString(src[bi:])
		for k := 0; k < size; k++ {
			offsets[bi+k] = ri
		}
		bi += size
		ri++
	}
	offsets[len(src)] = ri
	return offsets
}

func exprTokenize(src string) ([]exprTok, error) {
	runeAt := exprRuneOffsets(src)
	toks := make([]exprTok, 0, 16)
	push := func(k exprTokKind, s string, bi int) {
		toks = append(toks, exprTok{k: k, s: s, pos: runeAt[bi]})
	}
	i := 0
	for i < len(src) {
		c := src[i]
		switch c {
		case ' ', '\t', '\n', '\r':
			i++
			continue
		case '(':
			push(tkLParen, "(", i)
			i++
			continue
		case ')':
			push(tkRParen, ")", i)
			i++
			continue
		case '[':
			push(tkLBracket, "[", i)
			i++
			continue
		case ']':
			push(tkRBracket, "]", i)
			i++
			continue
		case '{':
			push(tkLBrace, "{", i)
			i++
			continue
		case '}':
			push(tkRBrace, "}", i)
			i++
			continue
		case ':':
			push(tkColon, ":", i)
			i++
			continue
		case ';':
			push(tkSemi, ";", i)
			i++
			continue
		case ',':
			push(tkComma, ",", i)
			i++
			continue
		}
		if i+1 < len(src) && exprMultiOps[src[i:i+2]] {
			push(tkOp, src[i:i+2], i)
			i += 2
			continue
		}
		if c == '=' {
			// lone '=' (the '==' case was handled just above)
			push(tkEq, "=", i)
			i++
			continue
		}
		if exprIsSingleOp(c) {
			push(tkOp, string(c), i)
			i++
			continue
		}
		rest := src[i:]
		if c == '.' || (c >= '0' && c <= '9') {
			if num := exprNumRe.FindString(rest); num != "" {
				v, err := strconv.ParseFloat(num, 64)
				if err != nil {
					return nil, &ExpressionParseError{
						Message: fmt.Sprintf("Malformed number %q", num),
						Pos:     runeAt[i],
					}
				}
				toks = append(toks, exprTok{k: tkNum, n: v, pos: runeAt[i]})
				i += len(num)
				continue
			}
		}
		if name := exprNameRe.FindString(rest); name != "" {
			if exprWordOps[name] {
				push(tkOp, name, i)
			} else {
				push(tkName, name, i)
			}
			i += len(name)
			continue
		}
		// The big-operator / unicode display forms (∑ ∫ ∈ ⟨⟩ …) are rendered by
		// ToUnicode/ToLatex, not the ascii form this parser inverts; refuse them
		// so a caller routes such input elsewhere. (The ascii aggregate surface
		// uses the words `sum`/`where`/`in`/`join`/`if` and `{ }` `:` `;`, all
		// handled above; the name-constituents `∂`/`∇` matched via exprNameRe.)
		r, _ := utf8.DecodeRuneInString(rest)
		if r > 127 {
			return nil, &ExpressionParseError{
				Message: fmt.Sprintf("unicode operator syntax (%s) — use the ascii text form", strconv.Quote(string(r))),
				Pos:     runeAt[i],
			}
		}
		return nil, &ExpressionParseError{
			Message: fmt.Sprintf("Unexpected character %s", strconv.Quote(string(r))),
			Pos:     runeAt[i],
		}
	}
	toks = append(toks, exprTok{k: tkEOF, pos: runeAt[len(src)]})
	return toks, nil
}

// ---------------------------------------------------------------------------
// parser (Pratt / precedence-climbing)
// ---------------------------------------------------------------------------

// exprParseFailure is the panic payload the recursive-descent parser unwinds
// with; ParseExpression / ParseEquation recover it into a returned error.
type exprParseFailure struct{ err *ExpressionParseError }

type exprTextParser struct {
	toks []exprTok
	p    int
}

func (p *exprTextParser) peek() exprTok { return p.peekAt(0) }

func (p *exprTextParser) peekAt(k int) exprTok {
	i := p.p + k
	if i > len(p.toks)-1 {
		i = len(p.toks) - 1
	}
	if i < 0 {
		i = 0
	}
	return p.toks[i]
}

func (p *exprTextParser) next() exprTok {
	t := p.peekAt(0)
	if p.p < len(p.toks) {
		p.p++
	}
	return t
}

func (p *exprTextParser) expect(k exprTokKind, what string) {
	if p.peek().k != k {
		p.fail("Expected " + what)
	}
	p.next()
}

func (p *exprTextParser) expectOp(v, what string) {
	t := p.peek()
	if t.k != tkOp || t.s != v {
		p.fail("Expected " + what)
	}
	p.next()
}

func (p *exprTextParser) fail(msg string) {
	p.failAt(msg, p.peek())
}

func (p *exprTextParser) failAt(msg string, tok exprTok) {
	panic(exprParseFailure{&ExpressionParseError{Message: msg, Pos: tok.pos}})
}

// atWord reports whether the next token is the contextual keyword name v.
func (p *exprTextParser) atWord(v string) bool {
	t := p.peek()
	return t.k == tkName && t.s == v
}

func (p *exprTextParser) parseEntry() Expression {
	e := p.parseExpr(0)
	if p.peek().k != tkEOF {
		p.fail("Unexpected trailing input")
	}
	return flattenParsedExpr(e)
}

func (p *exprTextParser) parseExpr(minPrec int) Expression {
	left := p.parsePrefix()
	for {
		t := p.peek()
		if t.k != tkOp || !exprInfixOps[t.s] {
			break
		}
		prec := opPrecedence(t.s)
		if prec < minPrec {
			break
		}
		p.next()
		rhsMin := prec + 1
		if exprRightAssocOps[t.s] {
			rhsMin = prec
		}
		rhs := p.parseExpr(rhsMin)
		left = ExprNode{Op: t.s, Args: []any{left, rhs}}
	}
	return left
}

func (p *exprTextParser) parsePrefix() Expression {
	t := p.peek()
	// `-` directly before a number is a NEGATIVE LITERAL, not a unary-minus
	// node. Both print as `-1.3`, but only a literal reprints WITHOUT parens as
	// an operand (`x^-1.3`, not `x^(-1.3)`) — matching how ToAscii emits
	// negative constants (e.g. Arrhenius `(300/T)^-1.3`).
	if t.k == tkOp && t.s == "-" && p.peekAt(1).k == tkNum {
		p.next()
		return -p.next().n
	}
	if t.k == tkOp && (t.s == "-" || t.s == "not") {
		p.next()
		min := exprUnaryMinusMinPrec
		if t.s == "not" {
			min = exprNotMinPrec
		}
		return ExprNode{Op: t.s, Args: []any{p.parseExpr(min)}}
	}
	return p.parsePostfix()
}

// parsePostfix parses an atom, then postfix `[…]` indexing, then the derivative
// sugar `D(expr)/D<name>`.
func (p *exprTextParser) parsePostfix() Expression {
	node := p.parseAtom()
	for p.peek().k == tkLBracket {
		// A trailing `[semiring=…]` is an aggregate suffix, never an index —
		// leave it for parseAggregate's tail (it can follow a `key=`/`if`
		// expression).
		if nx := p.peekAt(1); nx.k == tkName && nx.s == "semiring" {
			break
		}
		p.next() // '['
		args := []any{node, p.parseExpr(0)}
		for p.peek().k == tkComma {
			p.next()
			args = append(args, p.parseExpr(0))
		}
		p.expect(tkRBracket, "']'")
		node = ExprNode{Op: "index", Args: args}
	}
	if n, ok := node.(ExprNode); ok && n.Op == "D" {
		if slash := p.peek(); slash.k == tkOp && slash.s == "/" {
			if nameTok := p.peekAt(1); nameTok.k == tkName && len(nameTok.s) > 1 && nameTok.s[0] == 'D' {
				p.next() // '/'
				p.next() // 'D<var>'
				wrt := nameTok.s[1:]
				return ExprNode{Op: "D", Wrt: &wrt, Args: n.Args}
			}
		}
	}
	return node
}

func (p *exprTextParser) parseAtom() Expression {
	t := p.next()
	switch t.k {
	case tkNum:
		return t.n
	case tkLParen:
		e := p.parseExpr(0)
		p.expect(tkRParen, "')'")
		return e
	case tkLBracket:
		// A leading `[` is a const array literal (`[1, 2, 3]`, `[[1, 2], [3, 4]]`).
		return ExprNode{Op: "const", Value: p.parseArrayRest(), Args: []any{}}
	case tkName:
		return p.parseNameAtom(t)
	}
	p.failAt("Expected a number, name, '(', or '['", t)
	return nil // unreachable
}

func (p *exprTextParser) parseNameAtom(t exprTok) Expression {
	if t.s == "true" {
		return ExprNode{Op: "true", Args: []any{}}
	}
	// `makearray(region = value, …)` — a piecewise-region array. Its arguments
	// are `[lo:hi, …] = value` pairs, not plain call args, so it needs its own
	// parse rather than the generic parseCall path.
	if t.s == "makearray" && p.peek().k == tkLParen {
		return p.parseMakearray()
	}
	if p.peek().k == tkLParen {
		return p.parseCall(t.s)
	}
	// Template application `name<binding = value, …>` (or empty `name<>`) →
	// apply_expression_template. The `< NAME =` / `< >` lookahead distinguishes
	// it from a `<` comparison (whose RHS is never a lone `=` nor an empty `>`).
	lt, lt1 := p.peek(), p.peekAt(1)
	if lt.k == tkOp && lt.s == "<" &&
		((lt1.k == tkOp && lt1.s == ">") || (lt1.k == tkName && p.peekAt(2).k == tkEq)) {
		return p.parseTemplate(t.s)
	}
	// Aggregate reduction `sym[out_idx] (expr) where {…} …`. Only when the
	// bracket is followed (past its match) by `(` — otherwise `sym[i]` is an
	// ordinary index into a variable that happens to be named `sum`/`max`/….
	if exprAggregateSyms[t.s] && p.peek().k == tkLBracket && p.aggregateAhead() {
		return p.parseAggregate(t.s)
	}
	// Arg-witness reduction `argmin[g] (expr) where {…}` (same `[…] (` shape).
	if exprArgWitnessSyms[t.s] && p.peek().k == tkLBracket && p.aggregateAhead() {
		return p.parseArgWitness(t.s)
	}
	return t.s // bare variable / species / qualified reference
}

// parseArrayRest parses the elements of an array literal after `[` up to and
// including `]`.
func (p *exprTextParser) parseArrayRest() []any {
	els := []any{}
	if p.peek().k != tkRBracket {
		for {
			if p.peek().k == tkLBracket {
				p.next()
				els = append(els, p.parseArrayRest()) // nested raw array
			} else {
				els = append(els, p.parseExpr(0)) // number / name / expression element
			}
			if p.peek().k == tkComma {
				p.next()
				continue
			}
			break
		}
	}
	p.expect(tkRBracket, "']'")
	return els
}

// exprNamedArg is one `key = value` call argument, kept in source order so
// diagnostics are deterministic.
type exprNamedArg struct {
	key string
	val Expression
}

func (p *exprTextParser) parseCall(name string) Expression {
	p.next() // '('
	args := []any{}
	named := []exprNamedArg{}
	if p.peek().k != tkRParen {
		for {
			// A `key = value` argument (e.g. concat `axis=0`); a lone `=` (not
			// `==`) after a bare name marks it.
			if p.peek().k == tkName && p.peekAt(1).k == tkEq {
				key := p.next().s
				p.next() // '='
				named = append(named, exprNamedArg{key, p.parseExpr(0)})
			} else {
				args = append(args, p.parseExpr(0))
			}
			if p.peek().k == tkComma {
				p.next()
				continue
			}
			break
		}
	}
	p.expect(tkRParen, "',' or ')' in call to "+name+"(...)")
	return p.makeParsedCall(name, args, named, p.peek().pos)
}

// ---------------------------------------------------------------------------
// aggregate / template (the reduction & array-query tier)
// ---------------------------------------------------------------------------

// aggregateAhead reports whether the `[` at the current position closes with a
// `]` immediately followed by `(` — the signature of an aggregate
// `sym[…] (expr)`, as opposed to plain indexing `sym[i]`. Scans balanced
// brackets; consumes nothing.
func (p *exprTextParser) aggregateAhead() bool {
	depth := 0
	for i := p.p; i < len(p.toks); i++ {
		switch p.toks[i].k {
		case tkLBracket:
			depth++
		case tkRBracket:
			depth--
			if depth == 0 {
				return i+1 < len(p.toks) && p.toks[i+1].k == tkLParen
			}
		}
	}
	return false
}

// parseAggregate parses an `aggregate` reduction (esm-spec §4.2) — the inverse
// of formatAggregate:
//
//	sym '[' out_idx ']' '(' expr ')' ('where' '{' ranges '}')? ('join' '(' … ')')?
//	('if' filter)? 'distinct'? ('key' '=' expr)? ('[' 'semiring' '=' name ']')?
//
// `sym` selects the default `reduce`; an explicit `[semiring=…]` supersedes it,
// as does a `join` (which implies `sum_product`). `args` is a derived dependency
// cache (see deriveAggregateArgs); ToAscii doesn't print it, so its exact value
// is reprint-neutral.
func (p *exprTextParser) parseAggregate(sym string) Expression {
	p.next() // '['
	outputIdx := []any{}
	if p.peek().k != tkRBracket {
		for {
			t := p.next()
			if t.k != tkName {
				p.failAt("Expected an output index name", t)
			}
			outputIdx = append(outputIdx, t.s)
			if p.peek().k == tkComma {
				p.next()
				continue
			}
			break
		}
	}
	p.expect(tkRBracket, "']' after aggregate output indices")
	p.expect(tkLParen, "'(' before the aggregate body")
	expr := p.parseExpr(0)
	p.expect(tkRParen, "')' after the aggregate body")

	ranges := map[string]any{}
	if p.atWord("where") {
		p.next()
		ranges = p.parseRanges()
	}
	join := []any{}
	if p.atWord("join") {
		p.next()
		join = p.parseJoin()
	}
	var filter Expression
	if p.atWord("if") {
		p.next()
		filter = p.parseExpr(0)
	}
	distinct := false
	if p.atWord("distinct") {
		p.next()
		distinct = true
	}
	var key Expression
	if p.atWord("key") && p.peekAt(1).k == tkEq {
		p.next() // 'key'
		p.next() // '='
		key = p.parseExpr(0)
	}
	var semiring *string
	if p.peek().k == tkLBracket && p.peekAt(1).k == tkName && p.peekAt(1).s == "semiring" {
		p.next() // '['
		p.next() // 'semiring'
		p.expect(tkEq, "'=' in [semiring=…]")
		nm := p.next()
		if nm.k != tkName {
			p.failAt("Expected a semiring name", nm)
		}
		s := nm.s
		semiring = &s
		p.expect(tkRBracket, "']' after [semiring=…]")
	}
	// A join with no explicit semiring is the sum-of-products contraction.
	if semiring == nil && len(join) > 0 {
		s := "sum_product"
		semiring = &s
	}

	node := ExprNode{Op: "aggregate", OutputIdx: outputIdx}
	if semiring != nil {
		node.Semiring = semiring
	} else if red, ok := exprReduceBySym[sym]; ok {
		node.Reduce = &red
	}
	node.Ranges = ranges
	if len(join) > 0 {
		node.Join = join
	}
	if filter != nil {
		node.Filter = filter
	}
	if distinct {
		d := true
		node.Distinct = &d
	}
	if key != nil {
		node.Key = key
	}
	node.Expr = expr
	node.Args = deriveAggregateArgs(expr, join, filter, key)
	return node
}

// parseArgWitness parses an `argmin` / `argmax` arg-witness (esm-spec §4.2) —
// the inverse of formatArgWitness:
// `op '[' arg ']' '(' expr ')' ('where' '{' ranges '}')?`. Like aggregate, its
// `args` operand cache isn't printed and is derived.
func (p *exprTextParser) parseArgWitness(op string) Expression {
	p.next() // '['
	at := p.next()
	if at.k != tkName {
		p.failAt("Expected the arg-witness index name", at)
	}
	p.expect(tkRBracket, "']' after the arg-witness index")
	p.expect(tkLParen, "'(' before the arg-witness body")
	expr := p.parseExpr(0)
	p.expect(tkRParen, "')' after the arg-witness body")
	ranges := map[string]any{}
	if p.atWord("where") {
		p.next()
		ranges = p.parseRanges()
	}
	arg := at.s
	return ExprNode{
		Op:     op,
		Args:   deriveAggregateArgs(expr, nil, nil, nil),
		Arg:    &arg,
		Ranges: ranges,
		Expr:   expr,
	}
}

// parseRanges parses a `{ k in <rhs>, … }` where-body into a ranges object.
func (p *exprTextParser) parseRanges() map[string]any {
	p.expect(tkLBrace, "'{' after where")
	ranges := map[string]any{}
	if p.peek().k != tkRBrace {
		for {
			kt := p.next()
			if kt.k != tkName {
				p.failAt("Expected a range index name", kt)
			}
			if !p.atWord("in") {
				p.fail("Expected 'in' in a range clause")
			}
			p.next() // 'in'
			ranges[kt.s] = p.parseRangeRhs()
			if p.peek().k == tkComma {
				p.next()
				continue
			}
			break
		}
	}
	p.expect(tkRBrace, "'}' to close the where clause")
	return ranges
}

// parseRangeRhs parses one range RHS: `set` → {from}; `set(a, b)` → {from, of};
// `lo:hi` → [lo, hi].
func (p *exprTextParser) parseRangeRhs() any {
	bound := p.parseExpr(0)
	if p.peek().k == tkColon {
		p.next()
		return []any{bound, p.parseExpr(0)}
	}
	if s, ok := bound.(string); ok {
		return map[string]any{"from": s}
	}
	// `k in set(of1, of2)` prints as a generic call → {from, of}.
	if n, ok := bound.(ExprNode); ok && exprOpIsNameLike(n.Op) {
		of := []any{}
		for _, a := range n.Args {
			s, ok := a.(string)
			if !ok {
				p.fail("range set arguments must be names")
			}
			of = append(of, s)
		}
		return map[string]any{"from": n.Op, "of": of}
	}
	p.fail("malformed range (expected a set name, set(of…), or lo:hi)")
	return nil // unreachable
}

// exprOpIsNameLike reports whether op starts with a letter or `_`, i.e. it is a
// call-shaped op rather than a symbolic operator.
func exprOpIsNameLike(op string) bool {
	if op == "" {
		return false
	}
	return exprNameRe.MatchString(op)
}

// parseJoin parses `( a=b, c=d ; e=f )` → [{on:[[a,b],[c,d]]}, {on:[[e,f]]}].
func (p *exprTextParser) parseJoin() []any {
	p.expect(tkLParen, "'(' after join")
	clauses := []any{}
	cur := []any{}
	if p.peek().k != tkRParen {
		for {
			a := p.next()
			if a.k != tkName {
				p.failAt("Expected a join key name", a)
			}
			p.expect(tkEq, "'=' in a join pair")
			b := p.next()
			if b.k != tkName {
				p.failAt("Expected a join key name", b)
			}
			cur = append(cur, []any{a.s, b.s})
			if p.peek().k == tkComma {
				p.next()
				continue
			}
			if p.peek().k == tkSemi {
				p.next()
				clauses = append(clauses, map[string]any{"on": cur})
				cur = []any{}
				continue
			}
			break
		}
	}
	clauses = append(clauses, map[string]any{"on": cur})
	p.expect(tkRParen, "')' to close join(…)")
	return clauses
}

// parseTemplate parses `name<binding = value, …>` (or the empty `name<>`) into
// an apply_expression_template node.
func (p *exprTextParser) parseTemplate(name string) Expression {
	p.next() // '<'
	bindings := map[string]any{}
	for {
		t := p.peek()
		if t.k == tkOp && t.s == ">" {
			break
		}
		kt := p.next()
		if kt.k != tkName {
			p.failAt("Expected a binding name in <…>", kt)
		}
		p.expect(tkEq, "'=' in a template binding")
		bindings[kt.s] = p.parseExpr(exprTemplateArgMin)
		if p.peek().k == tkComma {
			p.next()
			continue
		}
		break
	}
	p.expectOp(">", "'>' to close a template application")
	nm := name
	return ExprNode{Op: "apply_expression_template", Args: []any{}, Name: &nm, Bindings: bindings}
}

// parseMakearray parses a `makearray` piecewise-region array (esm-spec §4.2) —
// the inverse of formatStructuralOp's makearray case:
//
//	'makearray' '(' region '=' value ( ',' region '=' value )* ')'
//	region := '[' bound ':' bound ( ',' bound ':' bound )* ']'
//
// Each region is a list of per-dimension `lo:hi` bounds, and `value` is the
// expression that region evaluates to. A bound is any expression (a number, a
// name like `NLON`, or e.g. `NLON - 1`). `args` is always `[]` (the printer
// emits none); `regions` and `values` are positionally paired. Values are
// flattened to the canonical n-ary `+`/`*` form, like the top-level parse.
func (p *exprTextParser) parseMakearray() Expression {
	p.next() // '('
	regions := [][][]any{}
	values := []any{}
	if p.peek().k != tkRParen {
		for {
			p.expect(tkLBracket, "'[' to open a makearray region")
			region := [][]any{}
			if p.peek().k != tkRBracket {
				for {
					lo := p.parseExpr(0)
					p.expect(tkColon, "':' between a region's lo:hi bounds")
					hi := p.parseExpr(0)
					region = append(region, []any{flattenParsedExpr(lo), flattenParsedExpr(hi)})
					if p.peek().k == tkComma {
						p.next()
						continue
					}
					break
				}
			}
			p.expect(tkRBracket, "']' to close a makearray region")
			p.expect(tkEq, "'=' after a makearray region")
			regions = append(regions, region)
			values = append(values, flattenParsedExpr(p.parseExpr(0)))
			if p.peek().k == tkComma {
				p.next()
				continue
			}
			break
		}
	}
	p.expect(tkRParen, "')' to close makearray(...)")
	return ExprNode{Op: "makearray", Args: []any{}, Regions: regions, Values: values}
}

// ---------------------------------------------------------------------------
// call reconstruction
// ---------------------------------------------------------------------------

// exprArrayLiteral extracts the raw element list of a parsed `const` array
// literal, or fails.
func (p *exprTextParser) exprArrayLiteral(e Expression, pos int) []any {
	if n, ok := e.(ExprNode); ok && n.Op == "const" {
		if v, ok := n.Value.([]any); ok {
			return v
		}
	}
	panic(exprParseFailure{&ExpressionParseError{Message: "expected an array literal [ ... ]", Pos: pos}})
}

func (p *exprTextParser) noNamed(named []exprNamedArg, name string, pos int) {
	if len(named) > 0 {
		panic(exprParseFailure{&ExpressionParseError{
			Message: fmt.Sprintf("unexpected %s=… in %s(...)", named[0].key, name),
			Pos:     pos,
		}})
	}
}

func (p *exprTextParser) makeParsedCall(name string, args []any, named []exprNamedArg, pos int) Expression {
	lookup := func(k string) (Expression, bool) {
		for _, n := range named {
			if n.key == k {
				return n.val, true
			}
		}
		return nil, false
	}

	// A dotted callee is a closed function — an `fn` node carrying the name.
	if strings.Contains(name, ".") {
		p.noNamed(named, name, pos)
		nm := name
		return ExprNode{Op: "fn", Name: &nm, Args: args}
	}
	// Call-shaped structural ops: reconstruct their non-`args` fields from the
	// positional / named arguments ToAscii renders.
	if name == "integral" && len(args) == 4 {
		if v, ok := args[1].(string); ok {
			p.noNamed(named, name, pos)
			return ExprNode{Op: "integral", Args: []any{args[0]}, Var: &v, Lower: args[2], Upper: args[3]}
		}
	}
	if name == "reshape" && len(args) == 2 {
		p.noNamed(named, name, pos)
		return ExprNode{Op: "reshape", Args: []any{args[0]}, Shape: p.exprArrayLiteral(args[1], pos)}
	}
	if name == "transpose" && (len(args) == 1 || len(args) == 2) {
		p.noNamed(named, name, pos)
		if len(args) == 1 {
			return ExprNode{Op: "transpose", Args: []any{args[0]}}
		}
		return ExprNode{Op: "transpose", Args: []any{args[0]}, Perm: p.exprArrayLiteral(args[1], pos)}
	}
	if name == "concat" {
		axis, ok := lookup("axis")
		if !ok {
			panic(exprParseFailure{&ExpressionParseError{Message: "concat(...) requires axis=<n>", Pos: pos}})
		}
		return ExprNode{Op: "concat", Args: args, Axis: axis}
	}
	// Geometry area query `polygon_intersection_area(a, b, manifold=<name>)`.
	// (Its sibling `intersect_polygon` stays refused: its `id` isn't printed.)
	if name == "polygon_intersection_area" {
		manifold, _ := lookup("manifold")
		m, ok := manifold.(string)
		if !ok {
			panic(exprParseFailure{&ExpressionParseError{
				Message: name + "(...) requires manifold=<name>", Pos: pos,
			}})
		}
		for _, n := range named {
			if n.key != "manifold" {
				panic(exprParseFailure{&ExpressionParseError{
					Message: fmt.Sprintf("unexpected %s=… in %s(...)", n.key, name),
					Pos:     pos,
				}})
			}
		}
		return ExprNode{Op: "polygon_intersection_area", Args: args, Manifold: &m}
	}
	p.noNamed(named, name, pos)
	if exprStructuralRefusals[name] {
		panic(exprParseFailure{&ExpressionParseError{
			Message: fmt.Sprintf("'%s' is not yet expressible in the text form", name),
			Pos:     pos,
		}})
	}
	if name == "D" {
		// Friendly form D(expr, t) — wrt as an explicit second arg — in addition
		// to the ToAscii form D(expr)/Dt handled in parsePostfix. Any other arity
		// is a nonstandard / discretization D (e.g. with boundary conditions)
		// that the printer emits via the generic call fallback; keep it a
		// generic call.
		if len(args) == 2 {
			if wrt, ok := args[1].(string); ok {
				return ExprNode{Op: "D", Wrt: &wrt, Args: []any{args[0]}}
			}
		}
		if len(args) == 1 {
			return ExprNode{Op: "D", Args: args}
		}
	}
	return ExprNode{Op: name, Args: args}
}

// ---------------------------------------------------------------------------
// derived operand cache
// ---------------------------------------------------------------------------

// deriveAggregateArgs is a best-effort reconstruction of an aggregate's `args`
// — its array operands. ToAscii does NOT print `args` (it's a derived
// dependency cache), and the authoritative set excludes parameter arrays by
// *declared role*, which needs the variable table. From the printed structure
// alone we approximate it as: the base of every `index(…)` in the body / filter
// / key, plus the names in `join` clauses, in first-appearance order. This is
// reprint-neutral (the printer ignores it) and a dependency superset (safe for
// graph / dead-code analysis); an editor holding the symbol table should
// recompute it on save.
func deriveAggregateArgs(expr Expression, join []any, filter, key Expression) []any {
	out := []any{}
	seen := map[string]bool{}
	add := func(n string) {
		if !seen[n] {
			seen[n] = true
			out = append(out, n)
		}
	}
	var bases func(e any)
	bases = func(e any) {
		switch v := e.(type) {
		case nil:
			return
		case ExprNode:
			if v.Op == "index" && len(v.Args) > 0 {
				if b, ok := v.Args[0].(string); ok {
					add(b)
				}
			}
			for _, child := range exprNodeChildValues(v) {
				bases(child)
			}
		case *ExprNode:
			if v != nil {
				bases(*v)
			}
		case []any:
			for _, c := range v {
				bases(c)
			}
		case [][]any:
			for _, c := range v {
				bases(c)
			}
		case [][][]any:
			for _, c := range v {
				bases(c)
			}
		case map[string]any:
			for _, k := range sortedKeys(v) {
				bases(v[k])
			}
		case map[string]Expression:
			for _, k := range sortedKeys(v) {
				bases(v[k])
			}
		}
	}
	bases(expr)
	for _, c := range join {
		cm, ok := c.(map[string]any)
		if !ok {
			continue
		}
		on, _ := cm["on"].([]any)
		for _, pair := range on {
			pp, ok := pair.([]any)
			if !ok {
				continue
			}
			for _, side := range pp {
				if s, ok := side.(string); ok {
					add(s)
				}
			}
		}
	}
	bases(filter)
	bases(key)
	return out
}

// exprNodeChildValues lists a node's expression-bearing sub-values in a stable
// order, so deriveAggregateArgs walks the whole subtree the way the TypeScript
// oracle's generic object walk does.
func exprNodeChildValues(n ExprNode) []any {
	children := make([]any, 0, len(n.Args)+8)
	for _, a := range n.Args {
		children = append(children, a)
	}
	children = append(children,
		n.Value, n.Expr, n.Filter, n.Key, n.Lower, n.Upper, n.Output, n.Axis)
	for _, v := range n.Values {
		children = append(children, v)
	}
	children = append(children, n.Regions)
	for _, v := range n.Shape {
		children = append(children, v)
	}
	for _, v := range n.Perm {
		children = append(children, v)
	}
	for _, v := range n.Join {
		children = append(children, v)
	}
	if n.Bindings != nil {
		children = append(children, n.Bindings)
	}
	if n.Ranges != nil {
		children = append(children, n.Ranges)
	}
	if n.Attrs != nil {
		children = append(children, n.Attrs)
	}
	if n.TableAxes != nil {
		children = append(children, n.TableAxes)
	}
	return children
}

// ---------------------------------------------------------------------------
// normalization
// ---------------------------------------------------------------------------

// flattenParsedExpr flattens nested same-op `+` / `*` in `args` into the n-ary
// form the printer emits and authored ASTs use: `a + b + c` → one `+` with three
// args, not left-nested pairs. (`-` and `/` are binary and stay as parsed.)
// Non-`args` expression fields (integral bounds, aggregate bodies, …) are left
// as parsed, matching the TypeScript oracle.
func flattenParsedExpr(e Expression) Expression {
	n, ok := e.(ExprNode)
	if !ok {
		return e
	}
	args := make([]any, len(n.Args))
	for i, a := range n.Args {
		args[i] = flattenParsedExpr(a)
	}
	if n.Op == "+" || n.Op == "*" {
		out := make([]any, 0, len(args))
		for _, a := range args {
			if an, ok := a.(ExprNode); ok && an.Op == n.Op && an.Wrt == nil {
				out = append(out, an.Args...)
			} else {
				out = append(out, a)
			}
		}
		n.Args = out
		return n
	}
	n.Args = args
	return n
}

// ---------------------------------------------------------------------------
// public API
// ---------------------------------------------------------------------------

// ParseExpression parses a single expression string into an AST expression —
// the inverse of ToAscii. It returns an error wrapping *ExpressionParseError on
// malformed input or on an operator with no text surface yet.
func ParseExpression(src string) (Expression, error) {
	toks, err := exprTokenize(src)
	if err != nil {
		return nil, err
	}
	return runExprParser(&exprTextParser{toks: toks})
}

// ParseEquation parses `lhs = rhs` into an Equation. The top-level separator is
// a LONE `=`; `==` (and `>=` / `<=` / `!=`) remain comparison operators within
// either side.
func ParseEquation(src string) (*Equation, error) {
	toks, err := exprTokenize(src)
	if err != nil {
		return nil, err
	}
	depth := 0
	angle := 0 // template `name<binding = value>` — its `=` is not a separator
	split := -1
	for i := 0; i < len(toks) && split == -1; i++ {
		t := toks[i]
		switch {
		case t.k == tkLParen || t.k == tkLBracket || t.k == tkLBrace:
			depth++
		case t.k == tkRParen || t.k == tkRBracket || t.k == tkRBrace:
			depth--
		case t.k == tkOp && t.s == "<" && i+2 < len(toks) &&
			toks[i+1].k == tkName && toks[i+2].k == tkEq:
			angle++
		case t.k == tkOp && t.s == ">" && angle > 0:
			angle--
		// The FIRST top-level lone `=` splits lhs/rhs; a later binding / `key=`
		// `=` (legitimately present in an aggregate or template on the rhs) is
		// left intact.
		case t.k == tkEq && depth == 0 && angle == 0:
			split = i
		}
	}
	if split == -1 {
		return nil, &ExpressionParseError{
			Message: "Expected 'lhs = rhs'",
			Pos:     toks[len(toks)-1].pos,
		}
	}
	lhsToks := make([]exprTok, 0, split+1)
	lhsToks = append(lhsToks, toks[:split]...)
	lhsToks = append(lhsToks, exprTok{k: tkEOF, pos: toks[split].pos})

	lhs, err := runExprParser(&exprTextParser{toks: lhsToks})
	if err != nil {
		return nil, err
	}
	rhs, err := runExprParser(&exprTextParser{toks: toks[split+1:]})
	if err != nil {
		return nil, err
	}
	return &Equation{LHS: lhs, RHS: rhs}, nil
}

// runExprParser drives p.parseEntry, converting the parser's internal panic
// unwind back into a returned *ExpressionParseError.
func runExprParser(p *exprTextParser) (expr Expression, err error) {
	defer func() {
		if r := recover(); r != nil {
			f, ok := r.(exprParseFailure)
			if !ok {
				panic(r)
			}
			expr, err = nil, f.err
		}
	}()
	return p.parseEntry(), nil
}
