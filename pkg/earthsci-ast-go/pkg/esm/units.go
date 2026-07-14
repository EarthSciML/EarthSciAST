package esm

import (
	"errors"
	"fmt"
	"math"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"
)

// Rat is an exact RATIONAL unit exponent (num/den).
//
// Dimension exponents are rational, not integer: `1/s^0.5` is the noise
// intensity of an SDE (tests/fixtures/sde/*.esm), `m^(1/2)` and `s^(-1/2)`
// appear wherever a square root of a dimensional quantity does, and `sqrt(x)`
// halves whatever exponents x carries. An int8 exponent vector cannot represent
// any of them, so — now that an unparseable unit is a HARD ERROR — an integer
// representation falsely rejects those files.
//
// The ZERO VALUE is the exponent 0: every operation normalizes a zero (or
// missing) denominator to 1 via fix(), so `Rat{}` and a composite literal such
// as `Rat{Num: 2}` are both well-formed. Nothing compares two Rats (or two
// Dimensions) with `==` — Equal cross-multiplies, so a non-reduced value never
// silently compares unequal to its reduced form.
type Rat struct {
	Num int32 `json:"num"`
	Den int32 `json:"den"`
}

// newRat builds a Rat in lowest terms with a positive denominator. A zero
// denominator is treated as 1 (see the Rat doc comment).
func newRat(num, den int64) Rat {
	if den == 0 {
		den = 1
	}
	if den < 0 {
		num, den = -num, -den
	}
	if g := gcd64(num, den); g > 1 {
		num, den = num/g, den/g
	}
	return Rat{Num: int32(num), Den: int32(den)}
}

func gcd64(a, b int64) int64 {
	if a < 0 {
		a = -a
	}
	if b < 0 {
		b = -b
	}
	for b != 0 {
		a, b = b, a%b
	}
	if a == 0 {
		return 1
	}
	return a
}

// fix normalizes the zero-value / int-literal spelling (Den == 0) to a proper
// fraction over 1.
func (r Rat) fix() Rat {
	if r.Den == 0 {
		return Rat{Num: r.Num, Den: 1}
	}
	return r
}

// ratInt is the exponent n/1.
func ratInt(n int) Rat { return Rat{Num: int32(n), Den: 1} }

// Add returns r + o.
func (r Rat) Add(o Rat) Rat {
	a, b := r.fix(), o.fix()
	return newRat(int64(a.Num)*int64(b.Den)+int64(b.Num)*int64(a.Den), int64(a.Den)*int64(b.Den))
}

// Sub returns r − o.
func (r Rat) Sub(o Rat) Rat {
	a, b := r.fix(), o.fix()
	return newRat(int64(a.Num)*int64(b.Den)-int64(b.Num)*int64(a.Den), int64(a.Den)*int64(b.Den))
}

// Mul returns r × o.
func (r Rat) Mul(o Rat) Rat {
	a, b := r.fix(), o.fix()
	return newRat(int64(a.Num)*int64(b.Num), int64(a.Den)*int64(b.Den))
}

// Equal reports whether two exponents denote the same rational number,
// regardless of whether either is in lowest terms.
func (r Rat) Equal(o Rat) bool {
	a, b := r.fix(), o.fix()
	return int64(a.Num)*int64(b.Den) == int64(b.Num)*int64(a.Den)
}

// IsZero reports whether the exponent is 0.
func (r Rat) IsZero() bool { return r.fix().Num == 0 }

// Float returns the exponent as a float64 (used for scale arithmetic).
func (r Rat) Float() float64 {
	a := r.fix()
	return float64(a.Num) / float64(a.Den)
}

// Neg returns −r.
func (r Rat) Neg() Rat {
	a := r.fix()
	return Rat{Num: -a.Num, Den: a.Den}
}

// String renders the exponent: "2", "-1", "1/2", "-3/2".
func (r Rat) String() string {
	a := r.fix()
	if a.Den == 1 {
		return strconv.Itoa(int(a.Num))
	}
	return fmt.Sprintf("%d/%d", a.Num, a.Den)
}

// Dimension is a vector of RATIONAL exponents over the 7 SI base units plus
// radian. Index order: m, kg, s, mol, K, A, cd, rad.
type Dimension [8]Rat

const (
	dimLength = iota
	dimMass
	dimTime
	dimAmount
	dimTemperature
	dimCurrent
	dimLuminosity
	dimAngle
)

// Dimensionless is the zero vector.
var Dimensionless = Dimension{}

// Multiply adds component-wise exponents.
func (d Dimension) Multiply(other Dimension) Dimension {
	var r Dimension
	for i := range d {
		r[i] = d[i].Add(other[i])
	}
	return r
}

// Divide subtracts component-wise exponents.
func (d Dimension) Divide(other Dimension) Dimension {
	var r Dimension
	for i := range d {
		r[i] = d[i].Sub(other[i])
	}
	return r
}

// Power scales each exponent by the integer n.
func (d Dimension) Power(n int) Dimension {
	return d.PowerRat(ratInt(n))
}

// PowerRat scales each exponent by the rational e — the operation `sqrt` and a
// fractional literal exponent both need.
func (d Dimension) PowerRat(e Rat) Dimension {
	var r Dimension
	for i := range d {
		r[i] = d[i].Mul(e)
	}
	return r
}

// Equal reports whether two dimensions denote the same exponent vector.
func (d Dimension) Equal(other Dimension) bool {
	for i := range d {
		if !d[i].Equal(other[i]) {
			return false
		}
	}
	return true
}

// IsDimensionless reports whether every exponent is zero.
func (d Dimension) IsDimensionless() bool {
	for i := range d {
		if !d[i].IsZero() {
			return false
		}
	}
	return true
}

// String renders a dimension vector in SI-base notation (e.g. "m*kg/s^2",
// "1/s^(1/2)").
func (d Dimension) String() string {
	if d.IsDimensionless() {
		return "1"
	}
	symbols := [8]string{"m", "kg", "s", "mol", "K", "A", "cd", "rad"}
	var num, den []string
	for i := range d {
		e := d[i].fix()
		switch {
		case e.Num > 0:
			num = append(num, dimFactor(symbols[i], e))
		case e.Num < 0:
			den = append(den, dimFactor(symbols[i], e.Neg()))
		}
	}
	var sb strings.Builder
	if len(num) == 0 {
		sb.WriteString("1")
	} else {
		sb.WriteString(strings.Join(num, "*"))
	}
	if len(den) > 0 {
		sb.WriteString("/")
		sb.WriteString(strings.Join(den, "/"))
	}
	return sb.String()
}

// radDim is the dimension of a plane angle (the `rad` base axis) — what the
// inverse circular functions return.
func radDim() Dimension {
	var d Dimension
	d[dimAngle] = ratInt(1)
	return d
}

// isAngleDim reports whether a dimension is exactly a plane angle (rad^1), the
// argument the circular functions accept alongside a pure number.
func isAngleDim(d Dimension) bool { return d.Equal(radDim()) }

// dimFactor renders one base-unit factor with a POSITIVE exponent: "m",
// "m^2", "m^(1/2)".
func dimFactor(symbol string, e Rat) string {
	e = e.fix()
	switch {
	case e.Num == 1 && e.Den == 1:
		return symbol
	case e.Den == 1:
		return fmt.Sprintf("%s^%d", symbol, e.Num)
	default:
		return fmt.Sprintf("%s^(%s)", symbol, e)
	}
}

// Unit is a named physical unit with a dimension vector and a scale factor
// relative to the canonical SI combination represented by Dim.
type Unit struct {
	Dim    Dimension
	Scale  float64
	Symbol string
}

// Multiply returns the product of two units (dimensions add, scales multiply).
func (u Unit) Multiply(other Unit) Unit {
	return Unit{Dim: u.Dim.Multiply(other.Dim), Scale: u.Scale * other.Scale}
}

// Divide returns the quotient of two units.
func (u Unit) Divide(other Unit) Unit {
	return Unit{Dim: u.Dim.Divide(other.Dim), Scale: u.Scale / other.Scale}
}

// Power raises a unit to an integer power.
func (u Unit) Power(n int) Unit {
	return u.PowerRat(ratInt(n))
}

// PowerRat raises a unit to a RATIONAL power (`s^(-1/2)`, `sqrt(m^3)`).
func (u Unit) PowerRat(e Rat) Unit {
	return Unit{Dim: u.Dim.PowerRat(e), Scale: math.Pow(u.Scale, e.Float())}
}

// baseUnit constructs a single-dimension unit with an explicit scale.
func baseUnit(idx int, scale float64) Unit {
	var d Dimension
	d[idx] = ratInt(1)
	return Unit{Dim: d, Scale: scale}
}

// unitRegistry holds all symbols recognized by ParseUnit.
var unitRegistry = buildUnitRegistry()

