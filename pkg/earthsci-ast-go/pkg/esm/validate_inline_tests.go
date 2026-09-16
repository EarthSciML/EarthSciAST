package esm

import (
	"fmt"
	"regexp"
	"sort"
	"strings"
)

// Static checks on every inline test (esm-spec §6.6), decidable from the document
// alone and so owed by every binding, executing or not:
//
//   - an assertion `variable` that is a bare name (element suffix removed) the
//     asserting component does not declare is `undefined_variable` (§6.6.3); a
//     dotted target names a declaration elsewhere and is resolved by the runtime;
//   - an `initial_conditions` / `parameter_overrides` key that matches no
//     declared name under the §6.6.2 rules is `unknown_override_key`; skipped
//     when the document still holds an unresolved `{ref}` mount a key could name
//     into;
//   - an assertion whose form does not match the declared rank of its target is
//     `assertion_rank_mismatch` (§6.6.5).

var inlineTestElementSuffix = regexp.MustCompile(`^(.*?)\[[^\]]*\]$`)

// stripElementSuffix turns `u[1]` into ("u", true); a name without an element
// suffix is returned unchanged.
func stripElementSuffix(name string) (string, bool) {
	if m := inlineTestElementSuffix.FindStringSubmatch(name); m != nil {
		return m[1], true
	}
	return name, false
}

// jsonPointerToken escapes one JSON Pointer reference token (RFC 6901).
func jsonPointerToken(key string) string {
	return strings.ReplaceAll(strings.ReplaceAll(key, "~", "~0"), "/", "~1")
}

// declaredOverrideNames holds the document's declared names qualified as a
// flatten qualifies them (`<component>.<name>`, `<component>.<subsystem>.<name>`
// at any depth), the component and subsystem names §6.6.2 rule 2 validates a
// key's leading segments against, and whether every mount is resolved.
type declaredOverrideNames struct {
	names      map[string]bool
	namespaces map[string]bool
	complete   bool
}

func (d *declaredOverrideNames) addRaw(prefix string, raw any) {
	component, ok := raw.(map[string]any)
	if !ok {
		d.complete = false
		return
	}
	if _, isRef := component["ref"]; isRef {
		d.complete = false
		return
	}
	d.namespaces[prefix[strings.LastIndex(prefix, ".")+1:]] = true
	for _, field := range []string{"variables", "species", "parameters"} {
		if decls, ok := component[field].(map[string]any); ok {
			for name := range decls {
				d.names[prefix+"."+name] = true
			}
		}
	}
	if subs, ok := component["subsystems"].(map[string]any); ok {
		for subName, sub := range subs {
			d.addRaw(prefix+"."+subName, sub)
		}
	}
}

func collectDeclaredOverrideNames(file *ESMFile) *declaredOverrideNames {
	d := &declaredOverrideNames{names: map[string]bool{}, namespaces: map[string]bool{}, complete: true}
	if len(file.topLevelModelRefs) > 0 {
		d.complete = false
	}
	for name, model := range file.Models {
		d.namespaces[name] = true
		for v := range model.Variables {
			d.names[name+"."+v] = true
		}
		for subName, sub := range model.Subsystems {
			d.addRaw(name+"."+subName, sub)
		}
	}
	for name, system := range file.ReactionSystems {
		d.namespaces[name] = true
		for sp := range system.Species {
			d.names[name+"."+sp] = true
		}
		for p := range system.Parameters {
			d.names[name+"."+p] = true
		}
		for subName, sub := range system.Subsystems {
			d.addRaw(name+"."+subName, sub)
		}
	}
	return d
}

// matches reports whether key reaches a declared name under §6.6.2 rules 1-3: an
// exact hit; a dotted suffix of the key that is a name, every dropped leading
// segment naming a component or subsystem; or the key a dotted suffix of some
// name. Ambiguity is a runtime diagnostic, so one match suffices.
func (d *declaredOverrideNames) matches(key string) bool {
	if d.names[key] {
		return true
	}
	parts := strings.Split(key, ".")
	for i := 1; i < len(parts); i++ {
		if !d.names[strings.Join(parts[i:], ".")] {
			continue
		}
		qualified := true
		for _, p := range parts[:i] {
			if !d.namespaces[p] {
				qualified = false
				break
			}
		}
		if qualified {
			return true
		}
	}
	tail := "." + key
	for name := range d.names {
		if strings.HasSuffix(name, tail) {
			return true
		}
	}
	return false
}

