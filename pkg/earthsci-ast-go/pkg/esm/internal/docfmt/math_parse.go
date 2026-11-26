package docfmt

// The parser: tokens to expressions. Port of
// formal/Esm/Document/Math/Parse.lean and `parseToks` of Induct.lean (Rust:
// document/math/parse.rs); prefix `ps`.
//
// Recursive descent with one function per precedence level (see
// math_print.go), each taking fuel exactly as in Lean: a function at fuel 0
// fails, and every call passes on the fuel its Lean definition passes. The
// chain loops (orLoop, addLoop, …) are loops here, spending one unit of fuel
// per iteration as the Lean recursion does. The helpers whose fuel only serves
// termination and is given as the input length (pNameLoop, pNames, pGrid,
// pCells) loop without it.
//
// Every parser returns (value, rest, ok).

import (
	"slices"

	"github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm/internal/unitspell"
)

// at reports whether ts[i] is the keyword k.
func at(ts []Tok, i int, k Kw) bool { return i < len(ts) && ts[i].isKw(k) }

// atKws reports whether ts starts with the keywords ks.
func atKws(ts []Tok, ks ...Kw) bool {
	if len(ts) < len(ks) {
		return false
	}
	for i, k := range ks {
		if !ts[i].isKw(k) {
			return false
		}
	}
	return true
}

// ## Small pieces

// psClose is `Math.close`: close an n-ary chain: one operand is itself, more
// make a node.
func psClose(o string, xs []Json) Json {
	if len(xs) == 1 {
		return xs[0]
	}
	return prNode(o, xs)
}

// psCmpOf is `Math.cmpOf`: the comparison a token spells.
func psCmpOf(k Kw) (string, bool) {
	switch k {
	case KwLt:
		return "<", true
	case KwLe:
		return "<=", true
	case KwGt:
		return ">", true
	case KwGe:
		return ">=", true
	case KwEq:
		return "==", true
	case KwNe:
		return "!=", true
	}
	return "", false
}

// psFnOf is `Math.fnOf`: the unary function a keyword spells.
func psFnOf(k Kw) (string, bool) {
	for _, p := range prFnKw {
		if p.k == k {
			return p.o, true
		}
	}
	return "", false
}

// psAtomStart is `Math.atomStart`: tokens that can start an operand of a
// product.
func psAtomStart(t Tok) bool {
	switch t.K {
	case TNum, TLetter, TGreek, TWord, TIt, TRm, TUps, TOpn, TTxt, TEsc:
		return true
	case TKw:
		switch t.W {
		case KwLpg, KwLp, KwLbk, KwLnot, KwFrac, KwSqrt, KwExp, KwLn, KwLog, KwSin, KwCos,
			KwTan, KwAsin, KwAcos, KwAtan, KwSinh, KwCosh, KwTanh, KwMin, KwMax, KwLabs,
			KwLfloor, KwLceil, KwAbs, KwFloor, KwCeil, KwDotacc, KwBcases, KwCases,
			KwEsmnode, KwBmat, KwVec, KwMat, KwSum, KwProd, KwLimits, KwLbkg, KwLr, KwNabla, KwPdiff:
			return true
		}
	}
	return false
}

// psIsLp is `Math.isLp`: `(` or `\left(`.
func psIsLp(t Tok) bool { return t.isKw(KwLp) || t.isKw(KwLpg) }

// psIsRp is `Math.isRp`: `)` or `\right)`.
func psIsRp(t Tok) bool { return t.isKw(KwRp) || t.isKw(KwRpg) }

// ## Names

// psDecodeFormula is `Math.decodeFormula`.
func psDecodeFormula(raw []rune) []rune {
	var out []rune
	for _, c := range raw {
		if c != '_' && c != '{' && c != '}' {
			out = append(out, c)
		}
	}
	return out
}

// psFormulaOf is `Math.formulaOf`: the name a formula token spells, if it is
// formula-shaped.
func psFormulaOf(sf Sf, t Tok) ([]rune, bool) {
	switch {
	case t.K == TRm && sf == SfLatex:
		rc := []rune(t.S)
		g := psDecodeFormula(rc)
		if exprIsFormula(g) && string(prFormulaRaw(g)) == t.S {
			return g, true
		}
	case t.K == TUps && sf == SfTypst:
		var g []rune
		for _, p := range t.Ups {
			g = append(g, []rune(p.A)...)
			g = append(g, []rune(p.B)...)
		}
		back := exprPieces(g)
		if !exprIsFormula(g) || len(back) != len(t.Ups) {
			return nil, false
		}
		for i, p := range back {
			if string(p.a) != t.Ups[i].A || string(p.b) != t.Ups[i].B {
				return nil, false
			}
		}
		return g, true
	}
	return nil, false
}

// psSubOrPlain is `Math.subOrPlain`: a single letter or Greek base, then an
// optional upright name subscript.
func psSubOrPlain(sf Sf, b []rune, r []Tok) ([]rune, []Tok) {
	if sf == SfLatex && len(r) >= 4 && r[0].isKw(KwUs) && r[1].isKw(KwLb) && r[2].K == TRm && r[3].isKw(KwRb) {
		g := append(append([]rune(nil), b...), '_')
		g = append(g, prUnescT([]rune(r[2].S))...)
		return g, r[4:]
	}
	if sf == SfTypst && len(r) >= 4 && r[0].isKw(KwUs) && r[1].isKw(KwLpg) && r[2].K == TUps && r[3].isKw(KwRp) &&
		len(r[2].Ups) == 1 && r[2].Ups[0].B == "" {
		g := append(append([]rune(nil), b...), '_')
		g = append(g, []rune(r[2].Ups[0].A)...)
		return g, r[4:]
	}
	return b, r
}

// psPSeg is `Math.pSeg`: one name segment.
func psPSeg(sf Sf, ts []Tok) ([]rune, []Tok, bool) {
	if len(ts) == 0 {
		return nil, nil, false
	}
	t, r := ts[0], ts[1:]
	switch t.K {
	case TLetter:
		if !exprIsLetter(t.C) {
			return nil, nil, false
		}
		g, r2 := psSubOrPlain(sf, []rune{t.C}, r)
		return g, r2, true
	case TGreek:
		gc := []rune(t.S)
		if !exprIsGreek(gc) {
			return nil, nil, false
		}
		g, r2 := psSubOrPlain(sf, gc, r)
		return g, r2, true
	case TIt:
		return []rune(t.S), r, true
	}
	g, ok := psFormulaOf(sf, t)
	if !ok {
		return nil, nil, false
	}
	return g, r, true
}

// psPName is `Math.pName`: a name: segments joined by the scope dot.
func psPName(sf Sf, ts []Tok) (string, []Tok, bool) {
	acc, r, ok := psPSeg(sf, ts)
	if !ok {
		return "", nil, false
	}
	acc = append([]rune(nil), acc...)
	for len(r) > 0 && r[0].isKw(KwSdot) {
		g, r2, ok := psPSeg(sf, r[1:])
		if !ok {
			return "", nil, false
		}
		acc = append(acc, '.')
		acc = append(acc, g...)
		r = r2
	}
	return string(acc), r, true
}

// ## JSON inside LaTeX escape nodes

// psPJson is `Math.pJson`.
func psPJson(lim *Lim, f int, ts []Tok) (Json, []Tok, bool) {
	if f == 0 || !lim.enter() {
		return nil, nil, false
	}
	defer lim.leave()
	f--
	if len(ts) == 0 {
		return nil, nil, false
	}
	t, r := ts[0], ts[1:]
	switch {
	case t.K == TWord && t.S == "null":
		return nil, r, true
	case t.K == TWord && t.S == "true":
		return true, r, true
	case t.K == TWord && t.S == "false":
		return false, r, true
	case t.K == TNum:
		return t.N, r, true
	case t.K == TJstr:
		return t.S, r, true
	case t.isKw(KwLbk) && at(r, 0, KwRbk):
		return []Json{}, r[1:], true
	case t.isKw(KwLbk):
		xs, r2, ok := psPJsonItems(lim, f, r)
		if ok && at(r2, 0, KwRbk) {
			return xs, r2[1:], true
		}
	case t.isKw(KwLb) && at(r, 0, KwRb):
		return Obj{}, r[1:], true
	case t.isKw(KwLb):
		kvs, r2, ok := psPJsonEntries(lim, f, r)
		if ok && at(r2, 0, KwRb) {
			return kvs, r2[1:], true
		}
	}
	return nil, nil, false
}

// psPJsonItems is `Math.pJsonItems`.
func psPJsonItems(lim *Lim, f int, ts []Tok) ([]Json, []Tok, bool) {
	out := []Json{}
	for {
		if f == 0 {
			return nil, nil, false
		}
		f--
		v, r, ok := psPJson(lim, f, ts)
		if !ok {
			return nil, nil, false
		}
		out = append(out, v)
		if !at(r, 0, KwComma) {
			return out, r, true
		}
		ts = r[1:]
	}
}

// psPJsonEntries is `Math.pJsonEntries`.
func psPJsonEntries(lim *Lim, f int, ts []Tok) (Obj, []Tok, bool) {
	out := Obj{}
	for {
		if f == 0 {
			return nil, nil, false
		}
		f--
		if len(ts) < 2 || ts[0].K != TJstr || !ts[1].isKw(KwColon) {
			return nil, nil, false
		}
		k := ts[0].S
		v, r, ok := psPJson(lim, f, ts[2:])
		if !ok {
			return nil, nil, false
		}
		out = append(out, KV{k, v})
		if !at(r, 0, KwComma) {
			return out, r, true
		}
		ts = r[1:]
	}
}

// ## Negative literals after an operand

// psNegTok is `Math.negTok`: a negative literal token.
func psNegTok(t Tok) bool { return t.K == TNum && surfNegNum(t.N) }

