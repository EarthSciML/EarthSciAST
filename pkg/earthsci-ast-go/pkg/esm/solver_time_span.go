package esm

import (
	"bytes"
	"encoding/json"
	"fmt"
	"regexp"
	"strconv"
)

// ---------------------------------------------------------------------------
// `solver.time_span`: the run interval a document asks for (esm-spec §2.2.7)
// ---------------------------------------------------------------------------

// SolverTimeSpan is the interval the document's author means it to be
// simulated over (esm-spec §2.2.7). It is a distinct type from TimeSpan (the
// `tests[].time_span` pair of float bounds) because a bound here may also be an
// RFC 3339 UTC timestamp. Both bounds are held exactly as authored and emitted
// verbatim; their value in seconds comes from ResolveTimeSpan and is never
// written back.
type SolverTimeSpan struct {
	Start TimePoint `json:"start"`
	End   TimePoint `json:"end"`
}

// TimePoint is one bound of a SolverTimeSpan: either a number in the
// document's time units (seconds of the independent variable) or an RFC 3339
// UTC timestamp (`YYYY-MM-DDThh:mm:ss(.f+)?Z`), which means the seconds from
// the document's time origin to that instant (esm-spec §2.2.7). Exactly one of
// Number and Timestamp is set. It round-trips verbatim: a timestamp stays the
// string, a number stays the number.
type TimePoint struct {
	Number    *float64
	Timestamp *string
}

func timePointNumber(v float64) TimePoint   { return TimePoint{Number: &v} }
func timePointTimestamp(s string) TimePoint { return TimePoint{Timestamp: &s} }

// MarshalJSON writes the bound back as authored: the timestamp string, or the
// number.
func (p TimePoint) MarshalJSON() ([]byte, error) {
	switch {
	case p.Timestamp != nil:
		return json.Marshal(*p.Timestamp)
	case p.Number != nil:
		return json.Marshal(*p.Number)
	}
	return nil, fmt.Errorf("solver.time_span bound holds neither a number nor a timestamp")
}

// UnmarshalJSON reads a bound that is a JSON number or a JSON string. The
// string's form is the schema's to judge; it is held as written.
func (p *TimePoint) UnmarshalJSON(data []byte) error {
	data = bytes.TrimSpace(data)
	if len(data) > 0 && data[0] == '"' {
		var s string
		if err := json.Unmarshal(data, &s); err != nil {
			return err
		}
		*p = TimePoint{Timestamp: &s}
		return nil
	}
	var v float64
	if err := json.Unmarshal(data, &v); err != nil {
		return fmt.Errorf("solver.time_span bound must be a number or a timestamp string: %w", err)
	}
	*p = TimePoint{Number: &v}
	return nil
}

// RejectSolverTimeSpanPreV13 rejects `solver.time_span` in files declaring
// esm < 1.3.0 with `solver_time_span_version_too_old` at `/solver/time_span`
// (esm-spec §2.2.4 requirement 4). A 1.1.0 or 1.2.0 document whose `solver`
// block carries no `time_span` stays valid. Below 1.1.0 the whole block is
// already refused by RejectSolverPreV11, which runs first.
func RejectSolverTimeSpanPreV13(view map[string]any) error {
	if view == nil {
		return nil
	}
	solver, ok := view["solver"].(map[string]any)
	if !ok {
		return nil
	}
	if _, has := solver["time_span"]; !has {
		return nil
	}
	if !esmVersionBelow(view, 1, 3) {
		return nil
	}
	esmRaw, _ := view["esm"].(string)
	return newETErr(
		CodeSolverTimeSpanVersionTooOld,
		fmt.Sprintf("`solver.time_span` requires esm >= 1.3.0; file declares %s (offending path: /solver/time_span)", esmRaw),
	)
}

// timeSpanBoundRE is the schema's pattern for a timestamp bound: RFC 3339 in
// UTC, `Z` required, no other offset, each field in its calendar range (but
// not the day-of-month against its month, which is the load-time check's).
var timeSpanBoundRE = regexp.MustCompile(
	`^([0-9]{4})-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])T([01][0-9]|2[0-3]):([0-5][0-9]):([0-5][0-9])(\.[0-9]+)?Z$`)

