/**
 * Variable hover highlighting with equivalence classes
 *
 * This module provides variable highlighting functionality for the esm-editor,
 * including equivalence class building from coupling rules using union-find,
 * and scoped reference normalization for different highlighting modes.
 */

import { createContext, useContext, createSignal, createMemo, Accessor, Setter } from 'solid-js';
import type { EsmFile, CouplingEntry } from 'earthsci-toolkit';

// Types for the highlighting context
export interface HighlightContextValue {
  /** Currently hovered variable */
  hoveredVar: Accessor<string | null>;
  /** Set the currently hovered variable */
  setHoveredVar: Setter<string | null>;
  /** All variables equivalent to the hovered variable */
  highlightedVars: Accessor<Set<string>>;
  /** Variable equivalence classes */
  equivalences: Accessor<Map<string, Set<string>>>;
}

export type ScopingMode = 'equation' | 'model' | 'file';

// Union-Find data structure for building equivalence classes
class UnionFind {
  private parent: Map<string, string> = new Map();
  private rank: Map<string, number> = new Map();

  // Make a new set with the given variable
  makeSet(variable: string): void {
    if (!this.parent.has(variable)) {
      this.parent.set(variable, variable);
      this.rank.set(variable, 0);
    }
  }

  // Find the root of the set containing the variable
  find(variable: string): string {
    if (!this.parent.has(variable)) {
      this.makeSet(variable);
    }

    const parent = this.parent.get(variable)!;
    if (parent !== variable) {
      // Path compression
      const root = this.find(parent);
      this.parent.set(variable, root);
      return root;
    }
    return variable;
  }

  // Union two sets by rank
  union(var1: string, var2: string): void {
    const root1 = this.find(var1);
    const root2 = this.find(var2);

    if (root1 === root2) return;

    const rank1 = this.rank.get(root1) || 0;
    const rank2 = this.rank.get(root2) || 0;

    if (rank1 < rank2) {
      this.parent.set(root1, root2);
    } else if (rank1 > rank2) {
      this.parent.set(root2, root1);
    } else {
      this.parent.set(root2, root1);
      this.rank.set(root1, rank1 + 1);
    }
  }

  // Get all variables in the same equivalence class
  getEquivalenceClass(variable: string): Set<string> {
    const root = this.find(variable);
    const equivalentVars = new Set<string>();

    // Find all variables with the same root
    for (const var_ of this.parent.keys()) {
      if (this.find(var_) === root) {
        equivalentVars.add(var_);
      }
    }

    return equivalentVars;
  }

  // Get all equivalence classes
  getAllEquivalenceClasses(): Map<string, Set<string>> {
    const classes = new Map<string, Set<string>>();

    for (const variable of this.parent.keys()) {
      const root = this.find(variable);
      if (!classes.has(root)) {
        classes.set(root, this.getEquivalenceClass(variable));
      }
    }

    return classes;
  }
}

/**
 * Build variable equivalence classes from coupling rules using union-find
 */
export function buildVarEquivalences(file: EsmFile): Map<string, Set<string>> {
  const unionFind = new UnionFind();

  // Process all coupling entries
  if (file.coupling) {
    for (const coupling of file.coupling) {
      processCouplingEntry(coupling, unionFind);
    }
  }

  return unionFind.getAllEquivalenceClasses();
}

/**
 * Process a single coupling entry to build equivalence relationships
 */
function processCouplingEntry(coupling: CouplingEntry, unionFind: UnionFind): void {
  switch (coupling.type) {
    case 'variable_map':
      // variable_map entries merge from↔to
      unionFind.union(coupling.from, coupling.to);
      break;

    case 'operator_compose':
      // operator_compose translate entries merge mapped variables
      if (coupling.translate) {
        for (const [fromVar, toTarget] of Object.entries(coupling.translate)) {
          const toVar = typeof toTarget === 'string' ? toTarget : toTarget.var;
          unionFind.union(fromVar, toVar);
        }
      }
      break;

    case 'couple':
      // Process connector equations for equivalence
      if (coupling.connector?.equations) {
        for (const equation of coupling.connector.equations) {
          // Couple connectors create equivalence relationships
          unionFind.union(equation.from, equation.to);
        }
      }
      break;

    // Other coupling types don't create variable equivalences
    case 'callback':
    case 'event':
      break;
  }
}

/**
 * Normalize a scoped reference for the given context
 *
 * Handles cases like:
 * - 'O3' in SimpleOzone context -> 'SimpleOzone.O3'
 * - 'SimpleOzone.O3' in any context -> 'SimpleOzone.O3'
 * - Both should be recognized as the same variable
 */
export function normalizeScopedReference(
  varName: string,
  currentModelContext?: string,
  scopingMode: ScopingMode = 'model'
): string[] {
  const normalized: string[] = [];

  // For equation mode, only return the literal name
  if (scopingMode === 'equation') {
    normalized.push(varName);
    return normalized;
  }

  // Always add the literal reference
  normalized.push(varName);

  // If it doesn't contain a dot and we have model context, add scoped version
  if (!varName.includes('.') && currentModelContext && scopingMode !== 'file') {
    normalized.push(`${currentModelContext}.${varName}`);
  }

  // For file mode, we can add additional equivalences based on all models
  // This would require the file structure to determine all possible scoped references

  return normalized;
}

