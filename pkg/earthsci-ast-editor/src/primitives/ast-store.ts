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

import type { Store, SetStoreFunction } from 'solid-js/store'
import { createStore, produce, reconcile, unwrap } from 'solid-js/store'
import { createSignal } from 'solid-js'
import { validate } from '@earthsciml/ast'
import type { EsmFile } from '@earthsciml/ast'
import { createUndoHistory, type UndoHistory, type UndoHistoryConfig } from './history.js'
import { getValueAtPath, PathUtils, type Path, type PathSegment } from './path-utils.js'

export { PathUtils, type Path, type PathSegment }

/**
 * Configuration for the AST store
 */
export interface AstStoreConfig {
  /** Initial ESM file data */
  initialFile?: EsmFile
  /** Configuration for undo/redo history */
  historyConfig?: UndoHistoryConfig
  /** Whether to enable automatic validation */
  enableValidation?: boolean
}

/**
 * AST Store interface providing centralized ESM file management
 */
export interface AstStore {
  /** Reactive ESM file store */
  file: Store<EsmFile>
  /** Function to update the store (captures an undo point per mutation) */
  setFile: SetStoreFunction<EsmFile>
  /** Get value at a specific path */
  getPath: (path: Path) => unknown
  /** Set value at a specific path */
  setPath: (path: Path, value: unknown) => void
  /** Update value at a specific path using a function */
  updatePath: <T>(path: Path, updateFn: (current: T) => T) => void
  /** Undo/redo history management */
  history: UndoHistory
  /** Current validation state */
  isValid: () => boolean
  /** Current validation errors */
  validationErrors: () => string[]
}

/**
 * Default empty ESM file structure.
 *
 * Shaped against the REAL ESM schema (`esm`, `metadata`, `models`,
 * `reaction_systems`, `coupling`) — a document with only `metadata` fails the
 * schema (it requires at least one component collection), so the empty
 * `models`/`reaction_systems` maps are load-bearing for validity.
 */
function createDefaultEsmFile(): EsmFile {
  const now = new Date().toISOString()
  return {
    esm: '0.8.0',
    metadata: {
      name: 'Untitled Model',
      description: 'A new ESM model',
      authors: [],
      created: now,
      modified: now,
    },
    models: {},
    reaction_systems: {},
    coupling: [],
  }
}

/**
 * Validate an ESM file, flattened to the `{ isValid, errors }` shape the store
 * surfaces via `isValid()` / `validationErrors()`.
 *
 * Delegates to the core `validate` from @earthsciml/ast (schema + structural
 * checks against the real format) instead of hand-rolling field checks against
 * a fictional schema, so genuinely conformant files are reported valid.
 */
function validateEsmFile(file: EsmFile): { isValid: boolean; errors: string[] } {
  try {
    const result = validate(file)
    const errors = [...(result.schema_errors ?? []), ...(result.structural_errors ?? [])].map(
      (e) => e.message,
    )
    return { isValid: result.is_valid, errors }
  } catch (error: unknown) {
    const message = error instanceof Error ? error.message : String(error)
    return { isValid: false, errors: [`Validation error: ${message}`] }
  }
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
    enableValidation = true,
  } = config

  // Create the main store
  const [file, setFileRaw] = createStore<EsmFile>(initialFile)

  // Create validation signals
  const [validationState, setValidationState] = createSignal(
    enableValidation ? validateEsmFile(initialFile) : { isValid: true, errors: [] },
  )

  function revalidate(): void {
    if (enableValidation) {
      setValidationState(validateEsmFile(unwrap(file)))
    }
  }

  // Create undo/redo history. Snapshots are restored with `reconcile` so
  // properties added after the snapshot are removed on undo (a plain merging
  // store set would leave them behind).
  const history = createUndoHistory(
    () => file,
    (newFile: EsmFile) => {
      setFileRaw(reconcile(newFile))
      revalidate()
    },
    historyConfig,
  )

  /**
   * Store setter that records the pre-mutation state as an undo point,
   * then applies the mutation and refreshes validation.
   */
  const setFile: SetStoreFunction<EsmFile> = ((...args: unknown[]) => {
    history.capture()
    ;(setFileRaw as (...a: unknown[]) => void)(...args)
    revalidate()
  }) as SetStoreFunction<EsmFile>

  /**
   * Get value at a specific path in the file
   */
  function getPath(path: Path): unknown {
    return getValueAtPath(file, path)
  }

  /**
   * Set value at a specific path in the file
   */
  function setPath(path: Path, value: unknown): void {
    if (path.length === 0) {
      // Replacing the whole file: use reconcile so removed keys are dropped
      history.capture()
      setFileRaw(reconcile(value as EsmFile))
      revalidate()
      return
    }

    // Setting nested path (setFile captures the undo point)
    setFile(
      produce((draft) => {
        let current: any = draft
        for (let i = 0; i < path.length - 1; i++) {
          const segment = path[i]
          if (current[segment] == null) {
            // Create intermediate objects/arrays as needed
            const nextSegment = path[i + 1]
            current[segment] = typeof nextSegment === 'number' ? [] : {}
          }
          current = current[segment]
        }
        current[path[path.length - 1]] = value
      }),
    )
  }

  /**
   * Update value at a specific path using a function
   */
  function updatePath<T>(path: Path, updateFn: (current: T) => T): void {
    const currentValue = getPath(path) as T
    const newValue = updateFn(currentValue)
    setPath(path, newValue)
  }

  /**
   * Get current validation status
   */
  function isValid(): boolean {
    return validationState().isValid
  }

  /**
   * Get current validation errors
   */
  function validationErrors(): string[] {
    return validationState().errors
  }

  return {
    file,
    setFile,
    getPath,
    setPath,
    updatePath,
    history,
    isValid,
    validationErrors,
  }
}

/**
 * Common path patterns for ESM file structures.
 *
 * Built from the REAL top-level keys — `models` and `reaction_systems`
 * (keyed by component name) — not the fictional `components` map, so these
 * paths resolve against genuinely conformant files.
 */
export const CommonPaths = {
  // Metadata
  metadata: (): Path => ['metadata'],
  metadataName: (): Path => ['metadata', 'name'],
  metadataDescription: (): Path => ['metadata', 'description'],

  // Models (each entry is a Model keyed by name under the real `models` key)
  models: (): Path => ['models'],
  model: (modelName: string): Path => ['models', modelName],
  modelVariables: (modelName: string): Path => ['models', modelName, 'variables'],
  modelVariable: (modelName: string, varName: string): Path => [
    'models',
    modelName,
    'variables',
    varName,
  ],
  modelEquations: (modelName: string): Path => ['models', modelName, 'equations'],
  modelEquation: (modelName: string, index: number): Path => [
    'models',
    modelName,
    'equations',
    index,
  ],

  // Reaction systems (keyed by name under the real `reaction_systems` key)
  reactionSystems: (): Path => ['reaction_systems'],
  reactionSystem: (systemName: string): Path => ['reaction_systems', systemName],
  reactionSpecies: (systemName: string): Path => ['reaction_systems', systemName, 'species'],
  reactionSpeciesEntry: (systemName: string, speciesName: string): Path => [
    'reaction_systems',
    systemName,
    'species',
    speciesName,
  ],
  reactions: (systemName: string): Path => ['reaction_systems', systemName, 'reactions'],
  reaction: (systemName: string, index: number): Path => [
    'reaction_systems',
    systemName,
    'reactions',
    index,
  ],

  // Coupling
  coupling: (): Path => ['coupling'],
  couplingEntry: (index: number): Path => ['coupling', index],
}
