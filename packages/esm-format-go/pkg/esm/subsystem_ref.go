package esm

import (
	"encoding/json"
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
func resolveSubsystemMap(subsystems map[string]interface{}, basePath string, visited map[string]bool) error {
	if len(subsystems) == 0 {
		return nil
	}

	for key, value := range subsystems {
		refObj, isRef := extractRef(value)
		if !isRef {
			continue
		}

		ref := refObj

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

		// Parse the referenced file as an EsmFile
		var refFile EsmFile
		if err := json.Unmarshal(data, &refFile); err != nil {
			return fmt.Errorf("subsystem %q: failed to parse referenced file %q: %w", key, sourceDesc, err)
		}

		// Recursively resolve subsystem refs in the loaded file
		if err := resolveSubsystemRefsInternal(&refFile, refBasePath, visited); err != nil {
			return fmt.Errorf("subsystem %q: resolving nested refs in %q: %w", key, sourceDesc, err)
		}

		// Remove from visited after successful resolution (allow the same file
		// to be referenced from different subsystem trees, just not circularly)
		delete(visited, refKey)

		// Extract the single top-level model or reaction system from the referenced file
		resolved, err := extractSingleSystem(&refFile, sourceDesc)
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
	m, ok := value.(map[string]interface{})
	if !ok {
		return "", false
	}

	ref, ok := m["ref"]
	if !ok {
		return "", false
	}

	refStr, ok := ref.(string)
	if !ok {
		return "", false
	}

	return refStr, true
}

// extractSingleSystem extracts the single top-level model, reaction system, or
// data loader from a referenced ESM file. If the file contains exactly one
// model, that model is returned. If it contains exactly one reaction system,
// that is returned. If it contains exactly one data loader, that is returned.
// If there are multiple systems or none, an error is returned.
func extractSingleSystem(file *EsmFile, path string) (interface{}, error) {
	modelCount := len(file.Models)
	rsCount := len(file.ReactionSystems)
	loaderCount := len(file.DataLoaders)
	total := modelCount + rsCount + loaderCount

	if total == 0 {
		return nil, fmt.Errorf("referenced file %q contains no models, reaction systems, or data loaders", path)
	}

	if total > 1 {
		return nil, fmt.Errorf("referenced file %q contains %d systems (expected exactly 1); "+
			"models=%d, reaction_systems=%d, data_loaders=%d", path, total, modelCount, rsCount, loaderCount)
	}

	// Extract the single system. Precedence: models -> reaction_systems -> data_loaders.
	if modelCount == 1 {
		for _, model := range file.Models {
			// Convert to a generic map for storage in the subsystems interface{} map
			data, err := json.Marshal(model)
			if err != nil {
				return nil, fmt.Errorf("failed to marshal resolved model from %q: %w", path, err)
			}
			var result interface{}
			if err := json.Unmarshal(data, &result); err != nil {
				return nil, fmt.Errorf("failed to unmarshal resolved model from %q: %w", path, err)
			}
			return result, nil
		}
	}

	if rsCount == 1 {
		for _, rs := range file.ReactionSystems {
			data, err := json.Marshal(rs)
			if err != nil {
				return nil, fmt.Errorf("failed to marshal resolved reaction system from %q: %w", path, err)
			}
			var result interface{}
			if err := json.Unmarshal(data, &result); err != nil {
				return nil, fmt.Errorf("failed to unmarshal resolved reaction system from %q: %w", path, err)
			}
			return result, nil
		}
	}

	for _, loader := range file.DataLoaders {
		data, err := json.Marshal(loader)
		if err != nil {
			return nil, fmt.Errorf("failed to marshal resolved data loader from %q: %w", path, err)
		}
		var result interface{}
		if err := json.Unmarshal(data, &result); err != nil {
			return nil, fmt.Errorf("failed to unmarshal resolved data loader from %q: %w", path, err)
		}
		return result, nil
	}

	// Unreachable, but satisfies the compiler
	return nil, fmt.Errorf("unexpected state extracting system from %q", path)
}
