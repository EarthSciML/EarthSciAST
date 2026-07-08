package esm

import (
	"encoding/json"
	"fmt"
	"math"
	"reflect"
	"strconv"
	"strings"
)

// canonicalFloat64String returns the discretization RFC §5.4.6 on-wire text
// form of f. Integer-valued floats in the plain-decimal range receive a
// trailing ".0" so that a JSON integer token and a JSON float token are
// never spelled the same way, preserving the round-trip int/float node
// distinction required by §5.4.1. Magnitudes outside [1e-6, 1e21) use
// exponent notation with lowercase 'e', no leading '+', and no leading
// zeros on the exponent. NaN and ±Inf are rejected with
// E_CANONICAL_NONFINITE.
func canonicalFloat64String(f float64) (string, error) {
	if math.IsNaN(f) {
		return "", fmt.Errorf("E_CANONICAL_NONFINITE: NaN not representable in canonical JSON")
	}
	if math.IsInf(f, 0) {
		return "", fmt.Errorf("E_CANONICAL_NONFINITE: %v not representable in canonical JSON", f)
	}
	if f == 0 {
		if math.Signbit(f) {
			return "-0.0", nil
		}
		return "0.0", nil
	}
	abs := math.Abs(f)
	if abs < 1e-6 || abs >= 1e21 {
		return normalizeExponentForm(strconv.FormatFloat(f, 'e', -1, 64)), nil
	}
	s := strconv.FormatFloat(f, 'f', -1, 64)
	if !strings.Contains(s, ".") {
		s += ".0"
	}
	return s, nil
}

// normalizeExponentForm converts Go's "1e+25" / "1e-07" spellings to the
// RFC §5.4.6 form: lowercase 'e', no leading '+', no leading zeros on
// the exponent magnitude.
func normalizeExponentForm(s string) string {
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

var jsonMarshalerType = reflect.TypeOf((*json.Marshaler)(nil)).Elem()

// canonicalizeForJSON walks v via reflection and returns a tree of Go
// primitives, []interface{}, and map[string]interface{} where every
// float encountered has been replaced with a json.Number holding its
// §5.4.6 canonical text form. Feeding the result to json.Marshal then
// yields output that satisfies the on-wire int/float disambiguation.
//
// Types implementing json.Marshaler (e.g. json.Number, json.RawMessage)
// are passed through untouched so that prior canonicalization inside
// interface{} slots is preserved.
func canonicalizeForJSON(v interface{}) (interface{}, error) {
	return canonicalizeValue(reflect.ValueOf(v))
}

func canonicalizeValue(rv reflect.Value) (interface{}, error) {
	if !rv.IsValid() {
		return nil, nil
	}

	// Preserve values that already marshal themselves (json.Number,
	// json.RawMessage). Check both value and addressable pointer receivers.
	if rv.Kind() != reflect.Invalid {
		t := rv.Type()
		if t.Implements(jsonMarshalerType) {
			return rv.Interface(), nil
		}
		if rv.CanAddr() && reflect.PointerTo(t).Implements(jsonMarshalerType) {
			return rv.Addr().Interface(), nil
		}
	}

	switch rv.Kind() {
	case reflect.Pointer, reflect.Interface:
		if rv.IsNil() {
			return nil, nil
		}
		return canonicalizeValue(rv.Elem())

	case reflect.Struct:
		return canonicalizeStruct(rv)

	case reflect.Map:
		if rv.IsNil() {
			return nil, nil
		}
		result := make(map[string]interface{}, rv.Len())
		iter := rv.MapRange()
		for iter.Next() {
			key := iter.Key()
			var ks string
			if key.Kind() == reflect.String {
				ks = key.String()
			} else {
				ks = fmt.Sprintf("%v", key.Interface())
			}
			val, err := canonicalizeValue(iter.Value())
			if err != nil {
				return nil, err
			}
			result[ks] = val
		}
		return result, nil

	case reflect.Slice:
		if rv.IsNil() {
			return nil, nil
		}
		return canonicalizeSequence(rv)

	case reflect.Array:
		return canonicalizeSequence(rv)

	case reflect.Float32, reflect.Float64:
		s, err := canonicalFloat64String(rv.Float())
		if err != nil {
			return nil, err
		}
		return json.Number(s), nil

	case reflect.Int, reflect.Int8, reflect.Int16, reflect.Int32, reflect.Int64:
		return rv.Int(), nil

	case reflect.Uint, reflect.Uint8, reflect.Uint16, reflect.Uint32, reflect.Uint64:
		return rv.Uint(), nil

	case reflect.Bool:
		return rv.Bool(), nil

	case reflect.String:
		return rv.String(), nil
	}

	return rv.Interface(), nil
}

func canonicalizeSequence(rv reflect.Value) (interface{}, error) {
	// []byte is a special case: encoding/json emits it as a base64 string.
	if rv.Type().Elem().Kind() == reflect.Uint8 {
		if rv.Kind() == reflect.Slice {
			return rv.Bytes(), nil
		}
		// Fixed-size [N]byte: copy into a slice so json.Marshal emits base64.
		b := make([]byte, rv.Len())
		for i := 0; i < rv.Len(); i++ {
			b[i] = byte(rv.Index(i).Uint())
		}
		return b, nil
	}
	result := make([]interface{}, rv.Len())
	for i := 0; i < rv.Len(); i++ {
		val, err := canonicalizeValue(rv.Index(i))
		if err != nil {
			return nil, err
		}
		result[i] = val
	}
	return result, nil
}

func canonicalizeStruct(rv reflect.Value) (interface{}, error) {
	t := rv.Type()
	result := make(map[string]interface{}, t.NumField())
	for i := 0; i < t.NumField(); i++ {
		field := t.Field(i)
		if !field.IsExported() {
			continue
		}
		name, omitempty, skip := parseJSONTag(field)
		if skip {
			continue
		}
		fv := rv.Field(i)
		if omitempty && isEmptyValue(fv) {
			continue
		}
		val, err := canonicalizeValue(fv)
		if err != nil {
			return nil, err
		}
		result[name] = val
	}
	return result, nil
}

func parseJSONTag(field reflect.StructField) (name string, omitempty, skip bool) {
	tag := field.Tag.Get("json")
	if tag == "-" {
		return "", false, true
	}
	name = field.Name
	if tag == "" {
		return name, false, false
	}
	parts := strings.Split(tag, ",")
	if parts[0] != "" {
		name = parts[0]
	}
	for _, p := range parts[1:] {
		if p == "omitempty" {
			omitempty = true
		}
	}
	return name, omitempty, false
}

// isEmptyValue mirrors encoding/json's isEmptyValue so omitempty behavior
// of the reflection walker matches json.Marshal exactly.
func isEmptyValue(v reflect.Value) bool {
	switch v.Kind() {
	case reflect.Array, reflect.Map, reflect.Slice, reflect.String:
		return v.Len() == 0
	case reflect.Bool:
		return !v.Bool()
	case reflect.Int, reflect.Int8, reflect.Int16, reflect.Int32, reflect.Int64:
		return v.Int() == 0
	case reflect.Uint, reflect.Uint8, reflect.Uint16, reflect.Uint32, reflect.Uint64, reflect.Uintptr:
		return v.Uint() == 0
	case reflect.Float32, reflect.Float64:
		return v.Float() == 0
	case reflect.Interface, reflect.Pointer:
		return v.IsNil()
	}
	return false
}