// timeOriginRE reads an origin field (`domain.temporal.reference_time` /
// `start`): `YYYY-MM-DD`, `T` or `t`, `hh:mm:ss`, an optional fraction, then
// `Z`, `z` or a `±hh:mm` offset (esm-spec §2.2.7). Field ranges are checked by
// civilSeconds, not here.
var timeOriginRE = regexp.MustCompile(
	`^([0-9]{4})-([0-9]{2})-([0-9]{2})[Tt]([0-9]{2}):([0-9]{2}):([0-9]{2})(\.[0-9]+)?([Zz]|([+-])([0-9]{2}):([0-9]{2}))$`)

// civilInstant is a date-time split as §2.2.7 converts it: the whole part W,
// integer seconds from the POSIX epoch by the proleptic Gregorian calendar
// with the offset subtracted, and the fraction f in [0, 1).
type civilInstant struct {
	whole int64
	frac  float64
}

// daysFromCivil counts days from 1970-01-01 to y-m-d in the proleptic
// Gregorian calendar (H. Hinnant's days_from_civil). Exact in int64 over any
// four-digit year.
func daysFromCivil(y, m, d int64) int64 {
	if m <= 2 {
		y--
	}
	era := y / 400
	if y < 0 && y%400 != 0 {
		era--
	}
	yoe := y - era*400
	mp := (m + 9) % 12
	doy := (153*mp+2)/5 + d - 1
	doe := yoe*365 + yoe/4 - yoe/100 + doy
	return era*146097 + doe - 719468
}

func daysInMonth(y, m int64) int64 {
	switch m {
	case 1, 3, 5, 7, 8, 10, 12:
		return 31
	case 4, 6, 9, 11:
		return 30
	case 2:
		if isLeapYear(int(y)) {
			return 29
		}
		return 28
	}
	return 0
}

func atoi64(s string) int64 {
	v, _ := strconv.ParseInt(s, 10, 64)
	return v
}

// fractionValue reads the fraction ".ddd" (with its dot) as a binary64 in
// [0, 1), or 0 when there is none.
func fractionValue(dotDigits string) float64 {
	if dotDigits == "" {
		return 0
	}
	v, _ := strconv.ParseFloat("0"+dotDigits, 64)
	return v
}

// civilSeconds converts calendar fields to a civilInstant, reporting false
// when a field is out of its range or the date names no calendar day. The
// offset (in minutes, signed) is subtracted from the whole part.
func civilSeconds(y, mo, d, h, mi, s int64, frac string, offsetMinutes int64) (civilInstant, bool) {
	if mo < 1 || mo > 12 || d < 1 || d > daysInMonth(y, mo) || h > 23 || mi > 59 || s > 59 {
		return civilInstant{}, false
	}
	whole := daysFromCivil(y, mo, d)*86400 + h*3600 + mi*60 + s - offsetMinutes*60
	return civilInstant{whole: whole, frac: fractionValue(frac)}, true
}

// parseTimeSpanBound reads a timestamp bound. ok is false when the string
// does not match the schema's pattern (formOK false) or matches it but names
// no calendar day (formOK true).
func parseTimeSpanBound(s string) (inst civilInstant, formOK, ok bool) {
	m := timeSpanBoundRE.FindStringSubmatch(s)
	if m == nil {
		return civilInstant{}, false, false
	}
	inst, ok = civilSeconds(atoi64(m[1]), atoi64(m[2]), atoi64(m[3]),
		atoi64(m[4]), atoi64(m[5]), atoi64(m[6]), m[7], 0)
	return inst, true, ok
}

