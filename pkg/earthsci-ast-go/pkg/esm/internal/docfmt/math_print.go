package docfmt

// The printer: expressions to tokens. Port of
// formal/Esm/Document/Math/Print.lean (Rust: document/math/print.rs); prefix
// `pr`.
//
// prPr prints an expression with its precedence level; Out.at wraps it for a
// position that needs a level at least L. The levels, loosest first (spec
// §4.1.1):
//
//	1  `or` chain
//	2  `and` chain
//	3  a comparison
//	4  `+` chain, binary `-`
//	5  `*` chain, unary `-`
//	6  `not`; a derivative applied to a parenthesized operand
//	7  Typst fraction; a negative literal and a quantity
//	8  power
//	9  index
//	10 atoms
//
// Which notation a node gets is decided from its exact JSON shape; anything
// without a native or call notation prints in the generic escape form.

import (
	"slices"
	"strconv"

	"github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm/internal/unitspell"
)

// ## Text pieces

// prEscSet is `Math.escSet`: the characters escaped by a backslash inside
// `\mathit{}`, `\operatorname{}`, `\esm{}` and a name subscript's `\mathrm{}`.
func prEscSet(c rune) bool {
	switch c {
	case '_', '^', '\\', '{', '}':
		return true
	}
	return false
}

// prEscT is `Math.escT`: escape the text of `\mathit{}` and the like.
func prEscT(cs []rune) []rune {
	out := make([]rune, 0, len(cs))
	for _, c := range cs {
		if prEscSet(c) {
			out = append(out, '\\')
		}
		out = append(out, c)
	}
	return out
}

// prUnescT is `Math.unescT`: undo prEscT (drop the backslash of every `\c`
// pair).
func prUnescT(cs []rune) []rune {
	out := make([]rune, 0, len(cs))
	for len(cs) > 0 {
		if cs[0] == '\\' && len(cs) >= 2 {
			out = append(out, cs[1])
			cs = cs[2:]
			continue
		}
		out = append(out, cs[0])
		cs = cs[1:]
	}
	return out
}

// prKeySpecial is `Math.keySpecial`.
func prKeySpecial(c rune) bool {
	switch c {
	case '$', '%', '&', '#', '~', '^', '\\':
		return true
	}
	return false
}

// prDig3 is `Math.dig3`: three decimal digits.
func prDig3(n uint32) []rune {
	return []rune{numDigitChar(byte(n / 100 % 10)), numDigitChar(byte(n / 10 % 10)), numDigitChar(byte(n % 10))}
}

// prEscK is `Math.escK`: escape a field key for `\mathrm{}`.
func prEscK(cs []rune) []rune {
	var out []rune
	for _, c := range cs {
		switch {
		case prKeySpecial(c):
			out = append(out, []rune("{\\char")...)
			out = append(out, prDig3(uint32(c))...)
			out = append(out, '}')
		case c == '_' || c == '{' || c == '}':
			out = append(out, '\\', c)
		default:
			out = append(out, c)
		}
	}
	return out
}

// prCharDigitNat is `Number.charDigit`: c.toNat - 48, saturating (any
// character, not only a digit).
func prCharDigitNat(c rune) uint64 {
	if c < 48 {
		return 0
	}
	return uint64(c - 48)
}

// prCharOfNat is Lean's `Char.ofNat`: an invalid code point is '\0'.
func prCharOfNat(n uint64) rune {
	if n > 0x10FFFF || (n >= 0xD800 && n <= 0xDFFF) {
		return 0
	}
	return rune(n)
}

// prUnescK is `Math.unescK`: undo prEscK.
func prUnescK(cs []rune) []rune {
	var out []rune
	for len(cs) > 0 {
		if len(cs) >= 10 && hasPrefix(cs, "{\\char") && cs[9] == '}' {
			out = append(out, prCharOfNat(100*prCharDigitNat(cs[6])+10*prCharDigitNat(cs[7])+prCharDigitNat(cs[8])))
			cs = cs[10:]
			continue
		}
		if cs[0] == '\\' && len(cs) >= 2 {
			out = append(out, cs[1])
			cs = cs[2:]
			continue
		}
		out = append(out, cs[0])
		cs = cs[1:]
	}
	return out
}

// ## The printing context

// Ctx is `Math.Ctx`: the surface and the symbol table.
type Ctx struct {
	sf Sf
	s  *Sym
	// lim is the read's state (limits.go); nil when printing.
	lim *Lim
}

// prRpG is `Math.rpG`: the closing token of a grouping parenthesis.
func prRpG(sf Sf) Tok {
	if sf == SfLatex {
		return tKw(KwRpg)
	}
	return tKw(KwRp)
}

// prGrp is `Math.grp`: grouping parentheses.
func prGrp(sf Sf, ts []Tok) []Tok {
	out := make([]Tok, 0, len(ts)+2)
	out = append(out, tKw(KwLpg))
	out = append(out, ts...)
	return append(out, prRpG(sf))
}

// prSepBy is `Math.sepBy`: items joined by a separator.
func prSepBy(sep []Tok, xs [][]Tok) []Tok {
	var out []Tok
	for i, x := range xs {
		if i > 0 {
			out = append(out, sep...)
		}
		out = append(out, x...)
	}
	return out
}

// cat concatenates token lists.
func cat(parts ...[]Tok) []Tok {
	n := 0
	for _, p := range parts {
		n += len(p)
	}
	out := make([]Tok, 0, n)
	for _, p := range parts {
		out = append(out, p...)
	}
	return out
}

// kws is a token list of keywords.
func kws(ks ...Kw) []Tok {
	out := make([]Tok, len(ks))
	for i, k := range ks {
		out[i] = tKw(k)
	}
	return out
}

// ## Names

// prBaseTok is `Math.baseTok`: a single letter or a Greek name as a token.
func prBaseTok(g []rune) Tok {
	if len(g) == 1 {
		return tLetter(g[0])
	}
	return tGreek(string(g))
}

// prSubTxt is `Math.subTxt`: the subscript text of a name, upright.
func prSubTxt(sf Sf, r []rune) []Tok {
	if sf == SfLatex {
		return []Tok{tKw(KwUs), tKw(KwLb), tRm(string(prEscT(r))), tKw(KwRb)}
	}
	return []Tok{tKw(KwUs), tKw(KwLpg), tUps([]UpsPair{{string(r), ""}}), tKw(KwRp)}
}

// prFormulaRaw is `Math.formulaRaw`: the raw `\mathrm{}` content of a formula
// (counts as `_{n}`).
func prFormulaRaw(g []rune) []rune {
	var out []rune
	for _, p := range exprPieces(g) {
		out = append(out, p.a...)
		if len(p.b) > 0 {
			out = append(out, '_', '{')
			out = append(out, p.b...)
			out = append(out, '}')
		}
	}
	return out
}

// prFormTok is `Math.formTok`: a formula name.
func prFormTok(sf Sf, g []rune) Tok {
	if sf == SfLatex {
		return tRm(string(prFormulaRaw(g)))
	}
	var ps []UpsPair
	for _, p := range exprPieces(g) {
		ps = append(ps, UpsPair{string(p.a), string(p.b)})
	}
	return tUps(ps)
}

// prSegToks is `Math.segToks`: one segment of a name, by its shape.
func prSegToks(sf Sf, g []rune) []Tok {
	if exprIsSingle(g) {
		return []Tok{prBaseTok(g)}
	}
	if b, r, ok := exprSubParts(g); ok {
		return append([]Tok{prBaseTok(b)}, prSubTxt(sf, r)...)
	}
	if exprIsFormula(g) {
		return []Tok{prFormTok(sf, g)}
	}
	return []Tok{tIt(string(g))}
}

// prExplicitName is `Math.explicitName`: an undeclared `e` or `d` prints in the
// explicit form.
func prExplicitName(s *Sym, n string) bool {
	return (n == "e" || n == "d") && !slices.Contains(s.Names, n)
}

// prNameToks is `Math.nameToks`: the tokens of a name.
func prNameToks(c Ctx, s string) []Tok {
	if prExplicitName(c.s, s) {
		return []Tok{tIt(s)}
	}
	segs := exprSplitDots([]rune(s))
	xs := make([][]Tok, len(segs))
	for i, g := range segs {
		xs[i] = prSegToks(c.sf, g)
	}
	return prSepBy([]Tok{tKw(KwSdot)}, xs)
}

// prPlainLast is `Math.plainLast`: the last segment of a name prints with no
// subscript.
func prPlainLast(s string) bool {
	segs := exprSplitDots([]rune(s))
	g := segs[len(segs)-1]
	if exprIsSingle(g) {
		return true
	}
	_, _, sub := exprSubParts(g)
	return !sub && !exprIsFormula(g)
}

// ## JSON inside escape nodes (LaTeX)

// prJsonToks is `Math.jsonToks`.
func prJsonToks(j Json) []Tok {
	var out []Tok
	return prJsonToksInto(j, out)
}

func prJsonToksInto(j Json, out []Tok) []Tok {
	switch v := j.(type) {
	case nil:
		return append(out, tWord("null"))
	case bool:
		if v {
			return append(out, tWord("true"))
		}
		return append(out, tWord("false"))
	case JNum:
		return append(out, tNum(v))
	case string:
		return append(out, tJstr(v))
	case []Json:
		out = append(out, tKw(KwLbk))
		for i, x := range v {
			if i > 0 {
				out = append(out, tKw(KwComma))
			}
			out = prJsonToksInto(x, out)
		}
		return append(out, tKw(KwRbk))
	case Obj:
		out = append(out, tKw(KwLb))
		for i, kv := range v {
			if i > 0 {
				out = append(out, tKw(KwComma))
			}
			out = append(out, tJstr(kv.K), tKw(KwColon))
			out = prJsonToksInto(kv.V, out)
		}
		return append(out, tKw(KwRb))
	}
	return out
}

// ## Operator tables

// opKw is an operator name and its keyword.
type opKw struct {
	o string
	k Kw
}

// prFnKw is `Math.fnKw`: unary functions with a native spelling, and their
// keyword.
var prFnKw = []opKw{
	{"exp", KwExp}, {"log", KwLn}, {"sin", KwSin}, {"cos", KwCos}, {"tan", KwTan},
	{"asin", KwAsin}, {"acos", KwAcos}, {"atan", KwAtan}, {"sinh", KwSinh}, {"cosh", KwCosh},
	{"tanh", KwTanh},
}