// psNegate is `Math.negate`: the number with the opposite sign; ok is false
// for the integer -2^63, whose opposite is outside Int64 (Rust builds it as an
// i128 and then finds it is not well formed).
func psNegate(n JNum) (JNum, bool) {
	if !n.Dec {
		if n.I == -1<<63 {
			return JNum{}, false
		}
		return IntNum(-n.I), true
	}
	return JNum{Dec: true, Neg: !n.Neg, Digits: n.Digits, E10: n.E10}, true
}

// psNegTail is `Math.negTail`: a negative literal right after an operand is a
// binary minus and a positive number. Returns the number without its sign;
// the tokens after it are the input's own.
func psNegTail(ts []Tok) (JNum, []Tok, bool) {
	if len(ts) == 0 || ts[0].K != TNum {
		return JNum{}, nil, false
	}
	n := ts[0].N
	m, ok := psNegate(n)
	if ok && surfNegNum(n) && m.Wfb() {
		return m, ts[1:], true
	}
	return JNum{}, nil, false
}

// ## Expressions

// CallArg is `Math.CallArg`: what pCallArgs read (named when Named).
type CallArg struct {
	Named bool
	K     string
	V     Json
}

// psAllPos is `Math.allPos`.
func psAllPos(xs []CallArg) ([]Json, bool) {
	out := make([]Json, 0, len(xs))
	for _, a := range xs {
		if a.Named {
			return nil, false
		}
		out = append(out, a.V)
	}
	return out, true
}

// psAllNamed is `Math.allNamed`.
func psAllNamed(xs []CallArg) (Obj, bool) {
	out := make(Obj, 0, len(xs))
	for _, a := range xs {
		if !a.Named {
			return nil, false
		}
		out = append(out, KV{a.K, a.V})
	}
	return out, true
}

// psSortKv is `Math.sortKV`: sort bindings by key (insertion from the right,
// so equal keys keep their order).
func psSortKv(xs Obj) Obj {
	out := Obj{}
	for i := len(xs) - 1; i >= 0; i-- {
		out = prInsKv(xs[i], out)
	}
	return out
}

// psUnitsOfRaw is `Math.unitsOfRaw`: the unit a LaTeX `\mathrm{…}` after a
// number spells.
func psUnitsOfRaw(raw []rune) ([]Factor, bool) {
	s := []rune(unitsMathrmOpen)
	s = append(s, raw...)
	s = append(s, '}')
	return unitsParseLatex(s)
}

// psQty is `Math.qty`: a quantity node.
func psQty(n JNum, l []Factor) Json {
	return Obj{{"args", []Json{}}, {"op", "const"}, {"units", unitspell.Spell(l)}, {"value", n}}
}

// psDNode is `Math.dNode`: a time-derivative node (`psDNode(x, "t")`).
func psDNode(x Json, w string) Json {
	return Obj{{"args", []Json{x}}, {"op", "D"}, {"wrt", w}}
}

// psPNode is `Math.pNode`: a `partial` node, the spatial derivative (spec §4.2).
func psPNode(x Json, w string) Json {
	return Obj{{"args", []Json{x}}, {"op", "partial"}, {"wrt", w}}
}

// psDerivNode is `Math.derivNode`: the derivative a fraction of differentials
// reads as: the time derivative `D` along `t`, `partial` along any other axis.
func psDerivNode(x Json, w string) Json {
	if w == "t" {
		return psDNode(x, "t")
	}
	return psPNode(x, w)
}

// psTNode is `Math.tNode`: a reference node (`apply_operator`, spec §9.6.2).
func psTNode(n string, bs Obj) Json {
	return Obj{{"args", []Json{}}, {"bindings", bs}, {"name", n}, {"op", "apply_operator"}}
}

// psConstNode is `Math.constNode`: the value, and the units when there are
// some.
func psConstNode(v Json, u *string) Json {
	if u == nil {
		return Obj{{"args", []Json{}}, {"op", "const"}, {"value", v}}
	}
	return Obj{{"args", []Json{}}, {"op", "const"}, {"units", *u}, {"value", v}}
}

// psPCells is `Math.pCells`: numbers separated by sep, up to the first other
// token.
func psPCells(sep Kw, ts []Tok) ([]JNum, []Tok, bool) {
	var out []JNum
	for {
		if len(ts) == 0 || ts[0].K != TNum {
			return nil, nil, false
		}
		out = append(out, ts[0].N)
		if len(ts) >= 2 && ts[1].K == TKw {
			if ts[1].W == sep {
				ts = ts[2:]
				continue
			}
			return out, ts[1:], true
		}
		return out, ts[1:], true
	}
}

// psPGrid is `Math.pGrid`: rows of numbers: cells separated by csep, rows by
// rsep, closed by closeK.
func psPGrid(csep, rsep, closeK Kw, ts []Tok) ([][]JNum, []Tok, bool) {
	var out [][]JNum
	for {
		row, r, ok := psPCells(csep, ts)
		if !ok || len(r) == 0 || r[0].K != TKw {
			return nil, nil, false
		}
		out = append(out, row)
		switch r[0].W {
		case rsep:
			ts = r[1:]
		case closeK:
			return out, r[1:], true
		default:
			return nil, nil, false
		}
	}
}

// psGridJson is `Math.gridJson`: a LaTeX `bmatrix`: one cell per row is a
// column (rank 1).
func psGridJson(rows [][]JNum) Json {
	col := true
	for _, r := range rows {
		if len(r) != 1 {
			col = false
			break
		}
	}
	out := make([]Json, len(rows))
	for i, r := range rows {
		if col {
			out[i] = r[0]
		} else {
			out[i] = psNumsJson(r)
		}
	}
	return out
}

// psNumsJson is a list of numbers as a JSON array.
func psNumsJson(ns []JNum) Json {
	out := make([]Json, len(ns))
	for i, n := range ns {
		out[i] = n
	}
	return out
}

// psConstTail is `Math.constTail`: the unit after an array, if any.
func psConstTail(v Json, r []Tok) (Json, []Tok, bool) {
	if len(r) > 0 && r[0].K == TUnits {
		u := unitspell.Spell(r[0].U)
		return psConstNode(v, &u), r[1:], true
	}
	return psConstNode(v, nil), r, true
}

// psIcTailP is `Math.icTailP`: the `ic` tail `(t_{0})` / `(t_0)`.
func psIcTailP(sf Sf, ts []Tok) ([]Tok, bool) {
	if len(ts) < 3 || !ts[0].isKw(KwLp) || ts[1].K != TLetter || ts[1].C != 't' || !ts[2].isKw(KwUs) {
		return nil, false
	}
	r := ts[3:]
	if sf == SfLatex {
		if len(r) >= 4 && r[0].isKw(KwLb) && r[1].isNum(0) && r[2].isKw(KwRb) && r[3].isKw(KwRp) {
			return r[4:], true
		}
		return nil, false
	}
	if len(r) >= 2 && r[0].isNum(0) && r[1].isKw(KwRp) {
		return r[2:], true
	}
	return nil, false
}

// psJsonStart is `Math.jsonStart`: a LaTeX field value that is JSON starts
// with `{`, `[`, a string or a word.
func psJsonStart(ts []Tok) bool {
	if len(ts) == 0 {
		return false
	}
	t := ts[0]
	return t.isKw(KwLb) || t.isKw(KwLbk) || t.K == TJstr || t.K == TWord
}

// psKeyOf is `Math.keyOf`: a field key: LaTeX `\mathrm{key} =`, Typst
// `upright("key") =`.
func psKeyOf(c Ctx, ts []Tok) (string, []Tok, bool) {
	if len(ts) < 2 || !ts[1].isKw(KwEq) {
		return "", nil, false
	}
	t := ts[0]
	if c.sf == SfLatex && t.K == TRm {
		return string(prUnescK([]rune(t.S))), ts[2:], true
	}
	if c.sf == SfTypst && t.K == TUps && len(t.Ups) == 1 && t.Ups[0].B == "" {
		return t.Ups[0].A, ts[2:], true
	}
	return "", nil, false
}

// psDCallNode is `Math.dCallNode`: `partial` with trailing operands.
func psDCallNode(w string, xs []Json) Json {
	return Obj{{"args", xs}, {"op", "partial"}, {"wrt", w}}
}

// psNabTail is `Math.nabTail`: after `\nabla`, which form it is (`\cdot` div,
// `\times` curl, `^{2}` laplacian, nothing grad) and the tokens of its operand.
func psNabTail(sf Sf, r []Tok) (string, []Tok) {
	switch {
	case at(r, 0, KwCdot):
		return "div", r[1:]
	case at(r, 0, KwTimes):
		return "curl", r[1:]
	case sf == SfLatex && len(r) >= 4 && r[0].isKw(KwCaret) && r[1].isKw(KwLb) && r[2].K == TNum &&
		r[2].N.IsInt(2) && r[3].isKw(KwRb):
		return "laplacian", r[4:]
	case sf == SfTypst && len(r) >= 2 && r[0].isKw(KwCaret) && r[1].K == TNum && r[1].N.IsInt(2):
		return "laplacian", r[2:]
	}
	return "grad", r
}

func psDeclared(c Ctx, n string) bool { return slices.Contains(c.s.Names, n) }

// psEulerHead is `Math.eulerHead`: the input starts with Euler's number raised
// to a power.
func psEulerHead(c Ctx, ts []Tok) bool {
	if len(ts) < 2 || !ts[1].isKw(KwCaret) {
		return false
	}
	t := ts[0]
	switch t.K {
	case TRm:
		return t.S == "e"
	case TUps:
		return len(t.Ups) == 1 && t.Ups[0].A == "e" && t.Ups[0].B == ""
	case TLetter:
		return t.C == 'e' && !psDeclared(c, "e")
	}
	return false
}

// psPNamePrim is `Math.pNamePrim`: a name, or an initial condition `N(t_{0})`.
func psPNamePrim(c Ctx, ts []Tok) (Json, []Tok, bool) {
	n, r, ok := psPName(c.sf, ts)
	if !ok {
		return nil, nil, false
	}
	if r2, ok := psIcTailP(c.sf, r); ok {
		return prNode("ic", []Json{n}), r2, true
	}
	return n, r, true
}