// parseTimeOrigin reads an origin field in the §2.2.7 form.
func parseTimeOrigin(s string) (civilInstant, bool) {
	m := timeOriginRE.FindStringSubmatch(s)
	if m == nil {
		return civilInstant{}, false
	}
	var offset int64
	if m[9] != "" {
		oh, om := atoi64(m[10]), atoi64(m[11])
		if oh > 23 || om > 59 {
			return civilInstant{}, false
		}
		offset = oh*60 + om
		if m[9] == "-" {
			offset = -offset
		}
	}
	return civilSeconds(atoi64(m[1]), atoi64(m[2]), atoi64(m[3]),
		atoi64(m[4]), atoi64(m[5]), atoi64(m[6]), m[7], offset)
}

// secondsFrom is the §2.2.7 value of the instant t on the clock whose zero is
// origin: (W − W0) in integers, converted to binary64, plus (f − f0) in
// binary64.
func secondsFrom(t, origin civilInstant) float64 {
	return float64(t.whole-origin.whole) + (t.frac - origin.frac)
}

// timeOriginSource is the origin field that applies (esm-spec §2.2.7): its
// pointer and value, or an empty pointer for the POSIX epoch. A field that is
// present but is not a string carries isString false.
type timeOriginSource struct {
	pointer  string
	value    string
	isString bool
}

func timeSpanError(detail string) error {
	return newETErr(CodeSolverTimeSpanInvalid, "/solver/time_span: "+detail)
}

// instant resolves the source to an instant, or a solver_time_span_invalid
// error naming both pointers when the field is unreadable.
func (o timeOriginSource) instant() (civilInstant, error) {
	if o.pointer == "" {
		return civilInstant{}, nil // the POSIX epoch
	}
	if o.isString {
		if inst, ok := parseTimeOrigin(o.value); ok {
			return inst, nil
		}
		return civilInstant{}, timeSpanError(fmt.Sprintf(
			"a timestamp bound is counted from the time origin %s = %q, which is not an RFC 3339 "+
				"date-time naming a calendar day (esm-spec §2.2.7)", o.pointer, o.value))
	}
	return civilInstant{}, timeSpanError(fmt.Sprintf(
		"a timestamp bound is counted from the time origin %s, which is not an RFC 3339 "+
			"date-time string (esm-spec §2.2.7)", o.pointer))
}

// timeOriginFromView picks the origin field from the raw JSON view, first
// match wins: reference_time, then start, then the epoch.
func timeOriginFromView(view map[string]any) timeOriginSource {
	domain, _ := view["domain"].(map[string]any)
	temporal, _ := domain["temporal"].(map[string]any)
	for _, key := range []string{"reference_time", "start"} {
		if raw, has := temporal[key]; has {
			s, isString := raw.(string)
			return timeOriginSource{pointer: "/domain/temporal/" + key, value: s, isString: isString}
		}
	}
	return timeOriginSource{}
}

// timeOriginFromFile picks the origin field from a typed document. The typed
// TemporalDomain cannot tell an absent `start` from an empty one, so an empty
// `start` reads as absent here; the load-time check, which sees the authored
// JSON, refuses an authored empty one.
func timeOriginFromFile(file *ESMFile) timeOriginSource {
	if file.Domain == nil || file.Domain.Temporal == nil {
		return timeOriginSource{}
	}
	tmp := file.Domain.Temporal
	if tmp.ReferenceTime != nil {
		return timeOriginSource{pointer: "/domain/temporal/reference_time", value: *tmp.ReferenceTime, isString: true}
	}
	if tmp.Start != "" {
		return timeOriginSource{pointer: "/domain/temporal/start", value: tmp.Start, isString: true}
	}
	return timeOriginSource{}
}