func buildUnitRegistry() map[string]Unit {
	r := map[string]Unit{}

	// SI base units (scale 1).
	r["m"] = baseUnit(dimLength, 1.0)
	r["kg"] = baseUnit(dimMass, 1.0)
	r["s"] = baseUnit(dimTime, 1.0)
	r["mol"] = baseUnit(dimAmount, 1.0)
	r["K"] = baseUnit(dimTemperature, 1.0)
	r["A"] = baseUnit(dimCurrent, 1.0)
	r["cd"] = baseUnit(dimLuminosity, 1.0)
	r["rad"] = baseUnit(dimAngle, 1.0)

	// Mass (gram, because kg is the SI base but g/mg/ug are common).
	r["g"] = Unit{Dim: r["kg"].Dim, Scale: 1e-3}
	r["mg"] = Unit{Dim: r["kg"].Dim, Scale: 1e-6}
	r["ug"] = Unit{Dim: r["kg"].Dim, Scale: 1e-9}

	// Length scales.
	r["dm"] = Unit{Dim: r["m"].Dim, Scale: 1e-1}
	r["cm"] = Unit{Dim: r["m"].Dim, Scale: 1e-2}
	r["mm"] = Unit{Dim: r["m"].Dim, Scale: 1e-3}
	r["um"] = Unit{Dim: r["m"].Dim, Scale: 1e-6}
	r["nm"] = Unit{Dim: r["m"].Dim, Scale: 1e-9}
	r["km"] = Unit{Dim: r["m"].Dim, Scale: 1e3}

	// Time scales.
	r["ms"] = Unit{Dim: r["s"].Dim, Scale: 1e-3}
	r["us"] = Unit{Dim: r["s"].Dim, Scale: 1e-6}
	r["ns"] = Unit{Dim: r["s"].Dim, Scale: 1e-9}
	r["min"] = Unit{Dim: r["s"].Dim, Scale: 60}
	r["h"] = Unit{Dim: r["s"].Dim, Scale: 3600}
	r["hr"] = Unit{Dim: r["s"].Dim, Scale: 3600}
	r["hour"] = r["h"]
	// The day is spelled "day". The one-letter "d" is DELIBERATELY NOT a unit
	// (§4.8.1): it reads as a deci- prefix or as a differential, and a binding
	// that accepts it diverges permissively from the spec registry.
	r["day"] = Unit{Dim: r["s"].Dim, Scale: 86400}
	r["yr"] = Unit{Dim: r["s"].Dim, Scale: 365.25 * 86400}
	r["year"] = r["yr"]

	// Volume (derived length^3 shortcut).
	liter := Unit{Dim: r["m"].Dim.Power(3), Scale: 1e-3}
	r["L"] = liter
	r["l"] = liter
	r["mL"] = Unit{Dim: liter.Dim, Scale: 1e-6}

	// Length, long form. The corpus spells metres out ("meters/second" in a
	// description-driven fixture); both spellings are the same unit.
	r["meter"] = r["m"]
	r["meters"] = r["m"]

	// Temperature (Celsius shares the Kelvin dimension; offset is not modeled).
	// Celsius is spelled "degC", "Celsius" or "°C" (normalizeUnitString folds
	// the latter into "degC"). The bare symbol "C" is NOT Celsius — see the
	// coulomb entry below.
	r["degC"] = r["K"]
	r["Celsius"] = r["K"]

	// Derived coherent SI units (scale 1 except where noted).
	r["Hz"] = Unit{Dim: r["s"].Dim.Power(-1), Scale: 1}
	r["N"] = r["kg"].Multiply(r["m"]).Divide(r["s"].Power(2))
	r["Pa"] = r["N"].Divide(r["m"].Power(2))
	r["J"] = r["N"].Multiply(r["m"])
	r["kJ"] = Unit{Dim: r["J"].Dim, Scale: 1000}
	r["cal"] = Unit{Dim: r["J"].Dim, Scale: 4.184}
	r["kcal"] = Unit{Dim: r["J"].Dim, Scale: 4184}
	r["W"] = r["J"].Divide(r["s"])

	// Pressure (non-SI but ubiquitous in atmospheric science).
	r["atm"] = Unit{Dim: r["Pa"].Dim, Scale: 101325}
	// Micro-atmosphere: the standard unit of seawater/air CO2 partial pressure
	// (pCO2) throughout the ocean-carbon corpus.
	r["uatm"] = Unit{Dim: r["Pa"].Dim, Scale: 101325e-6}
	r["bar"] = Unit{Dim: r["Pa"].Dim, Scale: 1e5}
	r["hPa"] = Unit{Dim: r["Pa"].Dim, Scale: 100}
	r["kPa"] = Unit{Dim: r["Pa"].Dim, Scale: 1000}
	r["mbar"] = Unit{Dim: r["Pa"].Dim, Scale: 100}
	r["Torr"] = Unit{Dim: r["Pa"].Dim, Scale: 101325.0 / 760.0}
	r["mmHg"] = Unit{Dim: r["Pa"].Dim, Scale: 133.322387415}
	r["psi"] = Unit{Dim: r["Pa"].Dim, Scale: 6894.757293168}

	// Energy / power (non-coherent multiples).
	r["erg"] = Unit{Dim: r["J"].Dim, Scale: 1e-7}
	r["BTU"] = Unit{Dim: r["J"].Dim, Scale: 1055.05585262}
	r["Wh"] = Unit{Dim: r["J"].Dim, Scale: 3600}
	r["kWh"] = Unit{Dim: r["J"].Dim, Scale: 3.6e6}
	r["kW"] = Unit{Dim: r["W"].Dim, Scale: 1000}
	r["MW"] = Unit{Dim: r["W"].Dim, Scale: 1e6}

	// Electromagnetic derived units.
	//
	// "C" is the COULOMB, per SI. It was previously bound to degrees Celsius,
	// which silently injected a temperature dimension into every electromagnetic
	// expression: tests/valid/units_dimensional_analysis.esm declares a charge
	// `q: "C"` and a field `E: "V/m"`, and their product — a force, declared "N"
	// — came out as kg*m*K/(s^3*A). Celsius has always had its own unambiguous
	// spellings ("degC", "°C"), so the SI reading is the correct one and the only
	// one that can be pinned as a cross-binding contract.
	r["C"] = r["A"].Multiply(r["s"])                                                      // coulomb = A*s
	r["V"] = r["W"].Divide(r["A"])                                                        // volt    = kg*m^2/(s^3*A)
	r["Ohm"] = r["V"].Divide(r["A"])                                                      // ohm     = kg*m^2/(s^3*A^2)
	r["F"] = Unit{Dim: r["C"].Dim.Divide(r["V"].Dim), Scale: 1}                           // farad   = A^2*s^4/(kg*m^2)
	r["T"] = Unit{Dim: r["V"].Multiply(r["s"]).Dim.Divide(r["m"].Dim.Power(2)), Scale: 1} // tesla   = kg/(s^2*A)

	// Temperature. degF is an INTERVAL of 5/9 K; like degC, the affine offset is
	// deliberately not modeled (dimensional analysis only cares about the scale).
	r["degF"] = Unit{Dim: r["K"].Dim, Scale: 5.0 / 9.0}

	// Plane angle. "degrees" is the long-form alias the corpus uses for lon/lat
	// coordinates and terrain aspect.
	r["deg"] = Unit{Dim: r["rad"].Dim, Scale: math.Pi / 180}
	r["degrees"] = r["deg"]

	// Amount of substance, scaled ("μmol/(m^2*s)" — photosynthesis flux — is in
	// the valid corpus; μ normalizes to u, see normalizeUnitString).
	r["kmol"] = Unit{Dim: r["mol"].Dim, Scale: 1e3}
	r["mmol"] = Unit{Dim: r["mol"].Dim, Scale: 1e-3}
	r["umol"] = Unit{Dim: r["mol"].Dim, Scale: 1e-6}
	r["nmol"] = Unit{Dim: r["mol"].Dim, Scale: 1e-9}

	// Concentration-ish.
	r["M"] = r["mol"].Divide(liter) // molarity

	// ESM / atmospheric chemistry units.
	// mol/mol, ppm, ppb, ppt are dimensionless mixing ratios; the scale is the
	// multiplier relative to 1 (mol/mol). The "v" (by-volume) spellings are the
	// same quantity.
	r["ppm"] = Unit{Dim: Dimensionless, Scale: 1e-6}
	r["ppb"] = Unit{Dim: Dimensionless, Scale: 1e-9}
	r["ppt"] = Unit{Dim: Dimensionless, Scale: 1e-12}
	r["ppmv"] = r["ppm"]
	r["ppbv"] = r["ppb"]
	r["pptv"] = r["ppt"]
	// COUNT NOUNS. A count of discrete things carries no physical dimension, so
	// each is dimensionless with scale 1 — exactly the treatment "molec" has
	// always had here (so that "molec/cm^3" matches "1/cm^3"). They are REAL unit
	// names in the shared corpus (population density "individuals/km^2", traffic
	// density "vehicles/km^2", clinical activity "units/L"), and since an
	// unresolvable unit string is now a hard error (see UnitFindingUnparseable),
	// omitting them would falsely reject those files.
	r["molec"] = Unit{Dim: Dimensionless, Scale: 1}
	r["molecule"] = r["molec"]
	r["individuals"] = Unit{Dim: Dimensionless, Scale: 1}
	r["vehicles"] = Unit{Dim: Dimensionless, Scale: 1}
	r["units"] = Unit{Dim: Dimensionless, Scale: 1}
	r["count"] = Unit{Dim: Dimensionless, Scale: 1}

	// Dimensionless RATIOS with a scale.
	//
	// "%" is a real unit token in the corpus (cloud fraction, relative humidity,
	// soil moisture). It is not an identifier byte, so parseAtom recognises it as
	// a symbol of its own; "percent" is the spelled-out alias.
	r["%"] = Unit{Dim: Dimensionless, Scale: 0.01}
	r["percent"] = r["%"]
	// Practical salinity: dimensionless by definition (PSS-78 is a conductivity
	// ratio), scale 1 — the ocean corpus declares salinity in "psu".
	r["psu"] = Unit{Dim: Dimensionless, Scale: 1}

	// Dobson unit: 2.6867e16 molec/cm^2 → dimension is length^-2.
	//
	// The constant is 2.6867e20 m^-2, NOT the rounded 2.69e20 this used to
	// carry: Rust checks conversion factors against the physically correct value
	// and Go's conversion tolerance is 1e-9 relative, so the two bindings
	// disagreed — by 5e-3 relative — on the SAME file, one accepting a declared
	// factor the other rejected. The exact value is the cross-binding contract.
	r["Dobson"] = Unit{Dim: r["m"].Dim.Power(-2), Scale: 2.6867e20} // 2.6867e16 * (1/cm^2 → 1/m^2 ×1e4)
	r["DU"] = r["Dobson"]

	return r
}