// prCmpKw is `Math.cmpKw`: comparisons and their token.
var prCmpKw = []opKw{
	{"<", KwLt}, {"<=", KwLe}, {">", KwGt}, {">=", KwGe}, {"==", KwEq}, {"!=", KwNe},
}

// prCallOps is `Math.callOps`: core operators in the call form.
var prCallOps = []string{"sign", "atan2", "asinh", "acosh", "atanh", "Pre", "enum"}

// prFieldCallOps is `Math.fieldCallOps`: core operators with no notation of
// their own that print in the call form, their fields as named arguments after
// `;` (when no field annotates the node).
var prFieldCallOps = []string{"broadcast", "reshape", "transpose", "concat", "faq", "makearray", "const"}

// prReservedOpn is `Math.reservedOpn`: names `\operatorname{…}` never means a
// template or an open operator by.
func prReservedOpn(n string) bool {
	return slices.Contains(prCallOps, n) || n == "D" || n == "neg" || n == "pow" ||
		slices.Contains(exprRemovedOps, n)
}

// prCoreOps is `Math.coreOps` (`coreOpNames` of `Notation`).
var prCoreOps = map[string]bool{
	"+": true, "-": true, "*": true, "/": true, "^": true, "pow": true, "neg": true,
	"<": true, "<=": true, ">": true, ">=": true, "==": true, "!=": true, "and": true,
	"or": true, "not": true, "true": true, "false": true, "ifelse": true, "exp": true,
	"log": true, "log10": true, "sqrt": true, "abs": true, "sign": true, "floor": true,
	"ceil": true, "sin": true, "cos": true, "tan": true, "asin": true, "acos": true,
	"atan": true, "sinh": true, "cosh": true, "tanh": true, "asinh": true, "acosh": true,
	"atanh": true, "atan2": true, "min": true, "max": true, "D": true, "ic": true,
	"Pre": true, "enum": true, "const": true, "faq": true, "makearray": true,
	"index": true, "broadcast": true, "reshape": true, "transpose": true, "concat": true,
	"apply_operator": true,
}

// prOpnOk is `Math.opnOK`: a name `\operatorname{…}` can carry: identifier
// characters and dots.
func prOpnOk(s string) bool {
	for i, c := range s {
		if i == 0 {
			if !exprIsIdStart(c) {
				return false
			}
		} else if !exprIsIdChar(c) && c != '.' {
			return false
		}
	}
	return s != ""
}

// prCallFormOk is `Math.callFormOK`: an operator prints in the call form: an
// open operator, or a core operator of prFieldCallOps none of whose fields
// annotates it.
func prCallFormOk(o string, fs Obj) bool {
	if !prCoreOps[o] {
		return true
	}
	if !slices.Contains(prFieldCallOps, o) {
		return false
	}
	for _, kv := range fs {
		if slices.Contains(NodeAnnotations, kv.K) {
			return false
		}
	}
	return true
}

// prOpnCallOk is the test the printer's open-operator form makes of a node
// with operator o and fields fs (besides `args` and `op`) under the symbol
// table s, apart from its field keys (prKeyOk): a core operator has a call
// form and no annotation field (prCallFormOk), a name `\operatorname{…}` carries, and no
// template o in scope. The parser's call form reads only nodes that pass it.
func prOpnCallOk(s *Sym, o string, fs Obj) bool {
	if !prCallFormOk(o, fs) || !prOpnOk(o) {
		return false
	}
	_, isTemplate := prTparams(s, o)
	return !isTemplate
}

// prMathKeys is `Math.mathKeys`: the fields of a core operator in the call form
// that hold an expression; the others print as JSON, even a string that is a
// name.
var prMathKeys = []string{"expr", "filter", "key"}

// prMathField is `Math.mathField`: a field of a call-form node prints as math:
// its value is an expression and, for a core operator, the field holds one.
func prMathField(o string, kv KV) bool {
	return exprIsE(kv.V) && (!prCoreOps[o] || slices.Contains(prMathKeys, kv.K))
}

// prKeyOk is `Math.keyOK`: a field key printed upright in a call: an
// identifier.
func prKeyOk(s string) bool { return exprSegOk([]rune(s)) }

// prInsKv is `Math.insKV`: sorted insertion by key.
func prInsKv(kv KV, l Obj) Obj {
	i := len(l)
	for j, e := range l {
		if kv.K < e.K {
			i = j
			break
		}
	}
	out := make(Obj, 0, len(l)+1)
	out = append(out, l[:i]...)
	out = append(out, kv)
	return append(out, l[i:]...)
}

// prFieldsOf is `Math.fieldsOf`: the fields of a node other than `op` and
// `args`.
func prFieldsOf(kvs Obj) Obj {
	out := Obj{}
	for _, kv := range kvs {
		if kv.K != "op" && kv.K != "args" {
			out = append(out, kv)
		}
	}
	return out
}

// prMkNode is `Math.mkNode`: a node from its operator, operands and other
// fields.
func prMkNode(o string, args []Json, fs Obj) Json {
	return prInsKv(KV{"args", args}, prInsKv(KV{"op", o}, fs))
}

// prNode is `Math.node`: the plain two-field node.
func prNode(o string, args []Json) Json {
	return Obj{{"args", args}, {"op", o}}
}

// prIsNegNum is `Math.isNegNum`.
func prIsNegNum(j Json) bool {
	n, ok := j.(JNum)
	return ok && surfNegNum(n)
}

// prSimpleTok is `Math.simpleTok`: Typst exponent and subscript tokens that
// need no parentheses.
func prSimpleTok(t Tok) bool {
	switch t.K {
	case TNum:
		if !t.N.Dec {
			return t.N.I >= 0
		}
		return !t.N.Neg && t.N.E10 >= -4 && t.N.E10 <= 5
	case TLetter, TGreek:
		return true
	}
	return false
}

// prStartsNum is `Math.startsNum`.
func prStartsNum(ts []Tok) bool { return len(ts) > 0 && ts[0].K == TNum }

// prTparams is `Math.tparams`: the template parameter list, when the symbol
// table knows it.
func prTparams(s *Sym, n string) ([]string, bool) {
	for _, t := range s.Templates {
		if t.Name == n {
			return t.Params, true
		}
	}
	return nil, false
}

func nodupStrings(xs []string) bool {
	for i, x := range xs {
		if slices.Contains(xs[:i], x) {
			return false
		}
	}
	return true
}

// prPositional is `Math.positional`: positional template arguments.
func prPositional(s *Sym, n string, bs Obj) ([]string, bool) {
	ps, ok := prTparams(s, n)
	if !ok || !nodupStrings(ps) || len(ps) != len(bs) {
		return nil, false
	}
	for _, p := range ps {
		if _, ok := exprLook(p, bs); !ok {
			return nil, false
		}
	}
	return ps, true
}

// prRawB is `Math.rawB`: balanced text up to the `}` that closes depth 0; `\x`
// is one unit.
func prRawB(d int, cs []rune) ([]rune, []rune, bool) {
	var out []rune
	for {
		if len(cs) == 0 {
			return nil, nil, false
		}
		switch c := cs[0]; {
		case c == '\\' && len(cs) >= 2:
			out = append(out, '\\', cs[1])
			cs = cs[2:]
		case c == '}':
			if d == 0 {
				return out, cs[1:], true
			}
			d--
			out = append(out, '}')
			cs = cs[1:]
		case c == '{':
			d++
			out = append(out, '{')
			cs = cs[1:]
		default:
			out = append(out, c)
			cs = cs[1:]
		}
	}
}

// prBalOk is `Math.balOK`: raw text that prRawB reads back whole.
func prBalOk(raw []rune) bool {
	cs := append(append([]rune(nil), raw...), '}')
	r, rest, ok := prRawB(0, cs)
	return ok && string(r) == string(raw) && len(rest) == 0
}

// prFactorsOf is `Math.factorsOf`: the two-sided factor list of a units string
// ([] when it does not parse), read with the binding's unit-spelling parser:
// the factors normalized per side (each symbol once with its exponents summed,
// zero sums dropped, sorted by symbol), positive exponents first.
func prFactorsOf(u string) []Factor { return unitspell.TwoSided(u) }

// prUnitsOk is `Math.unitsOK`: the units of a quantity print typeset.
func prUnitsOk(sf Sf, u string) bool {
	l := prFactorsOf(u)
	if len(l) == 0 || unitspell.Spell(l) != u {
		return false
	}
	for _, f := range l {
		if !unitsSymOk(f.Sym) || f.Exp.Sign() == 0 {
			return false
		}
	}
	if sf == SfLatex {
		back, ok := unitsParseLatex(unitsLatex(l))
		return ok && factorsEqual(back, l) && prBalOk(unitsLatexBody(l))
	}
	nd := append(unitsNumFactors(l), unitsDenFactors(l)...)
	return factorsEqual(nd, l)
}

// ## The printer

// prWrap is `Math.wrap`: wrap a printed form for a position needing level l.
func prWrap(sf Sf, l, lvl int, ts []Tok) []Tok {
	if l <= lvl {
		return ts
	}
	return prGrp(sf, ts)
}

// prMulToks is `Math.mulToks`: a `*` chain: juxtaposition, `\cdot` before a
// factor that starts with a number.
func prMulToks(xs [][]Tok) []Tok {
	var out []Tok
	for i, y := range xs {
		if i > 0 && prStartsNum(y) {
			out = append(out, tKw(KwCdot))
		}
		out = append(out, y...)
	}
	return out
}

// OpKind is the kind tag of OpK.
type OpKind uint8

// The printer kinds of a plain node's operator (`Math.OpK`).
const (
	OpMinus OpKind = iota
	OpDiv
	OpPow
	OpLnot
	OpTru
	OpFls
	OpIte
	OpIc
	OpIndex
	OpCmp
	OpUn
	OpPlus
	OpTimes
	OpLand
	OpLor
	OpMm
	// OpNab: one of the four defined operators with a `\nabla` form (grad,
	// div, laplacian, curl); OpK.N names it.
	OpNab
	OpCall
	OpOther
)

// OpK is `Math.OpK`: the kind, and the keyword of OpCmp, OpUn and OpMm.
type OpK struct {
	K OpKind
	W Kw
	N string
}

// prUnKw is `Math.unKw`: unary functions with a native spelling (`log10` is
// `\log_{10}`).
func prUnKw(o string) (Kw, bool) {
	for _, p := range prFnKw {
		if p.o == o {
			return p.k, true
		}
	}
	switch o {
	case "log10":
		return KwLog, true
	case "sqrt":
		return KwSqrt, true
	case "abs":
		return KwAbs, true
	case "floor":
		return KwFloor, true
	case "ceil":
		return KwCeil, true
	}
	return 0, false
}

