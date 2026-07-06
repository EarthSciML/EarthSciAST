/**
 * Tests for variable hover highlighting with equivalence classes
 */

import { describe, it, expect } from 'vitest';
import { createRoot } from 'solid-js';
import {
  buildVarEquivalences,
  normalizeScopedReference,
  createHighlightContext,
  isHighlighted
} from './highlighted-var';
import type { EsmFile, CouplingEntry } from 'earthsci-toolkit';

// Helper to create a minimal ESM file
function createEsmFile(coupling: CouplingEntry[] = []): EsmFile {
  return {
    esm: "0.8.0",
    metadata: {
      name: "test-file"
    },
    coupling
  } as EsmFile;
}

describe('buildVarEquivalences', () => {
  it('should handle empty coupling list', () => {
    const file = createEsmFile([]);
    const equivalences = buildVarEquivalences(file);

    // Should return an empty map
    expect(equivalences.size).toBe(0);
  });

  it('should build equivalences from variable_map couplings', () => {
    const couplings: CouplingEntry[] = [
      {
        type: 'variable_map',
        from: 'MeteoData.temperature',
        to: 'Chemistry.temperature',
        transform: 'identity'
      }
    ];

    const file = createEsmFile(couplings);
    const equivalences = buildVarEquivalences(file);

    // Should create one equivalence class with both variables
    expect(equivalences.size).toBe(1);

    // Find the equivalence class containing one of the variables
    let foundClass: Set<string> | undefined;
    for (const [, eqClass] of equivalences) {
      if (eqClass.has('MeteoData.temperature')) {
        foundClass = eqClass;
        break;
      }
    }

    expect(foundClass).toBeDefined();
    expect(foundClass!.has('MeteoData.temperature')).toBe(true);
    expect(foundClass!.has('Chemistry.temperature')).toBe(true);
    expect(foundClass!.size).toBe(2);
  });

  it('should build equivalences from operator_compose couplings', () => {
    const couplings: CouplingEntry[] = [
      {
        type: 'operator_compose',
        systems: ['Chemistry', 'Transport'],
        translate: {
          'Chemistry.O3': 'Transport.O3',
          'Chemistry.NO': { var: 'Transport.NO', factor: 1.0 }
        }
      }
    ];

    const file = createEsmFile(couplings);
    const equivalences = buildVarEquivalences(file);

    // Should create two equivalence classes
    expect(equivalences.size).toBe(2);

    // Check O3 equivalence
    let o3Class: Set<string> | undefined;
    for (const [, eqClass] of equivalences) {
      if (eqClass.has('Chemistry.O3')) {
        o3Class = eqClass;
        break;
      }
    }

    expect(o3Class).toBeDefined();
    expect(o3Class!.has('Chemistry.O3')).toBe(true);
    expect(o3Class!.has('Transport.O3')).toBe(true);

    // Check NO equivalence
    let noClass: Set<string> | undefined;
    for (const [, eqClass] of equivalences) {
      if (eqClass.has('Chemistry.NO')) {
        noClass = eqClass;
        break;
      }
    }

    expect(noClass).toBeDefined();
    expect(noClass!.has('Chemistry.NO')).toBe(true);
    expect(noClass!.has('Transport.NO')).toBe(true);
  });

  it('should build equivalences from couple couplings', () => {
    const couplings: CouplingEntry[] = [
      {
        type: 'couple',
        systems: ['Chemistry', 'Surface'],
        connector: {
          equations: [
            {
              from: 'Chemistry.deposition_flux',
              to: 'Chemistry.O3',
              transform: 'additive'
            }
          ]
        }
      }
    ];

    const file = createEsmFile(couplings);
    const equivalences = buildVarEquivalences(file);

    // Should create one equivalence class
    expect(equivalences.size).toBe(1);

    let foundClass: Set<string> | undefined;
    for (const [, eqClass] of equivalences) {
      if (eqClass.has('Chemistry.deposition_flux')) {
        foundClass = eqClass;
        break;
      }
    }

    expect(foundClass).toBeDefined();
    expect(foundClass!.has('Chemistry.deposition_flux')).toBe(true);
    expect(foundClass!.has('Chemistry.O3')).toBe(true);
  });

  it('should handle transitive equivalences', () => {
    const couplings: CouplingEntry[] = [
      {
        type: 'variable_map',
        from: 'A',
        to: 'B',
        transform: 'identity'
      },
      {
        type: 'variable_map',
        from: 'B',
        to: 'C',
        transform: 'identity'
      }
    ];

    const file = createEsmFile(couplings);
    const equivalences = buildVarEquivalences(file);

    // Should create one equivalence class with all three variables
    expect(equivalences.size).toBe(1);

    const equivalenceClass = Array.from(equivalences.values())[0];
    expect(equivalenceClass.has('A')).toBe(true);
    expect(equivalenceClass.has('B')).toBe(true);
    expect(equivalenceClass.has('C')).toBe(true);
    expect(equivalenceClass.size).toBe(3);
  });
});

