package docfmt

// The canonical number spelling (CONFORMANCE §5.5.3.1). Port of
// formal/Esm/Document/Number.lean (Rust: document/number.rs); prefix `num`.
//
//   - An integer prints plainly, `-` for a negative one.
//   - A decimal prints its digits positionally when its decimal exponent is in
//     [-4, 5], and otherwise as `d.f…e<exp>` with at least one fraction digit.
//
// numParse reads any decimal spelling and returns the canonical number;
// numParseRaw reads the token as written. A digit run whose value does not
// fit in Int64 is not an integer token (it has no canonical form).

import (
	"math"
	"strconv"
)

// numDigitChar is `Esm.digitChar`.
func numDigitChar(d byte) rune { return rune('0' + d) }

// numCharDigit is `Number.charDigit` (callers pass digit characters).
func numCharDigit(c rune) byte {
	if c < '0' {
		return 0
	}
	return byte(c - '0')
}

// numIsDigit: an ASCII digit.
func numIsDigit(c rune) bool { return c >= '0' && c <= '9' }

// numLeadZero is `Number.leadZero`.
func numLeadZero(ip []byte) bool { return len(ip) > 1 && ip[0] == 0 }

// numPrintInt is `Number.printInt`.
func numPrintInt(z int64) []rune { return []rune(strconv.FormatInt(z, 10)) }

// numReadDigits is `Number.readDigits`: the maximal run of digit characters at
// the front.
func numReadDigits(input []rune) ([]byte, []rune) {
	n := 0
	for n < len(input) && numIsDigit(input[n]) {
		n++
	}
	ds := make([]byte, n)
	for i := 0; i < n; i++ {
		ds[i] = numCharDigit(input[i])
	}
	return ds, input[n:]
}

// numParseInt is `Number.parseInt`: an optional `-`, then digits.
func numParseInt(input []rune) (int64, []rune, bool) {
	neg := len(input) > 0 && input[0] == '-'
	s := input
	if neg {
		s = input[1:]
	}
	ds, r := numReadDigits(s)
	if len(ds) == 0 {
		return 0, nil, false
	}
	u, ok := jsonDigitsVal(ds)
	if !ok {
		return 0, nil, false
	}
	z, ok := jsonSigned(neg, u)
	if !ok {
		return 0, nil, false
	}
	return z, r, true
}

// numFracDigits is `Number.fracDigits`.
func numFracDigits(fp []byte) []byte {
	if len(fp) == 0 {
		return []byte{0}
	}
	return fp
}

// numDecBody is `Number.decBody`: the unsigned spelling of d₁.d₂… × 10^e10.
func numDecBody(ds []byte, e10 int64) []rune {
	var out []rune
	switch {
	case e10 < -4 || e10 > 5:
		if len(ds) == 0 {
			return nil
		}
		out = append(out, numDigitChar(ds[0]), '.')
		for _, d := range numFracDigits(ds[1:]) {
			out = append(out, numDigitChar(d))
		}
		out = append(out, 'e')
		out = append(out, numPrintInt(e10)...)
	case e10 < 0:
		out = append(out, '0', '.')
		for i := int64(0); i < -e10-1; i++ {
			out = append(out, '0')
		}
		for _, d := range ds {
			out = append(out, numDigitChar(d))
		}
	default:
		k := int(e10 + 1)
		for i := 0; i < k && i < len(ds); i++ {
			out = append(out, numDigitChar(ds[i]))
		}
		for i := len(ds); i < k; i++ {
			out = append(out, '0')
		}
		out = append(out, '.')
		var rest []byte
		if len(ds) > k {
			rest = ds[k:]
		}
		for _, d := range numFracDigits(rest) {
			out = append(out, numDigitChar(d))
		}
	}
	return out
}

// numPrint is `Number.print`: the canonical spelling of a number.
func numPrint(n JNum) []rune {
	if !n.Dec {
		return numPrintInt(n.I)
	}
	var out []rune
	if n.Neg {
		out = append(out, '-')
	}
	return append(out, numDecBody(n.Digits, n.E10)...)
}

// numMkDec is `Number.mkDec`: the decimal with digits ds (leading and trailing
// zeros dropped) whose first listed digit sits at decimal exponent e10.
//
// ok is false when the exponent of the first nonzero digit leaves int64
// (Lean's exponent is unbounded); the readers refuse such a token.
func numMkDec(neg bool, ds []byte, e10 int64) (JNum, bool) {
	lead := 0
	for lead < len(ds) && ds[lead] == 0 {
		lead++
	}
	core := append([]byte(nil), ds[lead:]...)
	for len(core) > 0 && core[len(core)-1] == 0 {
		core = core[:len(core)-1]
	}
	if e10 < math.MinInt64+int64(lead) {
		return JNum{}, false
	}
	return JNum{Dec: true, Neg: neg, Digits: core, E10: e10 - int64(lead)}, true
}

// numFinishDec is `Number.finishDec`: an optional `e` exponent after the
// fraction digits.
func numFinishDec(neg bool, ds []byte, e10 int64, r []rune) (JNum, []rune, bool) {
	if len(r) > 0 && r[0] == 'e' {
		x, rest, ok := numParseInt(r[1:])
		if !ok {
			return JNum{}, nil, false
		}
		s := e10 + x
		if (x > 0 && s < e10) || (x < 0 && s > e10) {
			return JNum{}, nil, false
		}
		n, ok := numMkDec(neg, ds, s)
		return n, rest, ok
	}
	n, ok := numMkDec(neg, ds, e10)
	return n, r, ok
}

// numAfterInt is `Number.afterInt`.
func numAfterInt(neg bool, ip []byte, r []rune) (JNum, []rune, bool) {
	if len(r) > 0 && r[0] == '.' {
		q, rest := numReadDigits(r[1:])
		if len(q) == 0 {
			return JNum{}, nil, false
		}
		ds := append(append([]byte(nil), ip...), q...)
		return numFinishDec(neg, ds, int64(len(ip))-1, rest)
	}
	u, ok := jsonDigitsVal(ip)
	if !ok {
		return JNum{}, nil, false
	}
	z, ok := jsonSigned(neg, u)
	if !ok {
		// outside Int64: never well formed, so never a number token
		return JNum{}, nil, false
	}
	return IntNum(z), r, true
}

// numParseRaw is `Number.parseRaw`: a number token as written, not yet
// canonical.
func numParseRaw(input []rune) (JNum, []rune, bool) {
	neg := len(input) > 0 && input[0] == '-'
	s := input
	if neg {
		s = input[1:]
	}
	p, rest := numReadDigits(s)
	if len(p) == 0 || numLeadZero(p) {
		return JNum{}, nil, false
	}
	return numAfterInt(neg, p, rest)
}

// numCanonize is `Number.canonize`.
func numCanonize(n JNum) JNum {
	if !n.Dec {
		return n
	}
	if len(n.Digits) == 0 {
		return IntNum(0)
	}
	if z, integral, fits := jsonDecInt(n.Neg, n.Digits, n.E10); integral && fits {
		return IntNum(z)
	}
	return n
}

// numParse is `Number.parse`: a number token, in canonical form.
func numParse(input []rune) (JNum, []rune, bool) {
	n, r, ok := numParseRaw(input)
	if !ok {
		return JNum{}, nil, false
	}
	c := numCanonize(n)
	if !c.Wfb() {
		return JNum{}, nil, false
	}
	return c, r, true
}