// normalizeUnitString rewrites the non-ASCII and alternate spellings the shared
// corpus uses into the ASCII grammar ParseUnit implements. It is a pure
// spelling normalization — no unit is invented here, each target already exists
// in the registry — and it runs before the byte-level scanner, which only
// recognizes ASCII bytes:
//
//   - SUPERSCRIPT DIGITS ⁰¹²³⁴⁵⁶⁷⁸⁹ and superscript sign ⁻/⁺ → "^n"
//     ("W/m²" → "W/m^2", "cm³" → "cm^3", "m⁻³" → "m^-3"). A RUN of superscript
//     characters is one exponent, so "m¹⁰" is m^10, not m^1*0.
//   - MIDDOT · (U+00B7) and DOT OPERATOR ⋅ (U+22C5) → "*" ("J/(kg·K)",
//     "kg⋅m/s"). Both are multiplication in SI typography.
//   - U+00B5 MICRO SIGN and U+03BC GREEK SMALL LETTER MU → "u" ("μg" → "ug")
//   - "°C"/"°F"/"°K" → degC/degF/K, and a bare "°" → "deg"
//   - Ω (U+03A9 GREEK CAPITAL OMEGA) and Ω (U+2126 OHM SIGN) → "Ohm"
//
// These spellings are pervasive in tests/libraries and the spec's own examples;
// each of them used to be a parse failure, which — now that an unresolvable unit
// string is a HARD ERROR — is a false rejection of a valid file.
func normalizeUnitString(s string) string {
	if isASCIIString(s) {
		return s
	}
	runes := []rune(s)
	var b strings.Builder
	b.Grow(len(s) + 4)
	for i := 0; i < len(runes); i++ {
		r := runes[i]
		if isSuperscriptRune(r) {
			// A run of superscript characters is a single exponent.
			b.WriteByte('^')
			for i < len(runes) && isSuperscriptRune(runes[i]) {
				b.WriteByte(superscriptASCII(runes[i]))
				i++
			}
			i-- // the outer loop advances past the last consumed rune
			continue
		}
		switch r {
		case '·', '⋅': // MIDDLE DOT, DOT OPERATOR
			b.WriteByte('*')
		case 'µ', 'μ': // MICRO SIGN, GREEK SMALL LETTER MU
			b.WriteByte('u')
		case 'Ω', 'Ω': // GREEK CAPITAL OMEGA, OHM SIGN
			b.WriteString("Ohm")
		case '°': // DEGREE SIGN
			if i+1 < len(runes) {
				switch runes[i+1] {
				case 'C':
					b.WriteString("degC")
					i++
					continue
				case 'F':
					b.WriteString("degF")
					i++
					continue
				case 'K':
					b.WriteString("K")
					i++
					continue
				}
			}
			b.WriteString("deg")
		default:
			b.WriteRune(r)
		}
	}
	return b.String()
}

// isASCIIString reports whether s needs no Unicode normalization.
func isASCIIString(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] >= utf8.RuneSelf {
			return false
		}
	}
	return true
}

// superscriptTable maps every superscript rune to the ASCII byte it denotes.
var superscriptTable = map[rune]byte{
	'⁰': '0', '¹': '1', '²': '2', '³': '3', '⁴': '4',
	'⁵': '5', '⁶': '6', '⁷': '7', '⁸': '8', '⁹': '9',
	'⁻': '-', '⁺': '+',
}

func isSuperscriptRune(r rune) bool {
	_, ok := superscriptTable[r]
	return ok
}

func superscriptASCII(r rune) byte { return superscriptTable[r] }

// ParseUnit parses a unit string into a Unit. Grammar:
//
//	unit     := term ( ('*'|'/')? term )*
//	term     := atom ( ('^'|'**') exponent )?
//	exponent := integer | decimal | '(' integer '/' integer ')'
//	atom     := number | symbol | '%' | '(' unit ')' | '1'
//
// EXPONENTS ARE RATIONAL. "1/s^0.5" (SDE noise intensity), "s^(-1/2)" and
// "m^(3/2)" are legitimate corpus units; an integer-only exponent grammar
// cannot express them and — under the hard-error severity for an unparseable
// unit — falsely rejects the files that carry them.
//
// '*' AND '/' ARE ONE PRECEDENCE LEVEL, applied strictly left to right:
// "J/mol*K" is (J/mol)*K, NOT J/(mol*K), and "a/b/c" is a/(b*c). Giving '*' a
// tighter binding silently negates the exponent of every factor after a '/'.
//
// Whitespace separates tokens and, between two terms, means MULTIPLICATION —
// the SI style "kg m^2 s^-2" and the corpus's "ppb^-1 s^-1" (== ppb^-1 *
// s^-1). An explicit '*' is equivalent. '**' is accepted as a synonym for '^'
// (the Python/pint spelling, e.g. "Pa*m**3").
//
// A unit string carries DIMENSIONS ONLY: there is no species-tag convention, so
// the "C" of "kg C/m^2" is the coulomb, not a carbon tag.
//
// The empty string, "1" and "dimensionless" are the dimensionless unit.
// Non-ASCII spellings (μg, °C, W/m², J/(kg·K), Ω) are normalized first — see
// normalizeUnitString. Examples that must parse:
//
//	"m", "m/s", "m/s^2", "kg*m^2/s^3", "cm^3/molec/s", "mol/mol", "1/s",
//	"Pa", "J/(mol*K)", "Pa*m**3", "ppb^-1 s^-1", "μg/m^3", "°C", "1/s^0.5",
//	"s^(-1/2)", "W/m²", "J/(kg·K)", "%", "".
func ParseUnit(s string) (Unit, error) {
	s = strings.TrimSpace(s)
	if s == "" || s == "1" || s == "dimensionless" {
		return Unit{Scale: 1}, nil
	}
	src := normalizeUnitString(s)
	p := &unitParser{src: src}
	u, err := p.parseUnit()
	if err != nil {
		return Unit{}, fmt.Errorf("parse %q: %w", s, err)
	}
	if p.pos != len(p.src) {
		return Unit{}, fmt.Errorf("parse %q: unexpected %q at position %d", s, src[p.pos:], p.pos)
	}
	u.Symbol = s
	return u, nil
}

type unitParser struct {
	src string
	pos int
}

func (p *unitParser) skipSpace() {
	for p.pos < len(p.src) && unicode.IsSpace(rune(p.src[p.pos])) {
		p.pos++
	}
}

func (p *unitParser) peek() byte {
	p.skipSpace()
	if p.pos >= len(p.src) {
		return 0
	}
	return p.src[p.pos]
}

func (p *unitParser) parseUnit() (Unit, error) {
	u, err := p.parseTerm()
	if err != nil {
		return Unit{}, err
	}
	for {
		c := p.peek()
		switch {
		case c == '*' || c == '/':
			p.pos++
			next, err := p.parseTerm()
			if err != nil {
				return Unit{}, err
			}
			if c == '*' {
				u = u.Multiply(next)
			} else {
				u = u.Divide(next)
			}
		case startsAtom(c):
			// Juxtaposition is multiplication: "kg m^2 s^-2". peek() has
			// already skipped the separating whitespace, and the scanner is
			// greedy over identifier bytes, so "ms" remains ONE symbol
			// (millisecond) rather than m*s — juxtaposition can only arise
			// across a real token boundary.
			next, err := p.parseTerm()
			if err != nil {
				return Unit{}, err
			}
			u = u.Multiply(next)
		default:
			return u, nil
		}
	}
}

// startsAtom reports whether c can begin an atom (identifier, number, percent,
// or a parenthesized sub-unit) — the lookahead that drives implicit
// multiplication.
func startsAtom(c byte) bool {
	return isIdentStart(c) || (c >= '0' && c <= '9') || c == '(' || c == '%'
}

func (p *unitParser) parseTerm() (Unit, error) {
	u, err := p.parseAtom()
	if err != nil {
		return Unit{}, err
	}
	// Exponent: '^' or the Python/pint spelling '**'. peek() skips whitespace,
	// so the '**' bytes must be checked against the un-skipped position.
	switch {
	case p.peek() == '^':
		p.pos++
	case p.peek() == '*' && p.pos+1 < len(p.src) && p.src[p.pos+1] == '*':
		p.pos += 2
	default:
		return u, nil
	}
	exp, err := p.parseExponent()
	if err != nil {
		return Unit{}, err
	}
	return u.PowerRat(exp), nil
}

func (p *unitParser) parseAtom() (Unit, error) {
	p.skipSpace()
	if p.pos >= len(p.src) {
		return Unit{}, fmt.Errorf("unexpected end of input")
	}
	c := p.src[p.pos]
	if c == '(' {
		p.pos++
		u, err := p.parseUnit()
		if err != nil {
			return Unit{}, err
		}
		if p.peek() != ')' {
			return Unit{}, fmt.Errorf("missing ')'")
		}
		p.pos++
		return u, nil
	}
	// "%" is a unit symbol, not an identifier byte, so it is scanned on its own.
	if c == '%' {
		p.pos++
		return unitRegistry["%"], nil
	}
	// Bare integer "1" is dimensionless; any other bare number is a scalar factor.
	if c >= '0' && c <= '9' {
		start := p.pos
		for p.pos < len(p.src) && ((p.src[p.pos] >= '0' && p.src[p.pos] <= '9') || p.src[p.pos] == '.') {
			p.pos++
		}
		val, err := strconv.ParseFloat(p.src[start:p.pos], 64)
		if err != nil {
			return Unit{}, fmt.Errorf("invalid number %q", p.src[start:p.pos])
		}
		return Unit{Scale: val}, nil
	}
	// Identifier: letters followed by letters/digits/underscore.
	if !isIdentStart(c) {
		return Unit{}, fmt.Errorf("unexpected %q at position %d", c, p.pos)
	}
	start := p.pos
	p.pos++
	for p.pos < len(p.src) && isIdentCont(p.src[p.pos]) {
		p.pos++
	}
	sym := p.src[start:p.pos]
	u, ok := unitRegistry[sym]
	if !ok {
		return Unit{}, fmt.Errorf("unknown unit %q", sym)
	}
	return u, nil
}

