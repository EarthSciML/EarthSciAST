// Package docfmt reads and writes ESM documents as Markdown and Typst source
// text (CONFORMANCE_SPEC §5.58). It is a port of the executable Lean model under
// formal/Esm/Document/, laid out file by file like the Rust port
// (pkg/earthsci-ast-rs/src/document/):
//
//	json.go        Json.lean (the value type, canonical numbers)
//	number.go      Number.lean
//	strings.go     Strings.lean
//	yaml.go        Yaml.lean
//	typst_dict.go  TypstDict.lean
//	math_*.go      Math/*.lean
//	source_*.go    Source/*.lean
//
// The package works on its own value type ([Json]): object entries keep their
// order and numbers keep the canonical form of CONFORMANCE §5.5.3.1. The esm
// package converts at its public boundary with [FromGo] and [ToGo].
//
// Identifiers follow one rule so the port can be read beside the Rust: a Rust
// function `module::name_of_fn` is `<prefix>NameOfFn` here, the prefix naming
// the module (number → num, strings → str, typst_dict → tdict, …; see each
// file's header).
package docfmt

import (
	"encoding/json"
	"math"
	"sort"
	"strconv"
	"strings"
)

// Json is a JSON value (`Esm.Document.Json`): nil, bool, JNum, string, []Json
// or Obj.
type Json = any

// KV is one object entry.
type KV struct {
	K string
	V Json
}

// Obj is a JSON object: its entries, in order.
type Obj []KV

// JNum is a JSON number in canonical form (`Esm.Document.JNum`).
//
//   - !Dec: the integer I.
//   - Dec: the value ±d₁.d₂d₃… × 10^E10, Digits the shortest round-trip digits
//     (each below 10).
//
// Lean's integers are unbounded and the Rust port holds them in i128; here an
// integer is an int64, so a reader that would build an integer outside Int64
// (which is never well formed) fails instead.
type JNum struct {
	Dec    bool
	I      int64
	Neg    bool
	Digits []byte
	E10    int64
}

// IntNum is the integer number z.
func IntNum(z int64) JNum { return JNum{I: z} }

// IsInt reports whether n is the integer z.
func (n JNum) IsInt(z int64) bool { return !n.Dec && n.I == z }

// Equal is structural equality of two numbers.
func (n JNum) Equal(m JNum) bool {
	if n.Dec != m.Dec {
		return false
	}
	if !n.Dec {
		return n.I == m.I
	}
	return n.Neg == m.Neg && n.E10 == m.E10 && string(n.Digits) == string(m.Digits)
}

// jsonDigitsVal is `JNum.digitsVal` as an unsigned value; ok is false on
// overflow of uint64.
func jsonDigitsVal(ds []byte) (uint64, bool) {
	var a uint64
	for _, d := range ds {
		if a > (math.MaxUint64-uint64(d))/10 {
			return 0, false
		}
		a = a*10 + uint64(d)
	}
	return a, true
}

// jsonSigned is ±u as an int64; ok is false when it is outside Int64.
func jsonSigned(neg bool, u uint64) (int64, bool) {
	if neg {
		if u > 1<<63 {
			return 0, false
		}
		return int64(-u), true //nolint:gosec // two's complement negation in range
	}
	if u > math.MaxInt64 {
		return 0, false
	}
	return int64(u), true
}

// jsonDecInt is `JNum.decInt?`: integral reports whether the decimal is
// integral; when it is, fits reports whether its value is in Int64 and z is
// that value.
func jsonDecInt(neg bool, ds []byte, e10 int64) (z int64, integral, fits bool) {
	l := int64(len(ds))
	if l > e10+1 {
		return 0, false, false
	}
	zeros := e10 + 1 - l
	u, ok := jsonDigitsVal(ds)
	if !ok {
		return 0, true, false
	}
	for i := int64(0); i < zeros; i++ {
		if u != 0 && u > math.MaxUint64/10 {
			return 0, true, false
		}
		u *= 10
	}
	z, fits = jsonSigned(neg, u)
	return z, true, fits
}

