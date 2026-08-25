package esm

// reactions.go is the Analysis-tier reaction-network surface
// (esm-libraries-spec §1.2, §5.5): deriving a model's ODEs from a reaction
// network by mass-action kinetics, and the stoichiometric matrix.
//
// Go declared the Analysis tier without exporting either operation. The
// derivation itself was already here — flatten's lowerReactionsToEquations —
// but reachable only by flattening a whole document, which is not the question
// "what ODEs does THIS reaction system imply".
//
// SPECIES ORDER. Both functions order species lexicographically by name.
// ReactionSystem.Species is a map here, exactly as it is in Rust, and a bare
// *ReactionSystem carries no declaration order to recover — sorting is the only
// deterministic answer available, and it is the one Rust's stoichiometric_matrix
// already gives for the same reason. (Julia, Python and TypeScript hold species
// as an ordered list and use declaration order. The bindings genuinely differ
// here; no shared fixture pins it.)

// DeriveODEs converts a reaction network into a Model whose equations are the
// species' ODEs under mass-action kinetics (esm-spec §7.4).
//
// Species become UNKNOWNS — the `D(s,t)` equation emitted below is what makes
// one an ODE state under the §6.3.1 derived classification — except reservoir
// species (`constant: true`), which are held fixed and get no ODE, so they
// lower to PARAMETERS carrying their declared `default`. Rate parameters become
// parameters. Subsystems are derived recursively, as in the Julia reference.
//
// The equations come from the same lowerReactionsToEquations the flatten path
// uses, so a system's ODEs are identical whether reached through here or
// through Flatten. That is deliberate and mirrors how Julia and Rust are
// arranged — both have `derive_odes` call their own shared lowering helper
// rather than reimplementing mass action beside it. The helper is not itself
// exported: it takes an explicit species order that only a caller which has
// already decided the document's ordering (flatten) can supply meaningfully,
// and exporting that argument would export a decision this entry point is here
// to make.
func DeriveODEs(system *ReactionSystem) (*Model, error) {
	if system == nil {
		return nil, nil
	}

	speciesOrder := sortedKeys(system.Species)
	variables := make(map[string]ModelVariable, len(system.Species)+len(system.Parameters))
	for _, name := range speciesOrder {
		sp := system.Species[name]
		varType := VarTypeUnknown
		if sp.Constant != nil && *sp.Constant {
			varType = VarTypeParameter
		}
		variables[name] = ModelVariable{
			Type:        varType,
			Units:       sp.Units,
			Default:     sp.Default,
			Description: sp.Description,
		}
	}
	for _, name := range sortedKeys(system.Parameters) {
		p := system.Parameters[name]
		variables[name] = ModelVariable{
			Type:        VarTypeParameter,
			Units:       p.Units,
			Default:     p.Default,
			Description: p.Description,
		}
	}

	equations, err := lowerReactionsToEquations(system, speciesOrder)
	if err != nil {
		return nil, err
	}
	// A reaction system's `constraint_equations` are equations of the derived
	// model too — they are the algebraic half of the same system.
	equations = append(equations, system.ConstraintEquations...)

	model := &Model{
		Reference:        system.Reference,
		Variables:        variables,
		Equations:        equations,
		DiscreteEvents:   system.DiscreteEvents,
		ContinuousEvents: system.ContinuousEvents,
		Tolerance:        system.Tolerance,
	}

	if len(system.Subsystems) > 0 {
		subs := make(map[string]any, len(system.Subsystems))
		for _, name := range sortedKeys(system.Subsystems) {
			sub, ok := decodeSubsystemAs[ReactionSystem](system.Subsystems[name])
			if !ok {
				// Not a reaction system (a `$ref` mount, say): carry it through
				// untouched rather than dropping it.
				subs[name] = system.Subsystems[name]
				continue
			}
			derived, err := DeriveODEs(&sub)
			if err != nil {
				return nil, err
			}
			subs[name] = *derived
		}
		model.Subsystems = subs
	}

	return model, nil
}

// StoichiometricMatrix returns the NET stoichiometric matrix of a reaction
// network: rows are species (sorted by name, see the file header), columns are
// reactions in declaration order, and entry [i][j] is
// `products − substrates` for species i in reaction j. Negative means consumed,
// positive means produced.
//
// Values are float64 because esm permits fractional coefficients
// (`ISOP + O3 → 0.87 CH2O`); an integer-only network yields exact integers
// stored as float64.
//
// A species appearing more than once on the same side of one reaction has its
// coefficients SUMMED, which is why the entry accumulates rather than assigns.
// (That is a warning-level defect — `duplicate_reaction_species` — not an
// error, so the matrix must still have an answer for it.)
func StoichiometricMatrix(system *ReactionSystem) [][]float64 {
	if system == nil {
		return nil
	}
	speciesOrder := sortedKeys(system.Species)
	index := make(map[string]int, len(speciesOrder))
	for i, name := range speciesOrder {
		index[name] = i
	}

	matrix := make([][]float64, len(speciesOrder))
	for i := range matrix {
		matrix[i] = make([]float64, len(system.Reactions))
	}

	for j, reaction := range system.Reactions {
		for _, s := range reaction.Substrates {
			if i, ok := index[s.Species]; ok {
				matrix[i][j] -= s.Stoichiometry
			}
		}
		for _, p := range reaction.Products {
			if i, ok := index[p.Species]; ok {
				matrix[i][j] += p.Stoichiometry
			}
		}
	}
	return matrix
}