// prKindTable is `Math.kindTable`: the plain-node operators with their own
// notation.
var prKindTable = map[string]OpK{
	"-": {K: OpMinus}, "/": {K: OpDiv}, "^": {K: OpPow}, "not": {K: OpLnot},
	"true": {K: OpTru}, "false": {K: OpFls}, "ifelse": {K: OpIte}, "ic": {K: OpIc},
	"index": {K: OpIndex}, "+": {K: OpPlus}, "*": {K: OpTimes}, "and": {K: OpLand},
	"or": {K: OpLor}, "min": {K: OpMm, W: KwMin}, "max": {K: OpMm, W: KwMax},
	"grad": {K: OpNab, N: "grad"}, "div": {K: OpNab, N: "div"},
	"laplacian": {K: OpNab, N: "laplacian"}, "curl": {K: OpNab, N: "curl"},
}

// prKindOf is `Math.kindOf`.
func prKindOf(o string) OpK {
	for _, p := range prCmpKw {
		if p.o == o {
			return OpK{K: OpCmp, W: p.k}
		}
	}
	if k, ok := prUnKw(o); ok {
		return OpK{K: OpUn, W: k}
	}
	if k, ok := prKindTable[o]; ok {
		return k
	}
	if slices.Contains(prCallOps, o) {
		return OpK{K: OpCall}
	}
	return OpK{K: OpOther}
}

// Out is `Math.Out`: the printed form of an expression and its level. crow is
// the form as the last rows of a `cases` block; nil means the mkOut default
// (the form, `&`, `otherwise`), built on demand.
type Out struct {
	lvl  int
	toks []Tok
	crow []Tok
}

// prMkOut is `Math.mkOut`.
func prMkOut(l int, t []Tok) Out { return Out{lvl: l, toks: t} }

// Crow is the form as the last rows of a `cases` block.
func (o Out) Crow() []Tok {
	if o.crow != nil {
		return o.crow
	}
	return cat(o.toks, []Tok{tKw(KwAmp), tTxt("otherwise")})
}

// at is `Math.Out.at`.
func (o Out) at(sf Sf, l int) []Tok { return prWrap(sf, l, o.lvl, o.toks) }

// prEscToks is `Math.escToks`: the escape form: LaTeX `\esm{op}{fields}{args}`,
// Typst `esm.node("op", #(fields), args)`.
func prEscToks(sf Sf, o string, fs Obj, args [][]Tok) []Tok {
	if sf == SfLatex {
		out := []Tok{tEsc(o), tKw(KwLb)}
		out = append(out, prJsonToks(fs)...)
		out = append(out, tKw(KwRb), tKw(KwLb))
		out = append(out, prSepBy([]Tok{tKw(KwComma)}, args)...)
		return append(out, tKw(KwRb))
	}
	out := []Tok{tKw(KwEsmnode), tKw(KwLp), tTxt(o), tKw(KwComma), tCode(fs)}
	for _, a := range args {
		out = append(out, tKw(KwComma))
		out = append(out, a...)
	}
	return append(out, tKw(KwRp))
}

// prLpC is `Math.lpC`: the call parenthesis.
func prLpC(Sf) Tok { return tKw(KwLp) }

// prCallToks is `Math.callToks`: `name(args)` with call parentheses.
func prCallToks(sf Sf, head []Tok, args [][]Tok) []Tok {
	out := append([]Tok(nil), head...)
	out = append(out, prLpC(sf))
	out = append(out, prSepBy([]Tok{tKw(KwComma)}, args)...)
	return append(out, tKw(KwRp))
}

// prUnToks is `Math.unToks`: a unary function applied to the printed operand t.
func prUnToks(sf Sf, k Kw, t []Tok) []Tok {
	if sf == SfLatex {
		switch k {
		case KwSqrt:
			return cat(kws(KwSqrt, KwLb), t, kws(KwRb))
		case KwAbs:
			return cat(kws(KwLabs), t, kws(KwRabs))
		case KwFloor:
			return cat(kws(KwLfloor), t, kws(KwRfloor))
		case KwCeil:
			return cat(kws(KwLceil), t, kws(KwRceil))
		case KwLog:
			out := []Tok{tKw(KwLog), tKw(KwUs), tKw(KwLb), tNum(IntNum(10)), tKw(KwRb)}
			return append(out, prCallToks(sf, nil, [][]Tok{t})...)
		}
	} else if k == KwLog {
		out := []Tok{tKw(KwLog), tKw(KwUs), tNum(IntNum(10))}
		return append(out, prCallToks(sf, nil, [][]Tok{t})...)
	}
	return prCallToks(sf, []Tok{tKw(k)}, [][]Tok{t})
}

// prCaseRow is `Math.caseRow`: one cases row, `value & \text{if } condition`,
// then the row break.
func prCaseRow(sf Sf, v, cnd []Tok) []Tok {
	out := append([]Tok(nil), v...)
	out = append(out, tKw(KwAmp), tTxt("if "))
	out = append(out, cnd...)
	if sf == SfLatex {
		return append(out, tKw(KwNl))
	}
	return append(out, tKw(KwComma))
}

// prCasesToks is `Math.casesToks`.
func prCasesToks(sf Sf, rows []Tok) []Tok {
	if sf == SfLatex {
		return cat(kws(KwBcases), rows, kws(KwEcases))
	}
	return cat(kws(KwCases, KwLp), rows, kws(KwRp))
}

// prIcTail is `Math.icTail`: `t_{0}` in an initial condition `N(t_{0})`.
func prIcTail(sf Sf) []Tok {
	if sf == SfLatex {
		return []Tok{tKw(KwLp), tLetter('t'), tKw(KwUs), tKw(KwLb), tNum(IntNum(0)), tKw(KwRb), tKw(KwRp)}
	}
	return []Tok{tKw(KwLp), tLetter('t'), tKw(KwUs), tNum(IntNum(0)), tKw(KwRp)}
}

// prSubList is `Math.subList`: a subscript list: LaTeX `_{a, b}`; Typst `_a`
// for one simple token, else `_(a, b)`.
func prSubList(sf Sf, simp *Tok, args [][]Tok) []Tok {
	if sf == SfLatex {
		return cat(kws(KwUs, KwLb), prSepBy(kws(KwComma), args), kws(KwRb))
	}
	if simp != nil {
		return []Tok{tKw(KwUs), *simp}
	}
	return cat(kws(KwUs, KwLpg), prSepBy(kws(KwComma), args), kws(KwRp))
}

// prSimpleE is `Math.simpleE`: the one token a Typst exponent or subscript may
// be written as without parentheses.
func prSimpleE(c Ctx, j Json) *Tok {
	switch v := j.(type) {
	case JNum:
		t := tNum(v)
		if prSimpleTok(t) {
			return &t
		}
	case string:
		ts := prNameToks(c, v)
		if len(ts) == 1 && prSimpleTok(ts[0]) {
			t := ts[0]
			return &t
		}
	}
	return nil
}

// prSimpleArg is `Math.simpleArg`.
func prSimpleArg(c Ctx, xs []Json) *Tok {
	if len(xs) == 1 {
		return prSimpleE(c, xs[0])
	}
	return nil
}

// prSubOk is `Math.subOK`: the index prints with a subscript.
func prSubOk(s *Sym, base Json, is []Json) bool {
	b, ok := base.(string)
	if !ok || !exprNameOk(b) || !prPlainLast(b) || prExplicitName(s, b) {
		return false
	}
	if len(is) == 1 {
		switch x := is[0].(type) {
		case string:
			xc := []rune(x)
			return len(exprSplitDots(xc)) != 1 || !exprIsFormula(xc)
		case JNum:
			if !x.Dec {
				nm := b + "_" + strconv.FormatInt(x.I, 10)
				return x.I < 0 || !slices.Contains(s.Names, nm)
			}
		}
	}
	return true
}

// prSubPat4 is `Math.subPat4`: four tokens of an upright name subscript.
func prSubPat4(sf Sf, t1, t2, t3, t4 Tok) bool {
	if t1.isKw(KwUs) && t2.isKw(KwLb) && t3.K == TRm && t4.isKw(KwRb) {
		return sf == SfLatex
	}
	if t1.isKw(KwUs) && t2.isKw(KwLpg) && t3.K == TUps && t4.isKw(KwRp) &&
		len(t3.Ups) == 1 && t3.Ups[0].B == "" {
		return sf == SfTypst
	}
	return false
}

// prSubPat is `Math.subPat`: an upright name subscript at the front.
func prSubPat(sf Sf, ts []Tok) bool {
	return len(ts) >= 4 && prSubPat4(sf, ts[0], ts[1], ts[2], ts[3])
}

// prInlineD is `Math.inlineD`: derivative operand printed inline.
func prInlineD(o Out) bool { return o.lvl >= 9 }

// prKeyToks is `Math.keyToks`: a field key, upright.
func prKeyToks(sf Sf, k string) []Tok {
	if sf == SfLatex {
		return []Tok{tRm(string(prEscK([]rune(k))))}
	}
	return []Tok{tUps([]UpsPair{{k, ""}})}
}

// prJsonVal is `Math.jsonVal`: a field value that is not an expression, as
// JSON.
func prJsonVal(sf Sf, v Json) []Tok {
	if sf == SfLatex {
		return prJsonToks(v)
	}
	return []Tok{tCode(v)}
}

// prOpenToks is `Math.openToks`: the open-operator call.
func prOpenToks(sf Sf, o string, args, fields [][]Tok) []Tok {
	out := []Tok{tOpn(o), prLpC(sf)}
	out = append(out, prSepBy(kws(KwComma), args)...)
	if len(fields) > 0 {
		out = append(out, tKw(KwSemi))
		out = append(out, prSepBy(kws(KwComma), fields)...)
	}
	return append(out, tKw(KwRp))
}

