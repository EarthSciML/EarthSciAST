package esm

import (
	"encoding/json"
	"fmt"
	"math"
	"reflect"
	"strconv"
	"strings"
)

// canonicalFloat64String returns the DOCUMENT-serialization on-wire text form
// of f (CONFORMANCE_SPEC.md §5.5.3.1), used by canonicalizeForJSON for .esm
// serialization and the property-corpus round-trip driver.
//
// It applies §5.5.3.1 rule 1 (integral-float normalization): a float whose
// value is integral and fits int64 serializes as an INTEGER literal — no
// trailing ".0" — regardless of how it was spelled (0.0→"0", 9.0→"9",
// -696723.0→"-696723", 2.5e1→"25", ±0.0→"0"). The int64 round-trip test
// (int64(f) back to float64) is exact and also screens values outside int64
// range: a huge integral magnitude like 1e20 fails it and falls through to
// float rendering. All other values delegate to the shared §5.4.6 renderer
// (formatCanonicalFloatShared), so non-integral floats keep shortest-round-trip
// form and NaN/±Inf are rejected with an error wrapping ErrCanonicalNonFinite.
//
// This differs deliberately from the CanonicalJSON expression-equivalence form
// (formatCanonicalFloat / §5.4.6), which KEEPS the ".0" so 1.0 and 1 stay
// distinguishable for algebraic canonicalization (tests/conformance/canonical).
func canonicalFloat64String(f float64) (string, error) {
	if !math.IsNaN(f) && !math.IsInf(f, 0) && f == math.Trunc(f) {
		if i := int64(f); float64(i) == f {
			return strconv.FormatInt(i, 10), nil
		}
	}
	return formatCanonicalFloatShared(f)
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
func canonicalizeForJSON(v any) (any, error) {
	return canonicalizeValue(reflect.ValueOf(v))
}

func canonicalizeValue(rv reflect.Value) (any, error) {
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
		result := make(map[string]any, rv.Len())
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

func canonicalizeSequence(rv reflect.Value) (any, error) {
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
	result := make([]any, rv.Len())
	for i := 0; i < rv.Len(); i++ {
		val, err := canonicalizeValue(rv.Index(i))
		if err != nil {
			return nil, err
		}
		result[i] = val
	}
	return result, nil
}

func canonicalizeStruct(rv reflect.Value) (any, error) {
	t := rv.Type()
	result := make(map[string]any, t.NumField())
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