// Context for the highlight system
const HighlightContext = createContext<HighlightContextValue>();

/**
 * Provider component props
 */
export interface HighlightProviderProps {
  children: any;
  file: EsmFile;
  currentModelContext?: string;
  scopingMode?: ScopingMode;
}

/**
 * Create and provide the highlight context
 */
export function HighlightProvider(props: HighlightProviderProps) {
  // Hovered variable signal
  const [hoveredVar, setHoveredVar] = createSignal<string | null>(null);

  // Build equivalences from the file (memoized)
  const equivalences = createMemo(() => buildVarEquivalences(props.file));

  // Get highlighted variables based on the hovered variable
  const highlightedVars = createMemo(() => {
    const hovered = hoveredVar();
    if (!hovered) return new Set<string>();

    const equiv = equivalences();
    const scopingMode = props.scopingMode || 'model';

    // Normalize the hovered variable reference
    const normalizedRefs = normalizeScopedReference(
      hovered,
      props.currentModelContext,
      scopingMode
    );

    // Find all equivalent variables for any normalized reference
    const allEquivalent = new Set<string>();
    for (const ref of normalizedRefs) {
      for (const [, equivalentSet] of equiv.entries()) {
        if (equivalentSet.has(ref)) {
          // Add all variables in this equivalence class
          for (const equivalent of equivalentSet) {
            // Apply scoping mode filtering
            if (shouldIncludeInHighlighting(equivalent, hovered, scopingMode, props.currentModelContext)) {
              allEquivalent.add(equivalent);
            }
          }
          break;
        }
      }
    }

    // Also add the original hovered variable and its normalized versions
    for (const ref of normalizedRefs) {
      if (shouldIncludeInHighlighting(ref, hovered, scopingMode, props.currentModelContext)) {
        allEquivalent.add(ref);
      }
    }

    return allEquivalent;
  });

  const contextValue: HighlightContextValue = {
    hoveredVar,
    setHoveredVar,
    highlightedVars,
    equivalences,
  };

  return (
    <HighlightContext.Provider value={contextValue}>
      {props.children}
    </HighlightContext.Provider>
  );
}

/**
 * Hook to access the highlight context
 */
export function useHighlightContext(): HighlightContextValue {
  const context = useContext(HighlightContext);
  if (!context) {
    throw new Error('useHighlightContext must be used within a HighlightProvider');
  }
  return context;
}

/**
 * Determine if a variable should be included in highlighting based on scoping mode
 *
 * Note: This function is called for variables that are already known to be equivalent.
 * The scoping mode affects which equivalent variables to include in the highlighting.
 */
function shouldIncludeInHighlighting(
  variable: string,
  hoveredVariable: string,
  scopingMode: ScopingMode,
  _currentModelContext?: string
): boolean {
  switch (scopingMode) {
    case 'equation':
      // Only highlight exact literal matches within the current equation
      return variable === hoveredVariable;

    case 'model':
      // In model mode, include all equivalent variables regardless of their model context
      // The scoping only affects the initial normalization, but equivalent variables
      // from other models should still be highlighted to show coupling relationships
      return true;

    case 'file':
      // Highlight across all models with equivalence resolution
      return true;
  }
}

/**
 * Utility function to check if a variable is highlighted (O(1) lookup)
 */
export function isHighlighted(variable: string, highlightedVars: Set<string>): boolean {
  return highlightedVars.has(variable);
}

/**
 * Create a highlight context with default settings
 * Convenience function for simple use cases
 */
export function createHighlightContext(
  file: EsmFile,
  currentModelContext?: string,
  scopingMode: ScopingMode = 'model'
) {
  const [hoveredVar, setHoveredVar] = createSignal<string | null>(null);
  const equivalences = createMemo(() => buildVarEquivalences(file));

  const highlightedVars = createMemo(() => {
    const hovered = hoveredVar();
    if (!hovered) return new Set<string>();

    const equiv = equivalences();
    const normalizedRefs = normalizeScopedReference(hovered, currentModelContext, scopingMode);
    const allEquivalent = new Set<string>();

    for (const ref of normalizedRefs) {
      for (const [, equivalentSet] of equiv.entries()) {
        if (equivalentSet.has(ref)) {
          for (const equivalent of equivalentSet) {
            if (shouldIncludeInHighlighting(equivalent, hovered, scopingMode, currentModelContext)) {
              allEquivalent.add(equivalent);
            }
          }
          break;
        }
      }
    }

    for (const ref of normalizedRefs) {
      if (shouldIncludeInHighlighting(ref, hovered, scopingMode, currentModelContext)) {
        allEquivalent.add(ref);
      }
    }

    return allEquivalent;
  });

  return {
    hoveredVar,
    setHoveredVar,
    highlightedVars,
    equivalences,
  };
}