// parseExponent parses a RATIONAL exponent:
//
//	exponent := integer | decimal | '(' integer '/' integer ')'
//
// e.g. "2", "-1", "0.5", "(1/2)", "(-1/2)". A parenthesized form may also hold
// a plain (possibly decimal) number — "m^(-2)" is the common pint spelling.
// The decimal form is converted EXACTLY (0.5 → 1/2, 1.25 → 5/4), never through
// a float, so two spellings of the same exponent compare equal.
func (p *unitParser) parseExponent() (Rat, error) {
	p.skipSpace()
	if p.pos < len(p.src) && p.src[p.pos] == '(' {
		p.pos++
		num, err := p.parseSignedNumber()
		if err != nil {
			return Rat{}, err
		}
		exp := num
		if p.peek() == '/' {
			p.pos++
			den, err := p.parseSignedNumber()
			if err != nil {
				return Rat{}, err
			}
			if den.IsZero() {
				return Rat{}, fmt.Errorf("zero denominator in exponent")
			}
			// Both sides are rationals; the quotient is num * den^-1.
			d := den.fix()
			exp = num.Mul(Rat{Num: d.Den, Den: d.Num})
		}
		if p.peek() != ')' {
			return Rat{}, fmt.Errorf("missing ')' closing exponent at position %d", p.pos)
		}
		p.pos++
		return exp, nil
	}
	return p.parseSignedNumber()
}

// parseSignedNumber scans an optionally signed integer or decimal literal and
// returns it as an exact rational.
func (p *unitParser) parseSignedNumber() (Rat, error) {
	p.skipSpace()
	start := p.pos
	if p.pos < len(p.src) && (p.src[p.pos] == '-' || p.src[p.pos] == '+') {
		p.pos++
	}
	digits := 0
	for p.pos < len(p.src) && p.src[p.pos] >= '0' && p.src[p.pos] <= '9' {
		p.pos++
		digits++
	}
	frac := 0
	if p.pos < len(p.src) && p.src[p.pos] == '.' {
		p.pos++
		for p.pos < len(p.src) && p.src[p.pos] >= '0' && p.src[p.pos] <= '9' {
			p.pos++
			frac++
		}
	}
	if digits == 0 && frac == 0 {
		return Rat{}, fmt.Errorf("expected a numeric exponent at position %d", start)
	}
	return ratFromDecimalLiteral(p.src[start:p.pos])
}

// ratFromFloat converts a literal exponent VALUE from the AST (where a number
// arrives as a float64) into an exact rational. Whole numbers and the short
// decimals that actually occur (0.5, 1.5, 0.25, 0.3333…) round-trip through the
// shortest decimal representation, which is exactly what strconv.FormatFloat
// with 'f'/-1 produces.
func ratFromFloat(v float64) (Rat, error) {
	if math.IsNaN(v) || math.IsInf(v, 0) {
		return Rat{}, fmt.Errorf("exponent is not finite")
	}
	if v == math.Trunc(v) && math.Abs(v) < 1e9 {
		return ratInt(int(v)), nil
	}
	return ratFromDecimalLiteral(strconv.FormatFloat(v, 'f', -1, 64))
}

// ratFromDecimalLiteral converts a signed decimal literal ("-1", "0.5",
// "1.25") to an exact rational: the digits are read as an integer over the
// corresponding power of ten. No float is involved, so "0.5", ".5" and "(1/2)"
// all yield exactly 1/2.
func ratFromDecimalLiteral(lit string) (Rat, error) {
	neg := false
	switch {
	case strings.HasPrefix(lit, "-"):
		neg, lit = true, lit[1:]
	case strings.HasPrefix(lit, "+"):
		lit = lit[1:]
	}
	intPart, fracPart, _ := strings.Cut(lit, ".")
	if intPart == "" {
		intPart = "0"
	}
	// An exponent with more than 9 fractional digits cannot be represented as an
	// int32 fraction; nothing in the corpus needs one, and a silent overflow
	// would corrupt the dimension.
	if len(fracPart) > 9 || len(intPart) > 9 {
		return Rat{}, fmt.Errorf("exponent %q has too many digits to represent exactly", lit)
	}
	digits := intPart + fracPart
	n, err := strconv.ParseInt(digits, 10, 64)
	if err != nil {
		return Rat{}, fmt.Errorf("invalid exponent %q", lit)
	}
	den := int64(1)
	for i := 0; i < len(fracPart); i++ {
		den *= 10
	}
	if neg {
		n = -n
	}
	return newRat(n, den), nil
}

func isIdentStart(c byte) bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'
}

func isIdentCont(c byte) bool {
	return isIdentStart(c) || (c >= '0' && c <= '9')
}

// Unit-finding codes. A unit finding is either a DEFECT IN THE FILE — which
// invalidates the document — or a limit of the ANALYSIS, which does not. The
// classification is decided at the point the finding is raised (never recovered
// later from the prose) and carried on UnitWarning.Code; ValidateStructuralWithCodes
// promotes the defect-bearing codes to `unit_inconsistency` structural errors.
//
// The split is the cross-binding policy and mirrors TypeScript's units.ts:
//
//   - UnitFindingDimensionalMismatch — a PROVABLE inconsistency: adding metres
//     to kilograms, log() of a dimensional quantity, an equation whose sides
//     have different dimensions. The file is wrong. → HARD ERROR.
//   - UnitFindingUnparseable — a declared unit string that does not denote a
//     real unit ("not_a_unit"). The file is wrong. → HARD ERROR.
//   - UnitFindingAnalysis — the checker cannot DETERMINE a dimension: a
//     symbolic (non-literal) exponent, an operator with no dimensional rule
//     (index/fn/aggregate/table_lookup), a malformed arity. That is a statement
//     about the checker, not a defect in the file. → WARNING.
//
// An unknown VARIABLE is likewise never a mismatch (it propagates as "unknown"
// and suppresses the check); it is separately a hard `undefined_variable` error,
// so the units layer does not double-report it.
const (
	UnitFindingDimensionalMismatch = "dimensional_mismatch"
	UnitFindingUnparseable         = "unparseable_unit"
	UnitFindingAnalysis            = "analysis"
)

// dimError is a propagation failure that carries its classification.
type dimError struct {
	code string
	msg  string
}

func (e *dimError) Error() string { return e.msg }

// mismatchErrf builds a PROVABLE dimensional inconsistency (promotable).
func mismatchErrf(format string, a ...any) error {
	return &dimError{code: UnitFindingDimensionalMismatch, msg: fmt.Sprintf(format, a...)}
}

// analysisErrf builds an "I cannot determine this" finding (stays a warning).
func analysisErrf(format string, a ...any) error {
	return &dimError{code: UnitFindingAnalysis, msg: fmt.Sprintf(format, a...)}
}

// findingCode recovers the classification of a propagation error. An error from
// anywhere else is treated conservatively as an analysis limit.
func findingCode(err error) string {
	var de *dimError
	if errors.As(err, &de) {
		return de.code
	}
	return UnitFindingAnalysis
}

// PropagateDimension walks an Expression AST and returns the resulting Unit.
// It mirrors the Julia reference implementation (get_expression_dimensions):
//
//   - numeric literals → dimensionless
//   - variable names → looked up in env; unknown variables return nil, nil
//     (dimensional analysis is best-effort when unit annotations are missing)
//   - "+", "-" require all operands to share a dimension
//   - "*" multiplies dimensions, "/" divides
//   - "^" requires a dimensionless constant exponent (which may be RATIONAL)
//   - CIRCULAR functions (sin/cos/tan) take an ANGLE or a dimensionless number
//     and return dimensionless; INVERSE circular functions (asin/acos/atan,
//     atan2) take dimensionless arguments and RETURN AN ANGLE (rad)
//   - the remaining transcendentals (exp/log/ln/log10, the hyperbolics) require
//     a dimensionless argument and return dimensionless; sqrt halves the
//     operand's dimension
//   - "D" (derivative) divides by the wrt variable's unit (default "t")
//
// A non-nil error signals a dimensional inconsistency discovered during
// propagation. The caller decides whether to turn that into a UnitWarning.
func PropagateDimension(expr Expression, env map[string]Unit) (*Unit, error) {
	return propagateDimensionWithCoords(expr, env, nil)
}

// propagateDimensionWithCoords extends PropagateDimension with a coordinate
// unit environment so grad/div/laplacian can resolve node.Dim against the
// enclosing model's domain. A nil coordEnv means "no coordinate info
// available" — grad/div/laplacian falls back to returning an unknown result
// rather than hard-coding a metre denominator.
func propagateDimensionWithCoords(expr Expression, env map[string]Unit, coordEnv map[string]*Unit) (*Unit, error) {
	switch e := expr.(type) {
	case nil:
		return nil, nil
	case float64, int, int32, int64, float32:
		// A BARE NUMERIC LITERAL has an INDETERMINATE dimension, not a
		// dimensionless one. Nothing in the AST says whether `273.15` is a pure
		// number or a temperature offset, whether `0.0224` is a molar volume, or
		// whether `1.23` is a ppb→µg/m³ conversion factor. The valid corpus is
		// full of these implicit-unit constants, and calling them dimensionless
		// manufactures a mismatch on every line that uses one.
		//
		// This matters BECAUSE dimensional findings are now hard errors: a
		// checker that fails the build must not fabricate a dimension it cannot
		// know. It costs nothing on the invalid corpus, where every pinned
		// inconsistency is stated between DECLARED quantities (`length + mass`,
		// `ln(mass)`, `m^kg`). Literals still behave correctly where their
		// meaning IS determined: additively they are neutral and adopt their
		// sibling's dimension (`T - 273.15` → K), an all-literal expression is
		// dimensionless (`1 + 2`), and an exponent is read by VALUE (`x^2`).
		return nil, nil
	case string:
		if u, ok := env[e]; ok {
			cp := u
			return &cp, nil
		}
		// Unknown variable ⇒ UNKNOWN dimension, not dimensionless. It is
		// separately a hard `undefined_variable` error, so the units layer does
		// not double-report it.
		return nil, nil
	case ExprNode:
		return propagateExprNode(e, env, coordEnv)
	case *ExprNode:
		return propagateExprNode(*e, env, coordEnv)
	default:
		return nil, nil
	}
}

