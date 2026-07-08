/**
 * AST Store - Central reactive state management for ESM files
 *
 * Provides a SolidJS store wrapper around EsmFile with path-based updates,
 * integrated undo/redo functionality, and centralized state that all
 * components can share.
 *
 * Undo integration: every mutation that flows through the store's setters
 * (`setFile`, `setPath`, `updatePath`) captures the pre-mutation state as a
 * debounced undo point. Undo/redo restore snapshots with `reconcile`, so
 * keys added after a snapshot are correctly removed on undo.
 */

import { createStore, produce, reconcile, unwrap, Store, SetStoreFunction } from 'solid-js/store';
import { createSignal } from 'solid-js';
import type { EsmFile } from '@earthsciml/ast';
import { createUndoHistory, type UndoHistory, type UndoHistoryConfig } from './history.js';
import { getValueAtPath, PathUtils, type Path, type PathSegment } from './path-utils.js';

export { PathUtils, type Path, type PathSegment };

/**
 * Configuration for the AST store
 */
export interface AstStoreConfig {
  /** Initial ESM file data */
  initialFile?: EsmFile;
  /** Configuration for undo/redo history */
  historyConfig?: UndoHistoryConfig;
  /** Whether to enable automatic validation */
  enableValidation?: boolean;
}

/**
 * AST Store interface providing centralized ESM file management
 */
export interface AstStore {
  /** Reactive ESM file store */
  file: Store<EsmFile>;
  /** Function to update the store (captures an undo point per mutation) */
  setFile: SetStoreFunction<EsmFile>;
  /** Get value at a specific path */
  getPath: (path: Path) => any;
  /** Set value at a specific path */
  setPath: (path: Path, value: any) => void;
  /** Update value at a specific path using a function */
  updatePath: <T>(path: Path, updateFn: (current: T) => T) => void;
  /** Undo/redo history management */
  history: UndoHistory;
  /** Current validation state */
  isValid: () => boolean;
  /** Current validation errors */
  validationErrors: () => string[];
}

/**
 * Default empty ESM file structure
 */
function createDefaultEsmFile(): EsmFile {
  return {
    esm: "0.8.0",
    schema_version: "1.0",
    metadata: {
      name: "Untitled Model",
      description: "A new ESM model",
      authors: [],
      created: new Date().toISOString(),
      modified: new Date().toISOString()
    },
    components: {},
    coupling: []
  };
}

/**
 * Basic validation for ESM file structure
 */
function validateEsmFile(file: EsmFile): { isValid: boolean; errors: string[] } {
  const errors: string[] = [];

  if (!file.schema_version) {
    errors.push("Missing schema_version");
  }

  if (!file.metadata) {
    errors.push("Missing metadata");
  } else {
    if (!file.metadata.name) {
      errors.push("Missing metadata.name");
    }
  }

  if (!file.components) {
    errors.push("Missing components");
  }

  if (!Array.isArray(file.coupling)) {
    errors.push("coupling must be an array");
  }

  return {
    isValid: errors.length === 0,
    errors
  };
}

/**
 * Create a centralized AST store for ESM file management
 *
 * @param config - Configuration options
 * @returns AST store interface with reactive state and path-based updates
 */
export function createAstStore(config: AstStoreConfig = {}): AstStore {
  const {
    initialFile = createDefaultEsmFile(),
    historyConfig = {},
    enableValidation = true
  } = config;

  // Create the main store
  const [file, setFileRaw] = createStore<EsmFile>(initialFile);

  // Create validation signals
  const [validationState, setValidationState] = createSignal(
    enableValidation ? validateEsmFile(initialFile) : { isValid: true, errors: [] }
  );

  function revalidate(): void {
    if (enableValidation) {
      setValidationState(validateEsmFile(unwrap(file)));
    }
  }

  // Create undo/redo history. Snapshots are restored with `reconcile` so
  // properties added after the snapshot are removed on undo (a plain merging
  // store set would leave them behind).
  const history = createUndoHistory(
    () => file,
    (newFile: EsmFile) => {
      setFileRaw(reconcile(newFile));
      revalidate();
    },
    historyConfig
  );

  /**
   * Store setter that records the pre-mutation state as an undo point,
   * then applies the mutation and refreshes validation.
   */
  const setFile: SetStoreFunction<EsmFile> = ((...args: unknown[]) => {
    history.capture();
    (setFileRaw as (...a: unknown[]) => void)(...args);
    revalidate();
  }) as SetStoreFunction<EsmFile>;

  /**
   * Get value at a specific path in the file
   */
  function getPath(path: Path): any {
    return getValueAtPath(file, path);
  }

  /**
   * Set value at a specific path in the file
   */
  function setPath(path: Path, value: any): void {
    if (path.length === 0) {
      // Replacing the whole file: use reconcile so removed keys are dropped
      history.capture();
      setFileRaw(reconcile(value));
      revalidate();
      return;
    }

    // Setting nested path (setFile captures the undo point)
    setFile(
      produce(draft => {
        let current: any = draft;
        for (let i = 0; i < path.length - 1; i++) {
          const segment = path[i];
          if (current[segment] == null) {
            // Create intermediate objects/arrays as needed
            const nextSegment = path[i + 1];
            current[segment] = typeof nextSegment === 'number' ? [] : {};
          }
          current = current[segment];
        }
        current[path[path.length - 1]] = value;
      })
    );
  }

  /**
   * Update value at a specific path using a function
   */
  function updatePath<T>(path: Path, updateFn: (current: T) => T): void {
    const currentValue = getPath(path);
    const newValue = updateFn(currentValue);
    setPath(path, newValue);
  }

  /**
   * Get current validation status
   */
  function isValid(): boolean {
    return validationState().isValid;
  }

  /**
   * Get current validation errors
   */
  function validationErrors(): string[] {
    return validationState().errors;
  }

  return {
    file,
    setFile,
    getPath,
    setPath,
    updatePath,
    history,
    isValid,
    validationErrors
  };
}

/**
 * Common path patterns for ESM file structures
 */
export const CommonPaths = {
  metadata: (): Path => ['metadata'],
  metadataName: (): Path => ['metadata', 'name'],
  metadataDescription: (): Path => ['metadata', 'description'],
  components: (): Path => ['components'],
  component: (name: string): Path => ['components', name],
  componentType: (name: string): Path => ['components', name, 'type'],
  coupling: (): Path => ['coupling'],
  couplingEntry: (index: number): Path => ['coupling', index],

  // Model-specific paths
  modelVariables: (componentName: string): Path => ['components', componentName, 'variables'],
  modelVariable: (componentName: string, varName: string): Path => ['components', componentName, 'variables', varName],
  modelEquations: (componentName: string): Path => ['components', componentName, 'equations'],
  modelEquation: (componentName: string, index: number): Path => ['components', componentName, 'equations', index],

  // Reaction system paths
  reactionSpecies: (componentName: string): Path => ['components', componentName, 'species'],
  reactionSpeciesEntry: (componentName: string, speciesName: string): Path => ['components', componentName, 'species', speciesName],
  reactions: (componentName: string): Path => ['components', componentName, 'reactions'],
  reaction: (componentName: string, index: number): Path => ['components', componentName, 'reactions', index]
};