// validateInlineTests runs the static inline-test checks over every top-level
// component, in sorted order so the findings do not depend on map iteration.
func (s *structuralScan) validateInlineTests() {
	if s.file == nil {
		return
	}
	declared := collectDeclaredOverrideNames(s.file)
	for _, name := range sortedKeys(s.file.Models) {
		model := s.file.Models[name]
		shapes := map[string][]string{}
		for v, decl := range model.Variables {
			shapes[v] = nil
			if decl.Shape != nil {
				shapes[v] = *decl.Shape
			}
		}
		s.checkInlineTests(model.Tests, "/models/"+name, shapes, declared)
	}
	for _, name := range sortedKeys(s.file.ReactionSystems) {
		system := s.file.ReactionSystems[name]
		shapes := map[string][]string{}
		for sp := range system.Species {
			shapes[sp] = nil
		}
		for p, decl := range system.Parameters {
			shapes[p] = nil
			if decl.Shape != nil {
				shapes[p] = *decl.Shape
			}
		}
		s.checkInlineTests(system.Tests, "/reaction_systems/"+name, shapes, declared)
	}
}

func (s *structuralScan) checkInlineTests(tests []Test, componentPath string,
	shapes map[string][]string, declared *declaredOverrideNames) {
	for ti, test := range tests {
		base := fmt.Sprintf("%s/tests/%d", componentPath, ti)
		if declared.complete {
			for _, field := range []struct {
				name string
				keys map[string]any
			}{
				{"initial_conditions", test.InitialConditions},
				{"parameter_overrides", test.ParameterOverrides},
			} {
				keys := make([]string, 0, len(field.keys))
				for k := range field.keys {
					keys = append(keys, k)
				}
				sort.Strings(keys)
				for _, key := range keys {
					bareKey, _ := stripElementSuffix(key)
					if declared.matches(bareKey) {
						continue
					}
					s.addErr(StructuralError{
						Path:    fmt.Sprintf("%s/%s/%s", base, field.name, jsonPointerToken(key)),
						Code:    ErrorUnknownOverrideKey,
						Message: fmt.Sprintf("Override key %q in %s matches no declared name", key, field.name),
						Details: map[string]any{"key": key, "field": field.name},
					})
				}
			}
		}
		for ai, assertion := range test.Assertions {
			bare, isElement := stripElementSuffix(assertion.Variable)
			if strings.Contains(bare, ".") {
				continue
			}
			pointer := fmt.Sprintf("%s/assertions/%d", base, ai)
			shape, ok := shapes[bare]
			if !ok {
				s.addErr(StructuralError{
					Path:    pointer + "/variable",
					Code:    ErrorUndefinedVariable,
					Message: fmt.Sprintf("Variable %q referenced in assertion variable but not declared", bare),
					Details: map[string]any{"variable": bare},
				})
				continue
			}
			if isElement {
				continue
			}
			selects := assertion.Coords != nil || assertion.Reduce != ""
			switch {
			case len(shape) > 0 && !selects:
				s.addErr(StructuralError{
					Path:    pointer,
					Code:    ErrorAssertionRankMismatch,
					Message: fmt.Sprintf("Assertion on shaped variable %q selects no scalar (give coords, reduce, or an element name)", bare),
					Details: map[string]any{"variable": bare, "shape": shape},
				})
			case len(shape) == 0 && selects:
				s.addErr(StructuralError{
					Path:    pointer,
					Code:    ErrorAssertionRankMismatch,
					Message: fmt.Sprintf("Assertion on scalar variable %q carries coords or reduce", bare),
					Details: map[string]any{"variable": bare, "shape": []string{}},
				})
			}
		}
	}
}