func propagateExprNode(node ExprNode, env map[string]Unit, coordEnv map[string]*Unit) (*Unit, error) {
	switch node.Op {
	case "+", "-":
		// Unary minus: propagate its single operand.
		if node.Op == "-" && len(node.Args) == 1 {
			return propagateDimensionWithCoords(node.Args[0], env, coordEnv)
		}
		// A bare literal in ADDITIVE position is dimensionally NEUTRAL, not
		// dimensionless: it adopts the dimension of what it is added to. That is
		// how models are actually written — `T - 273.15`, `1 - phi`,
		// `biomass + 0.5` — with the literal silently carrying its sibling's
		// unit. Literal operands are therefore skipped, not compared. It costs no
		// coverage: a genuine inconsistency (`length + mass`) is between two
		// DECLARED quantities and is still caught.
		var first *Unit
		sawNonLiteral := false
		for i, arg := range node.Args {
			if _, isLiteral := toFloat64(arg); isLiteral {
				continue
			}
			sawNonLiteral = true
			u, err := propagateDimensionWithCoords(arg, env, coordEnv)
			if err != nil {
				return nil, err
			}
			if u == nil {
				continue
			}
			if first == nil {
				first = u
				continue
			}
			if !first.Dim.Equal(u.Dim) {
				return nil, mismatchErrf("dimensional mismatch in %q: arg 0 has %s, arg %d has %s",
					node.Op, first.Dim, i, u.Dim)
			}
		}
		if !sawNonLiteral {
			// An all-literal sum ("1 + 2") is a pure number.
			return &Unit{Scale: 1}, nil
		}
		return first, nil

	case "*":
		// A single indeterminate factor makes the whole product indeterminate.
		// Skipping the unknown factor instead (as this did) silently asserts it
		// is dimensionless, which is exactly wrong for the implicit-unit
		// constants the corpus multiplies by: `conc_ppb * 1.23` is a ppb→µg/m³
		// conversion, and reporting its dimension as "dimensionless" manufactures
		// a mismatch against the declared µg/m³.
		result := Unit{Scale: 1}
		for _, arg := range node.Args {
			u, err := propagateDimensionWithCoords(arg, env, coordEnv)
			if err != nil {
				return nil, err
			}
			if u == nil {
				return nil, nil
			}
			result = result.Multiply(*u)
		}
		return &result, nil

	case "/":
		if len(node.Args) != 2 {
			return nil, analysisErrf("'/' requires exactly 2 arguments, got %d", len(node.Args))
		}
		num, err := propagateDimensionWithCoords(node.Args[0], env, coordEnv)
		if err != nil {
			return nil, err
		}
		den, err := propagateDimensionWithCoords(node.Args[1], env, coordEnv)
		if err != nil {
			return nil, err
		}
		if num == nil || den == nil {
			return nil, nil
		}
		r := num.Divide(*den)
		return &r, nil

	case "^", "**", "pow":
		if len(node.Args) != 2 {
			return nil, analysisErrf("'%s' requires exactly 2 arguments, got %d", node.Op, len(node.Args))
		}
		base, err := propagateDimensionWithCoords(node.Args[0], env, coordEnv)
		if err != nil {
			return nil, err
		}
		expDim, err := propagateDimensionWithCoords(node.Args[1], env, coordEnv)
		if err != nil {
			return nil, err
		}
		if expDim != nil && !expDim.Dim.IsDimensionless() {
			return nil, mismatchErrf("exponent in '%s' must be dimensionless, got %s", node.Op, expDim.Dim)
		}
		if base == nil {
			return nil, nil
		}
		expVal, ok := toFloat64(node.Args[1])
		if !ok {
			// SYMBOLIC exponent (`x^alpha`, alpha a parameter): the result's
			// dimension depends on alpha's runtime VALUE, so it is genuinely
			// undeterminable. Assuming the base's dimension (as this did) is a
			// fabrication — for `k2 * x^alpha * z^beta` it manufactured a clean
			// `1/s` and then reported a mismatch against the true LHS, rejecting
			// the valid tests/valid/expr_graphs_variable_deps.esm.
			return nil, nil
		}
		// A FRACTIONAL literal exponent is fine: dimension exponents are
		// rational, so `p^0.5` is p's dimension halved.
		exp, err := ratFromFloat(expVal)
		if err != nil {
			return nil, analysisErrf("exponent %v in '%s' is not a representable rational: %v", expVal, node.Op, err)
		}
		r := base.PowerRat(exp)
		return &r, nil

	case "sqrt":
		if len(node.Args) != 1 {
			return nil, analysisErrf("sqrt requires 1 argument, got %d", len(node.Args))
		}
		base, err := propagateDimensionWithCoords(node.Args[0], env, coordEnv)
		if err != nil {
			return nil, err
		}
		if base == nil {
			return nil, nil
		}
		// sqrt HALVES every exponent — it is not a transcendental and does not
		// require a dimensionless argument. With RATIONAL exponents that is always
		// defined: sqrt(m^2/s^2) is m/s (the ordinary spelling of a wave speed or
		// an RMS) and sqrt(m^3) is m^(3/2). The old "non-square dimension"
		// rejection was an artifact of the integer exponent vector.
		return &Unit{Dim: base.Dim.PowerRat(newRat(1, 2)), Scale: math.Sqrt(base.Scale)}, nil

	case "sin", "cos", "tan":
		// CIRCULAR functions take an ANGLE. With `rad` carried as a base axis, the
		// argument is legitimately dimensioned — `sin(theta)` with theta declared
		// "rad" (or "deg") — so the rule is: an angle OR a dimensionless number.
		// `sin(kg)` is still rejected.
		if len(node.Args) != 1 {
			return nil, analysisErrf("'%s' requires 1 argument, got %d", node.Op, len(node.Args))
		}
		arg, err := propagateDimensionWithCoords(node.Args[0], env, coordEnv)
		if err != nil {
			return nil, err
		}
		if arg != nil && !arg.Dim.IsDimensionless() && !isAngleDim(arg.Dim) {
			return nil, mismatchErrf("argument of '%s' must be an angle or dimensionless, got %s", node.Op, arg.Dim)
		}
		return &Unit{Scale: 1}, nil

	case "asin", "acos", "atan":
		// INVERSE CIRCULAR functions RETURN AN ANGLE. Asserting a dimensionless
		// result while `rad` is a base axis makes every `theta: "rad"` computed by
		// `acos(...)` a guaranteed mismatch — which is exactly what the shipped
		// stdlib does (lib/solar.esm's solar zenith angle).
		if len(node.Args) != 1 {
			return nil, analysisErrf("'%s' requires 1 argument, got %d", node.Op, len(node.Args))
		}
		arg, err := propagateDimensionWithCoords(node.Args[0], env, coordEnv)
		if err != nil {
			return nil, err
		}
		if arg != nil && !arg.Dim.IsDimensionless() {
			return nil, mismatchErrf("argument of '%s' must be dimensionless, got %s", node.Op, arg.Dim)
		}
		return &Unit{Dim: radDim(), Scale: 1}, nil

	case "atan2":
		// atan2(y, x) RETURNS AN ANGLE. Its two arguments are a ratio, so they need
		// only share a dimension — any dimension.
		if len(node.Args) != 2 {
			return nil, analysisErrf("'atan2' requires 2 arguments, got %d", len(node.Args))
		}
		y, err := propagateDimensionWithCoords(node.Args[0], env, coordEnv)
		if err != nil {
			return nil, err
		}
		x, err := propagateDimensionWithCoords(node.Args[1], env, coordEnv)
		if err != nil {
			return nil, err
		}
		if x != nil && y != nil && !x.Dim.Equal(y.Dim) {
			return nil, mismatchErrf("atan2 arguments must share a dimension: %s vs %s", y.Dim, x.Dim)
		}
		return &Unit{Dim: radDim(), Scale: 1}, nil

	case "sinh", "cosh", "tanh", "asinh", "acosh", "atanh",
		"exp", "log", "log10", "ln":
		// The remaining transcendentals: a dimensionless argument, a dimensionless
		// result. (A hyperbolic argument is a pure number, not an angle.)
		if len(node.Args) != 1 {
			return nil, analysisErrf("'%s' requires 1 argument, got %d", node.Op, len(node.Args))
		}
		arg, err := propagateDimensionWithCoords(node.Args[0], env, coordEnv)
		if err != nil {
			return nil, err
		}
		if arg != nil && !arg.Dim.IsDimensionless() {
			return nil, mismatchErrf("argument of '%s' must be dimensionless, got %s", node.Op, arg.Dim)
		}
		return &Unit{Scale: 1}, nil

	case "abs", "sign":
		if len(node.Args) != 1 {
			return nil, analysisErrf("'%s' requires 1 argument, got %d", node.Op, len(node.Args))
		}
		return propagateDimensionWithCoords(node.Args[0], env, coordEnv)

	case OpDerivative:
		if len(node.Args) != 1 {
			return nil, analysisErrf("'D' requires 1 argument, got %d", len(node.Args))
		}
		varDim, err := propagateDimensionWithCoords(node.Args[0], env, coordEnv)
		if err != nil {
			return nil, err
		}
		if varDim == nil {
			return nil, nil
		}
		wrtUnit, ok := env[derivativeWrt(node)]
		if !ok {
			// An UNDECLARED independent variable has an unknown dimension, so the
			// derivative's dimension is unknown too. Defaulting to seconds here
			// was a false-positive factory: in a nondimensionalized model (state
			// and RHS both declared "1", `t` undeclared) it manufactured `1/s` on
			// the left against `1` on the right and reported a mismatch in a
			// perfectly valid file — 8 of them in tests/valid.
			//
			// Coverage is not lost: the equation-level rule
			// (derivativeTimeMismatch, applied in validateEquationDimensionsCoords)
			// still rejects a derivative equation that NO choice of time unit
			// could reconcile, which is what the invalid corpus actually pins.
			return nil, nil
		}
		r := varDim.Divide(wrtUnit)
		return &r, nil

	case "grad", "div", "laplacian":
		// Spatial derivative: operand dimensions divided by the spatial
		// coordinate's declared units. The coordinate is identified by
		// node.Dim and resolved against the enclosing model's domain
		// (coordEnv). When coordEnv is nil (no domain context) or the
		// coordinate is missing / declared without units, we return the
		// unpropagated operand dim — the structural check in
		// checkSpatialOperatorCoordinateUnits emits the unit_inconsistency
		// error separately, so we avoid hard-coding a metre denominator
		// here.
		if len(node.Args) < 1 {
			return nil, nil
		}
		operand, err := propagateDimensionWithCoords(node.Args[0], env, coordEnv)
		if err != nil {
			return nil, err
		}
		if operand == nil {
			return nil, nil
		}
		if node.Dim == nil || coordEnv == nil {
			return nil, nil
		}
		coord, present := coordEnv[*node.Dim]
		if !present || coord == nil || coord.Dim.IsDimensionless() {
			return nil, nil
		}
		r := operand.Divide(*coord)
		return &r, nil

	case "min", "max":
		// Return dimension of first operand; require others to match.
		var first *Unit
		for i, arg := range node.Args {
			u, err := propagateDimensionWithCoords(arg, env, coordEnv)
			if err != nil {
				return nil, err
			}
			if u == nil {
				continue
			}
			if first == nil {
				first = u
				continue
			}
			if !first.Dim.Equal(u.Dim) {
				return nil, mismatchErrf("dimensional mismatch in %q: arg 0 has %s, arg %d has %s",
					node.Op, first.Dim, i, u.Dim)
			}
		}
		return first, nil
	}
	// Unknown operator: propagate nothing rather than erroring, matching the
	// Julia reference which warns and returns nothing.
	return nil, nil
}