// Wfb is `JNum.wfb`: the number is in canonical form.
func (n JNum) Wfb() bool {
	if !n.Dec {
		return true
	}
	ds := n.Digits
	if len(ds) == 0 || ds[0] == 0 || ds[len(ds)-1] == 0 {
		return false
	}
	for _, d := range ds {
		if d >= 10 {
			return false
		}
	}
	_, integral, fits := jsonDecInt(n.Neg, ds, n.E10)
	return !integral || !fits
}

// JsonWfb is `Json.wfb`: every number canonical, every object with distinct
// keys.
func JsonWfb(j Json) bool {
	switch v := j.(type) {
	case JNum:
		return v.Wfb()
	case []Json:
		for _, x := range v {
			if !JsonWfb(x) {
				return false
			}
		}
	case Obj:
		if !jsonKeysDistinct(v) {
			return false
		}
		for _, kv := range v {
			if !JsonWfb(kv.V) {
				return false
			}
		}
	}
	return true
}

// jsonKeysDistinct: the keys of an entry list are pairwise distinct.
func jsonKeysDistinct(kvs Obj) bool {
	seen := make(map[string]bool, len(kvs))
	for _, kv := range kvs {
		if seen[kv.K] {
			return false
		}
		seen[kv.K] = true
	}
	return true
}

// exprLook is `Math.look`: the value of key k, and whether it is present.
func exprLook(k string, kvs Obj) (Json, bool) {
	for _, kv := range kvs {
		if kv.K == k {
			return kv.V, true
		}
	}
	return nil, false
}

// JNumOfFloat is the canonical number of a finite float64 (§5.5.3.1): an
// integral value in Int64 is the integer, any other value its shortest
// round-trip digits. ok is false for a non-finite value.
func JNumOfFloat(f float64) (JNum, bool) {
	if math.IsNaN(f) || math.IsInf(f, 0) {
		return JNum{}, false
	}
	if f == 0 {
		return IntNum(0), true
	}
	if f == math.Trunc(f) && f >= -0x1p63 && f < 0x1p63 {
		return IntNum(int64(f)), true
	}
	s := strconv.FormatFloat(math.Abs(f), 'e', -1, 64) // d.ddde±x
	mant, exp, _ := strings.Cut(s, "e")
	e, _ := strconv.Atoi(exp)
	mant = strings.Replace(mant, ".", "", 1)
	digits := make([]byte, len(mant))
	for i := range mant {
		digits[i] = mant[i] - '0'
	}
	for len(digits) > 1 && digits[len(digits)-1] == 0 {
		digits = digits[:len(digits)-1]
	}
	return JNum{Dec: true, Neg: f < 0, Digits: digits, E10: int64(e)}, true
}

// Float is the float64 a canonical number denotes (the value a JSON reader
// gets from its canonical spelling).
func (n JNum) Float() float64 {
	if !n.Dec {
		return float64(n.I)
	}
	f, _ := strconv.ParseFloat(string(numPrint(n)), 64)
	return f
}

