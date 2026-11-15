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
	"apply_expression_template": true,
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
	OpCall
	OpOther
)

// OpK is `Math.OpK`: the kind, and the keyword of OpCmp, OpUn and OpMm.
type OpK struct {
	K OpKind
	W Kw
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

// prDCall is `Math.dCall`: a spatial derivative with trailing operands:
// `\operatorname{D}_{x}(u, a, b)`.
func prDCall(sf Sf, w []Tok, args [][]Tok) []Tok {
	open, closeK := KwLpg, KwRp
	if sf == SfLatex {
		open, closeK = KwLb, KwRb
	}
	out := []Tok{tOpn("D"), tKw(KwUs), tKw(open)}
	out = append(out, w...)
	out = append(out, tKw(closeK))
	return append(out, prCallToks(sf, nil, args)...)
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
// when Mat is nil).
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
		if len(ns) > 0 && len(ns) <= 16 {
			return AForm{Col: ns}, true
		}
		return AForm{}, false
	}
	rs, ok := prRowsOf(xs)
	if !ok || len(rs) == 0 {
		return AForm{}, false
	}
	r := rs[0]
	if len(r) < 2 || len(rs)*len(r) > 16 {
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

// prArrToks is `Math.arrToks`: LaTeX `bmatrix`, Typst `vec(…)` / `mat(…)`.
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
// parts.
type FaqForm struct {
	red    RedK
	marked bool
	out    []Json
	ranges Obj
	expr   Json
	filter Json // nil when absent (hasFilter false)
	hasFlt bool
}

// prFaqJson is `Math.faqJson`.
func prFaqJson(f FaqForm) Json {
	args := []Json{}
	if f.marked {
		for _, b := range prBases(f.expr) {
			args = append(args, b)
		}
	}
	kvs := Obj{{"args", args}, {"expr", f.expr}}
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
	flt, hasFlt := exprLook("filter", kvs)
	return FaqForm{red: red, marked: len(args) > 0, out: out, ranges: rs, expr: e, filter: flt, hasFlt: hasFlt}, true
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
				return cat(prNameToks(c, k), kws(KwInn), prNameToks(c, s))
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
				return cat(prNameToks(c, k), kws(KwInn), prNameToks(c, s), kws(KwLp),
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

// prSubToksL is `Math.subToksL`: the LaTeX subscript.
func prSubToksL(c Ctx, f FaqForm) []Tok {
	rr := prRedRanges(f)
	if len(rr) == 1 && !f.hasFlt {
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

// prRedToks is `Math.redToks`: operator, subscript, body at level 5.
func prRedToks(c Ctx, f FaqForm) []Tok {
	return cat(prHeadToks(c.sf, f), prSubToks(c, f), prPa(c, 5, f.expr))
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
// when it has some.
func prFaqOut(c Ctx, f FaqForm) Out {
	if len(f.out) == 0 {
		return prMkOut(5, prRedToks(c, f))
	}
	entries := make([][]Tok, len(f.out))
	for i, j := range f.out {
		entries[i] = prEntryToks(c, f, j)
	}
	es := prSepBy(kws(KwComma), entries)
	if c.sf == SfLatex {
		return prMkOut(10, cat(kws(KwLbkg), prRedToks(c, f), kws(KwRbkg, KwUs, KwLb), es, kws(KwRb)))
	}
	return prMkOut(10, cat(kws(KwLr, KwLp, KwLbk), prRedToks(c, f), kws(KwRbk, KwRp, KwUs, KwLpg), es, kws(KwRp)))
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
		if prCoreOps[os] || !prOpnOk(os) {
			return esc()
		}
		if _, ok := prTparams(c.s, os); ok {
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
			if exprIsE(kv.V) {
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
			switch {
			case len(args) == 1:
				if w == "t" {
					return prDTime(sf, prPr(c, args[0]))
				} else if exprNameOk(w) {
					return prDSpace(sf, prNameToks(c, w), prPr(c, args[0]))
				}
				return esc()
			case len(args) >= 2:
				if w != "t" && exprNameOk(w) {
					ap := make([][]Tok, len(args))
					for i, x := range args {
						ap[i] = prPa(c, 4, x)
					}
					return prMkOut(10, prDCall(sf, prNameToks(c, w), ap))
				}
				return esc()
			default:
				return esc()
			}
		}
		if emptyArgs() && strAt(1, "op", "const") {
			v, _ := field(2, "value")
			if xs, ok := v.([]Json); ok {
				if af, ok := prArrForm(xs); ok {
					return prMkOut(10, prArrToks(sf, af))
				}
				return opn()
			}
		}
	case 4:
		if emptyArgs() && strAt(1, "op", "const") {
			uv, _ := field(2, "units")
			if u, ok := uv.(string); ok {
				v, _ := field(3, "value")
				switch x := v.(type) {
				case JNum:
					if prUnitsOk(sf, u) {
						return prMkOut(7, prQtyToks(x, prFactorsOf(u)))
					}
					return esc()
				case []Json:
					if af, ok := prArrForm(x); ok {
						if prUnitsOk(sf, u) {
							return prMkOut(7, cat(prArrToks(sf, af), prUnitToks(prFactorsOf(u))))
						}
						return esc()
					}
					return esc()
				}
			}
		}
		if emptyArgs() {
			bv, _ := field(1, "bindings")
			nv, _ := field(2, "name")
			bs, ok1 := bv.(Obj)
			n, ok2 := nv.(string)
			if ok1 && ok2 && strAt(3, "op", "apply_expression_template") {
				return prTemplate(c, n, bs, esc)
			}
		}
	}
	if f, ok := prFaqForm(kvs); ok && prFaqOk(f) {
		return prFaqOut(c, f)
	}
	return opn()
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
	case OpCall:
		ap := make([][]Tok, len(args))
		for i, x := range args {
			ap[i] = prPa(c, 4, x)
		}
		return prMkOut(10, prCallToks(sf, []Tok{tOpn(o)}, ap))
	}
	return opn()
}

// prTemplate is the `apply_expression_template` case of `Math.pr`.
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
		return esc()
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

// prPrint is `Math.print`: the tokens of a whole expression.
func prPrint(sf Sf, s *Sym, e Json) []Tok { return prPa(Ctx{sf: sf, s: s}, 1, e) }