// BuildUnitEnv converts a map of name→unit-string into a map of name→Unit.
// Entries whose unit string fails to parse are omitted from the returned
// environment and reported in the second return value (a name→parse-error map)
// so callers can emit warnings. Empty unit strings are skipped without error.
func BuildUnitEnv(raw map[string]string) (map[string]Unit, map[string]error) {
	env := make(map[string]Unit, len(raw))
	bad := map[string]error{}
	for name, s := range raw {
		if s == "" {
			continue
		}
		u, err := ParseUnit(s)
		if err != nil {
			bad[name] = err
			continue
		}
		env[name] = u
	}
	return env, bad
}

// buildModelUnitEnv builds the unit environment for a model from its declared
// variable units. See BuildUnitEnv for the return-value contract.
func buildModelUnitEnv(model *Model) (map[string]Unit, map[string]error) {
	raw := make(map[string]string, len(model.Variables))
	for name, v := range model.Variables {
		if v.Units != nil {
			raw[name] = *v.Units
		}
	}
	return BuildUnitEnv(raw)
}

// buildSystemUnitEnv builds the unit environment for a reaction system from the
// declared units of its species and parameters. See BuildUnitEnv for the
// return-value contract.
func buildSystemUnitEnv(system *ReactionSystem) (map[string]Unit, map[string]error) {
	raw := make(map[string]string, len(system.Species)+len(system.Parameters))
	for name, sp := range system.Species {
		if sp.Units != nil {
			raw[name] = *sp.Units
		}
	}
	for name, p := range system.Parameters {
		if p.Units != nil {
			raw[name] = *p.Units
		}
	}
	return BuildUnitEnv(raw)
}

// ValidateEquationDimensions checks that the LHS and RHS of an equation have
// the same dimension. It returns a non-nil UnitWarning iff a concrete
// inconsistency was detected. Missing annotations are treated as "unknown" and
// do NOT produce a warning (matching the Python/Julia best-effort semantics).
func ValidateEquationDimensions(eq *Equation, env map[string]Unit, path string) *UnitWarning {
	return validateEquationDimensionsCoords(eq, env, nil, path)
}

func dimString(u *Unit) string {
	if u == nil {
		return "unknown"
	}
	return u.Dim.String()
}

// derivativeWrt names the variable a derivative node differentiates with respect
// to, defaulting to the implicit independent variable.
func derivativeWrt(node ExprNode) string {
	if node.Wrt != nil {
		return *node.Wrt
	}
	return DefaultIndepVar
}

// derivativeStateDim inspects an equation's LHS. When it is a derivative taken
// with respect to an UNDECLARED variable — the ordinary case, since `t` is
// rarely given units — it returns the dimension of the differentiated state and
// true, signalling that the caller must use derivativeTimeMismatch instead of a
// direct LHS/RHS comparison. Otherwise it returns false.
func derivativeStateDim(lhs Expression, env map[string]Unit, coordEnv map[string]*Unit) (*Unit, bool) {
	var node ExprNode
	switch e := lhs.(type) {
	case ExprNode:
		node = e
	case *ExprNode:
		node = *e
	default:
		return nil, false
	}
	if node.Op != OpDerivative || len(node.Args) != 1 {
		return nil, false
	}
	if _, declared := env[derivativeWrt(node)]; declared {
		return nil, false
	}
	state, err := propagateDimensionWithCoords(node.Args[0], env, coordEnv)
	if err != nil {
		return nil, false
	}
	return state, true
}

// derivativeTimeMismatch decides a derivative equation whose independent
// variable carries no declared unit.
//
// The time unit is unknown, so d(state)/dt could have any time exponent — but
// the NON-time dimensions cannot move. If dim(state)/dim(rhs) has a nonzero
// exponent in any dimension other than time, no choice of time unit reconciles
// the two sides and the equation is provably wrong.
//
// This is what keeps units_invalid_derivative.esm (an `m` state assigned a `kg`
// expression) and units_incompatible_assignment.esm rejected, while accepting
// `D(x) = -x` with `x` dimensionless (ratio is a pure power of time).
func derivativeTimeMismatch(state, rhs *Unit) error {
	if state == nil || rhs == nil {
		return nil
	}
	ratio := state.Dim.Divide(rhs.Dim)
	for i := range ratio {
		if i == dimTime || ratio[i].IsZero() {
			continue
		}
		return mismatchErrf(
			"no time unit can reconcile d(%s)/dt with %s (their ratio %s is not a power of time)",
			state.Dim, rhs.Dim, ratio)
	}
	return nil
}

// validateModelUnits runs dimensional analysis over a model's declared units,
// its equations, and its observed-variable expressions, appending every finding
// to the result. Findings are CODED (see the UnitFinding* constants); the caller
// promotes the promotable ones to structural errors.
func validateModelUnits(modelName string, model *Model, basePath string, file *ESMFile, result *StructuralValidationResult) {
	env, bad := buildModelUnitEnv(model)
	for _, name := range sortedKeys(bad) {
		result.UnitWarnings = append(result.UnitWarnings, UnitWarning{
			Path:    fmt.Sprintf("%s/variables/%s/units", basePath, name),
			Code:    UnitFindingUnparseable,
			Message: fmt.Sprintf("could not parse unit: %v", bad[name]),
		})
	}
	for i, eq := range model.Equations {
		eqPath := fmt.Sprintf("%s/equations/%d", basePath, i)
		if w := validateEquationDimensionsCoords(&eq, env, nil, eqPath); w != nil {
			result.UnitWarnings = append(result.UnitWarnings, *w)
		}
	}
	validateObservedVariableUnits(model, env, basePath, result)
	checkConversionFactorConsistency(modelName, model, result)
	checkPhysicalConstantUnits(modelName, model, result)
	checkDefaultUnits(modelName, model, result)
}

// validateObservedVariableUnits dimension-checks each OBSERVED variable's
// defining expression against the variable's own declared units.
//
// An observed variable is an equation in every sense that matters here —
// `invalid_sum: {units: "m", expression: length + mass}` is exactly as wrong as
// the equation `invalid_sum = length + mass` — but it is stored in the variable
// table, not in `equations`, so a checker that walks only `model.Equations`
// (as this one did) is blind to it. That blindness is why Go accepted
// units_inconsistent_addition.esm, units_inconsistent_subtraction.esm,
// units_invalid_exponent.esm, units_invalid_logarithm.esm and
// units_mixed_dimensional_operations.esm — five fixtures the shared corpus pins
// as INVALID, each of whose only defect lives in an observed variable.
//
// Findings are reported at `/models/<M>/variables/<v>`, the pointer
// tests/invalid/expected_errors.json pins (and the one TypeScript emits).
func validateObservedVariableUnits(model *Model, env map[string]Unit, basePath string, result *StructuralValidationResult) {
	for _, name := range sortedKeys(model.Variables) {
		v := model.Variables[name]
		if v.Type != VarTypeObserved || v.Expression == nil {
			continue
		}
		path := fmt.Sprintf("%s/variables/%s", basePath, name)

		got, err := PropagateDimension(v.Expression, env)
		if err != nil {
			result.UnitWarnings = append(result.UnitWarnings, UnitWarning{
				Path:     path,
				Code:     findingCode(err),
				Message:  fmt.Sprintf("dimensional analysis failed on observed variable %q: %v", name, err),
				LhsUnits: declaredDimString(v.Units),
				RhsUnits: "error",
			})
			continue
		}
		// The expression's dimension must equal the variable's DECLARED units.
		// Either side being unknown means the check cannot be decided, which is
		// not a finding (an undeclared unit is not an error; an unparseable one
		// is already reported above).
		declared, ok := env[name]
		if !ok || got == nil {
			continue
		}
		if !declared.Dim.Equal(got.Dim) {
			result.UnitWarnings = append(result.UnitWarnings, UnitWarning{
				Path:     path,
				Code:     UnitFindingDimensionalMismatch,
				Message:  fmt.Sprintf("observed variable %q is declared %s but its expression has dimension %s", name, declared.Dim, got.Dim),
				LhsUnits: declared.Dim.String(),
				RhsUnits: got.Dim.String(),
			})
		}
	}
}