// timeSpanSeconds converts both bounds to seconds and checks the interval.
// Each bound is a number (float64) or a timestamp string already known to
// match the schema's pattern. The origin is read only when a bound is a
// timestamp.
func timeSpanSeconds(start, end TimePoint, origin timeOriginSource) ([2]float64, error) {
	var out [2]float64
	var originInst *civilInstant
	for i, p := range []TimePoint{start, end} {
		name := [2]string{"start", "end"}[i]
		switch {
		case p.Number != nil:
			out[i] = *p.Number
		case p.Timestamp != nil:
			inst, formOK, ok := parseTimeSpanBound(*p.Timestamp)
			if !formOK {
				return out, timeSpanError(fmt.Sprintf(
					"`%s` = %q is not an RFC 3339 UTC timestamp (YYYY-MM-DDThh:mm:ss[.f]Z)", name, *p.Timestamp))
			}
			if !ok {
				return out, timeSpanError(fmt.Sprintf(
					"`%s` = %q names no calendar day (esm-spec §2.2.7)", name, *p.Timestamp))
			}
			if originInst == nil {
				o, err := origin.instant()
				if err != nil {
					return out, err
				}
				originInst = &o
			}
			out[i] = secondsFrom(inst, *originInst)
		default:
			return out, timeSpanError(fmt.Sprintf("`%s` holds neither a number nor a timestamp", name))
		}
	}
	if !(out[1] > out[0]) {
		return out, timeSpanError(fmt.Sprintf(
			"`end` (%s s) is not after `start` (%s s): a time_span must be a non-empty interval (esm-spec §2.2.7)",
			strconv.FormatFloat(out[1], 'g', -1, 64), strconv.FormatFloat(out[0], 'g', -1, 64)))
	}
	return out, nil
}

// viewTimePoint reads a raw-JSON bound, reporting false when it is not of a
// schema-valid form (a number, or a string matching the pattern).
func viewTimePoint(raw any) (TimePoint, bool) {
	switch v := raw.(type) {
	case json.Number:
		f, err := strconv.ParseFloat(string(v), 64)
		if ne, isNE := err.(*strconv.NumError); isNE && ne.Err != strconv.ErrRange {
			return TimePoint{}, false
		}
		return timePointNumber(f), true
	case float64:
		return timePointNumber(v), true
	case string:
		if !timeSpanBoundRE.MatchString(v) {
			return TimePoint{}, false
		}
		return timePointTimestamp(v), true
	}
	return TimePoint{}, false
}

// rejectSolverTimeSpanInvalid is the §2.2.7 load-time check, on the root's raw
// JSON view: `end` after `start`, each timestamp a calendar day, and the
// origin readable when a timestamp needs it. It runs only when both bounds
// have a schema-valid form; anything else is the schema's to report.
func rejectSolverTimeSpanInvalid(view map[string]any) error {
	solver, ok := view["solver"].(map[string]any)
	if !ok {
		return nil
	}
	ts, ok := solver["time_span"].(map[string]any)
	if !ok {
		return nil
	}
	start, ok1 := viewTimePoint(ts["start"])
	end, ok2 := viewTimePoint(ts["end"])
	if !ok1 || !ok2 {
		return nil
	}
	_, err := timeSpanSeconds(start, end, timeOriginFromView(view))
	return err
}

// ResolveTimeSpan resolves the run interval by the esm-spec §2.2.7 chain: the
// call-site interval when callSite is non-nil (it always wins, both bounds),
// else the document's `solver.time_span` converted to binary64 seconds, else
// nil (no interval). A timestamp bound counts seconds from the document's time
// origin: `domain.temporal.reference_time`, else `domain.temporal.start`, else
// the POSIX epoch. Only the root's `solver` block is consulted; a mounted
// leaf's block does not cross the mount.
//
// The error is non-nil only for a document the load-time check would refuse
// (`solver_time_span_invalid`), which a loaded document never is but one built
// in code can be.
func ResolveTimeSpan(file *ESMFile, callSite *[2]float64) (*[2]float64, error) {
	if callSite != nil {
		out := *callSite
		return &out, nil
	}
	if file == nil || file.SolverHints == nil || file.SolverHints.TimeSpan == nil {
		return nil, nil
	}
	ts := file.SolverHints.TimeSpan
	out, err := timeSpanSeconds(ts.Start, ts.End, timeOriginFromFile(file))
	if err != nil {
		return nil, err
	}
	return &out, nil
}