// prDTime is `Math.dTime`: the time derivative.
func prDTime(sf Sf, a Out) Out {
	a1 := a.at(sf, 1)
	if sf == SfLatex {
		if prInlineD(a) {
			return prMkOut(10, cat([]Tok{tKw(KwFrac), tKw(KwLb), tRm("d")}, a1,
				[]Tok{tKw(KwRb), tKw(KwLb), tRm("d"), tLetter('t'), tKw(KwRb)}))
		}
		return prMkOut(6, cat([]Tok{tKw(KwFrac), tKw(KwLb), tRm("d"), tKw(KwRb), tKw(KwLb), tRm("d"), tLetter('t'), tKw(KwRb)},
			prGrp(sf, a1)))
	}
	if prInlineD(a) {
		return prMkOut(7, cat(kws(KwLpg, KwDif), a1,
			[]Tok{tKw(KwRp), tKw(KwSlash), tKw(KwLpg), tKw(KwDif), tLetter('t'), tKw(KwRp)}))
	}
	return prMkOut(6, cat([]Tok{tKw(KwLpg), tKw(KwDif), tKw(KwRp), tKw(KwSlash), tKw(KwLpg), tKw(KwDif), tLetter('t'), tKw(KwRp)},
		prGrp(sf, a1)))
}

// prDSpace is `Math.dSpace`: the spatial derivative along the axis printed w.
func prDSpace(sf Sf, w []Tok, a Out) Out {
	a1 := a.at(sf, 1)
	if sf == SfLatex {
		if prInlineD(a) {
			return prMkOut(10, cat(kws(KwFrac, KwLb, KwPdiff), a1, kws(KwRb, KwLb, KwPdiff), w, kws(KwRb)))
		}
		return prMkOut(6, cat(kws(KwFrac, KwLb, KwPdiff, KwRb, KwLb, KwPdiff), w, kws(KwRb), prGrp(sf, a1)))
	}
	if prInlineD(a) {
		return prMkOut(7, cat(kws(KwLpg, KwPdiff), a1, kws(KwRp, KwSlash, KwLpg, KwPdiff), w, kws(KwRp)))
	}
	return prMkOut(6, cat(kws(KwLpg, KwPdiff, KwRp, KwSlash, KwLpg, KwPdiff), w, kws(KwRp), prGrp(sf, a1)))
}

// prDCall is `Math.dCall`: `partial` with trailing operands:
// `\partial_{x}(u, a, b)` / `partial_(x)(u, a, b)`.
func prDCall(sf Sf, w []Tok, args [][]Tok) []Tok {
	open, closeK := KwLpg, KwRp
	if sf == SfLatex {
		open, closeK = KwLb, KwRb
	}
	out := []Tok{tKw(KwPdiff), tKw(KwUs), tKw(open)}
	out = append(out, w...)
	out = append(out, tKw(closeK))
	return append(out, prCallToks(sf, nil, args)...)
}

// prNabHead is `Math.nabHead`: what a `\nabla` form writes before its operand:
// `\nabla`, `\nabla \cdot`, `\nabla^{2}`, `\nabla \times` (Typst `nabla`,
// `nabla dot`, `nabla^2`, `nabla times`).
func prNabHead(sf Sf, n string) []Tok {
	switch n {
	case "div":
		return kws(KwNabla, KwCdot)
	case "laplacian":
		if sf == SfLatex {
			return []Tok{tKw(KwNabla), tKw(KwCaret), tKw(KwLb), tNum(IntNum(2)), tKw(KwRb)}
		}
		return []Tok{tKw(KwNabla), tKw(KwCaret), tNum(IntNum(2))}
	case "curl":
		return kws(KwNabla, KwTimes)
	}
	return kws(KwNabla)
}

// prNabArg is `Math.nabArg`: the operand of a `\nabla` form: another
// `\nabla` form as it is (`\nabla \cdot \nabla u` is div(grad(u))), anything
// else at the level of a power base; after the `\times` of a curl, an operand
// that starts with a number is parenthesized.
func prNabArg(sf Sf, n string, o Out) []Tok {
	if len(o.toks) > 0 && o.toks[0].K == TKw && o.toks[0].W == KwNabla && o.lvl >= 6 {
		return o.toks
	}
	t := o.at(sf, 9)
	if n == "curl" && prStartsNum(t) {
		return prGrp(sf, t)
	}
	return t
}

// prQtyToks is `Math.qtyToks`: the quantity: the number, then the unit as one
// token.
func prQtyToks(n JNum, l []Factor) []Tok { return []Tok{tNum(n), tUnits(l)} }

// ## Constant arrays

// prNumsOf is `Math.numsOf`: the entries of a list that are all well-formed
// numbers.
func prNumsOf(xs []Json) ([]JNum, bool) {
	out := make([]JNum, 0, len(xs))
	for _, x := range xs {
		n, ok := x.(JNum)
		if !ok || !exprNumOk(n) {
			return nil, false
		}
		out = append(out, n)
	}
	return out, true
}

// prRowsOf is `Math.rowsOf`: the rows of a list of number lists.
func prRowsOf(xs []Json) ([][]JNum, bool) {
	out := make([][]JNum, 0, len(xs))
	for _, x := range xs {
		ys, ok := x.([]Json)
		if !ok {
			return nil, false
		}
		r, ok := prNumsOf(ys)
		if !ok {
			return nil, false
		}
		out = append(out, r)
	}
	return out, true
}

// AForm is `Math.AForm`: the two array shapes with a native spelling (Col
// when Mat is nil), of any size.
type AForm struct {
	Col []JNum
	Mat [][]JNum
}

// prArrForm is `Math.arrForm`: a constant array printed natively.
func prArrForm(j Json) (AForm, bool) {
	xs, ok := j.([]Json)
	if !ok {
		return AForm{}, false
	}
	if ns, ok := prNumsOf(xs); ok {
		if len(ns) > 0 {
			return AForm{Col: ns}, true
		}
		return AForm{}, false
	}
	rs, ok := prRowsOf(xs)
	if !ok || len(rs) == 0 {
		return AForm{}, false
	}
	r := rs[0]
	if len(r) < 2 {
		return AForm{}, false
	}
	for _, q := range rs[1:] {
		if len(q) != len(r) {
			return AForm{}, false
		}
	}
	return AForm{Mat: rs}, true
}

// prNumToks is `Math.numToks`.
func prNumToks(ns []JNum) [][]Tok {
	out := make([][]Tok, len(ns))
	for i, n := range ns {
		out[i] = []Tok{tNum(n)}
	}
	return out
}

// prBmatMaxCols is the most columns a LaTeX `bmatrix` holds (amsmath's
// MaxMatrixCols); a wider matrix prints as `\left[\begin{array}{c…c} …
// \end{array}\right]`, one `c` per column.
const prBmatMaxCols = 10

// prArrToks is `Math.arrToks`: LaTeX `bmatrix` (or the `array` of a wider
// matrix), Typst `vec(…)` / `mat(…)`.
func prArrToks(sf Sf, a AForm) []Tok {
	if a.Mat == nil {
		if sf == SfLatex {
			return cat(kws(KwBmat), prSepBy(kws(KwNl), prNumToks(a.Col)), kws(KwEmat))
		}
		return cat(kws(KwVec, KwLp), prSepBy(kws(KwComma), prNumToks(a.Col)), kws(KwRp))
	}
	rows := make([][]Tok, len(a.Mat))
	if sf == SfLatex {
		for i, r := range a.Mat {
			rows[i] = prSepBy(kws(KwAmp), prNumToks(r))
		}
		if n := len(a.Mat[0]); n > prBmatMaxCols {
			return cat(kws(KwLbkg), []Tok{tArrC(n)}, prSepBy(kws(KwNl), rows), kws(KwEarr, KwRbkg))
		}
		return cat(kws(KwBmat), prSepBy(kws(KwNl), rows), kws(KwEmat))
	}
	for i, r := range a.Mat {
		rows[i] = prSepBy(kws(KwComma), prNumToks(r))
	}
	return cat(kws(KwMat, KwLp), prSepBy(kws(KwSemi), rows), kws(KwRp))
}

// prUnitToks is `Math.unitToks`: the unit after a number or an array.
func prUnitToks(l []Factor) []Tok { return []Tok{tUnits(l)} }

// ## Reductions (`faq`)

// prIdxBase is `Math.idxBase`: the array an `index` node reads, when it names
// one.
func prIdxBase(kvs Obj) (string, bool) {
	o, _ := exprLook("op", kvs)
	a, _ := exprLook("args", kvs)
	os, ok1 := o.(string)
	xs, ok2 := a.([]Json)
	if ok1 && ok2 && os == "index" && len(xs) > 0 {
		s, ok := xs[0].(string)
		return s, ok
	}
	return "", false
}

// prBasesJ is `Math.basesJ`: the arrays an expression indexes, in first-use
// order (appended to acc).
func prBasesJ(j Json, acc []string) []string {
	switch v := j.(type) {
	case Obj:
		if s, ok := prIdxBase(v); ok && !slices.Contains(acc, s) {
			acc = append(acc, s)
		}
		for _, kv := range v {
			acc = prBasesJ(kv.V, acc)
		}
	case []Json:
		for _, x := range v {
			acc = prBasesJ(x, acc)
		}
	}
	return acc
}

// prBases is `Math.bases`.
func prBases(e Json) []string { return prBasesJ(e, nil) }

// RedK is `Math.RedK`: the reductions with a native spelling.
type RedK uint8

// The reductions.
const (
	RedSum RedK = iota
	RedProd
	RedMax
	RedMin
)

// kw is `Math.RedK.kw`.
func (r RedK) kw() Kw {
	switch r {
	case RedProd:
		return KwProd
	case RedMax:
		return KwMax
	case RedMin:
		return KwMin
	}
	return KwSum
}

// field is `Math.RedK.field`.
func (r RedK) field() Obj {
	switch r {
	case RedProd:
		return Obj{{"reduce", "*"}}
	case RedMax:
		return Obj{{"reduce", "max"}}
	case RedMin:
		return Obj{{"reduce", "min"}}
	}
	return nil
}

// FaqForm is `Math.FaqForm`: a `faq` node with a native spelling, by its
// parts. marked: `args` lists the arrays the body indexes; otherwise `args` is
// set (empty, or names printed as a superscript set).
type FaqForm struct {
	red    RedK
	marked bool
	out    []Json
	ranges Obj
	expr   Json
	filter Json // nil when absent (hasFilter false)
	hasFlt bool
	set    []string
}

// args is `Math.FaqForm.args`: the `args` of a native `faq`.
func (f FaqForm) args() []Json {
	args := []Json{}
	if f.marked {
		for _, b := range prBases(f.expr) {
			args = append(args, b)
		}
		return args
	}
	for _, n := range f.set {
		args = append(args, n)
	}
	return args
}

// sup is `Math.FaqForm.sup`: the names a superscript set shows: set when
// `args` is not the body's arrays.
func (f FaqForm) sup() []string {
	if f.marked {
		return nil
	}
	return f.set
}

