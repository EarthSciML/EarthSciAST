import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { createRoot } from 'solid-js';
import { createAstStore, PathUtils, CommonPaths } from './ast-store';
import type { EsmFile } from '@earthsciml/ast';

describe('AST Store', () => {
  let cleanup: (() => void) | null = null;

  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    if (cleanup) {
      cleanup();
      cleanup = null;
    }
    vi.useRealTimers();
  });
  // Fixture shaped against the REAL ESM schema (`esm`, `metadata`, `models`,
  // `reaction_systems`, `coupling`) — and structurally valid, so it exercises
  // the store's core-backed validation as a genuinely conformant file.
  const createTestFile = (name: string = "Test Model"): EsmFile => ({
    esm: "0.8.0",
    metadata: {
      name,
      description: "Test model",
      authors: [],
      created: new Date().toISOString(),
      modified: new Date().toISOString()
    },
    models: {
      "Chemistry": {
        variables: {
          "O3": {
            type: "state",
            units: "mol/mol",
            description: "Ozone concentration"
          },
          "k1": {
            type: "parameter",
            units: "1/s",
            default: 0.001,
            description: "Ozone loss rate constant"
          }
        },
        equations: [
          {
            lhs: { op: "D", args: ["O3"], wrt: "t" },
            rhs: { op: "*", args: [{ op: "-", args: ["k1"] }, "O3"] }
          }
        ]
      }
    },
    reaction_systems: {},
    coupling: []
  });

  describe('createAstStore', () => {
    it('creates store with default ESM file', () => {
      createRoot((dispose) => {
        cleanup = dispose;
        const store = createAstStore();

        expect(store.file.esm).toBe("0.8.0");
        expect(store.file.metadata.name).toBe("Untitled Model");
        expect(store.file.models).toEqual({});
        expect(store.file.reaction_systems).toEqual({});
        expect(store.file.coupling).toEqual([]);
        expect(store.isValid()).toBe(true);
      });
    });

    it('creates store with initial file', () => {
      createRoot((dispose) => {
        const initialFile = createTestFile("My Model");
        const store = createAstStore({ initialFile });

        expect(store.file.metadata.name).toBe("My Model");
        expect(store.file.models).toHaveProperty("Chemistry");

        dispose();
      });
    });

    it('gets values at specified paths', () => {
      createRoot((dispose) => {
        const store = createAstStore({ initialFile: createTestFile() });

        expect(store.getPath(['metadata', 'name'])).toBe("Test Model");
        expect(store.getPath(['esm'])).toBe("0.8.0");
        expect(store.getPath(['models', 'Chemistry', 'variables', 'O3', 'type'])).toBe("state");
        expect(store.getPath(['nonexistent'])).toBeUndefined();

        dispose();
      });
    });

    it('sets values at specified paths', () => {
      createRoot((dispose) => {
        const store = createAstStore({ initialFile: createTestFile() });

        // Set existing property
        store.setPath(['metadata', 'name'], "Updated Model");
        expect(store.file.metadata.name).toBe("Updated Model");

        // Set nested property
        store.setPath(['models', 'Chemistry', 'variables', 'O3', 'description'], "Updated ozone");
        expect((store.file.models as any).Chemistry.variables.O3.description).toBe("Updated ozone");

        // Set new property
        store.setPath(['models', 'NewModel'], { variables: {}, equations: [] });
        expect(store.file.models).toHaveProperty("NewModel");
        expect((store.file.models as any).NewModel.equations).toEqual([]);

        dispose();
      });
    });

    it('updates values using update functions', () => {
      createRoot((dispose) => {
        const store = createAstStore({ initialFile: createTestFile() });

        // Update string value
        store.updatePath(['metadata', 'name'], (current: string) => current + " v2");
        expect(store.file.metadata.name).toBe("Test Model v2");

        // Update object value
        store.updatePath(['metadata'], (current: any) => ({
          ...current,
          description: "Updated description"
        }));
        expect(store.file.metadata.description).toBe("Updated description");

        dispose();
      });
    });

    it('creates intermediate objects when setting nested paths', () => {
      createRoot((dispose) => {
        const store = createAstStore();

        // Set deeply nested path that doesn't exist
        store.setPath(['models', 'NewModel', 'variables', 'CO2'], {
          type: "state",
          units: "ppmv"
        });

        expect(store.file.models).toHaveProperty("NewModel");
        expect((store.file.models as any).NewModel).toHaveProperty("variables");
        expect((store.file.models as any).NewModel.variables).toHaveProperty("CO2");
        expect((store.file.models as any).NewModel.variables.CO2.units).toBe("ppmv");

        dispose();
      });
    });

    it('integrates with undo/redo history', () => {
      createRoot((dispose) => {
        cleanup = dispose;
        const store = createAstStore({
          initialFile: createTestFile(),
          historyConfig: { debounceMs: 0, registerKeyboardShortcuts: false }
        });

        const originalName = store.file.metadata.name;

        // Capture initial state
        store.history.capture("Initial");
        vi.advanceTimersByTime(10);

        // Make a change
        store.setPath(['metadata', 'name'], "Changed Name");
        expect(store.file.metadata.name).toBe("Changed Name");

        // Undo the change
        store.history.undo();
        expect(store.file.metadata.name).toBe(originalName);
      });
    });

    it('automatically captures setPath mutations so they are undoable', () => {
      createRoot((dispose) => {
        cleanup = dispose;
        const store = createAstStore({
          initialFile: createTestFile(),
          historyConfig: { debounceMs: 50, registerKeyboardShortcuts: false }
        });

        const originalName = store.file.metadata.name;

        // No manual capture: the setter itself must record the undo point
        store.setPath(['metadata', 'name'], "Changed Name");
        expect(store.file.metadata.name).toBe("Changed Name");

        // Let the debounced capture land
        vi.advanceTimersByTime(100);
        expect(store.history.canUndo()).toBe(true);

        store.history.undo();
        expect(store.file.metadata.name).toBe(originalName);

        // And redo restores the mutation
        store.history.redo();
        expect(store.file.metadata.name).toBe("Changed Name");
      });
    });

    it('coalesces a burst of mutations into a single undo step', () => {
      createRoot((dispose) => {
        cleanup = dispose;
        const store = createAstStore({
          initialFile: createTestFile(),
          historyConfig: { debounceMs: 50, registerKeyboardShortcuts: false }
        });

        const originalName = store.file.metadata.name;

        store.setPath(['metadata', 'name'], "Name 1");
        store.setPath(['metadata', 'name'], "Name 2");
        store.setPath(['metadata', 'name'], "Name 3");
        vi.advanceTimersByTime(100);

        // One undo returns to the pre-burst state
        store.history.undo();
        expect(store.file.metadata.name).toBe(originalName);
      });
    });

    it('undo removes keys added after the snapshot', () => {
      createRoot((dispose) => {
        cleanup = dispose;
        const store = createAstStore({
          initialFile: createTestFile(),
          historyConfig: { debounceMs: 0, registerKeyboardShortcuts: false }
        });

        expect(store.file.models).not.toHaveProperty("NewModel");

        // Add a new key after the initial snapshot
        store.setPath(['models', 'NewModel'], { variables: {}, equations: [] });
        expect(store.file.models).toHaveProperty("NewModel");
        vi.advanceTimersByTime(10);

        // Undo must remove the added key (requires reconcile-based restore;
        // Solid's default merging setter would leave the key behind)
        store.history.undo();
        expect(store.file.models).not.toHaveProperty("NewModel");
        expect((store.file.models as any).NewModel).toBeUndefined();
        expect(store.file.models).toHaveProperty("Chemistry");
      });
    });

    it('validates ESM file structure', () => {
      createRoot((dispose) => {
        // Valid file
        const validStore = createAstStore({
          initialFile: createTestFile(),
          enableValidation: true
        });
        expect(validStore.isValid()).toBe(true);
        expect(validStore.validationErrors()).toHaveLength(0);

        // Invalid file missing metadata — the core schema requires `metadata`
        const invalidFile = { ...createTestFile() };
        delete (invalidFile as any).metadata;

        const invalidStore = createAstStore({
          initialFile: invalidFile as EsmFile,
          enableValidation: true
        });
        expect(invalidStore.isValid()).toBe(false);
        expect(invalidStore.validationErrors().some(e => e.includes("metadata"))).toBe(true);

        dispose();
      });
    });

    it('updates validation state when file changes', () => {
      createRoot((dispose) => {
        const store = createAstStore({
          initialFile: createTestFile(),
          enableValidation: true
        });

        expect(store.isValid()).toBe(true);

        // Make file invalid by nulling a required field
        store.setPath(['metadata'], null);
        expect(store.isValid()).toBe(false);
        expect(store.validationErrors().length).toBeGreaterThan(0);

        dispose();
      });
    });
  });

  describe('PathUtils', () => {
    it('converts strings to paths', () => {
      expect(PathUtils.fromString('metadata.name')).toEqual(['metadata', 'name']);
      expect(PathUtils.fromString('components.Chemistry.variables')).toEqual(['components', 'Chemistry', 'variables']);
      expect(PathUtils.fromString('')).toEqual([]);
      expect(PathUtils.fromString('single')).toEqual(['single']);
    });

    it('converts paths to strings', () => {
      expect(PathUtils.toString(['metadata', 'name'])).toBe('metadata.name');
      expect(PathUtils.toString(['components', 'Chemistry', 'variables'])).toBe('components.Chemistry.variables');
      expect(PathUtils.toString([])).toBe('');
      expect(PathUtils.toString(['single'])).toBe('single');
    });

    it('checks path equality', () => {
      expect(PathUtils.equals(['a', 'b'], ['a', 'b'])).toBe(true);
      expect(PathUtils.equals(['a', 'b'], ['a', 'c'])).toBe(false);
      expect(PathUtils.equals(['a'], ['a', 'b'])).toBe(false);
      expect(PathUtils.equals([], [])).toBe(true);
    });

    it('checks parent-child relationships', () => {
      expect(PathUtils.isParent(['a'], ['a', 'b'])).toBe(true);
      expect(PathUtils.isParent(['a', 'b'], ['a', 'b', 'c'])).toBe(true);
      expect(PathUtils.isParent(['a', 'b'], ['a', 'b'])).toBe(false); // Same path, not parent
      expect(PathUtils.isParent(['a', 'b'], ['a'])).toBe(false); // Child shorter than parent
      expect(PathUtils.isParent(['a', 'b'], ['x', 'b', 'c'])).toBe(false); // Different paths
    });

    it('gets parent paths', () => {
      expect(PathUtils.parent(['a', 'b', 'c'])).toEqual(['a', 'b']);
      expect(PathUtils.parent(['a'])).toEqual([]);
      expect(PathUtils.parent([])).toEqual([]);
    });

    it('gets last segment', () => {
      expect(PathUtils.lastSegment(['a', 'b', 'c'])).toBe('c');
      expect(PathUtils.lastSegment(['single'])).toBe('single');
      expect(PathUtils.lastSegment([])).toBeUndefined();
    });

    it('appends segments', () => {
      expect(PathUtils.append(['a', 'b'], 'c')).toEqual(['a', 'b', 'c']);
      expect(PathUtils.append([], 'first')).toEqual(['first']);
      expect(PathUtils.append(['a'], 0)).toEqual(['a', 0]);
    });
  });

  describe('CommonPaths', () => {
    it('provides metadata paths', () => {
      expect(CommonPaths.metadata()).toEqual(['metadata']);
      expect(CommonPaths.metadataName()).toEqual(['metadata', 'name']);
      expect(CommonPaths.metadataDescription()).toEqual(['metadata', 'description']);
    });

    it('provides model paths', () => {
      expect(CommonPaths.models()).toEqual(['models']);
      expect(CommonPaths.model('Chemistry')).toEqual(['models', 'Chemistry']);
      expect(CommonPaths.modelVariables('Chemistry')).toEqual(['models', 'Chemistry', 'variables']);
      expect(CommonPaths.modelVariable('Chemistry', 'O3')).toEqual(['models', 'Chemistry', 'variables', 'O3']);
      expect(CommonPaths.modelEquations('Chemistry')).toEqual(['models', 'Chemistry', 'equations']);
      expect(CommonPaths.modelEquation('Chemistry', 2)).toEqual(['models', 'Chemistry', 'equations', 2]);
    });

    it('provides reaction system paths', () => {
      expect(CommonPaths.reactionSystems()).toEqual(['reaction_systems']);
      expect(CommonPaths.reactionSystem('Reactions')).toEqual(['reaction_systems', 'Reactions']);
      expect(CommonPaths.reactionSpecies('Reactions')).toEqual(['reaction_systems', 'Reactions', 'species']);
      expect(CommonPaths.reactionSpeciesEntry('Reactions', 'O3')).toEqual(['reaction_systems', 'Reactions', 'species', 'O3']);
      expect(CommonPaths.reactions('Reactions')).toEqual(['reaction_systems', 'Reactions', 'reactions']);
      expect(CommonPaths.reaction('Reactions', 0)).toEqual(['reaction_systems', 'Reactions', 'reactions', 0]);
    });

    it('provides coupling paths', () => {
      expect(CommonPaths.coupling()).toEqual(['coupling']);
      expect(CommonPaths.couplingEntry(0)).toEqual(['coupling', 0]);
      expect(CommonPaths.couplingEntry(5)).toEqual(['coupling', 5]);
    });
  });
});