// psPWord is `Math.pWord`: a bare run of letters: the declared name when only
// it is declared, the product of its letters when only they are.
func psPWord(c Ctx, w string, r []Tok) (Json, []Tok, bool) {
	whole := psDeclared(c, w)
	letters := true
	for _, ch := range w {
		if !psDeclared(c, string(ch)) {
			letters = false
			break
		}
	}
	switch {
	case whole && !letters:
		return w, r, true
	case letters && !whole:
		var xs []Json
		for _, ch := range w {
			xs = append(xs, string(ch))
		}
		return prNode("*", xs), r, true
	}
	return nil, nil, false
}

// psDName is `Math.dName`: `d` then a name, up to a closing token k.
func psDName(c Ctx, k Kw, ts []Tok) (string, []Tok, bool) {
	if len(ts) >= 2 && ts[0].K == TWord && ts[1].K == TKw {
		w := ts[0].S
		if ts[1].W == k && !psDeclared(c, w) && len(w) > 0 && w[0] == 'd' {
			return w[1:], ts[2:], true
		}
		return "", nil, false
	}
	if len(ts) >= 1 && ts[0].K == TLetter && ts[0].C == 'd' {
		n, r, ok := psPName(c.sf, ts[1:])
		if ok && at(r, 0, k) {
			return n, r[1:], true
		}
	}
	return "", nil, false
}

// psPItalicD is `Math.pItalicD`: the italic-d derivative variant.
func psPItalicD(c Ctx, r []Tok) (Json, []Tok, bool) {
	if psDeclared(c, "d") {
		return nil, nil, false
	}
	if c.sf == SfLatex {
		n, r0, ok := psDName(c, KwRb, r)
		if !ok || !at(r0, 0, KwLb) {
			return nil, nil, false
		}
		w, r2, ok := psDName(c, KwRb, r0[1:])
		if !ok {
			return nil, nil, false
		}
		return psDerivNode(n, w), r2, true
	}
	n, r0, ok := psDName(c, KwRp, r)
	if !ok || !atKws(r0, KwSlash, KwLpg) {
		return nil, nil, false
	}
	w, r2, ok := psDName(c, KwRp, r0[2:])
	if !ok {
		return nil, nil, false
	}
	return psDerivNode(n, w), r2, true
}

// Row is `Math.Row`: a row of a reduction's subscript (a range, when IsRng),
// or an output entry.
type Row struct {
	IsRng bool
	K     string
	V     Json
}

// psRedOf is `Math.redOf`.
func psRedOf(k Kw) (RedK, bool) {
	switch k {
	case KwSum:
		return RedSum, true
	case KwProd:
		return RedProd, true
	case KwMax:
		return RedMax, true
	case KwMin:
		return RedMin, true
	}
	return 0, false
}

// psPRedHead is `Math.pRedHead`: the operator of a reduction and whether it is
// marked.
func psPRedHead(sf Sf, ts []Tok) (RedK, bool, []Tok, bool) {
	if len(ts) >= 4 && ts[0].isKw(KwLimits) && ts[1].isKw(KwLp) && ts[2].K == TKw && ts[3].isKw(KwRp) {
		if sf != SfTypst {
			return 0, false, nil, false
		}
		red, ok := psRedOf(ts[2].W)
		return red, true, ts[4:], ok
	}
	if len(ts) >= 2 && ts[0].K == TKw && ts[1].isKw(KwLimitsL) {
		red, ok := psRedOf(ts[0].W)
		if sf == SfLatex {
			return red, true, ts[2:], ok
		}
		return red, false, ts[1:], ok
	}
	if len(ts) >= 1 && ts[0].K == TKw {
		red, ok := psRedOf(ts[0].W)
		return red, false, ts[1:], ok
	}
	return 0, false, nil, false
}

// psPNames is `Math.pNames`: names separated by commas.
func psPNames(sf Sf, ts []Tok) ([]string, []Tok, bool) {
	var out []string
	for {
		n, r, ok := psPName(sf, ts)
		if !ok {
			return nil, nil, false
		}
		out = append(out, n)
		if !at(r, 0, KwComma) {
			return out, r, true
		}
		ts = r[1:]
	}
}

// psRowParts is `Math.rowParts`: ranges, then at most one filter, last.
func psRowParts(rows []Row) (Obj, Json, bool, bool) {
	rg := Obj{}
	var fl Json
	hasFl := false
	for i, row := range rows {
		if row.IsRng {
			rg = append(rg, KV{row.K, row.V})
		} else {
			if i+1 != len(rows) {
				return nil, nil, false, false
			}
			fl, hasFl = row.V, true
		}
	}
	return rg, fl, hasFl, true
}

// psEntryParts is `Math.entryParts`: the output entries of a list of entry
// rows, with their ranges.
func psEntryParts(rows []Row) ([]Json, Obj, bool) {
	outs := []Json{}
	rs := Obj{}
	for _, row := range rows {
		if row.IsRng {
			outs = append(outs, row.K)
			rs = append(rs, KV{row.K, row.V})
			continue
		}
		switch v := row.V.(type) {
		case string:
			outs = append(outs, v)
		case JNum:
			if !v.IsInt(1) {
				return nil, nil, false
			}
			outs = append(outs, v)
		default:
			return nil, nil, false
		}
	}
	return outs, rs, true
}

// psWithOut is `Math.withOut`: the reduction's parts with the output entries.
func psWithOut(f FaqForm, outs []Json, ors Obj) FaqForm {
	rs := append(append(Obj{}, ors...), f.ranges...)
	f.out = outs
	f.ranges = psSortKv(rs)
	return f
}

// psWithSup is `Math.withSup`: the superscript set read after the output
// entries is the reduction's set (the wrapped reduction carries none).
func psWithSup(f FaqForm, st []string) FaqForm {
	f.set = st
	return f
}

// psPSup is `Math.pSup`: the superscript set of a reduction or of an output
// form, if there is one: LaTeX `^{\{f, g\}}`, Typst `^({f, g})`. ok is false
// when the set starts but does not read.
func psPSup(sf Sf, r []Tok) ([]string, []Tok, bool) {
	open, closeK := KwLb, KwRb
	if sf == SfTypst {
		open, closeK = KwLpg, KwRp
	}
	if !atKws(r, KwCaret, open, KwLset) {
		return nil, r, true
	}
	ns, r2, ok := psPNames(sf, r[3:])
	if !ok || !atKws(r2, KwRset, closeK) {
		return nil, nil, false
	}
	return ns, r2[2:], true
}

// psMkTail is `Math.mkTail`: the `makearray` node of a table read back, with
// its subscript of output indices if one follows.
func psMkTail(sf Sf, rows []mkRow, r []Tok) (Json, []Tok, bool) {
	nodeOf := func(out []string) Json {
		m := MkForm{out: out, regions: make([][]Pair, len(rows)), values: make([]Json, len(rows))}
		for i, row := range rows {
			m.values[i] = row.v
			m.regions[i] = row.reg
		}
		return prMkJson(m)
	}
	open, closeK := KwLb, KwRb
	if sf == SfTypst {
		open, closeK = KwLpg, KwRp
	}
	if !atKws(r, KwUs, open) {
		return nodeOf(nil), r, true
	}
	ns, r2, ok := psPNames(sf, r[2:])
	if !ok || !at(r2, 0, closeK) {
		return nil, nil, false
	}
	return nodeOf(ns), r2[1:], true
}

// ## The level parsers

// psPOr is `Math.pOr`: level 1, an `or` chain.
func psPOr(c Ctx, f int, ts []Tok) (Json, []Tok, bool) {
	if f == 0 {
		return nil, nil, false
	}
	f--
	x, r, ok := psPAnd(c, f, ts)
	if !ok {
		return nil, nil, false
	}
	return psOrLoop(c, f, []Json{x}, r)
}

// psOrLoop is `Math.orLoop`.
func psOrLoop(c Ctx, f int, acc []Json, ts []Tok) (Json, []Tok, bool) {
	for {
		if f == 0 {
			return nil, nil, false
		}
		f--
		if !at(ts, 0, KwLor) {
			return psClose("or", acc), ts, true
		}
		y, r2, ok := psPAnd(c, f, ts[1:])
		if !ok {
			return nil, nil, false
		}
		acc = append(acc, y)
		ts = r2
	}
}

// psPAnd is `Math.pAnd`: level 2, an `and` chain.
func psPAnd(c Ctx, f int, ts []Tok) (Json, []Tok, bool) {
	if f == 0 {
		return nil, nil, false
	}
	f--
	x, r, ok := psPCmp(c, f, ts)
	if !ok {
		return nil, nil, false
	}
	return psAndLoop(c, f, []Json{x}, r)
}

// psAndLoop is `Math.andLoop`.
func psAndLoop(c Ctx, f int, acc []Json, ts []Tok) (Json, []Tok, bool) {
	for {
		if f == 0 {
			return nil, nil, false
		}
		f--
		if !at(ts, 0, KwLand) {
			return psClose("and", acc), ts, true
		}
		y, r2, ok := psPCmp(c, f, ts[1:])
		if !ok {
			return nil, nil, false
		}
		acc = append(acc, y)
		ts = r2
	}
}

// psPCmp is `Math.pCmp`: level 3, one comparison.
func psPCmp(c Ctx, f int, ts []Tok) (Json, []Tok, bool) {
	if f == 0 {
		return nil, nil, false
	}
	f--
	x, r, ok := psPAdd(c, f, ts)
	if !ok {
		return nil, nil, false
	}
	return psCmpLoop(c, f, x, r)
}

// psCmpLoop is `Math.cmpLoop`.
func psCmpLoop(c Ctx, f int, x Json, ts []Tok) (Json, []Tok, bool) {
	if f == 0 {
		return nil, nil, false
	}
	f--
	if len(ts) > 0 && ts[0].K == TKw {
		if o, ok := psCmpOf(ts[0].W); ok {
			y, r2, ok := psPAdd(c, f, ts[1:])
			if !ok {
				return nil, nil, false
			}
			return prNode(o, []Json{x, y}), r2, true
		}
	}
	return x, ts, true
}