// prFaqJson is `Math.faqJson`.
func prFaqJson(f FaqForm) Json {
	kvs := Obj{{"args", f.args()}, {"expr", f.expr}}
	if f.hasFlt {
		kvs = append(kvs, KV{"filter", f.filter})
	}
	kvs = append(kvs, KV{"op", "faq"}, KV{"output_idx", append([]Json{}, f.out...)})
	if len(f.ranges) > 0 {
		kvs = append(kvs, KV{"ranges", f.ranges})
	}
	return append(kvs, f.red.field()...)
}

// prFaqCand is `Math.faqCand`: the parts a `faq` node would have.
func prFaqCand(kvs Obj) (FaqForm, bool) {
	e, ok1 := exprLook("expr", kvs)
	o, _ := exprLook("output_idx", kvs)
	a, _ := exprLook("args", kvs)
	out, ok2 := o.([]Json)
	args, ok3 := a.([]Json)
	if !ok1 || !ok2 || !ok3 {
		return FaqForm{}, false
	}
	red := RedSum
	if r, has := exprLook("reduce", kvs); has {
		s, isStr := r.(string)
		switch {
		case isStr && s == "*":
			red = RedProd
		case isStr && s == "max":
			red = RedMax
		case isStr && s == "min":
			red = RedMin
		default:
			return FaqForm{}, false
		}
	}
	rs := Obj{}
	if rv, has := exprLook("ranges", kvs); has {
		o, ok := rv.(Obj)
		if !ok {
			return FaqForm{}, false
		}
		rs = o
	}
	marked, set := false, []string(nil)
	if len(args) > 0 {
		if prArgsAreBases(args, e) {
			marked = true
		} else {
			st, ok := prStrsOf(args)
			if !ok {
				return FaqForm{}, false
			}
			set = st
		}
	}
	flt, hasFlt := exprLook("filter", kvs)
	return FaqForm{red: red, marked: marked, out: out, ranges: rs, expr: e, filter: flt, hasFlt: hasFlt, set: set}, true
}

// prArgsAreBases is the `jbeqL as ((bases e).map .str)` test of
// `Math.faqCand`: `args` is exactly the arrays the body indexes.
func prArgsAreBases(args []Json, e Json) bool {
	bs := prBases(e)
	if len(bs) != len(args) {
		return false
	}
	for i, b := range bs {
		if s, ok := args[i].(string); !ok || s != b {
			return false
		}
	}
	return true
}

// prStrsOf is `Math.strsOf`: the strings of a list of JSON values, when they
// are all strings.
func prStrsOf(xs []Json) ([]string, bool) {
	out := make([]string, 0, len(xs))
	for _, x := range xs {
		s, ok := x.(string)
		if !ok {
			return nil, false
		}
		out = append(out, s)
	}
	return out, true
}

// prFaqForm is `Math.faqForm`: the parts of a `faq` node, when it is exactly
// the node they rebuild.
func prFaqForm(kvs Obj) (FaqForm, bool) {
	f, ok := prFaqCand(kvs)
	if !ok || !JsonEqual(prFaqJson(f), kvs) {
		return FaqForm{}, false
	}
	return f, true
}

// prRangeOk is `Math.rangeOK`: a range a row can spell.
func prRangeOk(j Json) bool {
	switch v := j.(type) {
	case []Json:
		return len(v) == 2 && exprIsE(v[0]) && exprIsE(v[1])
	case Obj:
		if len(v) == 1 && v[0].K == "from" {
			s, ok := v[0].V.(string)
			return ok && exprNameOk(s)
		}
		if len(v) == 2 && v[0].K == "from" && v[1].K == "of" {
			s, ok := v[0].V.(string)
			ps, ok2 := v[1].V.([]Json)
			if !ok || !ok2 || !exprNameOk(s) || len(ps) == 0 {
				return false
			}
			for _, p := range ps {
				q, ok := p.(string)
				if !ok || !exprNameOk(q) {
					return false
				}
			}
			return true
		}
	}
	return false
}

// prOutNames is `Math.outNames`.
func prOutNames(out []Json) []string {
	var names []string
	for _, j := range out {
		if k, ok := j.(string); ok {
			names = append(names, k)
		}
	}
	return names
}

// prOutOk is `Math.outOK`: an output entry: a name, or the singleton dimension
// `1`.
func prOutOk(j Json) bool {
	switch v := j.(type) {
	case string:
		return exprNameOk(v)
	case JNum:
		return v.IsInt(1)
	}
	return false
}

// prOccursJ is `Math.occursJ`: a bare name occurs in an expression.
func prOccursJ(k string, j Json) bool {
	switch v := j.(type) {
	case string:
		return v == k
	case []Json:
		for _, x := range v {
			if prOccursJ(k, x) {
				return true
			}
		}
	case Obj:
		for _, kv := range v {
			if prOccursJ(k, kv.V) {
				return true
			}
		}
	}
	return false
}

// prFaqOk is `Math.faqOK`: the conditions under which the native spelling
// reads back.
func prFaqOk(f FaqForm) bool {
	names := prOutNames(f.out)
	if !exprIsE(f.expr) || (f.hasFlt && !exprIsE(f.filter)) {
		return false
	}
	for _, o := range f.out {
		if !prOutOk(o) {
			return false
		}
	}
	if !nodupStrings(names) || !exprKeysSorted(f.ranges) {
		return false
	}
	for _, n := range f.set {
		if !exprNameOk(n) {
			return false
		}
	}
	for _, kv := range f.ranges {
		if !exprNameOk(kv.K) || !prRangeOk(kv.V) {
			return false
		}
		if !slices.Contains(names, kv.K) && !prOccursJ(kv.K, f.expr) && (!f.hasFlt || !prOccursJ(kv.K, f.filter)) {
			return false
		}
	}
	return true
}

// prUpSet is `Math.upSet`: a segment of an index set's name prints upright in a
// Typst range row when it would otherwise print `italic("…")`.
func prUpSet(sf Sf, g []rune) bool {
	_, _, sub := exprSubParts(g)
	return sf == SfTypst && exprSegOk(g) && !exprIsSingle(g) && !sub && !exprIsFormula(g)
}

// prSetSegToks is `Math.setSegToks`: one segment of an index set's name.
func prSetSegToks(sf Sf, g []rune) []Tok {
	if prUpSet(sf, g) {
		return []Tok{tUps([]UpsPair{{A: string(g), B: ""}})}
	}
	return prSegToks(sf, g)
}

// prSetToks is `Math.setToks`: the tokens of an index set's name in a range row.
func prSetToks(c Ctx, s string) []Tok {
	if prExplicitName(c.s, s) {
		return []Tok{tIt(s)}
	}
	segs := exprSplitDots([]rune(s))
	xs := make([][]Tok, len(segs))
	for i, g := range segs {
		xs[i] = prSetSegToks(c.sf, g)
	}
	return prSepBy([]Tok{tKw(KwSdot)}, xs)
}

// prRowToks is `Math.rowToks`: a range row: `a \le k \le b`, `k \in S`,
// `k \in S(i, j)`.
func prRowToks(c Ctx, k string, v Json) []Tok {
	switch x := v.(type) {
	case []Json:
		if len(x) == 2 {
			return cat(prPa(c, 4, x[0]), kws(KwLe), prNameToks(c, k), kws(KwLe), prPa(c, 4, x[1]))
		}
	case Obj:
		if len(x) == 1 && x[0].K == "from" {
			if s, ok := x[0].V.(string); ok {
				return cat(prNameToks(c, k), kws(KwInn), prSetToks(c, s))
			}
		}
		if len(x) == 2 && x[0].K == "from" && x[1].K == "of" {
			s, ok := x[0].V.(string)
			ps, ok2 := x[1].V.([]Json)
			if ok && ok2 {
				items := make([][]Tok, len(ps))
				for i, p := range ps {
					if q, ok := p.(string); ok {
						items[i] = prNameToks(c, q)
					}
				}
				return cat(prNameToks(c, k), kws(KwInn), prSetToks(c, s), kws(KwLp),
					prSepBy(kws(KwComma), items), kws(KwRp))
			}
		}
	}
	return nil
}

// prRedRanges is `Math.redRanges`: the ranges of indices that are not output
// indices.
func prRedRanges(f FaqForm) Obj {
	names := prOutNames(f.out)
	var out Obj
	for _, kv := range f.ranges {
		if !slices.Contains(names, kv.K) {
			out = append(out, kv)
		}
	}
	return out
}

// prSubRows is `Math.subRows`: the rows of the subscript: the reduced ranges,
// then the filter.
func prSubRows(c Ctx, f FaqForm) [][]Tok {
	var rows [][]Tok
	for _, kv := range prRedRanges(f) {
		rows = append(rows, prRowToks(c, kv.K, kv.V))
	}
	if f.hasFlt {
		rows = append(rows, prPa(c, 1, f.filter))
	}
	return rows
}

// prHeadToks is `Math.headToks`: the operator, marked when `args` is listed.
func prHeadToks(sf Sf, f FaqForm) []Tok {
	if sf == SfLatex {
		out := []Tok{tKw(f.red.kw())}
		if f.marked {
			out = append(out, tKw(KwLimitsL))
		}
		return out
	}
	if f.marked {
		return kws(KwLimits, KwLp, f.red.kw(), KwRp)
	}
	return kws(f.red.kw())
}

// prSubToksL is `Math.subToksL`: the LaTeX subscript: none, one row, a lone
// dense range `_{k=a}^{b}` (not when `args` is a superscript set), or
// `\substack`.
func prSubToksL(c Ctx, f FaqForm) []Tok {
	rr := prRedRanges(f)
	if len(rr) == 1 && !f.hasFlt && len(f.sup()) == 0 {
		if ab, ok := rr[0].V.([]Json); ok && len(ab) == 2 {
			return cat(kws(KwUs, KwLb), prNameToks(c, rr[0].K), kws(KwEq), prPa(c, 4, ab[0]),
				kws(KwRb, KwCaret, KwLb), prPa(c, 1, ab[1]), kws(KwRb))
		}
	}
	rows := prSubRows(c, f)
	switch len(rows) {
	case 0:
		return nil
	case 1:
		return cat(kws(KwUs, KwLb), rows[0], kws(KwRb))
	}
	return cat(kws(KwUs, KwLb, KwSubstack, KwLb), prSepBy(kws(KwNl), rows), kws(KwRb, KwRb))
}

