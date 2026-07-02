package esm

import (
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
)

// ResolveSubsystemRefs walks all subsystem maps in models and reaction systems,
// resolving any entries that contain a "ref" field by loading and inlining the
// referenced ESM file content.
//
// Resolution rules:
//   - If ref starts with http:// or https://, fetch the file over HTTP.
//   - Otherwise, the ref is resolved as a local file path relative to basePath.
//   - Referenced files are parsed recursively, so nested refs are resolved.
//   - Circular references are detected and reported as errors.
//
// The function modifies file in-place, replacing reference objects with the
// resolved model or reaction system content.
func ResolveSubsystemRefs(file *EsmFile, basePath string) error {
	visited := make(map[string]bool)
	return resolveSubsystemRefsInternal(file, basePath, visited)
}

// resolveSubsystemRefsInternal is the recursive implementation that tracks
// visited paths for circular reference detection.
func resolveSubsystemRefsInternal(file *EsmFile, basePath string, visited map[string]bool) error {
	// Resolve subsystems in models
	for modelName, model := range file.Models {
		if err := resolveSubsystemMap(model.Subsystems, basePath, visited); err != nil {
			return fmt.Errorf("model %q subsystems: %w", modelName, err)
		}
		file.Models[modelName] = model
	}

	// Resolve subsystems in reaction systems
	for rsName, rs := range file.ReactionSystems {
		if err := resolveSubsystemMap(rs.Subsystems, basePath, visited); err != nil {
			return fmt.Errorf("reaction_system %q subsystems: %w", rsName, err)
		}
		file.ReactionSystems[rsName] = rs
	}

	return nil
}

// resolveSubsystemMap resolves references in a single subsystems map.
// Each value in the map is either already-resolved content (left as-is) or a
// reference object with a "ref" key (resolved by loading the referenced file).
//
// The referenced document is resolved on its RAW JSON view: the esm-spec §9.7
// machinery runs first (version gates, template-library rejection —
// `subsystem_ref_is_template_library` — import resolution, and metaparameter
// close, with the edge's optional `bindings` supplying §9.7.6 binding site 3),
// then the §9.6.3 rewrite fixpoint, then nested subsystem refs recursively.
// Working on the raw view keeps full Expression fidelity (aggregate /
// makearray fields the typed ExprNode does not model survive intact).
func resolveSubsystemMap(subsystems map[string]interface{}, basePath string, visited map[string]bool) error {
	if len(subsystems) == 0 {
		return nil
	}

	for key, value := range subsystems {
		refObj, bindingsRaw, isRef := extractRefWithBindings(value)
		if !isRef {
			continue
		}

		ref := refObj

		// The edge's metaparameter bindings (esm-spec §9.7.6 binding site 3).
		bindings := map[string]int64{}
		for _, bk := range sortedKeys(bindingsRaw) {
			bv, err := metaparamInt(bindingsRaw[bk],
				fmt.Sprintf("subsystems.%s: binding '%s'", key, bk))
			if err != nil {
				return err
			}
			bindings[bk] = bv
		}

		var (
			data        []byte
			refKey      string
			refBasePath string
			sourceDesc  string
			err         error
		)

		if strings.HasPrefix(ref, "http://") || strings.HasPrefix(ref, "https://") {
			refKey = ref
			sourceDesc = ref
			refBasePath = basePath

			if visited[refKey] {
				return fmt.Errorf("subsystem %q: circular reference detected for %q", key, ref)
			}
			visited[refKey] = true

			data, err = fetchRemoteRef(ref)
			if err != nil {
				return fmt.Errorf("subsystem %q: %w", key, err)
			}
		} else {
			refPath := ref
			if !filepath.IsAbs(refPath) {
				refPath = filepath.Join(basePath, refPath)
			}

			absPath, absErr := filepath.Abs(refPath)
			if absErr != nil {
				return fmt.Errorf("subsystem %q: failed to resolve path %q: %w", key, ref, absErr)
			}

			refKey = absPath
			sourceDesc = absPath
			refBasePath = filepath.Dir(absPath)

			if visited[refKey] {
				return fmt.Errorf("subsystem %q: circular reference detected for %q", key, ref)
			}
			visited[refKey] = true

			data, err = os.ReadFile(absPath)
			if err != nil {
				return fmt.Errorf("subsystem %q: failed to read referenced file %q: %w", key, absPath, err)
			}
		}

		// Decode the referenced file's raw view (UseNumber preserves the
		// int/float distinction through the §9.7 resolver).
		view, err := decodeJSONView(data)
		if err != nil {
			return fmt.Errorf("subsystem %q: failed to parse referenced file %q: %w", key, sourceDesc, err)
		}

		// Spec-version gates (esm-spec §9.6.5).
		if err := RejectExpressionTemplatesPreV04(view); err != nil {
			return err
		}
		if err := RejectTemplateImportsPreV08(view); err != nil {
			return err
		}

		// A §4.7 subsystem ref MUST NOT target a template-library file — the
		// two reference mechanisms are disjoint (esm-spec §9.7.1).
		if isTemplateLibraryDoc(view) {
			return newETErr("subsystem_ref_is_template_library",
				fmt.Sprintf("subsystem %q: ref %q targets a template-library file (%s); libraries are imported via expression_template_imports (esm-spec §9.7.1)", key, ref, sourceDesc))
		}

		// Resolve the referenced document's §9.7 machinery with this edge's
		// bindings, then run the §9.6.3 rewrite fixpoint so the inlined
		// component carries only normal Expression ASTs (Option A).
		orders := extractTemplateOrders(string(data))
		if _, err := resolveTemplateMachinery(view, orders, refBasePath, bindings); err != nil {
			return err
		}
		if err := lowerExpressionTemplatesOrdered(view, orders); err != nil {
			return err
		}

		// Recursively resolve subsystem refs nested in the loaded file's
		// components, relative to its own directory.
		for _, kind := range []string{"models", "reaction_systems"} {
			comps, ok := view[kind].(map[string]interface{})
			if !ok {
				continue
			}
			for _, compRaw := range comps {
				compObj, ok := compRaw.(map[string]interface{})
				if !ok {
					continue
				}
				if subs, ok := compObj["subsystems"].(map[string]interface{}); ok {
					if err := resolveSubsystemMap(subs, refBasePath, visited); err != nil {
						return fmt.Errorf("subsystem %q: resolving nested refs in %q: %w", key, sourceDesc, err)
					}
				}
			}
		}

		// Remove from visited after successful resolution (allow the same file
		// to be referenced from different subsystem trees, just not circularly)
		delete(visited, refKey)

		// Extract the single top-level model, reaction system, or data loader
		resolved, err := extractSingleSystemRaw(view, sourceDesc)
		if err != nil {
			return fmt.Errorf("subsystem %q: %w", key, err)
		}

		subsystems[key] = resolved
	}

	return nil
}

