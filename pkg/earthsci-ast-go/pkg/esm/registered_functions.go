package esm

// Closed function registry — Go reference implementation (esm-tzp / esm-aia).
//
// Implements the spec-defined closed function set from esm-spec §9.2:
//
//   * datetime.year, month, day, hour, minute, second, day_of_year,
//     julian_day, is_leap_year — proleptic-Gregorian calendar
//     decomposition of an IEEE-754 binary64 UTC scalar (seconds since
//     the Unix epoch, no leap-second consultation).
//   * interp.searchsorted — 1-based search-into-sorted-array
//     (smallest i with xs[i] >= x; out-of-range below → 1, above → N+1).
//   * interp.linear — 1-D linear interpolation into a tabulated
//     dataset; extrapolate-flat outside the axis range; pinned
//     evaluation order `t[i] + w*(t[i+1] - t[i])` for cross-binding
//     bit-equivalence (esm-spec §9.2).
//   * interp.bilinear — 2-D linear interpolation; per-axis clamp +
//     cell-of-knot convention; two 1-D x-blends followed by one
//     y-blend (esm-spec §9.2).
//
// The set is closed: callers MUST reject any `fn`-op `name` outside this
// list (diagnostic `unknown_closed_function`). New entries require a spec
// rev (esm-spec §9.1).

import (
	"fmt"
	"math"
	"sort"
	"time"
)

// Time-decomposition constants for the datetime.* closed functions
// (esm-spec §9.2). Named to replace the inline magic literals the audit
// flagged in toUnixDateTime / datetimeJulianDay.
const (
	secondsPerDay     = 86400.0 // seconds in a UTC day (floor-divmod split)
	secondsPerHalfDay = 43200.0 // noon offset for the continuous Julian Day
	nanosPerSecond    = 1e9     // fractional-second → nanosecond scale
)

// ClosedFunctionError carries the spec-defined diagnostic codes pinned by
// esm-spec §9.1–§9.2 / §9.3:
//
//   - unknown_closed_function     — `fn` name is not in the v0.3.0 set.
//   - closed_function_arity       — wrong number of arguments.
//   - closed_function_overflow    — integer-typed result would overflow Int32.
//   - searchsorted_non_monotonic  — xs is not non-decreasing.
//   - searchsorted_nan_in_table   — xs contains a NaN entry.
//   - interp_non_monotonic_axis   — interp.linear/bilinear axis is not strictly increasing.
//   - interp_axis_length_mismatch — table shape disagrees with axis length(s).
//   - interp_nan_in_axis          — interp.linear/bilinear axis contains NaN.
//   - interp_axis_too_short       — interp.linear/bilinear axis has fewer than 2 entries.
type ClosedFunctionError struct {
	Code    string
	Message string
}

func (e *ClosedFunctionError) Error() string {
	return fmt.Sprintf("[%s] %s", e.Code, e.Message)
}

// DiagnosticCode returns the stable diagnostic code (DiagnosticError).
func (e *ClosedFunctionError) DiagnosticCode() string { return e.Code }

func newClosedFunctionError(code, msg string) *ClosedFunctionError {
	return &ClosedFunctionError{Code: code, Message: msg}
}

// closedFunctionNames is the v0.3.0 closed function set. Bindings MUST
// reject any `fn` op `name` not in this set with diagnostic
// `unknown_closed_function`.
var closedFunctionNames = map[string]struct{}{
	"datetime.year":         {},
	"datetime.month":        {},
	"datetime.day":          {},
	"datetime.hour":         {},
	"datetime.minute":       {},
	"datetime.second":       {},
	"datetime.day_of_year":  {},
	"datetime.julian_day":   {},
	"datetime.is_leap_year": {},
	"interp.searchsorted":   {},
	"interp.linear":         {},
	"interp.bilinear":       {},
}

// ClosedFunctionNames returns the v0.3.0 closed function set as a sorted
// slice. Useful for error messages and round-trip validation tests.
func ClosedFunctionNames() []string {
	out := make([]string, 0, len(closedFunctionNames))
	for k := range closedFunctionNames {
		out = append(out, k)
	}
	sort.Strings(out) // stable order for diagnostic output
	return out
}