// prSubToksT is `Math.subToksT`: the Typst subscript: rows in `_( … )`,
// stacked with `\`.
func prSubToksT(c Ctx, f FaqForm) []Tok {
	rows := prSubRows(c, f)
	if len(rows) == 0 {
		return nil
	}
	return cat(kws(KwUs, KwLpg), prSepBy(kws(KwNl), rows), kws(KwRp))
}

// prSubToks is `Math.subToks`.
func prSubToks(c Ctx, f FaqForm) []Tok {
	if c.sf == SfLatex {
		return prSubToksL(c, f)
	}
	return prSubToksT(c, f)
}

// prSupToks is `Math.supToks`: the superscript set of names: LaTeX
// `^{\{f, g\}}`, Typst `^({f, g})`.
func prSupToks(c Ctx, ns []string) []Tok {
	items := make([][]Tok, len(ns))
	for i, n := range ns {
		items[i] = prNameToks(c, n)
	}
	if c.sf == SfLatex {
		return cat(kws(KwCaret, KwLb, KwLset), prSepBy(kws(KwComma), items), kws(KwRset, KwRb))
	}
	return cat(kws(KwCaret, KwLpg, KwLset), prSepBy(kws(KwComma), items), kws(KwRset, KwRp))
}

// prSupT is `Math.supT`: the `args` set of a `faq`, as a superscript, when it
// is one.
func prSupT(c Ctx, f FaqForm) []Tok {
	if len(f.sup()) == 0 {
		return nil
	}
	return prSupToks(c, f.sup())
}

// prRedToks is `Math.redToks`: operator, subscript, the superscript set (on
// the operator only when there are no output indices), body at level 5.
func prRedToks(c Ctx, f FaqForm) []Tok {
	var sup []Tok
	if len(f.out) == 0 {
		sup = prSupT(c, f)
	}
	return cat(prHeadToks(c.sf, f), prSubToks(c, f), sup, prPa(c, 5, f.expr))
}

// prEntryToks is `Math.entryToks`: an output entry: its range row when it has
// one.
func prEntryToks(c Ctx, f FaqForm, j Json) []Tok {
	if k, ok := j.(string); ok {
		if v, ok := exprLook(k, f.ranges); ok {
			return prRowToks(c, k, v)
		}
		return prNameToks(c, k)
	}
	return []Tok{tNum(IntNum(1))}
}

// prFaqOut is `Math.faqOut`: the native `faq`, wrapped with its output indices
// when it has some. A superscript set goes on the bracket, before its
// subscript; the form is then a power's level (a power of it, or an index into
// it, is parenthesized: no double superscript).
func prFaqOut(c Ctx, f FaqForm) Out {
	if len(f.out) == 0 {
		return prMkOut(5, prRedToks(c, f))
	}
	entries := make([][]Tok, len(f.out))
	for i, j := range f.out {
		entries[i] = prEntryToks(c, f, j)
	}
	es := prSepBy(kws(KwComma), entries)
	sup := prSupT(c, f)
	l := 10
	if len(sup) > 0 {
		l = 8
	}
	if c.sf == SfLatex {
		return prMkOut(l, cat(kws(KwLbkg), prRedToks(c, f), kws(KwRbkg), sup, kws(KwUs, KwLb), es, kws(KwRb)))
	}
	return prMkOut(l, cat(kws(KwLr, KwLp, KwLbk), prRedToks(c, f), kws(KwRbk, KwRp), sup, kws(KwUs, KwLpg), es, kws(KwRp)))
}

// ## Block assembly (`makearray`)

// Pair is a bound pair `[a, b]` of a `makearray` region.
type Pair struct{ A, B Json }

// MkForm is `Math.MkForm`: a `makearray` node with a native spelling, by its
// parts: the output indices (empty when the node has no `output_idx`), and
// the regions with their values.
type MkForm struct {
	out     []string
	regions [][]Pair
	values  []Json
}

// prMkJson is `Math.mkJson`.
func prMkJson(m MkForm) Json {
	kvs := Obj{{"args", []Json{}}, {"op", "makearray"}}
	if len(m.out) > 0 {
		os := make([]Json, len(m.out))
		for i, o := range m.out {
			os[i] = o
		}
		kvs = append(kvs, KV{"output_idx", os})
	}
	rs := make([]Json, len(m.regions))
	for i, r := range m.regions {
		ps := make([]Json, len(r))
		for j, p := range r {
			ps[j] = []Json{p.A, p.B}
		}
		rs[i] = ps
	}
	return append(kvs, KV{"regions", rs}, KV{"values", append([]Json{}, m.values...)})
}

// prRegionsOf is `Math.regionsOf` (with `Math.pairsOf`): the regions of a
// `regions` list.
func prRegionsOf(xs []Json) ([][]Pair, bool) {
	out := make([][]Pair, 0, len(xs))
	for _, x := range xs {
		ps, ok := x.([]Json)
		if !ok {
			return nil, false
		}
		r := make([]Pair, 0, len(ps))
		for _, p := range ps {
			ab, ok := p.([]Json)
			if !ok || len(ab) != 2 {
				return nil, false
			}
			r = append(r, Pair{ab[0], ab[1]})
		}
		out = append(out, r)
	}
	return out, true
}

// prMkCand is `Math.mkCand`: the parts a `makearray` node would have.
func prMkCand(kvs Obj) (MkForm, bool) {
	rv, _ := exprLook("regions", kvs)
	vv, _ := exprLook("values", kvs)
	rs, ok1 := rv.([]Json)
	vs, ok2 := vv.([]Json)
	if !ok1 || !ok2 {
		return MkForm{}, false
	}
	var out []string
	if ov, has := exprLook("output_idx", kvs); has {
		os, ok := ov.([]Json)
		if !ok {
			return MkForm{}, false
		}
		if out, ok = prStrsOf(os); !ok {
			return MkForm{}, false
		}
	}
	regs, ok := prRegionsOf(rs)
	if !ok {
		return MkForm{}, false
	}
	return MkForm{out: out, regions: regs, values: vs}, true
}

// prMkForm is `Math.mkForm`: the parts of a `makearray` node, when it is
// exactly the node they rebuild.
func prMkForm(kvs Obj) (MkForm, bool) {
	m, ok := prMkCand(kvs)
	if !ok || !JsonEqual(prMkJson(m), kvs) {
		return MkForm{}, false
	}
	return m, true
}

// prMkOk is `Math.mkOK`: the conditions under which the native spelling reads
// back: one value per region, at least one region, each region a nonempty list
// of bound pairs, values and bounds expressions, output indices names.
func prMkOk(m MkForm) bool {
	if len(m.values) == 0 || len(m.regions) != len(m.values) {
		return false
	}
	for _, v := range m.values {
		if !exprIsE(v) {
			return false
		}
	}
	for _, r := range m.regions {
		if len(r) == 0 {
			return false
		}
		for _, p := range r {
			if !exprIsE(p.A) || !exprIsE(p.B) {
				return false
			}
		}
	}
	for _, o := range m.out {
		if !exprNameOk(o) {
			return false
		}
	}
	return true
}

// prCellSep is `Math.cellSep`: the cell separator of the table.
func prCellSep(sf Sf) Kw {
	if sf == SfLatex {
		return KwAmp
	}
	return KwComma
}

// prRowSep is `Math.rowSep`: the row separator of the table.
func prRowSep(sf Sf) Kw {
	if sf == SfLatex {
		return KwNl
	}
	return KwSemi
}

// prPairToks is `Math.pairToks`: a bound pair: `a, b` (its brackets are
// written around it).
func prPairToks(c Ctx, p Pair) []Tok {
	return cat(prPa(c, 1, p.A), kws(KwComma), prPa(c, 1, p.B))
}

// prRegToks is `Math.regToks`: a region: `[a, b] \times [c, d]`, one bound
// pair per dimension.
func prRegToks(c Ctx, r []Pair) []Tok {
	var out []Tok
	for i, p := range r {
		if i == 0 {
			out = append(out, tKw(KwLbk))
		} else {
			out = append(out, tKw(KwTimes), tKw(KwLbk))
		}
		out = append(out, prPairToks(c, p)...)
		out = append(out, tKw(KwRbk))
	}
	return out
}

// prMkRow is `Math.mkRow`: a row of the table: the value, then the region it
// fills.
func prMkRow(c Ctx, v Json, r []Pair) []Tok {
	return cat(prPa(c, 1, v), kws(prCellSep(c.sf)), prRegToks(c, r))
}

// prMatHead is `Math.matHead`: the Typst table head: `mat(delim: "[",
// augment: #1,`.
func prMatHead() []Tok {
	return []Tok{tKw(KwMat), tKw(KwLp), tWord("delim"), tKw(KwColon), tTxt("["), tKw(KwComma),
		tWord("augment"), tKw(KwColon), tCode(IntNum(1)), tKw(KwComma)}
}

// prMkSub is `Math.mkSub`: the output indices as the bracket's subscript.
func prMkSub(c Ctx, out []string) []Tok {
	if len(out) == 0 {
		return nil
	}
	items := make([][]Tok, len(out))
	for i, n := range out {
		items[i] = prNameToks(c, n)
	}
	if c.sf == SfLatex {
		return cat(kws(KwUs, KwLb), prSepBy(kws(KwComma), items), kws(KwRb))
	}
	return cat(kws(KwUs, KwLpg), prSepBy(kws(KwComma), items), kws(KwRp))
}

// prMkOutT is `Math.mkOutT`: the native `makearray`: a bracketed two-column
// table, value then region, one row per region in order; LaTeX
// `\left[\begin{array}{l|l} v & [a, b] \\ … \end{array}\right]`, Typst
// `mat(delim: "[", augment: #1, v, [a, b]; …)`; the output indices as its
// subscript.
func prMkOutT(c Ctx, m MkForm) Out {
	rows := make([][]Tok, len(m.values))
	for i, v := range m.values {
		rows[i] = prMkRow(c, v, m.regions[i])
	}
	body := prSepBy(kws(prRowSep(c.sf)), rows)
	if c.sf == SfLatex {
		return prMkOut(10, cat(kws(KwLbkg, KwBarr), body, kws(KwEarr, KwRbkg), prMkSub(c, m.out)))
	}
	return prMkOut(10, cat(prMatHead(), body, kws(KwRp), prMkSub(c, m.out)))
}

// prTnameOk is `Math.tnameOK`.
func prTnameOk(n string) bool { return prOpnOk(n) && !prReservedOpn(n) }