// fetchRemoteRef downloads a subsystem reference from an HTTP(S) URL and
// returns the raw response body.
func fetchRemoteRef(url string) ([]byte, error) {
	resp, err := http.Get(url)
	if err != nil {
		return nil, fmt.Errorf("failed to fetch remote ref %q: %w", url, err)
	}
	defer func() { _ = resp.Body.Close() }()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("failed to fetch remote ref %q: HTTP %d %s", url, resp.StatusCode, resp.Status)
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("failed to read remote ref %q: %w", url, err)
	}
	return body, nil
}

// extractRef checks if a value is a reference object (a map with a "ref" key)
// and returns the ref string if so.
func extractRef(value interface{}) (string, bool) {
	ref, _, ok := extractRefWithBindings(value)
	return ref, ok
}

// extractRefWithBindings checks if a value is a reference object (a map with
// a "ref" key) and returns the ref string plus its optional metaparameter
// `bindings` object (esm-spec §9.7.6 binding site 3).
func extractRefWithBindings(value interface{}) (string, map[string]interface{}, bool) {
	m, ok := value.(map[string]interface{})
	if !ok {
		return "", nil, false
	}

	ref, ok := m["ref"]
	if !ok {
		return "", nil, false
	}

	refStr, ok := ref.(string)
	if !ok {
		return "", nil, false
	}

	bindings, _ := m["bindings"].(map[string]interface{})
	return refStr, bindings, true
}

// extractSingleSystemRaw extracts the single top-level model, reaction
// system, or data loader from a referenced ESM document's RAW view. If the
// file contains exactly one such component it is returned as-is (a generic
// map, preserving every Expression field verbatim). If there are multiple
// systems or none, an error is returned.
func extractSingleSystemRaw(view map[string]interface{}, path string) (interface{}, error) {
	models, _ := view["models"].(map[string]interface{})
	rss, _ := view["reaction_systems"].(map[string]interface{})
	loaders, _ := view["data_loaders"].(map[string]interface{})
	total := len(models) + len(rss) + len(loaders)

	if total == 0 {
		return nil, fmt.Errorf("referenced file %q contains no models, reaction systems, or data loaders", path)
	}

	if total > 1 {
		return nil, fmt.Errorf("referenced file %q contains %d systems (expected exactly 1); "+
			"models=%d, reaction_systems=%d, data_loaders=%d", path, total, len(models), len(rss), len(loaders))
	}

	// Extract the single system. Precedence: models -> reaction_systems -> data_loaders.
	for _, m := range models {
		return m, nil
	}
	for _, rs := range rss {
		return rs, nil
	}
	for _, loader := range loaders {
		return loader, nil
	}

	// Unreachable, but satisfies the compiler
	return nil, fmt.Errorf("unexpected state extracting system from %q", path)
}