// IsClosedFunction reports whether name is in the v0.3.0 closed registry.
func IsClosedFunction(name string) bool {
	_, ok := closedFunctionNames[name]
	return ok
}

// datetimeFieldAccessors maps the seven datetime.* field-extraction functions
// (esm-spec §9.2) to their calendar accessor. Each takes a single UTC-scalar
// argument, decomposes it via toUnixDateTime, and returns a signed 32-bit
// integer (range-checked uniformly through checkInt32 — the small calendar
// fields never overflow, so this only ever matters for datetime.year).
var datetimeFieldAccessors = map[string]func(time.Time) int{
	"datetime.year":        func(t time.Time) int { return t.Year() },
	"datetime.month":       func(t time.Time) int { return int(t.Month()) },
	"datetime.day":         func(t time.Time) int { return t.Day() },
	"datetime.hour":        func(t time.Time) int { return t.Hour() },
	"datetime.minute":      func(t time.Time) int { return t.Minute() },
	"datetime.second":      func(t time.Time) int { return t.Second() },
	"datetime.day_of_year": func(t time.Time) int { return t.YearDay() },
}

// EvaluateClosedFunction dispatches a closed function call. `name` is the
// dotted-module spec name (e.g. "datetime.julian_day"); `args` is a slice
// of evaluated argument values. Integer-typed results are returned as
// int32 to make the integer contract explicit; float-typed results are
// float64. For interp.searchsorted, the second argument MUST be the
// inline table extracted from the `const`-op AST node — the caller is
// responsible for that extraction.
//
// Returns *ClosedFunctionError on contract violations.
func EvaluateClosedFunction(name string, args []any) (any, error) {
	if !IsClosedFunction(name) {
		return nil, newClosedFunctionError("unknown_closed_function",
			fmt.Sprintf("`fn` name %q is not in the v0.3.0 closed function registry "+
				"(esm-spec §9.2). Adding a primitive requires a spec rev.", name))
	}

	// The seven single-field datetime.* accessors share one shape
	// (arity 1 → toUnixDateTime → calendar field → Int32), so they are
	// table-driven rather than repeated as seven near-identical switch arms.
	if accessor, ok := datetimeFieldAccessors[name]; ok {
		if err := expectArity(name, args, 1); err != nil {
			return nil, err
		}
		t, err := toUnixDateTime(args[0])
		if err != nil {
			return nil, err
		}
		return checkInt32(name, int64(accessor(t)))
	}

	switch name {
	case "datetime.julian_day":
		if err := expectArity(name, args, 1); err != nil {
			return nil, err
		}
		f, ok := toFloat64(args[0])
		if !ok {
			return nil, newClosedFunctionError("closed_function_arity",
				fmt.Sprintf("%s: argument must be numeric, got %T", name, args[0]))
		}
		return datetimeJulianDay(f), nil
	case "datetime.is_leap_year":
		if err := expectArity(name, args, 1); err != nil {
			return nil, err
		}
		t, err := toUnixDateTime(args[0])
		if err != nil {
			return nil, err
		}
		if isLeapYear(t.Year()) {
			return int32(1), nil
		}
		return int32(0), nil
	case "interp.searchsorted":
		if err := expectArity(name, args, 2); err != nil {
			return nil, err
		}
		x, ok := toFloat64(args[0])
		if !ok {
			return nil, newClosedFunctionError("closed_function_arity",
				fmt.Sprintf("%s: first argument (x) must be numeric, got %T", name, args[0]))
		}
		xs, err := toFloat64Array(name, "xs", args[1])
		if err != nil {
			return nil, err
		}
		return interpSearchsorted(name, x, xs)
	case "interp.linear":
		if err := expectArity(name, args, 3); err != nil {
			return nil, err
		}
		table, err := toFloat64Array(name, "table", args[0])
		if err != nil {
			return nil, err
		}
		axis, err := toFloat64Array(name, "axis", args[1])
		if err != nil {
			return nil, err
		}
		x, ok := toFloat64(args[2])
		if !ok {
			return nil, newClosedFunctionError("closed_function_arity",
				fmt.Sprintf("%s: third argument (x) must be numeric, got %T", name, args[2]))
		}
		return interpLinear(table, axis, x)
	case "interp.bilinear":
		if err := expectArity(name, args, 5); err != nil {
			return nil, err
		}
		table, err := toInterpMatrix(name, "table", args[0])
		if err != nil {
			return nil, err
		}
		axisX, err := toFloat64Array(name, "axis_x", args[1])
		if err != nil {
			return nil, err
		}
		axisY, err := toFloat64Array(name, "axis_y", args[2])
		if err != nil {
			return nil, err
		}
		x, ok := toFloat64(args[3])
		if !ok {
			return nil, newClosedFunctionError("closed_function_arity",
				fmt.Sprintf("%s: fourth argument (x) must be numeric, got %T", name, args[3]))
		}
		y, ok := toFloat64(args[4])
		if !ok {
			return nil, newClosedFunctionError("closed_function_arity",
				fmt.Sprintf("%s: fifth argument (y) must be numeric, got %T", name, args[4]))
		}
		return interpBilinear(table, axisX, axisY, x, y)
	}
	// Unreachable — IsClosedFunction guarded above.
	return nil, newClosedFunctionError("unknown_closed_function",
		fmt.Sprintf("internal: `fn` name %q is in the registry but has no dispatch arm", name))
}

