/**
 * AST Store - Central reactive state management for ESM files
 *
 * Provides a SolidJS store wrapper around EsmFile with path-based updates,
 * integrated undo/redo functionality, and centralized state that all
 * components can share.
 */

import { createStore, produce, Store, SetStoreFunction } from 'solid-js/store';
import { createSignal, createMemo } from 'solid-js';
import type { EsmFile } from 'earthsci-toolkit';
import { createUndoHistory, type UndoHistory, type UndoHistoryConfig } from './history.js';

/**
 * Path segment for navigating nested structures
 */
export type PathSegment = string | number;

/**
 * Path for addressing nested properties in the ESM file
 */
export type Path = PathSegment[];

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
  /** Function to update the store */
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
 * Navigate to a path in an object and return the value
 */
function getValueAtPath(obj: any, path: Path): any {
  if (path.length === 0) return obj;

  let current = obj;
  for (const segment of path) {
    if (current == null) return undefined;
    current = current[segment];
  }
  return current;
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
  const [file, setFile] = createStore<EsmFile>(initialFile);

  // Create validation signals
  const [validationState, setValidationState] = createSignal(
    enableValidation ? validateEsmFile(initialFile) : { isValid: true, errors: [] }
  );

  // Create undo/redo history
  const fileSignal = createMemo(() => file);
  const history = createUndoHistory(
    fileSignal,
    (newFile: EsmFile) => {
      setFile(newFile);
      if (enableValidation) {
        setValidationState(validateEsmFile(newFile));
      }
    },
    historyConfig
  );

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
      // Setting root file
      setFile(value);
    } else {
      // Setting nested path
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

    // Update validation if enabled
    if (enableValidation) {
      setValidationState(validateEsmFile(file));
    }
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
 * Utility functions for common path operations
 */
export const PathUtils = {
  /**
   * Convert a dot-separated string to a path array
   */
  fromString: (pathString: string): Path => {
    return pathString.split('.').filter(segment => segment.length > 0);
  },

  /**
   * Convert a path array to a dot-separated string
   */
  toString: (path: Path): string => {
    return path.join('.');
  },

  /**
   * Check if two paths are equal
   */
  equals: (path1: Path, path2: Path): boolean => {
    if (path1.length !== path2.length) return false;
    return path1.every((segment, i) => segment === path2[i]);
  },

  /**
   * Check if path1 is a parent of path2
   */
  isParent: (parent: Path, child: Path): boolean => {
    if (parent.length >= child.length) return false;
    return parent.every((segment, i) => segment === child[i]);
  },

  /**
   * Get the parent path (all segments except the last)
   */
  parent: (path: Path): Path => {
    return path.slice(0, -1);
  },

  /**
   * Get the last segment of a path
   */
  lastSegment: (path: Path): PathSegment | undefined => {
    return path[path.length - 1];
  },

  /**
   * Append a segment to a path
   */
  append: (path: Path, segment: PathSegment): Path => {
    return [...path, segment];
  }
};

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