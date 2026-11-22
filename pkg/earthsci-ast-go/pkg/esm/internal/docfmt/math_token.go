package docfmt

// Math tokens, shared by the two surfaces. Port of
// formal/Esm/Document/Math/Token.lean (Rust: document/math/token.rs).
//
// A token names what the surface text MEANS (KwLand is `\land` in LaTeX and
// `and` in Typst), so one parser reads both; each surface has its own renderer
// and lexer.

import "github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm/internal/unitspell"

// Factor is `Esm.Units.Factor`: a unit symbol and its (signed, rational)
// exponent.
type Factor = unitspell.Factor

// Kw is a keyword token (`Math.Kw`).
type Kw uint8

// The keywords, in the order of the Rust enum.
const (
	// operators
	KwPlus Kw = iota
	KwMinus
	KwEq
	KwNe
	KwLt
	KwGt
	KwLe
	KwGe
	KwLand
	KwLor
	KwLnot
	KwCdot
	KwTimes
	KwSlash
	KwCaret
	KwUs
	// delimiters: KwLp/KwRp call parentheses, KwLpg/KwRpg grouping parentheses
	KwLp
	KwRp
	KwLpg
	KwRpg
	KwLb
	KwRb
	KwLbk
	KwRbk
	KwComma
	KwSemi
	KwColon
	KwAmp
	KwNl
	KwSdot
	// functions and notations
	KwFrac
	KwSqrt
	KwExp
	KwLn
	KwLog
	KwSin
	KwCos
	KwTan
	KwAsin
	KwAcos
	KwAtan
	KwSinh
	KwCosh
	KwTanh
	KwMin
	KwMax
	KwLabs
	KwRabs
	KwLfloor
	KwRfloor
	KwLceil
	KwRceil
	KwAbs
	KwFloor
	KwCeil
	KwPdiff
	KwDif
	KwDotacc
	KwBcases
	KwEcases
	KwCases
	KwEsmnode
	// the nabla of the grad, div, laplacian and curl forms: LaTeX `\nabla`, Typst `nabla`
	KwNabla
	// constant arrays
	KwBmat
	KwEmat
	KwVec
	KwMat
	// faq reductions
	KwSum
	KwProd
	KwInn
	KwSubstack
	KwLimits
	KwLbkg
	KwRbkg
	KwLr
	KwLimitsL
	// makearray: LaTeX `\begin{array}{l|l}` `\end{array}`
	KwBarr
	KwEarr
	// a set of names, LaTeX `\{` `\}`, Typst `{` `}` (the `args` of a `faq`)
	KwLset
	KwRset
)

// TokKind says which variant a Tok is.
type TokKind uint8

// The token variants (`Math.Tok`).
const (
	TNum    TokKind = iota // N
	TLetter                // C
	TGreek                 // S
	TWord                  // S
	TIt                    // S
	TRm                    // S
	TUps                   // Ups
	TOpn                   // S
	TTxt                   // S
	TJstr                  // S
	TEsc                   // S
	TCode                  // J
	TUnits                 // U
	TKw                    // W
	TArrC                  // Cols
)

// UpsPair is one entry of an Ups token.
type UpsPair struct{ A, B string }

// Tok is a math token (`Math.Tok`); K selects the variant and the field it
// carries.
type Tok struct {
	K   TokKind
	N   JNum      // TNum
	C   rune      // TLetter
	S   string    // TGreek TWord TIt TRm TOpn TTxt TJstr TEsc
	Ups []UpsPair // TUps
	J   Json      // TCode
	U   []Factor  // TUnits
	W   Kw        // TKw
	// Cols is the column count of a LaTeX `\begin{array}{c…c}` (TArrC): the
	// opener of a constant matrix wider than a `bmatrix` holds.
	Cols int
}

// Token constructors.

func tNum(n JNum) Tok            { return Tok{K: TNum, N: n} }
func tLetter(c rune) Tok         { return Tok{K: TLetter, C: c} }
func tGreek(s string) Tok        { return Tok{K: TGreek, S: s} }
func tWord(s string) Tok         { return Tok{K: TWord, S: s} }
func tIt(s string) Tok           { return Tok{K: TIt, S: s} }
func tRm(s string) Tok           { return Tok{K: TRm, S: s} }
func tUps(p []UpsPair) Tok       { return Tok{K: TUps, Ups: p} }
func tOpn(s string) Tok          { return Tok{K: TOpn, S: s} }
func tTxt(s string) Tok          { return Tok{K: TTxt, S: s} }
func tJstr(s string) Tok         { return Tok{K: TJstr, S: s} }
func tEsc(s string) Tok          { return Tok{K: TEsc, S: s} }
func tCode(j Json) Tok           { return Tok{K: TCode, J: j} }
func tUnits(u []Factor) Tok      { return Tok{K: TUnits, U: u} }
func tKw(k Kw) Tok               { return Tok{K: TKw, W: k} }
func tArrC(n int) Tok            { return Tok{K: TArrC, Cols: n} }
func (t Tok) isKw(k Kw) bool     { return t.K == TKw && t.W == k }
func (t Tok) isNum(z int64) bool { return t.K == TNum && t.N.IsInt(z) }

// factorsEqual is equality of two factor lists.
func factorsEqual(a, b []Factor) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i].Sym != b[i].Sym || a[i].Exp.Cmp(b[i].Exp) != 0 {
			return false
		}
	}
	return true
}

// Equal is structural equality of two tokens.
func (t Tok) Equal(u Tok) bool {
	if t.K != u.K {
		return false
	}
	switch t.K {
	case TNum:
		return t.N.Equal(u.N)
	case TLetter:
		return t.C == u.C
	case TUps:
		if len(t.Ups) != len(u.Ups) {
			return false
		}
		for i := range t.Ups {
			if t.Ups[i] != u.Ups[i] {
				return false
			}
		}
		return true
	case TCode:
		return JsonEqual(t.J, u.J)
	case TUnits:
		return factorsEqual(t.U, u.U)
	case TKw:
		return t.W == u.W
	case TArrC:
		return t.Cols == u.Cols
	}
	return t.S == u.S
}

// Sf is the math surface (`Math.Sf`).
type Sf uint8

// The two surfaces.
const (
	SfLatex Sf = iota
	SfTypst
)