// expectArity returns ClosedFunctionError(closed_function_arity) when the
// argument count differs from `n`.
func expectArity(name string, args []any, n int) error {
	if len(args) != n {
		return newClosedFunctionError("closed_function_arity",
			fmt.Sprintf("%s expects %d argument(s), got %d", name, n, len(args)))
	}
	return nil
}

// checkInt32 range-checks an integer-typed closed-function result. The spec
// pins integer outputs to signed 32-bit; e.g. datetime.year of an absurd
// `t_utc` could overflow.
func checkInt32(name string, v int64) (int32, error) {
	if v < math.MinInt32 || v > math.MaxInt32 {
		return 0, newClosedFunctionError("closed_function_overflow",
			fmt.Sprintf("%s: result %d overflows Int32", name, v))
	}
	return int32(v), nil
}

// toUnixDateTime converts a UTC scalar time (seconds since Unix epoch) to
// time.Time at UTC. The spec pins floor-divmod by 86400 for the
// (date, time-of-day) split; time.Unix already does this with the
// proleptic-Gregorian calendar. Float fractional seconds are converted to
// nanoseconds before construction.
func toUnixDateTime(v any) (time.Time, error) {
	f, ok := toFloat64(v)
	if !ok {
		return time.Time{}, newClosedFunctionError("closed_function_arity",
			fmt.Sprintf("argument must be numeric, got %T", v))
	}
	// Split into integer seconds and fractional nanoseconds. Use
	// math.Floor so that negative-fractional inputs ("0.5 seconds before
	// epoch") follow Python-style floored division per esm-spec §9.2.
	whole := math.Floor(f)
	frac := f - whole
	sec := int64(whole)
	nsec := int64(math.Round(frac * nanosPerSecond))
	if nsec >= nanosPerSecond {
		sec++
		nsec -= nanosPerSecond
	}
	return time.Unix(sec, nsec).UTC(), nil
}

// datetimeJulianDay computes the continuous Julian Day Number (JDN) for a
// UTC scalar time, including the fractional time-of-day offset relative
// to noon UTC. Uses the Fliegel–van Flandern (1968) integer formula plus
// `(time_of_day_seconds − 43200) / 86400`, ≤ 1 ulp agreement to the spec
// reference per esm-spec §9.2.1.
func datetimeJulianDay(tUTC float64) float64 {
	t, _ := toUnixDateTime(tUTC)
	y := t.Year()
	m := int(t.Month())
	d := t.Day()
	mAdj := (m - 14) / 12
	jdn := (1461*(y+4800+mAdj))/4 +
		(367*(m-2-12*mAdj))/12 -
		(3*((y+4900+mAdj)/100))/4 +
		d - 32075
	// JDN counts noon-to-noon; convert time-of-day seconds (since 00:00 UTC)
	// to a fractional offset relative to noon.
	secondsInDay := math.Mod(tUTC, secondsPerDay)
	if secondsInDay < 0 {
		secondsInDay += secondsPerDay
	}
	return float64(jdn) + (secondsInDay-secondsPerHalfDay)/secondsPerDay
}