// prPr is `Math.pr`: the printer.
func prPr(c Ctx, e Json) Out {
	sf := c.sf
	var kvs Obj
	switch v := e.(type) {
	case JNum:
		if prIsNegNum(e) {
			return prMkOut(7, []Tok{tNum(v)})
		}
		return prMkOut(10, []Tok{tNum(v)})
	case string:
		return prMkOut(10, prNameToks(c, v))
	case Obj:
		kvs = v
	default:
		return prMkOut(10, nil)
	}
	esc := func() Out {
		o, _ := exprLook("op", kvs)
		a, _ := exprLook("args", kvs)
		os, ok1 := o.(string)
		args, ok2 := a.([]Json)
		if !ok1 || !ok2 {
			return prMkOut(10, nil)
		}
		parts := make([][]Tok, len(args))
		for i, x := range args {
			parts[i] = prPa(c, 1, x)
		}
		return prMkOut(10, prEscToks(sf, os, prFieldsOf(kvs), parts))
	}
	opn := func() Out {
		o, _ := exprLook("op", kvs)
		a, _ := exprLook("args", kvs)
		os, ok1 := o.(string)
		args, ok2 := a.([]Json)
		if !ok1 || !ok2 {
			return esc()
		}
		fs := prFieldsOf(kvs)
		if !prOpnCallOk(c.s, os, fs) {
			return esc()
		}
		for _, kv := range fs {
			if !prKeyOk(kv.K) {
				return esc()
			}
		}
		ap := make([][]Tok, len(args))
		for i, x := range args {
			ap[i] = prPa(c, 4, x)
		}
		fp := make([][]Tok, len(fs))
		for i, kv := range fs {
			var val []Tok
			if prMathField(os, kv) {
				val = prPa(c, 4, kv.V)
			} else {
				val = prJsonVal(sf, kv.V)
			}
			fp[i] = cat(prKeyToks(sf, kv.K), kws(KwEq), val)
		}
		return prMkOut(10, prOpenToks(sf, os, ap, fp))
	}
	field := func(i int, k string) (Json, bool) {
		if i < len(kvs) && kvs[i].K == k {
			return kvs[i].V, true
		}
		return nil, false
	}
	strAt := func(i int, k, v string) bool {
		x, ok := field(i, k)
		s, isStr := x.(string)
		return ok && isStr && s == v
	}
	emptyArgs := func() bool {
		x, _ := field(0, "args")
		a, ok := x.([]Json)
		return ok && len(a) == 0
	}
	switch len(kvs) {
	case 2:
		a, _ := field(0, "args")
		o, _ := field(1, "op")
		args, ok1 := a.([]Json)
		os, ok2 := o.(string)
		if ok1 && ok2 {
			return prPlain(c, os, args, opn, esc)
		}
	case 3:
		a, _ := field(0, "args")
		wv, _ := field(2, "wrt")
		args, ok1 := a.([]Json)
		w, ok2 := wv.(string)
		if ok1 && strAt(1, "op", "D") && ok2 {
			// `D` is the time derivative only; a `D` with any other `wrt` is
			// written in the escape form (a document reads it as `partial`).
			if len(args) == 1 && w == "t" {
				return prDTime(sf, prPr(c, args[0]))
			}
			return esc()
		}
		if ok1 && strAt(1, "op", "partial") && ok2 {
			switch {
			case len(args) == 1:
				if w != "t" && exprNameOk(w) {
					return prDSpace(sf, prNameToks(c, w), prPr(c, args[0]))
				}
				return opn()
			case len(args) >= 2:
				if w != "t" && exprNameOk(w) {
					ap := make([][]Tok, len(args))
					for i, x := range args {
						ap[i] = prPa(c, 4, x)
					}
					return prMkOut(10, prDCall(sf, prNameToks(c, w), ap))
				}
				return opn()
			default:
				return opn()
			}
		}
		if emptyArgs() && strAt(1, "op", "const") {
			v, _ := field(2, "value")
			if _, ok := v.([]Json); ok {
				if nat, ok := prNative(c, kvs); ok {
					return nat()
				}
				return opn()
			}
		}
	case 4:
		if emptyArgs() && strAt(1, "op", "const") {
			uv, _ := field(2, "units")
			v, _ := field(3, "value")
			_, isStr := uv.(string)
			switch v.(type) {
			case JNum, []Json:
				if isStr {
					if nat, ok := prNative(c, kvs); ok {
						return nat()
					}
					return opn()
				}
			}
		}
		if emptyArgs() {
			bv, _ := field(1, "bindings")
			nv, _ := field(2, "name")
			bs, ok1 := bv.(Obj)
			n, ok2 := nv.(string)
			if ok1 && ok2 && strAt(3, "op", "apply_operator") {
				return prTemplate(c, n, bs, esc)
			}
		}
	}
	if nat, ok := prNative(c, kvs); ok {
		return nat()
	}
	return opn()
}

// prNative is the native spelling the dispatch of `Math.pr` gives a `const`,
// `faq` or `makearray` node, when one applies: a constant array (with a unit
// the surface spells), a quantity, a reduction, a table. It returns the
// printing to do, so a caller asking only whether one applies prints nothing.
func prNative(c Ctx, kvs Obj) (func() Out, bool) {
	sf := c.sf
	field := func(i int, k string) (Json, bool) {
		if i < len(kvs) && kvs[i].K == k {
			return kvs[i].V, true
		}
		return nil, false
	}
	a, _ := field(0, "args")
	o, _ := field(1, "op")
	args, okA := a.([]Json)
	if os, ok := o.(string); okA && ok && len(args) == 0 && os == "const" {
		switch len(kvs) {
		case 3:
			v, _ := field(2, "value")
			if xs, ok := v.([]Json); ok {
				if af, ok := prArrForm(xs); ok {
					return func() Out { return prMkOut(10, prArrToks(sf, af)) }, true
				}
			}
		case 4:
			uv, _ := field(2, "units")
			v, _ := field(3, "value")
			if u, ok := uv.(string); ok && prUnitsOk(sf, u) {
				switch x := v.(type) {
				case JNum:
					return func() Out { return prMkOut(7, prQtyToks(x, prFactorsOf(u))) }, true
				case []Json:
					if af, ok := prArrForm(x); ok {
						return func() Out {
							return prMkOut(7, cat(prArrToks(sf, af), prUnitToks(prFactorsOf(u))))
						}, true
					}
				}
			}
		}
	}
	if f, ok := prFaqForm(kvs); ok && prFaqOk(f) {
		return func() Out { return prFaqOut(c, f) }, true
	}
	if m, ok := prMkForm(kvs); ok && prMkOk(m) {
		return func() Out { return prMkOutT(c, m) }, true
	}
	return nil, false
}

// prPlain is the [("args", .arr as), ("op", .str o)] case of `Math.pr`.
func prPlain(c Ctx, o string, args []Json, opn, esc func() Out) Out {
	sf := c.sf
	chain := func(l int, sep Kw, hasSep bool, lvl int) Out {
		parts := make([][]Tok, len(args))
		for i, x := range args {
			parts[i] = prPa(c, l, x)
		}
		if hasSep {
			return prMkOut(lvl, prSepBy(kws(sep), parts))
		}
		return prMkOut(lvl, prMulToks(parts))
	}
	k := prKindOf(o)
	switch k.K {
	case OpMinus:
		if len(args) == 1 {
			t := prPa(c, 5, args[0])
			body := t
			if prStartsNum(t) {
				body = prGrp(sf, t)
			}
			return prMkOut(5, cat(kws(KwMinus), body))
		}
		if len(args) == 2 {
			return prMkOut(4, cat(prPa(c, 4, args[0]), kws(KwMinus), prPa(c, 5, args[1])))
		}
	case OpDiv:
		if len(args) == 2 {
			if sf == SfLatex {
				return prMkOut(10, cat(kws(KwFrac, KwLb), prPa(c, 1, args[0]), kws(KwRb, KwLb), prPa(c, 1, args[1]), kws(KwRb)))
			}
			return prMkOut(7, cat(prPa(c, 8, args[0]), kws(KwSlash), prPa(c, 8, args[1])))
		}
	case OpPow:
		if len(args) == 2 {
			var ex []Tok
			if sf == SfLatex {
				ex = cat(kws(KwLb), prPa(c, 1, args[1]), kws(KwRb))
			} else if t := prSimpleE(c, args[1]); t != nil {
				ex = []Tok{*t}
			} else {
				ex = prGrp(sf, prPr(c, args[1]).toks)
			}
			return prMkOut(8, cat(prPa(c, 9, args[0]), kws(KwCaret), ex))
		}
	case OpLnot:
		if len(args) == 1 {
			return prMkOut(6, cat(kws(KwLnot), prPa(c, 6, args[0])))
		}
	case OpTru:
		if len(args) == 0 {
			return prMkOut(10, []Tok{tTxt("true")})
		}
	case OpFls:
		if len(args) == 0 {
			return prMkOut(10, []Tok{tTxt("false")})
		}
	case OpIte:
		if len(args) == 3 {
			rows := prCaseRow(sf, prPa(c, 1, args[1]), prPa(c, 1, args[0]))
			rows = append(rows, prPr(c, args[2]).Crow()...)
			return Out{lvl: 10, toks: prCasesToks(sf, rows), crow: rows}
		}
	case OpUn:
		if len(args) == 1 {
			return prMkOut(10, prUnToks(sf, k.W, prPa(c, 1, args[0])))
		}
	case OpIc:
		if len(args) == 1 {
			if n, ok := args[0].(string); ok {
				if exprNameOk(n) {
					return prMkOut(10, cat(prNameToks(c, n), prIcTail(sf)))
				}
				return esc()
			}
		}
	case OpIndex:
		if len(args) >= 2 {
			base, is := args[0], args[1:]
			subs := func() [][]Tok {
				out := make([][]Tok, len(is))
				for i, x := range is {
					out[i] = prPa(c, 1, x)
				}
				return out
			}
			sl := prSubList(sf, prSimpleArg(c, is), subs())
			if prSubOk(c.s, base, is) && !prSubPat(sf, sl) {
				b, _ := base.(string)
				return prMkOut(9, cat(prNameToks(c, b), sl))
			}
			return prMkOut(9, cat(prPa(c, 10, base), kws(KwLbk), prSepBy(kws(KwComma), subs()), kws(KwRbk)))
		}
	case OpCmp:
		if len(args) == 2 {
			return prMkOut(3, cat(prPa(c, 4, args[0]), kws(k.W), prPa(c, 4, args[1])))
		}
	case OpPlus:
		if len(args) >= 2 {
			return chain(5, KwPlus, true, 4)
		}
		return opn()
	case OpTimes:
		if len(args) >= 2 {
			return chain(6, 0, false, 5)
		}
		return opn()
	case OpLand:
		if len(args) >= 2 {
			return chain(3, KwLand, true, 2)
		}
		return opn()
	case OpLor:
		if len(args) >= 2 {
			return chain(2, KwLor, true, 1)
		}
		return opn()
	case OpMm:
		if len(args) >= 2 {
			ap := make([][]Tok, len(args))
			for i, x := range args {
				ap[i] = prPa(c, 1, x)
			}
			return prMkOut(10, prCallToks(sf, kws(k.W), ap))
		}
		return opn()
	case OpNab:
		if len(args) == 1 {
			return prMkOut(6, cat(prNabHead(sf, k.N), prNabArg(sf, k.N, prPr(c, args[0]))))
		}
		return opn()
	case OpCall:
		ap := make([][]Tok, len(args))
		for i, x := range args {
			ap[i] = prPa(c, 4, x)
		}
		return prMkOut(10, prCallToks(sf, []Tok{tOpn(o)}, ap))
	}
	return opn()
}