// declaredDimString renders a declared unit string's dimension, or "unknown"
// when it is absent or does not parse.
func declaredDimString(units *string) string {
	if units == nil {
		return "unknown"
	}
	u, err := ParseUnit(*units)
	if err != nil {
		return "unknown"
	}
	return u.Dim.String()
}

// validateEquationDimensionsCoords mirrors ValidateEquationDimensions but uses
// the coord-aware propagator so grad/div/laplacian resolves node.Dim against
// the enclosing model's domain.
// The reported Path is the EQUATION pointer (`/models/<M>/equations/<i>`) for
// every finding, including one discovered inside the LHS or RHS. That is the
// pointer tests/invalid/expected_errors.json pins and the one TypeScript emits;
// the previous `/lhs` and `/rhs` suffixes pointed at no schema node and did not
// match the corpus.
func validateEquationDimensionsCoords(eq *Equation, env map[string]Unit, coordEnv map[string]*Unit, path string) *UnitWarning {
	lhs, lhsErr := propagateDimensionWithCoords(eq.LHS, env, coordEnv)
	rhs, rhsErr := propagateDimensionWithCoords(eq.RHS, env, coordEnv)

	if lhsErr != nil {
		return &UnitWarning{
			Path:     path,
			Code:     findingCode(lhsErr),
			Message:  "dimensional analysis failed on LHS: " + lhsErr.Error(),
			LhsUnits: "error",
			RhsUnits: dimString(rhs),
		}
	}
	if rhsErr != nil {
		return &UnitWarning{
			Path:     path,
			Code:     findingCode(rhsErr),
			Message:  "dimensional analysis failed on RHS: " + rhsErr.Error(),
			LhsUnits: dimString(lhs),
			RhsUnits: "error",
		}
	}

	// D(x)/d<wrt> = rhs with an UNDECLARED <wrt>: the LHS dimension is unknown
	// (see the OpDerivative case), so the sides cannot be compared directly. The
	// equation is still provably wrong when no time unit could reconcile them.
	if state, undeclared := derivativeStateDim(eq.LHS, env, coordEnv); undeclared {
		if err := derivativeTimeMismatch(state, rhs); err != nil {
			return &UnitWarning{
				Path:     path,
				Code:     UnitFindingDimensionalMismatch,
				Message:  err.Error(),
				LhsUnits: dimString(state),
				RhsUnits: dimString(rhs),
			}
		}
		return nil
	}

	if lhs == nil || rhs == nil {
		return nil
	}
	if !lhs.Dim.Equal(rhs.Dim) {
		return &UnitWarning{
			Path:     path,
			Code:     UnitFindingDimensionalMismatch,
			Message:  fmt.Sprintf("LHS dimension %s does not match RHS dimension %s", lhs.Dim, rhs.Dim),
			LhsUnits: lhs.Dim.String(),
			RhsUnits: rhs.Dim.String(),
		}
	}
	return nil
}

// knownPhysicalConstant pairs a canonical unit string with a human description.
type knownPhysicalConstant struct {
	canonical   string
	description string
}

// knownPhysicalConstants lists well-known physical constants whose declared
// units can be dimensionally verified. Conservative on purpose — names chosen
// to minimize collision with common non-constant uses. Mirrors Python's
// _KNOWN_PHYSICAL_CONSTANTS.
var knownPhysicalConstants = map[string]knownPhysicalConstant{
	"R":   {"J/(mol*K)", "ideal gas constant"},
	"k_B": {"J/K", "Boltzmann constant"},
	"N_A": {"1/mol", "Avogadro constant"},
}

// checkPhysicalConstantUnits flags parameters whose name matches a well-known
// physical constant but whose declared units are dimensionally incompatible
// with the canonical form (e.g., R declared as 'kcal/mol' — missing temperature
// — instead of 'J/(mol*K)'). Reports at the first observed-variable usage
// site in the same model; otherwise at the declaration.
//
// Mirrors Python's parse._check_physical_constant_units (gt-3tgv).
func checkPhysicalConstantUnits(modelName string, model *Model, result *StructuralValidationResult) {
	for vname, vdef := range model.Variables {
		if vdef.Type != VarTypeParameter {
			continue
		}
		constant, ok := knownPhysicalConstants[vname]
		if !ok {
			continue
		}
		if vdef.Units == nil || *vdef.Units == "" {
			continue
		}
		declared := *vdef.Units
		declaredU, err := ParseUnit(declared)
		if err != nil {
			continue
		}
		canonicalU, err := ParseUnit(constant.canonical)
		if err != nil {
			continue
		}
		if declaredU.Dim.Equal(canonicalU.Dim) {
			continue
		}
		usageName := ""
		for otherName, otherDef := range model.Variables {
			if otherDef.Type != VarTypeObserved || otherDef.Expression == nil {
				continue
			}
			if exprReferencesName(otherDef.Expression, vname) {
				usageName = otherName
				break
			}
		}
		target := usageName
		if target == "" {
			target = vname
		}
		result.StructuralErrors = append(result.StructuralErrors, StructuralError{
			Path:    fmt.Sprintf("/models/%s/variables/%s", modelName, target),
			Code:    ErrorUnitInconsistency,
			Message: "Physical constant used with incorrect dimensional analysis",
			Details: map[string]any{
				"constant_name":        vname,
				"constant_description": constant.description,
				"declared_units":       declared,
				"canonical_units":      constant.canonical,
			},
		})
	}
}

// exprReferencesName reports whether the expression tree references a variable
// by exact name (string leaf match).
func exprReferencesName(e Expression, name string) bool {
	switch v := e.(type) {
	case string:
		return v == name
	case ExprNode:
		for _, a := range v.Args {
			if exprReferencesName(a, name) {
				return true
			}
		}
	case *ExprNode:
		if v == nil {
			return false
		}
		for _, a := range v.Args {
			if exprReferencesName(a, name) {
				return true
			}
		}
	}
	return false
}

// checkConversionFactorConsistency flags observed variables whose expression
// has the shape `<numeric> * <var>` (or `<var> * <numeric>`) when the declared
// output units and the source variable's units are dimensionally compatible
// but the numeric literal disagrees with the correct linear scale factor.
//
// Example: `converted_pressure` in Pa assigned `50000 * p_atm` where p_atm is
// in atm. Dimensions match (both are pressure) but the numeric factor should
// be 101325 Pa/atm.
//
// Mirrors Python's parse._check_conversion_factor_consistency (gt-nvdv).
// Affine conversions (e.g., degC→K) are skipped; compound expressions,
// matching units, and unparseable units are silently ignored.
func checkConversionFactorConsistency(modelName string, model *Model, result *StructuralValidationResult) {
	varUnits := make(map[string]string, len(model.Variables))
	for name, v := range model.Variables {
		if v.Units != nil {
			varUnits[name] = *v.Units
		}
	}
	for vname, vdef := range model.Variables {
		if vdef.Type != VarTypeObserved || vdef.Expression == nil {
			continue
		}
		lhsUnits := ""
		if vdef.Units != nil {
			lhsUnits = *vdef.Units
		}
		if lhsUnits == "" {
			continue
		}
		node, ok := asExprNode(vdef.Expression)
		if !ok || node.Op != "*" || len(node.Args) != 2 {
			continue
		}
		var numeric float64
		var varRef string
		var haveNumeric, haveVar bool
		for _, a := range node.Args {
			switch v := a.(type) {
			case bool:
				// ignored
			case float64:
				numeric = v
				haveNumeric = true
			case int:
				numeric = float64(v)
				haveNumeric = true
			case int64:
				numeric = float64(v)
				haveNumeric = true
			case string:
				varRef = v
				haveVar = true
			}
		}
		if !haveNumeric || !haveVar {
			continue
		}
		srcUnits, ok := varUnits[varRef]
		if !ok || srcUnits == "" {
			continue
		}
		if srcUnits == lhsUnits {
			continue
		}
		srcU, err := ParseUnit(srcUnits)
		if err != nil {
			continue
		}
		lhsU, err := ParseUnit(lhsUnits)
		if err != nil {
			continue
		}
		if !srcU.Dim.Equal(lhsU.Dim) {
			continue // dimensional mismatch — other checks handle it
		}
		if isAffineTempUnit(srcUnits) || isAffineTempUnit(lhsUnits) {
			continue
		}
		if lhsU.Scale == 0 {
			continue
		}
		factor := srcU.Scale / lhsU.Scale
		if factor == 0 {
			continue
		}
		tol := 1e-9 * math.Max(math.Abs(factor), 1.0)
		if math.Abs(numeric-factor) <= tol {
			continue
		}
		result.StructuralErrors = append(result.StructuralErrors, StructuralError{
			Path:    fmt.Sprintf("/models/%s/variables/%s", modelName, vname),
			Code:    ErrorUnitInconsistency,
			Message: "Unit conversion factor is incorrect for specified unit transformation",
			Details: map[string]any{
				"variable":        vname,
				"declared_units":  lhsUnits,
				"source_units":    srcUnits,
				"declared_factor": numeric,
				"expected_factor": factor,
			},
		})
	}
}

// isAffineTempUnit reports whether a unit string denotes a temperature scale
// with an OFFSET (Celsius, Fahrenheit). The registry models both as a scaled
// Kelvin — the offset is deliberately not carried — so a scale-factor comparison
// against them is meaningless and is skipped.
//
// The bare "C" is NOT matched: it is the COULOMB (esm-spec §4.8.1). Celsius is
// spelled "degC", "Celsius", or "°C" (which normalizeUnitString folds to degC).
func isAffineTempUnit(s string) bool {
	switch strings.TrimSpace(normalizeUnitString(s)) {
	case "degC", "degF", "Celsius":
		return true
	}
	return false
}