// isLeapYear: proleptic-Gregorian. Pure integer arithmetic, exact zero
// error vs. the spec.
func isLeapYear(y int) bool {
	return (y%4 == 0 && y%100 != 0) || y%400 == 0
}

// interpSearchsorted implements `interp.searchsorted` per esm-spec §9.2.2:
// 1-based, left-side bias (smallest i with xs[i] ≥ x), out-of-range below
// → 1, above → N+1, NaN x → N+1, NaN entries in xs → error, non-monotonic
// xs → error.
func interpSearchsorted(name string, x float64, xs []float64) (int32, error) {
	n := len(xs)
	if n == 0 {
		// Empty table: extends "above-range → N+1" rule to N=0; the only
		// consistent extension that composes with `index`.
		return int32(1), nil
	}
	// Validate monotonicity + NaN-in-table once per call.
	for i := 0; i < n; i++ {
		if math.IsNaN(xs[i]) {
			return 0, newClosedFunctionError("searchsorted_nan_in_table",
				fmt.Sprintf("%s: xs[%d] is NaN; NaN entries in xs are forbidden", name, i+1))
		}
		if i > 0 && xs[i] < xs[i-1] {
			return 0, newClosedFunctionError("searchsorted_non_monotonic",
				fmt.Sprintf("%s: xs is not non-decreasing (xs[%d]=%g < xs[%d]=%g)",
					name, i+1, xs[i], i, xs[i-1]))
		}
	}
	// NaN x → N+1 ("greater than every finite element").
	if math.IsNaN(x) {
		return checkInt32(name, int64(n+1))
	}
	// Linear scan: spec mandates left-side bias on duplicates; binary search
	// would also work but the §9.2 inline-cap pins tables to ≤ 1024 entries.
	for i := 0; i < n; i++ {
		if xs[i] >= x {
			return checkInt32(name, int64(i+1))
		}
	}
	return checkInt32(name, int64(n+1))
}

// toFloat64Array extracts a 1-D []float64 from an evaluated `const`-op array
// argument to a closed function (the `xs` table of interp.searchsorted; the
// table / axes of interp.linear / interp.bilinear). Accepts []float64
// (programmatically built) and []interface{} (post-parse). NaN entries are
// preserved: NaN string literals are already coerced to a float64 NaN by
// toFloat64 (strconv.ParseFloat accepts "NaN"/"nan"), and downstream validators
// reject NaN where the spec forbids it (searchsorted_nan_in_table,
// interp_nan_in_axis). `role` names the argument in diagnostics.
//
// This replaces the former toFloat64Slice + toInterpAxisOrTable pair, which
// were behaviorally identical (their explicit NaN-string branches were
// unreachable once toFloat64 handles "NaN"); their doc claim of distinctness
// was false.
func toFloat64Array(name, role string, v any) ([]float64, error) {
	switch xs := v.(type) {
	case []float64:
		out := make([]float64, len(xs))
		copy(out, xs)
		return out, nil
	case []any:
		out := make([]float64, len(xs))
		for i, e := range xs {
			f, ok := toFloat64(e)
			if !ok {
				return nil, newClosedFunctionError("closed_function_arity",
					fmt.Sprintf("%s: %s[%d] is not numeric (%T)", name, role, i+1, e))
			}
			out[i] = f
		}
		return out, nil
	default:
		return nil, newClosedFunctionError("closed_function_arity",
			fmt.Sprintf("%s: %s argument must be an array, got %T", name, role, v))
	}
}