// psPAdd is `Math.pAdd`: level 4, `+` chains and binary `-`.
func psPAdd(c Ctx, f int, ts []Tok) (Json, []Tok, bool) {
	if f == 0 {
		return nil, nil, false
	}
	f--
	x, r, ok := psPMul(c, f, ts)
	if !ok {
		return nil, nil, false
	}
	return psAddLoop(c, f, []Json{x}, r)
}

// psAddLoop is `Math.addLoop`. After negTail, Lean parses the list with the
// number's sign removed; here that list is built and the rest mapped back onto
// the input (the rest is a suffix of the input's tail either way).
func psAddLoop(c Ctx, f int, acc []Json, ts []Tok) (Json, []Tok, bool) {
	for {
		if f == 0 {
			return nil, nil, false
		}
		f--
		switch {
		case at(ts, 0, KwPlus):
			y, r2, ok := psPMul(c, f, ts[1:])
			if !ok {
				return nil, nil, false
			}
			acc = append(acc, y)
			ts = r2
		case at(ts, 0, KwMinus):
			y, r2, ok := psPMul(c, f, ts[1:])
			if !ok {
				return nil, nil, false
			}
			v, ok := c.lim.shallow(prNode("-", []Json{psClose("+", acc), y}))
			if !ok {
				return nil, nil, false
			}
			acc = []Json{v}
			ts = r2
		default:
			m, r, ok := psNegTail(ts)
			if !ok {
				return psClose("+", acc), ts, true
			}
			r1 := make([]Tok, 0, len(r)+1)
			r1 = append(r1, tNum(m))
			r1 = append(r1, r...)
			y, rest, ok := psPMul(c, f, r1)
			if !ok {
				return nil, nil, false
			}
			n := min(len(rest), len(r))
			v, ok := c.lim.shallow(prNode("-", []Json{psClose("+", acc), y}))
			if !ok {
				return nil, nil, false
			}
			acc = []Json{v}
			ts = r[len(r)-n:]
		}
	}
}

// psPMul is `Math.pMul`: level 5, unary minus and `*` chains.
func psPMul(c Ctx, f int, ts []Tok) (Json, []Tok, bool) {
	if f == 0 || !c.lim.enter() {
		return nil, nil, false
	}
	defer c.lim.leave()
	f--
	if at(ts, 0, KwMinus) {
		x, r2, ok := psPMul(c, f, ts[1:])
		if !ok {
			return nil, nil, false
		}
		return prNode("-", []Json{x}), r2, true
	}
	x, r, ok := psPNot(c, f, ts)
	if !ok {
		return nil, nil, false
	}
	return psMulLoop(c, f, []Json{x}, r)
}

// psMulLoop is `Math.mulLoop`.
func psMulLoop(c Ctx, f int, acc []Json, ts []Tok) (Json, []Tok, bool) {
	for {
		if f == 0 {
			return nil, nil, false
		}
		f--
		switch {
		case at(ts, 0, KwCdot) || at(ts, 0, KwTimes):
			y, r2, ok := psPNot(c, f, ts[1:])
			if !ok {
				return nil, nil, false
			}
			acc = append(acc, y)
			ts = r2
		case at(ts, 0, KwSlash):
			if c.sf != SfLatex {
				return psClose("*", acc), ts, true
			}
			y, r2, ok := psPNot(c, f, ts[1:])
			if !ok {
				return nil, nil, false
			}
			v, ok := c.lim.shallow(prNode("/", []Json{psClose("*", acc), y}))
			if !ok {
				return nil, nil, false
			}
			acc = []Json{v}
			ts = r2
		case len(ts) > 0:
			if !psAtomStart(ts[0]) || psNegTok(ts[0]) {
				return psClose("*", acc), ts, true
			}
			y, r2, ok := psPNot(c, f, ts)
			if !ok {
				return nil, nil, false
			}
			acc = append(acc, y)
			ts = r2
		default:
			return psClose("*", acc), ts, true
		}
	}
}

// psPNot is `Math.pNot`: level 6, `not`.
func psPNot(c Ctx, f int, ts []Tok) (Json, []Tok, bool) {
	if f == 0 || !c.lim.enter() {
		return nil, nil, false
	}
	defer c.lim.leave()
	f--
	if at(ts, 0, KwLnot) {
		x, r2, ok := psPNot(c, f, ts[1:])
		if !ok {
			return nil, nil, false
		}
		return prNode("not", []Json{x}), r2, true
	}
	if at(ts, 0, KwNabla) {
		o, rest := psNabTail(c.sf, ts[1:])
		x, r2, ok := psPNabArg(c, f, rest)
		if !ok {
			return nil, nil, false
		}
		return prNode(o, []Json{x}), r2, true
	}
	return psPFrac(c, f, ts)
}

// psPNabArg is `Math.pNabArg`: the operand of a `\nabla` form: another
// `\nabla` form, or a postfix-level operand.
func psPNabArg(c Ctx, f int, ts []Tok) (Json, []Tok, bool) {
	if f == 0 {
		return nil, nil, false
	}
	f--
	if at(ts, 0, KwNabla) {
		return psPNot(c, f, ts)
	}
	return psPPost(c, f, ts)
}

// psPFrac is `Math.pFrac`: level 7, the Typst fraction, grouping to the left.
func psPFrac(c Ctx, f int, ts []Tok) (Json, []Tok, bool) {
	if f == 0 {
		return nil, nil, false
	}
	f--
	x, r, ok := psPPow(c, f, ts)
	if !ok {
		return nil, nil, false
	}
	return psFracLoop(c, f, x, r)
}

// psFracLoop is `Math.fracLoop`.
func psFracLoop(c Ctx, f int, x Json, ts []Tok) (Json, []Tok, bool) {
	for {
		if f == 0 {
			return nil, nil, false
		}
		f--
		if !at(ts, 0, KwSlash) || c.sf != SfTypst {
			return x, ts, true
		}
		y, r2, ok := psPPow(c, f, ts[1:])
		if !ok {
			return nil, nil, false
		}
		x, ok = c.lim.shallow(prNode("/", []Json{x, y}))
		if !ok {
			return nil, nil, false
		}
		ts = r2
	}
}

// psPPow is `Math.pPow`: level 8, a power.
func psPPow(c Ctx, f int, ts []Tok) (Json, []Tok, bool) {
	if f == 0 {
		return nil, nil, false
	}
	f--
	x, r, ok := psPPost(c, f, ts)
	if !ok {
		return nil, nil, false
	}
	if at(r, 0, KwCaret) {
		y, r2, ok := psPExpo(c, f, r[1:])
		if !ok {
			return nil, nil, false
		}
		return prNode("^", []Json{x, y}), r2, true
	}
	return x, r, true
}

// psPExpo is `Math.pExpo`: an exponent: LaTeX `{…}`; Typst `(…)` or one simple
// token.
func psPExpo(c Ctx, f int, ts []Tok) (Json, []Tok, bool) {
	if f == 0 || len(ts) == 0 {
		return nil, nil, false
	}
	f--
	switch {
	case c.sf == SfLatex && ts[0].isKw(KwLb):
		y, r, ok := psPOr(c, f, ts[1:])
		if ok && at(r, 0, KwRb) {
			return y, r[1:], true
		}
	case c.sf == SfTypst && ts[0].isKw(KwLpg):
		y, r, ok := psPOr(c, f, ts[1:])
		if ok && len(r) > 0 && psIsRp(r[0]) {
			return y, r[1:], true
		}
	case c.sf == SfTypst:
		if prSimpleTok(ts[0]) {
			y, rest, ok := psPPrim(c, f, ts[:1])
			if ok && len(rest) == 0 {
				return y, ts[1:], true
			}
		}
	}
	return nil, nil, false
}

// psPPost is `Math.pPost`: level 9, postfix index, `_{…}` or `[…]`.
func psPPost(c Ctx, f int, ts []Tok) (Json, []Tok, bool) {
	if f == 0 {
		return nil, nil, false
	}
	f--
	x, r, ok := psPPrim(c, f, ts)
	if !ok {
		return nil, nil, false
	}
	return psPostLoop(c, f, x, r)
}

// psIndexNode is the `index` node of x by is.
func psIndexNode(x Json, is []Json) Json {
	args := make([]Json, 0, len(is)+1)
	args = append(args, x)
	return prNode("index", append(args, is...))
}

// psPostLoop is `Math.postLoop`.
func psPostLoop(c Ctx, f int, x Json, ts []Tok) (Json, []Tok, bool) {
	for {
		if f == 0 {
			return nil, nil, false
		}
		f--
		switch {
		case at(ts, 0, KwUs):
			r := ts[1:]
			switch {
			case c.sf == SfLatex && at(r, 0, KwLb):
				is, r2, ok := psPList(c, f, 1, r[1:])
				if !ok || !at(r2, 0, KwRb) || len(is) == 0 {
					return nil, nil, false
				}
				x = psIndexNode(x, is)
				ts = r2[1:]
			case c.sf == SfTypst && at(r, 0, KwLpg):
				is, r2, ok := psPList(c, f, 1, r[1:])
				if !ok || len(r2) == 0 || !psIsRp(r2[0]) || len(is) == 0 {
					return nil, nil, false
				}
				x = psIndexNode(x, is)
				ts = r2[1:]
			case c.sf == SfTypst && len(r) > 0 && prSimpleTok(r[0]):
				i, rest, ok := psPPrim(c, f, r[:1])
				if !ok || len(rest) != 0 {
					return nil, nil, false
				}
				x = prNode("index", []Json{x, i})
				ts = r[1:]
			default:
				return nil, nil, false
			}
		case at(ts, 0, KwLbk):
			is, r2, ok := psPList(c, f, 1, ts[1:])
			if !ok || !at(r2, 0, KwRbk) || len(is) == 0 {
				return nil, nil, false
			}
			x = psIndexNode(x, is)
			ts = r2[1:]
		default:
			return x, ts, true
		}
	}
}

