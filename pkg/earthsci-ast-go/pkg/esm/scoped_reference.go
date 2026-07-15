package esm

import (
	"encoding/json"
	"strings"
)

// resolveScopedReference resolves a scoped reference like "Model.Subsystem.var"
// by walking the subsystem hierarchy to the variable it names.
//
// The second result reports whether resolution succeeded. On success the first
// result is the resolved LEAF variable name (the final path segment); a bare
// (dot-less) input is returned unchanged with ok=true. On failure the first
// result is a best-effort remainder — the original reference when the top-level
// system is unknown, or the joined unresolved remaining path when navigation
// fails partway down a subsystem chain — and callers must not treat it as a
// resolved name.
func resolveScopedReference(scopedRef string, file *ESMFile, currentSystem string) (string, bool) {
	if !strings.Contains(scopedRef, ".") {
		// Not a scoped reference, return as-is
		return scopedRef, true
	}

	parts := strings.Split(scopedRef, ".")
	if len(parts) < 2 {
		return scopedRef, false
	}

	systemName := parts[0]
	remainingPath := parts[1:]

	// First, try relative resolution within the current system
	if currentSystem != "" {
		// Check if the reference is relative to the current system (e.g., "SubsystemA.temp" within "MainModel")
		if currentModel, exists := file.Models[currentSystem]; exists {
			if resolved, found := resolveScopedInModel(parts, &currentModel); found {
				return resolved, true
			}
		}

		if currentReactionSystem, exists := file.ReactionSystems[currentSystem]; exists {
			if resolved, found := resolveScopedInReactionSystem(parts, &currentReactionSystem); found {
				return resolved, true
			}
		}
	}

	// If relative resolution failed, try absolute resolution
	// Check if this is a model or reaction system
	if model, exists := file.Models[systemName]; exists {
		return resolveScopedInModel(remainingPath, &model)
	}

	if system, exists := file.ReactionSystems[systemName]; exists {
		return resolveScopedInReactionSystem(remainingPath, &system)
	}

	// A DATA LOADER is a scopable namespace too: `GEOSFP_MeteoData.u` names the
	// variable `u` the loader exposes. Loaders were absent from this resolver, so
	// every loader-scoped reference — the whole point of a data loader — came back
	// unresolved (audit G7).
	if loader, exists := file.DataLoaders[systemName]; exists {
		return resolveScopedInDataLoader(remainingPath, &loader)
	}

	return scopedRef, false
}

// resolveScopedInDataLoader resolves a reference into a data loader's exposed
// variable set. A loader has no subsystems, so the path must be exactly one
// segment: the variable name.
func resolveScopedInDataLoader(path []string, loader *DataLoader) (string, bool) {
	if len(path) != 1 {
		return strings.Join(path, "."), false
	}
	varName := path[0]
	if _, exists := loader.Variables[varName]; exists {
		return varName, true
	}
	return varName, false
}

// subsystemPathExists reports whether a dotted name addresses a subsystem that
// really exists — "AtmosphericChemistry.Aerosols", or a deeper chain such as
// "EmissionSources.Biogenic.Forest". Coupling `systems` entries may name a
// subsystem, so the coupling check consults this before reporting the name as an
// undefined system.
func subsystemPathExists(dotted string, file *ESMFile) bool {
	parts := strings.Split(dotted, ".")
	if len(parts) < 2 {
		return false
	}
	root, rest := parts[0], parts[1:]

	if model, exists := file.Models[root]; exists {
		return subsystemChainExists(rest, model.Subsystems)
	}
	if system, exists := file.ReactionSystems[root]; exists {
		return subsystemChainExists(rest, system.Subsystems)
	}
	return false
}

// subsystemChainExists walks a chain of subsystem names down from a subsystems
// map, reporting whether the whole chain resolves.
func subsystemChainExists(path []string, subsystems map[string]any) bool {
	if len(path) == 0 {
		return true
	}
	raw, exists := subsystems[path[0]]
	if !exists {
		return false
	}
	if len(path) == 1 {
		return true
	}
	// Descend: the nested value may be spelled as either component kind, so try
	// a Model first and fall back to a ReactionSystem.
	if sub, ok := decodeSubsystemAs[Model](raw); ok && len(sub.Subsystems) > 0 {
		return subsystemChainExists(path[1:], sub.Subsystems)
	}
	if sub, ok := decodeSubsystemAs[ReactionSystem](raw); ok && len(sub.Subsystems) > 0 {
		return subsystemChainExists(path[1:], sub.Subsystems)
	}
	return false
}

// resolveScopedInModel resolves a scoped reference within a model
func resolveScopedInModel(path []string, model *Model) (string, bool) {
	if len(path) == 1 {
		// Direct variable reference
		varName := path[0]
		if _, exists := model.Variables[varName]; exists {
			return varName, true
		}
		return varName, false
	}

	// Navigate to subsystem
	subsystemName := path[0]
	remainingPath := path[1:]

	if model.Subsystems != nil {
		if subsystemData, exists := model.Subsystems[subsystemName]; exists {
			if subsystem, ok := decodeSubsystemAs[Model](subsystemData); ok {
				return resolveScopedInModel(remainingPath, &subsystem)
			}
		}
	}

	return strings.Join(path, "."), false
}

// decodeSubsystemAs re-decodes a raw subsystem value (a generic JSON map, as it
// is stored in Model/ReactionSystem.Subsystems) into the typed component T
// (Model or ReactionSystem) via a marshal→unmarshal round-trip. It reports false
// if the value cannot be marshaled or decoded into T.
func decodeSubsystemAs[T any](raw any) (T, bool) {
	var out T
	data, err := json.Marshal(raw)
	if err != nil {
		return out, false
	}
	if err := json.Unmarshal(data, &out); err != nil {
		return out, false
	}
	return out, true
}

// resolveScopedInReactionSystem resolves a scoped reference within a reaction system
func resolveScopedInReactionSystem(path []string, system *ReactionSystem) (string, bool) {
	if len(path) == 1 {
		// Direct variable reference
		varName := path[0]

		// Check species
		if _, exists := system.Species[varName]; exists {
			return varName, true
		}

		// Check parameters
		if _, exists := system.Parameters[varName]; exists {
			return varName, true
		}

		return varName, false
	}

	// Navigate to subsystem
	subsystemName := path[0]
	remainingPath := path[1:]

	if system.Subsystems != nil {
		if subsystemData, exists := system.Subsystems[subsystemName]; exists {
			if subsystem, ok := decodeSubsystemAs[ReactionSystem](subsystemData); ok {
				return resolveScopedInReactionSystem(remainingPath, &subsystem)
			}
		}
	}

	return strings.Join(path, "."), false
}