// toInterpMatrix extracts a 2-D table for interp.bilinear. The outer
// length is preserved; inner row lengths are checked against axis_y in
// the validator. Ragged inner rows surface as `interp_axis_length_mismatch`
// from the validator (per esm-spec §9.2 errors table), not here.
func toInterpMatrix(name, role string, v any) ([][]float64, error) {
	switch outer := v.(type) {
	case [][]float64:
		out := make([][]float64, len(outer))
		for i, row := range outer {
			out[i] = make([]float64, len(row))
			copy(out[i], row)
		}
		return out, nil
	case []any:
		out := make([][]float64, len(outer))
		for i, row := range outer {
			r, err := toFloat64Array(name, fmt.Sprintf("%s[%d]", role, i+1), row)
			if err != nil {
				return nil, err
			}
			out[i] = r
		}
		return out, nil
	default:
		return nil, newClosedFunctionError("closed_function_arity",
			fmt.Sprintf("%s: %s argument must be a 2-D array, got %T", name, role, v))
	}
}

// validateInterpAxis checks an axis array against the load-time contract
// (esm-spec §9.2): length ≥ 2, no NaN entries, strictly increasing.
// Order: too_short → nan_in_axis → non_monotonic, so each fixture's
// isolated-error scenario surfaces the spec-named diagnostic regardless
// of which other constraints would also fail given a more pathological
// input.
func validateInterpAxis(fnName, axisName string, axis []float64) error {
	if len(axis) < 2 {
		return newClosedFunctionError("interp_axis_too_short",
			fmt.Sprintf("%s: %s has %d entries; need ≥ 2 to form an interval to blend across",
				fnName, axisName, len(axis)))
	}
	for i, v := range axis {
		if math.IsNaN(v) {
			return newClosedFunctionError("interp_nan_in_axis",
				fmt.Sprintf("%s: %s[%d] is NaN; axes MUST NOT contain NaN", fnName, axisName, i+1))
		}
	}
	for i := 1; i < len(axis); i++ {
		if axis[i] <= axis[i-1] {
			return newClosedFunctionError("interp_non_monotonic_axis",
				fmt.Sprintf("%s: %s is not strictly increasing (%s[%d]=%g ≤ %s[%d]=%g)",
					fnName, axisName, axisName, i+1, axis[i], axisName, i, axis[i-1]))
		}
	}
	return nil
}

// interpLinear implements `interp.linear` per esm-spec §9.2. Validation
// order: length-mismatch (between table and axis), then axis well-formedness
// via validateInterpAxis. Evaluation uses the spec-pinned form
// `t[i] + w*(t[i+1] - t[i])` so that w=0 returns t[i] exactly and w=1
// returns t[i+1] without 1−w cancellation.
func interpLinear(table, axis []float64, x float64) (float64, error) {
	const fnName = "interp.linear"
	// `axis_too_short` MUST take precedence over a length mismatch when
	// both could apply; checking the axis first satisfies that ordering
	// when N=1 with a matching table length.
	if len(axis) < 2 {
		return 0, newClosedFunctionError("interp_axis_too_short",
			fmt.Sprintf("%s: axis has %d entries; need ≥ 2 to form an interval to blend across",
				fnName, len(axis)))
	}
	if len(table) != len(axis) {
		return 0, newClosedFunctionError("interp_axis_length_mismatch",
			fmt.Sprintf("%s: len(table)=%d != len(axis)=%d", fnName, len(table), len(axis)))
	}
	if err := validateInterpAxis(fnName, "axis", axis); err != nil {
		return 0, err
	}
	n := len(axis)
	// NaN x: comparisons in steps 1–2 fall through; produce NaN via the blend.
	// Computing it directly keeps the result identical to the spec narration
	// without scanning for a non-existent in-range cell.
	if math.IsNaN(x) {
		return math.NaN(), nil
	}
	// Step 1: below-range clamp.
	if x <= axis[0] {
		return table[0], nil
	}
	// Step 2: above-range clamp.
	if x >= axis[n-1] {
		return table[n-1], nil
	}
	// Step 3: locate the cell `axis[i] ≤ x < axis[i+1]` (existence and
	// uniqueness guaranteed by strict monotonicity + the clamps above).
	i := 0
	for k := 0; k < n-1; k++ {
		if axis[k] <= x && x < axis[k+1] {
			i = k
			break
		}
	}
	w := (x - axis[i]) / (axis[i+1] - axis[i])
	return table[i] + w*(table[i+1]-table[i]), nil
}