// psPList is `Math.pList`: a comma-separated list of expressions at level l (1
// or 4), possibly empty when the next token closes it.
func psPList(c Ctx, f, l int, ts []Tok) ([]Json, []Tok, bool) {
	if f == 0 {
		return nil, nil, false
	}
	f--
	if len(ts) == 0 {
		return []Json{}, ts, true
	}
	if t := ts[0]; psIsRp(t) || t.isKw(KwRb) || t.isKw(KwRbk) {
		return []Json{}, ts, true
	}
	return psPItems(c, f, l, ts)
}

// psPItems is `Math.pItems`.
func psPItems(c Ctx, f, l int, ts []Tok) ([]Json, []Tok, bool) {
	out := []Json{}
	for {
		if f == 0 {
			return nil, nil, false
		}
		f--
		x, r, ok := psPLv(c, f, l, ts)
		if !ok {
			return nil, nil, false
		}
		out = append(out, x)
		if !at(r, 0, KwComma) {
			return out, r, true
		}
		ts = r[1:]
	}
}

// psPLv is `Math.pLv`: parse at level 1 or level 4.
func psPLv(c Ctx, f, l int, ts []Tok) (Json, []Tok, bool) {
	if f == 0 {
		return nil, nil, false
	}
	f--
	if l == 4 {
		return psPAdd(c, f, ts)
	}
	return psPOr(c, f, ts)
}

// psPCallArgs is `Math.pCallArgs`: call arguments at level 4: each
// positional, or `name = value`.
func psPCallArgs(c Ctx, f int, ts []Tok) ([]CallArg, []Tok, bool) {
	if f == 0 {
		return nil, nil, false
	}
	f--
	if at(ts, 0, KwRp) || at(ts, 0, KwSemi) {
		return []CallArg{}, ts, true
	}
	return psPCallItems(c, f, ts)
}

// psPCallItems is `Math.pCallItems`.
func psPCallItems(c Ctx, f int, ts []Tok) ([]CallArg, []Tok, bool) {
	out := []CallArg{}
	for {
		if f == 0 {
			return nil, nil, false
		}
		f--
		x, r, ok := psPAdd(c, f, ts)
		if !ok {
			return nil, nil, false
		}
		if k, isStr := x.(string); isStr && at(r, 0, KwEq) {
			v, r2, ok := psPAdd(c, f, r[1:])
			if !ok {
				return nil, nil, false
			}
			out = append(out, CallArg{Named: true, K: k, V: v})
			if !at(r2, 0, KwComma) {
				return out, r2, true
			}
			ts = r2[1:]
			continue
		}
		out = append(out, CallArg{V: x})
		if !at(r, 0, KwComma) {
			return out, r, true
		}
		ts = r[1:]
	}
}

// psPFields is `Math.pFields`: open-operator fields after `;`.
func psPFields(c Ctx, f int, ts []Tok) (Obj, []Tok, bool) {
	out := Obj{}
	for {
		if f == 0 {
			return nil, nil, false
		}
		f--
		k, r, ok := psKeyOf(c, ts)
		if !ok {
			return nil, nil, false
		}
		v, r2, ok := psPVal(c, f, r)
		if !ok {
			return nil, nil, false
		}
		out = append(out, KV{k, v})
		if !at(r2, 0, KwComma) {
			return out, r2, true
		}
		ts = r2[1:]
	}
}

// psPVal is `Math.pVal`: a field value: JSON (LaTeX JSON tokens, Typst
// `#value`) or an expression.
func psPVal(c Ctx, f int, ts []Tok) (Json, []Tok, bool) {
	if f == 0 {
		return nil, nil, false
	}
	f--
	if c.sf == SfTypst {
		if len(ts) > 0 && ts[0].K == TCode {
			return ts[0].J, ts[1:], true
		}
		return psPAdd(c, f, ts)
	}
	if psJsonStart(ts) {
		return psPJson(c.lim, f, ts)
	}
	return psPAdd(c, f, ts)
}

func psNodupKeys(xs Obj) bool {
	for i, x := range xs {
		for _, y := range xs[:i] {
			if y.K == x.K {
				return false
			}
		}
	}
	return true
}

// psPOpn is `Math.pOpn`: `\operatorname{n}(…)`.
func psPOpn(c Ctx, f int, n string, ts []Tok) (Json, []Tok, bool) {
	if f == 0 {
		return nil, nil, false
	}
	if len(ts) == 0 {
		if psBareTnameOk(c.s, n) {
			return psTNode(n, Obj{}), ts, true
		}
		return nil, nil, false
	}
	f--
	t0, r := ts[0], ts[1:]
	if psIsLp(t0) {
		args, r1, ok := psPCallArgs(c, f, r)
		if !ok {
			return nil, nil, false
		}
		switch {
		case at(r1, 0, KwRp):
			r2 := r1[1:]
			switch {
			case slices.Contains(prCallOps, n):
				vs, ok := psAllPos(args)
				if !ok {
					return nil, nil, false
				}
				return prNode(n, vs), r2, true
			case n == "neg":
				vs, ok := psAllPos(args)
				if !ok || len(vs) != 1 {
					return nil, nil, false
				}
				return prNode("-", []Json{vs[0]}), r2, true
			case n == "pow":
				vs, ok := psAllPos(args)
				if !ok || len(vs) != 2 {
					return nil, nil, false
				}
				return prNode("^", []Json{vs[0], vs[1]}), r2, true
			case slices.Contains(exprRemovedOps, n) || n == "D":
				return nil, nil, false
			}
			ps, hasPs := prTparams(c.s, n)
			vs, allPos := psAllPos(args)
			bs, allNamed := psAllNamed(args)
			switch {
			case hasPs && allPos:
				if len(ps) != len(vs) {
					return nil, nil, false
				}
				zs := make(Obj, len(ps))
				for i, p := range ps {
					zs[i] = KV{p, vs[i]}
				}
				return psTNode(n, psSortKv(zs)), r2, true
			case allNamed && len(bs) > 0:
				if !psNodupKeys(bs) {
					return nil, nil, false
				}
				return psTNode(n, psSortKv(bs)), r2, true
			case !hasPs && allPos:
				return prMkNode(n, vs, Obj{}), r2, true
			}
			return nil, nil, false
		case at(r1, 0, KwSemi):
			if slices.Contains(exprRemovedOps, n) {
				return nil, nil, false
			}
			vs, ok1 := psAllPos(args)
			fs, r2, ok2 := psPFields(c, f, r1[1:])
			if ok1 && ok2 && at(r2, 0, KwRp) && psPrintsCallForm(c, n, vs, fs) {
				return prMkNode(n, vs, fs), r2[1:], true
			}
		}
		return nil, nil, false
	}
	if t0.isKw(KwUs) {
		if n == "D" {
			return psPDCall(c, f, r)
		}
		return nil, nil, false
	}
	if psBareTnameOk(c.s, n) {
		return psTNode(n, Obj{}), ts, true
	}
	return nil, nil, false
}

// psPrintsCallForm is whether the node `\operatorname{n}(vs; fs)` reads as
// is one the printer writes in that form: the fields fs are distinct and
// none is `op` or `args`, its call-form test holds (prOpnCallOk: an
// annotation field refuses a core operator only) and its dispatch gives it
// no native spelling (a `faq`, `makearray` or `const` that prints natively).
// A field key that is not an identifier is still read (the printer escapes
// it).
func psPrintsCallForm(c Ctx, n string, vs []Json, fs Obj) bool {
	if !psNodupKeys(fs) || !prOpnCallOk(c.s, n, fs) {
		return false
	}
	for _, kv := range fs {
		if kv.K == "op" || kv.K == "args" {
			return false
		}
	}
	_, native := prNative(c, prMkNode(n, vs, fs).(Obj))
	return !native
}

// psBareTnameOk is whether a bare `\operatorname{n}` reads as a template
// applied with no bindings: the printer writes that node bare unless a
// template n with no parameters is in scope, which it writes `n()`.
func psBareTnameOk(s *Sym, n string) bool {
	if ps, ok := prTparams(s, n); ok && len(ps) == 0 {
		return false
	}
	return prTnameOk(n)
}

// psPDCall is `Math.pDCall`: `\operatorname{D}_{x}(u, a, b)` after the `_`.
func psPDCall(c Ctx, f int, ts []Tok) (Json, []Tok, bool) {
	if f == 0 {
		return nil, nil, false
	}
	f--
	var w string
	var r2 []Tok
	switch {
	case c.sf == SfLatex && at(ts, 0, KwLb):
		n, r, ok := psPName(c.sf, ts[1:])
		if !ok || !at(r, 0, KwRb) {
			return nil, nil, false
		}
		w, r2 = n, r[1:]
	case c.sf == SfTypst && at(ts, 0, KwLpg):
		n, r, ok := psPName(c.sf, ts[1:])
		if !ok || !at(r, 0, KwRp) {
			return nil, nil, false
		}
		w, r2 = n, r[1:]
	default:
		return nil, nil, false
	}
	if len(r2) == 0 || !psIsLp(r2[0]) {
		return nil, nil, false
	}
	args, r4, ok := psPCallArgs(c, f, r2[1:])
	if !ok || !at(r4, 0, KwRp) {
		return nil, nil, false
	}
	xs, ok := psAllPos(args)
	if !ok {
		return nil, nil, false
	}
	return psDCallNode(w, xs), r4[1:], true
}

// psNoteRemovedOp records a removed operator written in the call or escape
// form at the front of ts, so a refusal can name it (CONFORMANCE §7.1). Not in
// Lean, whose reader refuses every bad input alike.
func psNoteRemovedOp(lim *Lim, ts []Tok) {
	var name string
	switch {
	case len(ts) > 0 && (ts[0].K == TOpn || ts[0].K == TEsc):
		name = ts[0].S
	case len(ts) > 2 && ts[0].isKw(KwEsmnode) && ts[2].K == TTxt:
		name = ts[2].S
	default:
		return
	}
	if slices.Contains(exprRemovedOps, name) {
		lim.noteRemovedOp(name)
	}
}

