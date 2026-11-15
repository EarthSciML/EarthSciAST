package docfmt

// Pieces the LaTeX and Typst spellings share: literal prefixes, binary
// operator tokens, and the reading of numbers (a JSON spelling, or a
// scientific literal `mantissa × 10^exponent` whose tail each surface reads
// with its own sciExp). Port of formal/Esm/Document/Math/Surface.lean (Rust:
// document/math/surface.rs); prefix `surf`.

// surfDropP is `Math.dropP`: strip a literal prefix.
func surfDropP(p string, cs []rune) ([]rune, bool) { return cutPrefix(cs, p) }

// surfIsBin is `Math.isBin`: the binary operator tokens.
func surfIsBin(t Tok) bool {
	if t.K != TKw {
		return false
	}
	switch t.W {
	case KwPlus, KwEq, KwNe, KwLt, KwGt, KwLe, KwGe, KwLand, KwLor, KwCdot, KwTimes, KwAmp, KwNl, KwInn:
		return true
	}
	return false
}

// surfSciSplit is `Math.sciSplit`: the mantissa (with its sign) and exponent
// of a number printed in scientific notation.
func surfSciSplit(n JNum) ([]rune, int64, bool) {
	if !n.Dec || len(n.Digits) == 0 || (n.E10 >= -4 && n.E10 <= 5) {
		return nil, 0, false
	}
	var m []rune
	if n.Neg {
		m = append(m, '-')
	}
	m = append(m, numDigitChar(n.Digits[0]), '.')
	for _, d := range numFracDigits(n.Digits[1:]) {
		m = append(m, numDigitChar(d))
	}
	return m, n.E10, true
}

// surfNegNum is `Math.negNum`: a number below zero.
func surfNegNum(n JNum) bool {
	if !n.Dec {
		return n.I < 0
	}
	return n.Neg
}

// surfSciNum is `Math.sciNum`: the value of a mantissa times 10^z, in
// canonical form. A decimal exponent outside int64 fails (Lean would build
// that decimal), which no document writes.
func surfSciNum(n0 JNum, z int64) (JNum, bool) {
	var neg bool
	var ds []byte
	var e int64
	if n0.Dec {
		neg, ds, e = n0.Neg, n0.Digits, n0.E10
	} else {
		u := uint64(n0.I)
		if n0.I < 0 {
			u = uint64(-(n0.I + 1)) + 1
		}
		ds = numNatDigits(u)
		neg = n0.I < 0
		e = int64(len(ds)) - 1
	}
	s := e + z
	if (z > 0 && s < e) || (z < 0 && s > e) {
		return JNum{}, false
	}
	var m JNum
	if n0.Dec {
		m = numCanonize(JNum{Dec: true, Neg: neg, Digits: ds, E10: s})
	} else {
		m = numCanonize(numMkDec(neg, ds, s))
	}
	if !m.Wfb() {
		return JNum{}, false
	}
	return m, true
}

// surfParseRawWide is numParseRaw, except that an integer token outside Int64
// is read as the decimal it denotes (Rust reads it as an i128 integer and
// sciNum turns it into a decimal; this gives the same sciNum result).
func surfParseRawWide(input []rune) (JNum, []rune, bool) {
	if n, r, ok := numParseRaw(input); ok {
		return n, r, true
	}
	neg := len(input) > 0 && input[0] == '-'
	s := input
	if neg {
		s = input[1:]
	}
	p, rest := numReadDigits(s)
	if len(p) == 0 || numLeadZero(p) || (len(rest) > 0 && rest[0] == '.') {
		return JNum{}, nil, false
	}
	return numMkDec(neg, p, int64(len(p))-1), rest, true
}

// surfLexNum is `Math.lexNum`: a number: its JSON spelling, or a decimal
// mantissa followed by a scientific tail that sciExp reads.
func surfLexNum(sciExp func([]rune) (int64, []rune, bool), cs []rune) (Tok, []rune, bool) {
	n0, r, ok := surfParseRawWide(cs)
	if !ok {
		return Tok{}, nil, false
	}
	if z, r3, ok := sciExp(r); ok {
		if m, ok := surfSciNum(n0, z); ok {
			return tNum(m), r3, true
		}
	}
	n, r2, ok := numParse(cs)
	if !ok {
		return Tok{}, nil, false
	}
	return tNum(n), r2, true
}

// surfLexSigned is `Math.lexSigned`: a number where `-` starts it only when
// the value is below zero (otherwise the `-` is a minus sign of its own).
func surfLexSigned(sciExp func([]rune) (int64, []rune, bool), cs []rune) (Tok, []rune, bool) {
	if len(cs) > 0 && cs[0] == '-' {
		t, r2, ok := surfLexNum(sciExp, cs)
		if !ok || t.K != TNum {
			return Tok{}, nil, false
		}
		if surfNegNum(t.N) {
			return t, r2, true
		}
		return tKw(KwMinus), cs[1:], true
	}
	return surfLexNum(sciExp, cs)
}
