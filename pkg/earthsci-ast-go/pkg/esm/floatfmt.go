package esm

import (
	"fmt"
	"math"
	"strconv"
	"strings"
)

// floatfmt.go is the SINGLE canonical §5.4.6 float renderer. The package
// currently carries two byte-identical implementations of this spec —
// canonicalFloat64String (+ normalizeExponentForm) in canonical.go and
// formatCanonicalFloat in canonicalize.go — so any spec tweak has to be made in
// three places. formatCanonicalFloatShared is the one place both should
// delegate to (Wave 2 collapses the originals onto it and deletes them).
//
// The output is byte-for-byte identical to both existing implementations for
// every finite float64. For NaN/±Inf it returns an error that WRAPS the
// ErrCanonicalNonFinite sentinel (defined in canonicalize.go), so
// errors.Is(err, ErrCanonicalNonFinite) matches on BOTH the Canonicalize path
// and the Save/ToJSON path — closing the consistency gap the audit flagged
// (canonicalFloat64String today builds an unwrapped fmt.Errorf).

// §5.4.6 uses plain decimal notation only inside the magnitude window
// [canonicalPlainDecimalMin, canonicalPlainDecimalMax); magnitudes outside it
// render in lowercase-e exponent form. These were inline 1e-6/1e21 magic
// literals in canonical.go and canonicalize.go.
const (
	canonicalPlainDecimalMin = 1e-6
	canonicalPlainDecimalMax = 1e21
)

// formatCanonicalFloatShared renders a float64 in discretization RFC §5.4.6
// on-wire form:
//
//   - ±0 renders as "-0.0" / "0.0" (signbit preserved).
//   - |f| in [1e-6, 1e21) renders as shortest-round-trip plain decimal, with a
//     trailing ".0" appended to integer-valued magnitudes so a JSON integer
//     token and a JSON float token are never spelled the same way (preserving
//     the §5.4.1 int/float round-trip distinction).
//   - |f| outside that window renders in exponent form with lowercase 'e', no
//     leading '+', and no leading zeros on the exponent magnitude.
//   - NaN and ±Inf return an error wrapping ErrCanonicalNonFinite; the message
//     text matches the existing canonicalFloat64String messages verbatim.
func formatCanonicalFloatShared(f float64) (string, error) {
	if math.IsNaN(f) {
		return "", fmt.Errorf("%w: NaN not representable in canonical JSON", ErrCanonicalNonFinite)
	}
	if math.IsInf(f, 0) {
		return "", fmt.Errorf("%w: %v not representable in canonical JSON", ErrCanonicalNonFinite, f)
	}
	if f == 0 {
		if math.Signbit(f) {
			return "-0.0", nil
		}
		return "0.0", nil
	}
	abs := math.Abs(f)
	if abs < canonicalPlainDecimalMin || abs >= canonicalPlainDecimalMax {
		return normalizeCanonicalExponent(strconv.FormatFloat(f, 'e', -1, 64)), nil
	}
	s := strconv.FormatFloat(f, 'f', -1, 64)
	if !strings.Contains(s, ".") {
		s += ".0"
	}
	return s, nil
}

// normalizeCanonicalExponent converts Go's "1e+25" / "1e-07" spellings to the
// §5.4.6 form: lowercase 'e', no leading '+', no leading zeros on the exponent
// magnitude. Equivalent to canonical.go's normalizeExponentForm and to the
// inline exponent cleanup in canonicalize.go's formatCanonicalFloat.
func normalizeCanonicalExponent(s string) string {
	idx := strings.IndexAny(s, "eE")
	if idx < 0 {
		return s
	}
	mantissa := s[:idx]
	exp := s[idx+1:]
	neg := false
	switch {
	case strings.HasPrefix(exp, "+"):
		exp = exp[1:]
	case strings.HasPrefix(exp, "-"):
		neg = true
		exp = exp[1:]
	}
	exp = strings.TrimLeft(exp, "0")
	if exp == "" {
		exp = "0"
	}
	if neg {
		exp = "-" + exp
	}
	return mantissa + "e" + exp
}