func psOpAllowed(o string) bool {
	return exprOpOk(o) && !slices.Contains(exprRemovedOps, o) && !slices.Contains(exprDeprecatedOps, o)
}

// psPPrim is `Math.pPrim`: a primary. The cases are tried in the order of the
// Rust match; a case whose shape matches decides the result.
func psPPrim(c Ctx, f int, ts []Tok) (Json, []Tok, bool) {
	if f == 0 {
		return nil, nil, false
	}
	f--
	psNoteRemovedOp(c.lim, ts)
	fail := func() (Json, []Tok, bool) { return nil, nil, false }
	parenClose := func(r []Tok) (Json, []Tok, bool) {
		x, r1, ok := psPOr(c, f, r)
		if ok && len(r1) > 0 && psIsRp(r1[0]) {
			return x, r1[1:], true
		}
		return fail()
	}
	closed := func(r []Tok, k Kw, o string) (Json, []Tok, bool) {
		x, r1, ok := psPOr(c, f, r)
		if ok && at(r1, 0, k) {
			return prNode(o, []Json{x}), r1[1:], true
		}
		return fail()
	}
	if len(ts) == 0 {
		return psPPrimDefault(c, f, ts)
	}
	t0 := ts[0]
	r := ts[1:]
	if t0.K == TNum {
		if len(r) > 0 && r[0].K == TUnits {
			return psQty(t0.N, r[0].U), r[1:], true
		}
		return t0.N, r, true
	}
	if t0.isKw(KwBmat) {
		rows, r2, ok := psPGrid(KwAmp, KwNl, KwEmat, r)
		if !ok {
			return fail()
		}
		// a matrix wider than a bmatrix holds prints as an array
		for _, row := range rows {
			if len(row) > prBmatMaxCols {
				return fail()
			}
		}
		return psConstTail(psGridJson(rows), r2)
	}
	if t0.isKw(KwLbkg) && len(r) > 0 && r[0].K == TArrC {
		n := r[0].Cols
		rows, r2, ok := psPGrid(KwAmp, KwNl, KwEarr, r[1:])
		if !ok || n <= prBmatMaxCols || !at(r2, 0, KwRbkg) {
			return fail()
		}
		for _, row := range rows {
			if len(row) != n {
				return fail()
			}
		}
		return psConstTail(psGridJson(rows), r2[1:])
	}
	if t0.isKw(KwVec) && len(r) >= 1 {
		if !psIsLp(r[0]) {
			return fail()
		}
		ns, r2, ok := psPCells(KwComma, r[1:])
		if ok && at(r2, 0, KwRp) {
			return psConstTail(psNumsJson(ns), r2[1:])
		}
		return fail()
	}
	if t0.isKw(KwMat) && psMatHead(r) {
		rows, r2, ok := psPMkRows(c, f, KwComma, KwSemi, KwRp, r[len(prMatHead())-1:])
		if !ok {
			return fail()
		}
		return psMkTail(c.sf, rows, r2)
	}
	if t0.isKw(KwMat) && len(r) >= 1 {
		if !psIsLp(r[0]) {
			return fail()
		}
		rows, r2, ok := psPGrid(KwComma, KwSemi, KwRp, r[1:])
		if !ok {
			return fail()
		}
		out := make([]Json, len(rows))
		for i, q := range rows {
			out[i] = psNumsJson(q)
		}
		return psConstTail(out, r2)
	}
	if t0.K == TTxt && t0.S == "true" {
		return prNode("true", []Json{}), r, true
	}
	if t0.K == TTxt && t0.S == "false" {
		return prNode("false", []Json{}), r, true
	}
	if t0.isKw(KwLpg) || t0.isKw(KwLp) {
		if c.sf == SfTypst && at(r, 0, KwDif) {
			return psPDt(c, f, KwDif, r[1:])
		}
		if c.sf == SfTypst && atKws(r, KwPdiff, KwUs) {
			x, r2, ok := psPOr(c, f, r)
			if ok && len(r2) > 0 && psIsRp(r2[0]) {
				return x, r2[1:], true
			}
			return fail()
		}
		if c.sf == SfTypst && at(r, 0, KwPdiff) {
			return psPDt(c, f, KwPdiff, r[1:])
		}
		if c.sf == SfTypst && len(r) > 0 && r[0].K == TLetter && r[0].C == 'd' {
			if x, r2, ok := psPItalicD(c, r); ok {
				return x, r2, true
			}
			return parenClose(r)
		}
		return parenClose(r)
	}
	if t0.isKw(KwLbk) {
		x, r2, ok := psPOr(c, f, r)
		if ok && at(r2, 0, KwRbk) {
			return x, r2[1:], true
		}
		return fail()
	}
	if t0.isKw(KwFrac) && at(r, 0, KwLb) {
		return psPFracL(c, f, r[1:])
	}
	if t0.isKw(KwPdiff) && at(r, 0, KwUs) {
		return psPDCall(c, f, r[1:])
	}
	if t0.isKw(KwSqrt) {
		switch {
		case c.sf == SfLatex && at(r, 0, KwLb):
			return closed(r[1:], KwRb, "sqrt")
		case c.sf == SfTypst && len(r) > 0:
			if psIsLp(r[0]) {
				return psPFn1(c, f, "sqrt", r[1:])
			}
		}
		return fail()
	}
	if t0.isKw(KwLog) && at(r, 0, KwUs) {
		r = r[1:]
		switch {
		case c.sf == SfLatex && len(r) >= 4 && r[0].isKw(KwLb) && r[1].isNum(10) && r[2].isKw(KwRb):
			if psIsLp(r[3]) {
				return psPFn1(c, f, "log10", r[4:])
			}
		case c.sf == SfTypst && len(r) >= 2 && r[0].isNum(10):
			if psIsLp(r[1]) {
				return psPFn1(c, f, "log10", r[2:])
			}
		}
		return fail()
	}
	if t0.isKw(KwLabs) {
		return closed(r, KwRabs, "abs")
	}
	if t0.isKw(KwLfloor) {
		return closed(r, KwRfloor, "floor")
	}
	if t0.isKw(KwLceil) {
		return closed(r, KwRceil, "ceil")
	}
	if (t0.isKw(KwMin) || t0.isKw(KwMax)) && len(r) >= 1 {
		if !r[0].isKw(KwLp) {
			return psPRed(c, f, ts)
		}
		xs, r2, ok := psPList(c, f, 1, r[1:])
		if ok && at(r2, 0, KwRp) && len(xs) >= 2 {
			o := "max"
			if t0.W == KwMin {
				o = "min"
			}
			return prNode(o, xs), r2[1:], true
		}
		return fail()
	}
	if t0.isKw(KwLbkg) && at(r, 0, KwBarr) {
		rows, r2, ok := psPMkRows(c, f, KwAmp, KwNl, KwEarr, r[1:])
		if !ok || !at(r2, 0, KwRbkg) {
			return fail()
		}
		return psMkTail(c.sf, rows, r2[1:])
	}
	if t0.isKw(KwSum) || t0.isKw(KwProd) || t0.isKw(KwLimits) || t0.isKw(KwLbkg) {
		return psPRed(c, f, ts)
	}
	if atKws(ts, KwLr, KwLp, KwLbk) {
		return psPRed(c, f, ts)
	}
	if t0.K == TOpn {
		return psPOpn(c, f, t0.S, r)
	}
	if t0.isKw(KwBcases) {
		return psPCases(c, f, r)
	}
	if t0.isKw(KwCases) && len(r) >= 1 {
		if psIsLp(r[0]) {
			return psPCases(c, f, r[1:])
		}
		return fail()
	}
	if t0.K == TEsc && at(r, 0, KwLb) {
		fsv, r1, ok := psPJson(c.lim, f, r[1:])
		fs, isObj := fsv.(Obj)
		if !ok || !isObj || !atKws(r1, KwRb, KwLb) {
			return fail()
		}
		args, r2, ok := psPList(c, f, 1, r1[2:])
		if !ok || !at(r2, 0, KwRb) || !psOpAllowed(t0.S) {
			return fail()
		}
		return prMkNode(t0.S, args, fs), r2[1:], true
	}
	if t0.isKw(KwEsmnode) && len(ts) >= 5 && ts[2].K == TTxt && ts[3].isKw(KwComma) && ts[4].K == TCode {
		if fs, isObj := ts[4].J.(Obj); isObj {
			if !psIsLp(ts[1]) {
				return fail()
			}
			args, r2, ok := psPEscArgs(c, f, ts[5:])
			if !ok || !psOpAllowed(ts[2].S) {
				return fail()
			}
			return prMkNode(ts[2].S, args, fs), r2, true
		}
	}
	if t0.isKw(KwDotacc) && at(r, 0, KwLb) {
		x, r2, ok := psPOr(c, f, r[1:])
		if ok && at(r2, 0, KwRb) {
			return psDNode(x, "t"), r2[1:], true
		}
		return fail()
	}
	if t0.isKw(KwCdot) && at(r, 0, KwLp) {
		x, r2, ok := psPOr(c, f, r[1:])
		if ok && at(r2, 0, KwRp) {
			return psDNode(x, "t"), r2[1:], true
		}
		return fail()
	}
	if t0.K == TKw && len(r) >= 1 {
		if !psIsLp(r[0]) {
			return fail()
		}
		r1 := r[1:]
		switch t0.W {
		case KwLog:
			return psPFn1(c, f, "log", r1)
		case KwAbs:
			return psPFn1(c, f, "abs", r1)
		case KwFloor:
			return psPFn1(c, f, "floor", r1)
		case KwCeil:
			return psPFn1(c, f, "ceil", r1)
		}
		if o, ok := psFnOf(t0.W); ok {
			return psPFn1(c, f, o, r1)
		}
		return fail()
	}
	if t0.K == TWord {
		return psPWord(c, t0.S, r)
	}
	return psPPrimDefault(c, f, ts)
}