// checkDefaultUnits flags a variable whose `default_units` require an AFFINE
// conversion to its declared `units` (`units: "K"` with `default_units: "degC"`:
// 25 degC is 298.15 K, not 25 K).
//
// A scalar `default` can only carry a multiplicative conversion; an offset
// cannot be applied to it, so the declaration is unsatisfiable and the value it
// would produce is silently wrong. Mirrors TS validate/model-checks.ts
// `validateDefaultUnits` (tests/invalid/units_parameter_default_mismatch.esm).
func checkDefaultUnits(modelName string, model *Model, result *StructuralValidationResult) {
	for _, vname := range sortedKeys(model.Variables) {
		v := model.Variables[vname]
		if v.DefaultUnits == nil || v.Units == nil {
			continue
		}
		declared, defaultUnits := *v.Units, *v.DefaultUnits
		if declared == "" || defaultUnits == "" || declared == defaultUnits {
			continue
		}
		if !isAffineTempUnit(declared) && !isAffineTempUnit(defaultUnits) {
			continue
		}
		result.StructuralErrors = append(result.StructuralErrors, StructuralError{
			Path: fmt.Sprintf("/models/%s/variables/%s", modelName, vname),
			Code: ErrorUnitInconsistency,
			Message: fmt.Sprintf(
				"default_units '%s' requires an affine conversion to/from '%s'; a scalar default cannot carry an offset — use an expression instead",
				defaultUnits, declared),
			Details: map[string]any{
				"variable":      vname,
				"units":         declared,
				"default_units": defaultUnits,
			},
		})
	}
}

// validateReactionRateUnits enforces the mass-action dimensional constraint
// from spec §7.4: rate dimensions must equal concentration^(1-total_order)/time,
// where the reference concentration unit is the first substrate's units.
// Matches the Julia/Python/TS/Rust checks. Skipped for dimensionless species
// (mol/mol, ppm, …) because atmospheric-chemistry rate expressions commonly
// bake a number-density factor into the rate constant.
func validateReactionRateUnits(_ string, system *ReactionSystem, basePath string, result *StructuralValidationResult) {
	env, _ := buildSystemUnitEnv(system)

	timeUnit := Unit{Dim: Dimension{dimTime: ratInt(1)}, Scale: 1.0}

	for i, rx := range system.Reactions {
		rxPath := fmt.Sprintf("%s/reactions/%d", basePath, i)

		rateUnit, err := PropagateDimension(rx.Rate, env)
		if err != nil || rateUnit == nil {
			continue
		}

		if len(rx.Substrates) == 0 {
			continue
		}

		firstSp := rx.Substrates[0].Species
		concUnit, ok := env[firstSp]
		if !ok {
			continue
		}
		if concUnit.Dim.IsDimensionless() {
			continue
		}

		totalOrder := 0
		resolvable := true
		fractionalSubstrate := false
		for _, sub := range rx.Substrates {
			if _, ok := env[sub.Species]; !ok {
				resolvable = false
				break
			}
			if sub.Stoichiometry != math.Trunc(sub.Stoichiometry) || math.IsInf(sub.Stoichiometry, 0) || math.IsNaN(sub.Stoichiometry) {
				// Unit exponents must be integer — skip the rate-units
				// compatibility check for fractional substrate stoichiometry.
				fractionalSubstrate = true
				break
			}
			totalOrder += int(sub.Stoichiometry)
		}
		if !resolvable || fractionalSubstrate {
			continue
		}

		// `rate` carries EITHER of two things, and they have different units:
		//
		//   - a mass-action rate CONSTANT (`rate: "k"`), whose units are
		//     conc^(1-order)/time — the reaction's rate is then k * ΠCᵢ; or
		//   - an explicit rate LAW that already multiplies in the substrate
		//     concentrations (`rate: k*exp(...)*A*B`), whose units are the rate
		//     itself, conc/time.
		//
		// Comparing a rate LAW against the rate-CONSTANT units is off by exactly
		// ΠCᵢ and rejects correct chemistry — it fired on the perfectly valid
		// second-order Arrhenius law in tests/valid/expr_graphs_variable_deps.esm.
		// A rate expression that REFERENCES its own substrates is a rate law.
		expectedRateUnit := concUnit.Power(1 - totalOrder).Divide(timeUnit)
		if rateIsExplicitLaw(rx) {
			expectedRateUnit = concUnit.Divide(timeUnit)
		}
		if !rateUnit.Dim.Equal(expectedRateUnit.Dim) {
			rateUnitsStr := ""
			if varName, isVar := rateVarName(rx.Rate); isVar {
				if p, ok := system.Parameters[varName]; ok && p.Units != nil {
					rateUnitsStr = *p.Units
				} else if s, ok := system.Species[varName]; ok && s.Units != nil {
					rateUnitsStr = *s.Units
				}
			}
			firstSpUnits := ""
			if s, ok := system.Species[firstSp]; ok && s.Units != nil {
				firstSpUnits = *s.Units
			}
			result.StructuralErrors = append(result.StructuralErrors, StructuralError{
				Path:    rxPath,
				Code:    ErrorUnitInconsistency,
				Message: "Reaction rate expression has incompatible units for reaction stoichiometry",
				Details: map[string]any{
					"reaction_id":         rx.ID,
					"rate_units":          rateUnitsStr,
					"expected_rate_units": formatExpectedRateUnits(firstSpUnits, totalOrder),
					"reaction_order":      totalOrder,
				},
			})
		}
	}
}

// formatExpectedRateUnits composes the canonical rate-unit string from the
// reference species unit string and total reaction order, matching the
// contract in tests/invalid/expected_errors.json. Examples:
//
//	("mol/L", 2) → "L/(mol*s)"
//	("mol/L", 1) → "1/s"
//	("mol/L", 0) → "mol/(L*s)"
//	("mol/m^3", 2) → "m^3/(mol*s)"
func formatExpectedRateUnits(speciesUnits string, totalOrder int) string {
	exp := 1 - totalOrder
	if exp == 0 {
		return "1/s"
	}
	num, den := splitUnitNumDen(speciesUnits)
	if exp < 0 {
		num, den = den, num
		exp = -exp
	}
	numStr := powerFactor(num, exp)
	denFactors := []string{}
	if df := powerFactor(den, exp); df != "" {
		denFactors = append(denFactors, df)
	}
	denFactors = append(denFactors, "s")
	if numStr == "" {
		numStr = "1"
	}
	if len(denFactors) == 1 {
		return numStr + "/" + denFactors[0]
	}
	return numStr + "/(" + strings.Join(denFactors, "*") + ")"
}

// splitUnitNumDen splits a unit string like "mol/L" into ("mol", "L") or
// "mol/(L*s)" into ("mol", "L*s"). The split is on the first top-level '/'.
// Returns ("", "") for an empty string. If no '/' appears, the whole string
// is the numerator.
func splitUnitNumDen(s string) (string, string) {
	s = strings.TrimSpace(s)
	if s == "" {
		return "", ""
	}
	depth := 0
	for i, r := range s {
		switch r {
		case '(':
			depth++
		case ')':
			depth--
		case '/':
			if depth == 0 {
				num := strings.TrimSpace(s[:i])
				den := strings.TrimSpace(s[i+1:])
				den = strings.TrimPrefix(den, "(")
				den = strings.TrimSuffix(den, ")")
				return num, den
			}
		}
	}
	return s, ""
}

// powerFactor raises a unit factor to an integer power, rendering the result
// as a string. Parenthesizes compound factors for clarity when the power is
// not 1.
func powerFactor(s string, n int) string {
	s = strings.TrimSpace(s)
	if s == "" {
		return ""
	}
	if n == 1 {
		return s
	}
	if strings.ContainsAny(s, "*/") {
		return fmt.Sprintf("(%s)^%d", s, n)
	}
	return fmt.Sprintf("%s^%d", s, n)
}

// rateVarName returns the variable name if the rate expression is a bare
// variable reference, otherwise ("", false).
func rateVarName(rate Expression) (string, bool) {
	if s, ok := rate.(string); ok {
		return s, true
	}
	return "", false
}

// rateIsExplicitLaw reports whether a reaction's `rate` expression is a full
// rate LAW (it multiplies in its own substrate concentrations, e.g.
// `k*exp(-Ea/(R*T))*A*B`) rather than a bare mass-action rate CONSTANT
// (`rate: "k"`). The two have different units — conc/time vs
// conc^(1-order)/time — so the dimensional check must know which it is looking
// at. Referencing a substrate is the discriminator.
func rateIsExplicitLaw(rx Reaction) bool {
	for _, sub := range rx.Substrates {
		if exprReferencesName(rx.Rate, sub.Species) {
			return true
		}
	}
	return false
}

// validateReactionSystemUnits runs dimensional analysis over a reaction
// system. Rate expressions whose dimensions cannot be determined are skipped;
// rate expressions that surface a concrete inconsistency produce a warning.
func validateReactionSystemUnits(_ string, system *ReactionSystem, basePath string, result *StructuralValidationResult) {
	env, bad := buildSystemUnitEnv(system)
	for _, name := range sortedKeys(bad) {
		result.UnitWarnings = append(result.UnitWarnings, UnitWarning{
			Path:    fmt.Sprintf("%s/%s/units", basePath, name),
			Code:    UnitFindingUnparseable,
			Message: fmt.Sprintf("could not parse unit: %v", bad[name]),
		})
	}
	for i, rx := range system.Reactions {
		rxPath := fmt.Sprintf("%s/reactions/%d/rate", basePath, i)
		if _, err := PropagateDimension(rx.Rate, env); err != nil {
			result.UnitWarnings = append(result.UnitWarnings, UnitWarning{
				Path:    rxPath,
				Code:    findingCode(err),
				Message: "dimensional analysis failed: " + err.Error(),
			})
		}
	}
	for i, eq := range system.ConstraintEquations {
		eqPath := fmt.Sprintf("%s/constraint_equations/%d", basePath, i)
		if w := ValidateEquationDimensions(&eq, env, eqPath); w != nil {
			result.UnitWarnings = append(result.UnitWarnings, *w)
		}
	}
}