// interpBilinear implements `interp.bilinear` per esm-spec §9.2.
// Validation order:
//  1. axis_x too short
//  2. axis_y too short
//  3. table outer length vs len(axis_x)
//  4. each inner row length vs len(axis_y) (also catches ragged rows)
//  5. axis_x / axis_y NaN + monotonicity (via validateInterpAxis)
//
// Evaluation uses the spec-pinned form: two 1-D x-blends followed by one
// y-blend, each in `a + w*(b - a)`. Cell location uses the "largest index
// in [0, N-2] with axis[i] ≤ q" convention so that a query exactly on an
// interior knot lands on `i = k` (wx = 0) per esm-spec §9.2.
func interpBilinear(table [][]float64, axisX, axisY []float64, x, y float64) (float64, error) {
	const fnName = "interp.bilinear"
	if len(axisX) < 2 {
		return 0, newClosedFunctionError("interp_axis_too_short",
			fmt.Sprintf("%s: axis_x has %d entries; need ≥ 2", fnName, len(axisX)))
	}
	if len(axisY) < 2 {
		return 0, newClosedFunctionError("interp_axis_too_short",
			fmt.Sprintf("%s: axis_y has %d entries; need ≥ 2", fnName, len(axisY)))
	}
	if len(table) != len(axisX) {
		return 0, newClosedFunctionError("interp_axis_length_mismatch",
			fmt.Sprintf("%s: outer len(table)=%d != len(axis_x)=%d",
				fnName, len(table), len(axisX)))
	}
	for i, row := range table {
		if len(row) != len(axisY) {
			return 0, newClosedFunctionError("interp_axis_length_mismatch",
				fmt.Sprintf("%s: len(table[%d])=%d != len(axis_y)=%d",
					fnName, i+1, len(row), len(axisY)))
		}
	}
	if err := validateInterpAxis(fnName, "axis_x", axisX); err != nil {
		return 0, err
	}
	if err := validateInterpAxis(fnName, "axis_y", axisY); err != nil {
		return 0, err
	}
	// NaN x or y: spec says result is NaN. Shortcut the cell-location step,
	// which can't find an `i` with `axis[i] ≤ NaN` (every such comparison
	// returns false).
	if math.IsNaN(x) || math.IsNaN(y) {
		return math.NaN(), nil
	}
	xQ := clampFlat(x, axisX[0], axisX[len(axisX)-1])
	yQ := clampFlat(y, axisY[0], axisY[len(axisY)-1])
	i := largestKnotIndex(axisX, xQ)
	j := largestKnotIndex(axisY, yQ)
	wx := (xQ - axisX[i]) / (axisX[i+1] - axisX[i])
	wy := (yQ - axisY[j]) / (axisY[j+1] - axisY[j])
	rowJ := table[i][j] + wx*(table[i+1][j]-table[i][j])
	rowJp1 := table[i][j+1] + wx*(table[i+1][j+1]-table[i][j+1])
	return rowJ + wy*(rowJp1-rowJ), nil
}

// clampFlat is the per-axis 1-D extrapolate-flat clamp from esm-spec §9.2.
// Distinct from a generic min/max because the comparison form (`v ≤ lo`,
// `v ≥ hi`) is what the spec narrates and what NaN-propagation depends on
// in interp.linear; interp.bilinear's NaN inputs are short-circuited by
// the caller before reaching here.
func clampFlat(v, lo, hi float64) float64 {
	if v <= lo {
		return lo
	}
	if v >= hi {
		return hi
	}
	return v
}

// largestKnotIndex returns the largest i in [0, len(axis)-2] with
// axis[i] ≤ q. Caller guarantees axis is strictly increasing with len ≥ 2
// and `axis[0] ≤ q ≤ axis[len-1]` (post-clamp). On the boundary q ==
// axis[len-1], i = len-2 (so wx = 1 and the pinned form returns
// table[i+1][j]); on an interior knot axis[k], i = k (wx = 0) per spec.
func largestKnotIndex(axis []float64, q float64) int {
	n := len(axis)
	// Walk from the right: the first knot at-or-below q is the cell start.
	for k := n - 2; k >= 0; k-- {
		if axis[k] <= q {
			return k
		}
	}
	return 0
}