// psPPrimDefault is the last case of `Math.pPrim`: e raised to a power, or a
// name.
func psPPrimDefault(c Ctx, f int, ts []Tok) (Json, []Tok, bool) {
	if psEulerHead(c, ts) {
		return psPEulerExp(c, f, ts[2:])
	}
	return psPNamePrim(c, ts)
}

// psPEulerExp is `Math.pEulerExp`: `\exp` written as a power of e.
func psPEulerExp(c Ctx, f int, ts []Tok) (Json, []Tok, bool) {
	if f == 0 {
		return nil, nil, false
	}
	f--
	y, r, ok := psPExpo(c, f, ts)
	if !ok {
		return nil, nil, false
	}
	return prNode("exp", []Json{y}), r, true
}

// psPSet is `Math.pSet`: an index set's name: a name, or in Typst one upright
// word.
func psPSet(sf Sf, ts []Tok) (string, []Tok, bool) {
	if s, r, ok := psPName(sf, ts); ok {
		return s, r, true
	}
	if sf == SfTypst && len(ts) > 0 && ts[0].K == TUps && len(ts[0].Ups) == 1 && ts[0].Ups[0].B == "" {
		return ts[0].Ups[0].A, ts[1:], true
	}
	return "", nil, false
}

// psPRange is `Math.pRange`: a range row: `k \in S`, `k \in S(i, j)`,
// `a \le k \le b`.
func psPRange(c Ctx, f int, ts []Tok) (Row, []Tok, bool) {
	if f == 0 {
		return Row{}, nil, false
	}
	f--
	x, r, ok := psPAdd(c, f, ts)
	if !ok {
		return Row{}, nil, false
	}
	if k, isStr := x.(string); isStr && at(r, 0, KwInn) {
		s, r2, ok := psPSet(c.sf, r[1:])
		if !ok {
			return Row{}, nil, false
		}
		if at(r2, 0, KwLp) {
			ps, r3, ok := psPNames(c.sf, r2[1:])
			if !ok || !at(r3, 0, KwRp) {
				return Row{}, nil, false
			}
			of := make([]Json, len(ps))
			for i, p := range ps {
				of[i] = p
			}
			return Row{IsRng: true, K: k, V: Obj{{"from", s}, {"of", of}}}, r3[1:], true
		}
		return Row{IsRng: true, K: k, V: Obj{{"from", s}}}, r2, true
	}
	if at(r, 0, KwLe) {
		y, r2, ok := psPAdd(c, f, r[1:])
		k, isStr := y.(string)
		if !ok || !isStr || !at(r2, 0, KwLe) {
			return Row{}, nil, false
		}
		b, r3, ok := psPAdd(c, f, r2[1:])
		if !ok {
			return Row{}, nil, false
		}
		return Row{IsRng: true, K: k, V: []Json{x, b}}, r3, true
	}
	return Row{}, nil, false
}

// psPRow is `Math.pRow`: a row ending at a token isEnd accepts: an expression
// read whole first, else a range.
func psPRow(c Ctx, f int, isEnd func(Tok) bool, ts []Tok) (Row, []Tok, bool) {
	if f == 0 {
		return Row{}, nil, false
	}
	f--
	if x, r, ok := psPOr(c, f, ts); ok && len(r) > 0 && isEnd(r[0]) {
		return Row{V: x}, r, true
	}
	return psPRange(c, f, ts)
}

// psPRows is `Math.pRows`: rows separated by sep, up to closeK (consumed).
func psPRows(c Ctx, f int, sep, closeK Kw, ts []Tok) ([]Row, []Tok, bool) {
	var out []Row
	isEnd := func(t Tok) bool { return t.isKw(sep) || t.isKw(closeK) }
	for {
		if f == 0 {
			return nil, nil, false
		}
		f--
		row, r, ok := psPRow(c, f, isEnd, ts)
		if !ok || len(r) == 0 || r[0].K != TKw {
			return nil, nil, false
		}
		out = append(out, row)
		switch r[0].W {
		case sep:
			ts = r[1:]
		case closeK:
			return out, r[1:], true
		default:
			return nil, nil, false
		}
	}
}

// psPRedBody is `Math.pRedBody`: a reduction after its operator: the
// subscript rows, then the body.
func psPRedBody(c Ctx, f int, red RedK, marked bool, ts []Tok) (FaqForm, []Tok, bool) {
	if f == 0 {
		return FaqForm{}, nil, false
	}
	f--
	var rs []Row
	var r []Tok
	if c.sf == SfLatex {
		switch {
		case atKws(ts, KwUs, KwLb, KwSubstack, KwLb):
			rows, r1, ok := psPRows(c, f, KwNl, KwRb, ts[4:])
			if !ok || !at(r1, 0, KwRb) {
				return FaqForm{}, nil, false
			}
			rs, r = rows, r1[1:]
		case atKws(ts, KwUs, KwLb):
			row, r1, ok := psPRow(c, f, func(t Tok) bool { return t.isKw(KwRb) }, ts[2:])
			if !ok {
				return FaqForm{}, nil, false
			}
			k, a, isEq := psLoneEq(row)
			switch {
			case isEq && atKws(r1, KwRb, KwCaret, KwLb, KwLset):
				// a lone equality filter, then a superscript set
				rs, r = []Row{row}, r1[1:]
			case isEq && atKws(r1, KwRb, KwCaret, KwLb):
				b, r3, ok := psPOr(c, f, r1[3:])
				if !ok || !at(r3, 0, KwRb) {
					return FaqForm{}, nil, false
				}
				rs, r = []Row{{IsRng: true, K: k, V: []Json{a, b}}}, r3[1:]
			case at(r1, 0, KwRb):
				rs, r = []Row{row}, r1[1:]
			default:
				return FaqForm{}, nil, false
			}
		default:
			rs, r = nil, ts
		}
	} else {
		if atKws(ts, KwUs, KwLpg) {
			rows, r1, ok := psPRows(c, f, KwNl, KwRp, ts[2:])
			if !ok {
				return FaqForm{}, nil, false
			}
			rs, r = rows, r1
		} else {
			rs, r = nil, ts
		}
	}
	rg, fl, hasFl, ok1 := psRowParts(rs)
	st, r1, ok2 := psPSup(c.sf, r)
	// a marked head lists the body's arrays as `args`, so a set there has no
	// meaning: refused rather than dropped
	if !ok1 || !ok2 || (marked && len(st) > 0) {
		return FaqForm{}, nil, false
	}
	body, r2, ok := psPMul(c, f, r1)
	if !ok {
		return FaqForm{}, nil, false
	}
	return FaqForm{red: red, marked: marked, out: []Json{}, ranges: rg, expr: body, filter: fl, hasFlt: hasFl, set: st}, r2, true
}

// psLoneEq is the `.obj [("args", .arr [.str k, a]), ("op", .str "==")]`
// pattern of pRedBody, on a filter row.
func psLoneEq(row Row) (string, Json, bool) {
	if row.IsRng {
		return "", nil, false
	}
	kvs, ok := row.V.(Obj)
	if !ok || len(kvs) != 2 || kvs[0].K != "args" || kvs[1].K != "op" {
		return "", nil, false
	}
	xs, ok1 := kvs[0].V.([]Json)
	o, ok2 := kvs[1].V.(string)
	if !ok1 || !ok2 || o != "==" || len(xs) != 2 {
		return "", nil, false
	}
	k, ok := xs[0].(string)
	if !ok {
		return "", nil, false
	}
	return k, xs[1], true
}

// psPRed is `Math.pRed`: a rank-0 reduction, or a reduction wrapped with its
// output entries.
func psPRed(c Ctx, f int, ts []Tok) (Json, []Tok, bool) {
	if f == 0 {
		return nil, nil, false
	}
	f--
	wrapped := func(r []Tok, bracket []Kw, open, closeK Kw) (Json, []Tok, bool) {
		red, marked, r1, ok := psPRedHead(c.sf, r)
		if !ok {
			return nil, nil, false
		}
		form, r2, ok := psPRedBody(c, f, red, marked, r1)
		// the printer writes an output form's set on the bracket, never on the
		// reduction inside it
		if !ok || len(form.set) > 0 || !atKws(r2, bracket...) {
			return nil, nil, false
		}
		st, r3, ok := psPSup(c.sf, r2[len(bracket):])
		if !ok || (marked && len(st) > 0) || !atKws(r3, KwUs, open) {
			return nil, nil, false
		}
		es, r4, ok := psPRows(c, f, KwComma, closeK, r3[2:])
		if !ok {
			return nil, nil, false
		}
		outs, ors, ok := psEntryParts(es)
		if !ok {
			return nil, nil, false
		}
		return prFaqJson(psWithSup(psWithOut(form, outs, ors), st)), r4, true
	}
	if at(ts, 0, KwLbkg) {
		return wrapped(ts[1:], []Kw{KwRbkg}, KwLb, KwRb)
	}
	if atKws(ts, KwLr, KwLp, KwLbk) {
		return wrapped(ts[3:], []Kw{KwRbk, KwRp}, KwLpg, KwRp)
	}
	red, marked, r1, ok := psPRedHead(c.sf, ts)
	if !ok {
		return nil, nil, false
	}
	form, r, ok := psPRedBody(c, f, red, marked, r1)
	if !ok {
		return nil, nil, false
	}
	return prFaqJson(form), r, true
}

// psPFn1 is `Math.pFn1`: `f(x)` after the opening parenthesis.
func psPFn1(c Ctx, f int, o string, ts []Tok) (Json, []Tok, bool) {
	if f == 0 {
		return nil, nil, false
	}
	f--
	x, r, ok := psPOr(c, f, ts)
	if ok && at(r, 0, KwRp) {
		return prNode(o, []Json{x}), r[1:], true
	}
	return nil, nil, false
}