describe('normalizeScopedReference', () => {
  it('should return literal name for equation mode', () => {
    const normalized = normalizeScopedReference('O3', 'Chemistry', 'equation');
    expect(normalized).toEqual(['O3']);
  });

  it('should add scoped reference in model mode', () => {
    const normalized = normalizeScopedReference('O3', 'Chemistry', 'model');
    expect(normalized).toContain('O3');
    expect(normalized).toContain('Chemistry.O3');
    expect(normalized.length).toBe(2);
  });

  it('should not add scoped reference if already scoped', () => {
    const normalized = normalizeScopedReference('Chemistry.O3', 'Chemistry', 'model');
    expect(normalized).toEqual(['Chemistry.O3']);
  });

  it('should handle file mode', () => {
    const normalized = normalizeScopedReference('O3', 'Chemistry', 'file');
    expect(normalized).toContain('O3');
    // In file mode, we could add more equivalences but for now just the literal
  });

  it('should handle no model context', () => {
    const normalized = normalizeScopedReference('O3', undefined, 'model');
    expect(normalized).toEqual(['O3']);
  });
});

describe('createHighlightContext', () => {
  it('should create working highlight context', () => {
    createRoot(() => {
      const couplings: CouplingEntry[] = [
        {
          type: 'variable_map',
          from: 'A',
          to: 'B',
          transform: 'identity'
        }
      ];

      const file = createEsmFile(couplings);
      const context = createHighlightContext(file, 'TestModel', 'model');

      // Initially no variables should be highlighted
      expect(context.hoveredVar()).toBeNull();
      expect(context.highlightedVars().size).toBe(0);

      // Hover over variable A
      context.setHoveredVar('A');
      expect(context.hoveredVar()).toBe('A');

      // Should highlight both A and B (equivalents)
      const highlighted = context.highlightedVars();
      expect(highlighted.has('A')).toBe(true);
      expect(highlighted.has('B')).toBe(true);

      // Clear hover
      context.setHoveredVar(null);
      expect(context.highlightedVars().size).toBe(0);
    });
  });

  it('should respect scoping modes', () => {
    createRoot(() => {
      const file = createEsmFile([]);

      // Test equation mode - should only highlight exact matches
      const eqContext = createHighlightContext(file, 'Chemistry', 'equation');
      eqContext.setHoveredVar('O3');

      const eqHighlighted = eqContext.highlightedVars();
      expect(eqHighlighted.has('O3')).toBe(true);
      expect(eqHighlighted.size).toBe(1); // Only exact match

      // Test model mode - should add scoped reference
      const modelContext = createHighlightContext(file, 'Chemistry', 'model');
      modelContext.setHoveredVar('O3');

      const modelHighlighted = modelContext.highlightedVars();
      expect(modelHighlighted.has('O3')).toBe(true);
      expect(modelHighlighted.has('Chemistry.O3')).toBe(true);
    });
  });
});

describe('isHighlighted', () => {
  it('should return true for highlighted variables', () => {
    const highlightedVars = new Set(['A', 'B', 'Chemistry.O3']);

    expect(isHighlighted('A', highlightedVars)).toBe(true);
    expect(isHighlighted('B', highlightedVars)).toBe(true);
    expect(isHighlighted('Chemistry.O3', highlightedVars)).toBe(true);
    expect(isHighlighted('C', highlightedVars)).toBe(false);
  });

  it('should return false for non-highlighted variables', () => {
    const highlightedVars = new Set<string>();

    expect(isHighlighted('A', highlightedVars)).toBe(false);
    expect(isHighlighted('B', highlightedVars)).toBe(false);
  });
});

describe('complex equivalence scenarios', () => {
  it('should handle multiple coupling types creating complex equivalences', () => {
    const couplings: CouplingEntry[] = [
      // Variable map A -> B
      {
        type: 'variable_map',
        from: 'ModelA.var1',
        to: 'ModelB.var1',
        transform: 'identity'
      },
      // Operator compose linking B -> C
      {
        type: 'operator_compose',
        systems: ['ModelB', 'ModelC'],
        translate: {
          'ModelB.var1': 'ModelC.var1'
        }
      },
      // Couple linking C -> D
      {
        type: 'couple',
        systems: ['ModelC', 'ModelD'],
        connector: {
          equations: [
            {
              from: 'ModelC.var1',
              to: 'ModelD.var1',
              transform: 'additive'
            }
          ]
        }
      }
    ];

    const file = createEsmFile(couplings);
    const equivalences = buildVarEquivalences(file);

    // Should create one large equivalence class with all four variables
    expect(equivalences.size).toBe(1);

    const equivalenceClass = Array.from(equivalences.values())[0];
    expect(equivalenceClass.has('ModelA.var1')).toBe(true);
    expect(equivalenceClass.has('ModelB.var1')).toBe(true);
    expect(equivalenceClass.has('ModelC.var1')).toBe(true);
    expect(equivalenceClass.has('ModelD.var1')).toBe(true);
    expect(equivalenceClass.size).toBe(4);
  });

  it('should handle scoped reference normalization with equivalences', () => {
    createRoot(() => {
      const couplings: CouplingEntry[] = [
        {
          type: 'variable_map',
          from: 'Chemistry.O3',
          to: 'Transport.O3',
          transform: 'identity'
        }
      ];

      const file = createEsmFile(couplings);
      const context = createHighlightContext(file, 'Chemistry', 'model');

      // Hover over unscoped 'O3' in Chemistry context
      context.setHoveredVar('O3');

      const highlighted = context.highlightedVars();

      // Should highlight:
      // - 'O3' (literal)
      // - 'Chemistry.O3' (scoped version)
      // - 'Transport.O3' (equivalent from coupling)
      expect(highlighted.has('O3')).toBe(true);
      expect(highlighted.has('Chemistry.O3')).toBe(true);
      expect(highlighted.has('Transport.O3')).toBe(true);
    });
  });
});