// FromGo converts a decoded document value (map[string]any, []any, string,
// bool, nil, and numbers as int64, float64, json.Number or another Go numeric
// type) to a Json value, every object's entries sorted by key, as the printers
// require (`Source.canonDoc`). A non-finite number becomes null.
func FromGo(v any) Json {
	switch x := v.(type) {
	case nil:
		return nil
	case bool:
		return x
	case string:
		return x
	case []any:
		out := make([]Json, len(x))
		for i, e := range x {
			out[i] = FromGo(e)
		}
		return out
	case map[string]any:
		keys := make([]string, 0, len(x))
		for k := range x {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		out := make(Obj, len(keys))
		for i, k := range keys {
			out[i] = KV{k, FromGo(x[k])}
		}
		return out
	case int64:
		return IntNum(x)
	case int:
		return IntNum(int64(x))
	case int32:
		return IntNum(int64(x))
	case float32:
		return fromFloat(float64(x))
	case float64:
		return fromFloat(x)
	case json.Number:
		s := string(x)
		if !strings.ContainsAny(s, ".eE") {
			if i, err := strconv.ParseInt(s, 10, 64); err == nil {
				return IntNum(i)
			}
		}
		f, err := strconv.ParseFloat(s, 64)
		if err != nil && !math.IsInf(f, 0) {
			return nil
		}
		return fromFloat(f)
	case uint64:
		if x <= math.MaxInt64 {
			return IntNum(int64(x))
		}
		return fromFloat(float64(x))
	}
	return nil
}

func fromFloat(f float64) Json {
	if n, ok := JNumOfFloat(f); ok {
		return n
	}
	return nil
}

// ToGo converts a Json value to the decoded-document representation the esm
// package uses: map[string]any, []any, string, bool, nil, int64 for an
// integer, float64 for a decimal.
func ToGo(j Json) any {
	switch x := j.(type) {
	case JNum:
		if !x.Dec {
			return x.I
		}
		return x.Float()
	case []Json:
		out := make([]any, len(x))
		for i, e := range x {
			out[i] = ToGo(e)
		}
		return out
	case Obj:
		out := make(map[string]any, len(x))
		for _, kv := range x {
			out[kv.K] = ToGo(kv.V)
		}
		return out
	}
	return j
}

// SortKeys is the value with every object's entries sorted by key (code point
// order), the key order of the canonical serialization.
func SortKeys(j Json) Json {
	switch x := j.(type) {
	case []Json:
		out := make([]Json, len(x))
		for i, e := range x {
			out[i] = SortKeys(e)
		}
		return out
	case Obj:
		out := make(Obj, len(x))
		for i, kv := range x {
			out[i] = KV{kv.K, SortKeys(kv.V)}
		}
		sort.SliceStable(out, func(a, b int) bool { return out[a].K < out[b].K })
		return out
	}
	return j
}

// JsonEqual is structural equality of two values (object entries in order).
func JsonEqual(a, b Json) bool {
	switch x := a.(type) {
	case nil:
		return b == nil
	case bool:
		y, ok := b.(bool)
		return ok && x == y
	case string:
		y, ok := b.(string)
		return ok && x == y
	case JNum:
		y, ok := b.(JNum)
		return ok && x.Equal(y)
	case []Json:
		y, ok := b.([]Json)
		if !ok || len(x) != len(y) {
			return false
		}
		for i := range x {
			if !JsonEqual(x[i], y[i]) {
				return false
			}
		}
		return true
	case Obj:
		y, ok := b.(Obj)
		if !ok || len(x) != len(y) {
			return false
		}
		for i := range x {
			if x[i].K != y[i].K || !JsonEqual(x[i].V, y[i].V) {
				return false
			}
		}
		return true
	}
	return false
}

// Render is the compact canonical JSON text (`Adapter.Doc.render`), as
// `esm-lean` prints a parsed document: entries in their order, canonical
// numbers, strings quoted with `\uXXXX` escapes.
func Render(j Json) string {
	var b strings.Builder
	renderInto(j, &b)
	return b.String()
}

func renderInto(j Json, b *strings.Builder) {
	switch x := j.(type) {
	case nil:
		b.WriteString("null")
	case bool:
		if x {
			b.WriteString("true")
		} else {
			b.WriteString("false")
		}
	case JNum:
		b.WriteString(string(numPrint(x)))
	case string:
		b.WriteString(string(strQuote(false, x)))
	case []Json:
		b.WriteByte('[')
		for i, e := range x {
			if i > 0 {
				b.WriteByte(',')
			}
			renderInto(e, b)
		}
		b.WriteByte(']')
	case Obj:
		b.WriteByte('{')
		for i, kv := range x {
			if i > 0 {
				b.WriteByte(',')
			}
			b.WriteString(string(strQuote(false, kv.K)))
			b.WriteByte(':')
			renderInto(kv.V, b)
		}
		b.WriteByte('}')
	}
}