func psIsRm(t Tok, s string) bool { return t.K == TRm && t.S == s }

// psPFracL is `Math.pFracL`: after `\frac{`: a time or spatial derivative, the
// italic-d variant, or a quotient.
func psPFracL(c Ctx, f int, ts []Tok) (Json, []Tok, bool) {
	if f == 0 {
		return nil, nil, false
	}
	f--
	isT := func(t Tok) bool { return t.K == TLetter && t.C == 't' }
	if len(ts) >= 6 && psIsRm(ts[0], "d") && ts[1].isKw(KwRb) && ts[2].isKw(KwLb) && psIsRm(ts[3], "d") &&
		isT(ts[4]) && ts[5].isKw(KwRb) {
		return psPDApply(c, f, "t", ts[6:])
	}
	if len(ts) >= 1 && psIsRm(ts[0], "d") {
		x, r, ok := psPOr(c, f, ts[1:])
		if ok && len(r) >= 5 && r[0].isKw(KwRb) && r[1].isKw(KwLb) && psIsRm(r[2], "d") && isT(r[3]) && r[4].isKw(KwRb) {
			return psDNode(x, "t"), r[5:], true
		}
		return nil, nil, false
	}
	if atKws(ts, KwPdiff, KwRb, KwLb, KwPdiff) {
		w, r, ok := psPName(c.sf, ts[4:])
		if ok && at(r, 0, KwRb) {
			return psPDApply(c, f, w, r[1:])
		}
		return nil, nil, false
	}
	if atKws(ts, KwPdiff, KwUs) {
		x, r1, ok := psPOr(c, f, ts)
		if ok && atKws(r1, KwRb, KwLb) {
			y, r2, ok := psPOr(c, f, r1[2:])
			if ok && at(r2, 0, KwRb) {
				return prNode("/", []Json{x, y}), r2[1:], true
			}
		}
		return nil, nil, false
	}
	if at(ts, 0, KwPdiff) {
		x, r, ok := psPOr(c, f, ts[1:])
		if ok && atKws(r, KwRb, KwLb, KwPdiff) {
			w, r2, ok := psPName(c.sf, r[3:])
			if ok && at(r2, 0, KwRb) {
				return psDerivNode(x, w), r2[1:], true
			}
		}
		return nil, nil, false
	}
	if x, r, ok := psPItalicD(c, ts); ok {
		return x, r, true
	}
	x, r1, ok := psPOr(c, f, ts)
	if ok && atKws(r1, KwRb, KwLb) {
		y, r2, ok := psPOr(c, f, r1[2:])
		if ok && at(r2, 0, KwRb) {
			return prNode("/", []Json{x, y}), r2[1:], true
		}
	}
	return nil, nil, false
}

// psPDt is `Math.pDT`: `(dif N)/(dif t)` and `(partial u)/(partial x)` after
// the first `(dif` / `(partial`.
func psPDt(c Ctx, f int, k Kw, ts []Tok) (Json, []Tok, bool) {
	if f == 0 {
		return nil, nil, false
	}
	f--
	if len(ts) >= 4 && ts[0].isKw(KwRp) && ts[1].isKw(KwSlash) && ts[2].isKw(KwLpg) && ts[3].K == TKw {
		if ts[3].W != k {
			return nil, nil, false
		}
		w, r2, ok := psPName(c.sf, ts[4:])
		if !ok || !at(r2, 0, KwRp) || (k == KwDif && w != "t") {
			return nil, nil, false
		}
		return psPDApply(c, f, w, r2[1:])
	}
	x, r, ok := psPOr(c, f, ts)
	if !ok || len(r) < 4 || !r[0].isKw(KwRp) || !r[1].isKw(KwSlash) || !r[2].isKw(KwLpg) || r[3].K != TKw || r[3].W != k {
		return nil, nil, false
	}
	w, r2, ok := psPName(c.sf, r[4:])
	if !ok || !at(r2, 0, KwRp) || (k == KwDif && w != "t") {
		return nil, nil, false
	}
	return psDerivNode(x, w), r2[1:], true
}

// psPDApply is `Math.pDApply`: a derivative operator applied to a
// parenthesized operand.
func psPDApply(c Ctx, f int, w string, ts []Tok) (Json, []Tok, bool) {
	if f == 0 || !at(ts, 0, KwLpg) {
		return nil, nil, false
	}
	f--
	x, r, ok := psPOr(c, f, ts[1:])
	if ok && len(r) > 0 && psIsRp(r[0]) {
		return psDerivNode(x, w), r[1:], true
	}
	return nil, nil, false
}

// psPCases is `Math.pCases`: `cases` rows; a chain re-nests to the right.
func psPCases(c Ctx, f int, ts []Tok) (Json, []Tok, bool) {
	if f == 0 || !c.lim.enter() {
		return nil, nil, false
	}
	defer c.lim.leave()
	f--
	v, r0, ok := psPOr(c, f, ts)
	if !ok || len(r0) < 2 || !r0[0].isKw(KwAmp) || r0[1].K != TTxt {
		return nil, nil, false
	}
	r := r0[2:]
	switch r0[1].S {
	case "otherwise":
		if c.sf == SfLatex && at(r, 0, KwEcases) {
			return v, r[1:], true
		}
		if c.sf == SfTypst && at(r, 0, KwRp) {
			return v, r[1:], true
		}
	case "if ":
		cnd, r2, ok := psPOr(c, f, r)
		if !ok || len(r2) == 0 || r2[0].K != TKw {
			return nil, nil, false
		}
		brk := KwComma
		if c.sf == SfLatex {
			brk = KwNl
		}
		if r2[0].W != brk {
			return nil, nil, false
		}
		e, r3, ok := psPCases(c, f, r2[1:])
		if !ok {
			return nil, nil, false
		}
		return prNode("ifelse", []Json{cnd, v, e}), r3, true
	}
	return nil, nil, false
}

// psMatHead reports whether r, after `mat`, is the rest of the Typst table
// head `(delim: "[", augment: #1,` (prMatHead).
func psMatHead(r []Tok) bool {
	h := prMatHead()[1:]
	if len(r) < len(h) {
		return false
	}
	for i, t := range h {
		if t.K == TCode {
			if n, ok := r[i].J.(JNum); r[i].K != TCode || !ok || !n.IsInt(1) {
				return false
			}
		} else if !r[i].Equal(t) {
			return false
		}
	}
	return true
}

// mkRow is a row of a `makearray` table read back: the value and its region.
type mkRow struct {
	v   Json
	reg []Pair
}

// psPPair is `Math.pPair`: a bound pair after its `[`: `a, b]`.
func psPPair(c Ctx, f int, ts []Tok) (Pair, []Tok, bool) {
	if f == 0 {
		return Pair{}, nil, false
	}
	f--
	a, r, ok := psPOr(c, f, ts)
	if !ok || !at(r, 0, KwComma) {
		return Pair{}, nil, false
	}
	b, r2, ok := psPOr(c, f, r[1:])
	if !ok || !at(r2, 0, KwRbk) {
		return Pair{}, nil, false
	}
	return Pair{a, b}, r2[1:], true
}

// psPRegTail is `Math.pRegTail`: the further bound pairs of a region, each
// after `\times` `[`.
func psPRegTail(c Ctx, f int, ts []Tok) ([]Pair, []Tok, bool) {
	var out []Pair
	for {
		if f == 0 {
			return nil, nil, false
		}
		f--
		if !atKws(ts, KwTimes, KwLbk) {
			return out, ts, true
		}
		p, r, ok := psPPair(c, f, ts[2:])
		if !ok {
			return nil, nil, false
		}
		out = append(out, p)
		ts = r
	}
}

// psPMkRows is `Math.pMkRows`: the rows of a `makearray` table: a value, the
// cell separator csep, a region; rows separated by rsep, up to closeK
// (consumed).
func psPMkRows(c Ctx, f int, csep, rsep, closeK Kw, ts []Tok) ([]mkRow, []Tok, bool) {
	var out []mkRow
	for {
		if f == 0 {
			return nil, nil, false
		}
		f--
		v, r, ok := psPOr(c, f, ts)
		if !ok || !atKws(r, csep, KwLbk) {
			return nil, nil, false
		}
		p, r1, ok := psPPair(c, f, r[2:])
		if !ok {
			return nil, nil, false
		}
		ps, r2, ok := psPRegTail(c, f, r1)
		if !ok || len(r2) == 0 || r2[0].K != TKw {
			return nil, nil, false
		}
		out = append(out, mkRow{v: v, reg: append([]Pair{p}, ps...)})
		switch r2[0].W {
		case rsep:
			ts = r2[1:]
		case closeK:
			return out, r2[1:], true
		default:
			return nil, nil, false
		}
	}
}

// psPEscArgs is `Math.pEscArgs`: Typst escape arguments: `, a` repeated, then
// `)`.
func psPEscArgs(c Ctx, f int, ts []Tok) ([]Json, []Tok, bool) {
	out := []Json{}
	for {
		if f == 0 {
			return nil, nil, false
		}
		f--
		switch {
		case at(ts, 0, KwRp):
			return out, ts[1:], true
		case at(ts, 0, KwComma):
			x, r2, ok := psPOr(c, f, ts[1:])
			if !ok {
				return nil, nil, false
			}
			out = append(out, x)
			ts = r2
		default:
			return nil, nil, false
		}
	}
}

// psNeed is `Math.need` (RoundTrip.lean): the fuel a token list of length n is
// read with at level l.
func psNeed(l, n int) int { return 30*n + max(12-l, 0) }

// psParseToks is `Math.parseToks` (Induct.lean): read a whole token list.
func psParseToks(lim *Lim, sf Sf, s *Sym, ts []Tok) (Json, bool) {
	e, r, ok := psPOr(Ctx{sf: sf, s: s, lim: lim}, psNeed(1, len(ts)), ts)
	if !ok || len(r) != 0 {
		return nil, false
	}
	return e, true
}