// prTemplate is the `apply_operator` case of `Math.pr`.
func prTemplate(c Ctx, n string, bs Obj, esc func() Out) Out {
	sf := c.sf
	if !prTnameOk(n) || !exprKeysSorted(bs) {
		return esc()
	}
	for _, kv := range bs {
		if !exprIsE(kv.V) {
			return esc()
		}
	}
	vals := make([][]Tok, len(bs))
	for i, kv := range bs {
		vals[i] = prPa(c, 4, kv.V)
	}
	if ps, ok := prPositional(c.s, n, bs); ok {
		args := make([][]Tok, len(ps))
		for i, p := range ps {
			for j, kv := range bs {
				if kv.K == p {
					args[i] = vals[j]
					break
				}
			}
		}
		return prMkOut(10, prCallToks(sf, []Tok{tOpn(n)}, args))
	}
	if len(bs) == 0 {
		return prMkOut(5, []Tok{tOpn(n)})
	}
	for _, kv := range bs {
		if !exprNameOk(kv.K) {
			return esc()
		}
	}
	args := make([][]Tok, len(bs))
	for i, kv := range bs {
		args[i] = cat(prNameToks(c, kv.K), kws(KwEq), vals[i])
	}
	return prMkOut(10, prCallToks(sf, []Tok{tOpn(n)}, args))
}

// prPa is `Math.pa`: the tokens of an expression for a position needing level
// l.
func prPa(c Ctx, l int, e Json) []Tok { return prPr(c, e).at(c.sf, l) }

// ## The defining form of an equation
//
// An equation whose right side is a `faq` with output indices,
// `x = [body]_(s ∈ S)`, prints with the output indices on its left side and
// their ranges after its right side, `x_s = body, s ∈ S`. The right side is the
// reduction over the remaining ranges (a `faq` with no output indices), or the
// body alone when the `faq` reduces nothing and carries nothing else. The
// reader takes a trailing `, rows` after a whole equation back to the `faq`
// (prUnlift); the printer uses the form only when that gives back exactly the
// equation (prLiftOk), and the bracket form otherwise.

// prSortKvs is `Math.sortKVs`: sort bindings by key (insertion from the right).
func prSortKvs(xs Obj) Obj {
	out := Obj{}
	for i := len(xs) - 1; i >= 0; i-- {
		out = prInsKv(xs[i], out)
	}
	return out
}

// prIsRedNode is `Math.isRedNode`: a `faq` node with no output indices.
func prIsRedNode(j Json) bool {
	kvs, ok := j.(Obj)
	if !ok {
		return false
	}
	o, _ := exprLook("op", kvs)
	oi, _ := exprLook("output_idx", kvs)
	os, isStr := o.(string)
	l, isArr := oi.([]Json)
	return isStr && os == "faq" && isArr && len(l) == 0
}

// prBinNode matches exactly `{"args": [a, b], "op": op}`.
func prBinNode(j Json, op string) (Json, Json, bool) {
	kvs, ok := j.(Obj)
	if !ok || len(kvs) != 2 || kvs[0].K != "args" || kvs[1].K != "op" {
		return nil, nil, false
	}
	if o, ok := kvs[1].V.(string); !ok || o != op {
		return nil, nil, false
	}
	sides, ok := kvs[0].V.([]Json)
	if !ok || len(sides) != 2 {
		return nil, nil, false
	}
	return sides[0], sides[1], true
}

// prWithoutOutRanges is the fields of a node other than `output_idx` and
// `ranges`.
func prWithoutOutRanges(kvs Obj) Obj {
	out := Obj{}
	for _, kv := range kvs {
		if kv.K != "output_idx" && kv.K != "ranges" {
			out = append(out, kv)
		}
	}
	return out
}

// prUnlift is `Math.unlift`: the equation `x_(os) = rhs` with the ranges rows
// of its output indices, as the equation it writes: `x = faq` with the output
// indices os and the rows' ranges, over rhs read as the reduction (a `faq` with
// no output indices) or as the body.
func prUnlift(q Json, rows Obj) (Json, bool) {
	lhs, rhs, ok := prBinNode(q, "==")
	if !ok {
		return nil, false
	}
	lk, ok := lhs.(Obj)
	if !ok || len(lk) != 2 || lk[0].K != "args" || lk[1].K != "op" {
		return nil, false
	}
	if o, ok := lk[1].V.(string); !ok || o != "index" {
		return nil, false
	}
	ia, ok := lk[0].V.([]Json)
	if !ok || len(ia) == 0 {
		return nil, false
	}
	x, ok := ia[0].(string)
	if !ok {
		return nil, false
	}
	os := append([]Json{}, ia[1:]...)
	var f Json
	if kvs, isObj := rhs.(Obj); isObj && prIsRedNode(rhs) {
		rest := Obj{}
		if rv, has := exprLook("ranges", kvs); has {
			if rs, ok := rv.(Obj); ok {
				rest = rs
			}
		}
		rr := append(append(Obj{}, rest...), rows...)
		fs := append(Obj{{"output_idx", os}, {"ranges", prSortKvs(rr)}}, prWithoutOutRanges(kvs)...)
		f = prSortKvs(fs)
	} else {
		f = Obj{{"args", []Json{}}, {"expr", rhs}, {"op", "faq"}, {"output_idx", os},
			{"ranges", prSortKvs(append(Obj{}, rows...))}}
	}
	return Obj{{"args", []Json{x, f}}, {"op", "=="}}, true
}

// prLiftParts is `Math.liftParts`: the parts of the defining form of an
// equation `x = faq`: the equation `x_(os) = rhs` and the ranges of the output
// indices, when the left side is a name that takes a subscript and the `faq`
// has output indices.
func prLiftParts(e Json) (Json, Obj, bool) {
	xj, r, ok := prBinNode(e, "==")
	if !ok {
		return nil, nil, false
	}
	x, ok1 := xj.(string)
	kvs, ok2 := r.(Obj)
	if !ok1 || !ok2 {
		return nil, nil, false
	}
	o, _ := exprLook("op", kvs)
	oj, _ := exprLook("output_idx", kvs)
	rj, _ := exprLook("ranges", kvs)
	op, isStr := o.(string)
	os, isArr := oj.([]Json)
	rs, isObj := rj.(Obj)
	if !isStr || op != "faq" || !isArr || !isObj {
		return nil, nil, false
	}
	if len(os) == 0 || !prPlainLast(x) {
		return nil, nil, false
	}
	outs := prOutNames(os)
	rows := Obj{}
	for _, k := range outs {
		if v, has := exprLook(k, rs); has {
			rows = append(rows, KV{k, v})
		}
	}
	rest := Obj{}
	for _, kv := range rs {
		if !slices.Contains(outs, kv.K) {
			rest = append(rest, kv)
		}
	}
	bare := len(rest) == 0
	for _, kv := range kvs {
		switch kv.K {
		case "expr", "op", "output_idx", "ranges":
		case "args":
			if a, ok := kv.V.([]Json); !ok || len(a) != 0 {
				bare = false
			}
		default:
			bare = false
		}
	}
	body, _ := exprLook("expr", kvs)
	var rhs Json
	if bare && !prIsRedNode(body) {
		rhs = body
	} else {
		fs := Obj{{"output_idx", []Json{}}}
		if len(rest) > 0 {
			fs = append(fs, KV{"ranges", rest})
		}
		rk := prSortKvs(append(fs, prWithoutOutRanges(kvs)...))
		// The reduction must have its native spelling (`faqForm` and `faqOK`).
		if f, ok := prFaqForm(rk); !ok || !prFaqOk(f) {
			return nil, nil, false
		}
		rhs = rk
	}
	lhs := Obj{{"args", append([]Json{x}, os...)}, {"op", "index"}}
	return Obj{{"args", []Json{lhs, rhs}}, {"op", "=="}}, rows, true
}

// prLiftOk is `Math.liftOK`: the defining form is used: it reads back as
// exactly e.
func prLiftOk(e, q Json, rows Obj) bool {
	if len(rows) == 0 || !exprIsE(q) {
		return false
	}
	for _, kv := range rows {
		if !exprNameOk(kv.K) || !prRangeOk(kv.V) {
			return false
		}
		if ab, ok := kv.V.([]Json); ok && len(ab) == 2 && (!exprIsE(ab[0]) || !exprIsE(ab[1])) {
			return false
		}
	}
	u, ok := prUnlift(q, rows)
	return ok && JsonEqual(u, e)
}

// prDefRowsToks is `Math.defRowsToks`: the range rows after a defining equation,
// separated by commas.
func prDefRowsToks(c Ctx, rows Obj) []Tok {
	xs := make([][]Tok, len(rows))
	for i, kv := range rows {
		xs[i] = prRowToks(c, kv.K, kv.V)
	}
	return prSepBy(kws(KwComma), xs)
}

// prPrint is `Math.print`: the tokens of a whole expression: an equation
// `x = faq` with output indices in its defining form when that reads back,
// otherwise as any expression.
func prPrint(sf Sf, s *Sym, e Json) []Tok {
	c := Ctx{sf: sf, s: s}
	if q, rows, ok := prLiftParts(e); ok && prLiftOk(e, q, rows) {
		return cat(prPa(c, 1, q), kws(KwComma), prDefRowsToks(c, rows))
	}
	return prPa(c, 1, e)
}
