package esm

import (
	"encoding/json"
	"strings"
)

// resolveScopedReference resolves a scoped reference like "Model.Subsystem.var"
// by walking the subsystem hierarchy to find the actual variable
// Returns the resolved variable name and whether it was found
func resolveScopedReference(scopedRef string, file *EsmFile, currentSystem string) (string, bool) {
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

	return scopedRef, false
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
			// Try to unmarshal the subsystem as a Model
			var subsystem Model
			if bytes, err := json.Marshal(subsystemData); err == nil {
				if err := json.Unmarshal(bytes, &subsystem); err == nil {
					return resolveScopedInModel(remainingPath, &subsystem)
				}
			}
		}
	}

	return strings.Join(path, "."), false
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
			// Try to unmarshal the subsystem as a ReactionSystem
			var subsystem ReactionSystem
			if bytes, err := json.Marshal(subsystemData); err == nil {
				if err := json.Unmarshal(bytes, &subsystem); err == nil {
					return resolveScopedInReactionSystem(remainingPath, &subsystem)
				}
			}
		}
	}

	return strings.Join(path, "."), false
}

// getAllAvailableVariables returns a map of all variables available in a given system context
// This includes variables from the current system and all accessible subsystem variables
func getAllAvailableVariables(file *EsmFile, systemName string) map[string]bool {
	allVars := make(map[string]bool)

	// Helper function to collect variables from a model
	var collectFromModel func(model *Model, prefix string)
	collectFromModel = func(model *Model, prefix string) {
		// Add direct variables
		for varName := range model.Variables {
			if prefix == "" {
				allVars[varName] = true
			} else {
				allVars[prefix+"."+varName] = true
			}
		}

		// Recursively collect from subsystems
		if model.Subsystems != nil {
			for subsystemName, subsystemData := range model.Subsystems {
				var subsystem Model
				if bytes, err := json.Marshal(subsystemData); err == nil {
					if err := json.Unmarshal(bytes, &subsystem); err == nil {
						newPrefix := subsystemName
						if prefix != "" {
							newPrefix = prefix + "." + subsystemName
						}
						collectFromModel(&subsystem, newPrefix)
					}
				}
			}
		}
	}

	// Helper function to collect variables from a reaction system
	var collectFromReactionSystem func(system *ReactionSystem, prefix string)
	collectFromReactionSystem = func(system *ReactionSystem, prefix string) {
		// Add species
		for speciesName := range system.Species {
			if prefix == "" {
				allVars[speciesName] = true
			} else {
				allVars[prefix+"."+speciesName] = true
			}
		}

		// Add parameters
		for paramName := range system.Parameters {
			if prefix == "" {
				allVars[paramName] = true
			} else {
				allVars[prefix+"."+paramName] = true
			}
		}

		// Recursively collect from subsystems
		if system.Subsystems != nil {
			for subsystemName, subsystemData := range system.Subsystems {
				var subsystem ReactionSystem
				if bytes, err := json.Marshal(subsystemData); err == nil {
					if err := json.Unmarshal(bytes, &subsystem); err == nil {
						newPrefix := subsystemName
						if prefix != "" {
							newPrefix = prefix + "." + subsystemName
						}
						collectFromReactionSystem(&subsystem, newPrefix)
					}
				}
			}
		}
	}

	// Collect variables from the specified system
	if model, exists := file.Models[systemName]; exists {
		collectFromModel(&model, "")
	}

	if system, exists := file.ReactionSystems[systemName]; exists {
		collectFromReactionSystem(&system, "")
	}

	// Also collect variables from other systems (for cross-system references)
	for modelName, model := range file.Models {
		if modelName != systemName {
			collectFromModel(&model, modelName)
		}
	}

	for sysName, system := range file.ReactionSystems {
		if sysName != systemName {
			collectFromReactionSystem(&system, sysName)
		}
	}

	return allVars
}
