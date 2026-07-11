/**
 * Undo/Redo History Management for ESM Editor
 *
 * Provides undo/redo functionality with debounced change capture and
 * keyboard shortcuts.
 *
 * Capture semantics: `capture()` snapshots the file state eagerly (at call
 * time) and pushes the snapshot onto the undo stack after the debounce
 * delay. Calls arriving while a capture is pending are coalesced — the
 * earliest snapshot wins — so a burst of edits becomes a single undo step
 * whose snapshot is the state before the burst. Callers that mutate state
 * (e.g. the AST store) should call `capture()` immediately BEFORE applying
 * a mutation so the pre-mutation state becomes the undo point.
 */

import { createSignal, onCleanup, untrack, type Accessor, type Setter } from 'solid-js'
import type { EsmFile } from '@earthsciml/ast'

/**
 * Configuration for undo history behavior
 */
export interface UndoHistoryConfig {
  /** Maximum number of history entries to keep */
  maxEntries?: number
  /** Debounce delay in milliseconds to avoid capturing every keystroke */
  debounceMs?: number
  /** Whether to automatically register keyboard shortcuts */
  registerKeyboardShortcuts?: boolean
}

/**
 * History entry representing a state snapshot
 */
export interface HistoryEntry {
  /** The ESM file state at this point */
  state: EsmFile
  /** Timestamp when this entry was created */
  timestamp: number
  /** Optional description of the change */
  description?: string
}

/**
 * Undo/redo history management interface
 */
export interface UndoHistory {
  /** Undo the last change */
  undo: () => void
  /** Redo the next change */
  redo: () => void
  /** Whether undo is available */
  canUndo: () => boolean
  /** Whether redo is available */
  canRedo: () => boolean
  /** Clear all history */
  clear: () => void
  /** Get current history length */
  historyLength: () => number
  /** Capture the current state as an undo point (debounced) */
  capture: (description?: string) => void
}

/**
 * Internal stack entry: a public {@link HistoryEntry} plus its serialized form,
 * computed once when the entry is created so change-detection and duplicate
 * skipping never re-stringify a full snapshot.
 */
interface StackEntry extends HistoryEntry {
  /** `JSON.stringify(state)`, cached at push time. */
  stateJson: string
}

/**
 * Deep clone an EsmFile to create an independent snapshot.
 * Works for both plain objects and Solid store proxies.
 */
function cloneEsmFile(file: EsmFile): EsmFile {
  return JSON.parse(JSON.stringify(file))
}

/**
 * Create undo/redo history management for an ESM file
 *
 * @param file - Reactive signal (or store accessor) for the current ESM file
 * @param setFile - Function to update the ESM file when restoring a snapshot
 * @param config - Optional configuration
 * @returns History management interface with undo/redo functions
 */
export function createUndoHistory(
  file: () => EsmFile,
  setFile: (newFile: EsmFile) => void,
  config: UndoHistoryConfig = {},
): UndoHistory {
  const {
    maxEntries = 100,
    debounceMs = 500,
    // Off by default: each instance would otherwise register its OWN global
    // document keydown listener, so two stores double-fire undo/redo and the
    // listener leaks when `createUndoHistory` runs outside a reactive root
    // (no `onCleanup` owner). Opt in per instance, or call
    // `createUndoKeyboardHandler` once at the app root.
    registerKeyboardShortcuts = false,
  } = config

  // History stacks (entries carry a cached `stateJson` — see StackEntry)
  const [undoStack, setUndoStack] = createSignal<StackEntry[]>([])
  const [redoStack, setRedoStack] = createSignal<StackEntry[]>([])

  // Track if we're currently applying a history change to avoid capturing it
  let isApplyingHistory = false
  let debounceTimeout: number | null = null
  // Snapshot waiting for its debounced push (earliest snapshot of the burst)
  let pendingEntry: { snapshot: EsmFile; description?: string } | null = null
  // Serialized form of the last state pushed, for O(1) change detection
  let lastCapturedJson: string | null = null

  /**
   * Push a snapshot onto the undo stack (skipping no-op captures) and
   * clear the redo stack.
   */
  function pushEntry(snapshot: EsmFile, description?: string) {
    // Serialize once; reuse for change-detection and for the entry's cache.
    const snapshotJson = JSON.stringify(snapshot)

    // Don't capture if the state hasn't actually changed since the last push
    if (lastCapturedJson !== null && snapshotJson === lastCapturedJson) {
      return
    }

    const entry: StackEntry = {
      state: snapshot,
      stateJson: snapshotJson,
      timestamp: Date.now(),
      description,
    }

    setUndoStack((prev) => {
      const newStack = [...prev, entry]
      // Maintain maximum stack size
      if (newStack.length > maxEntries) {
        newStack.splice(0, newStack.length - maxEntries)
      }
      return newStack
    })

    // Clear redo stack when new change is made
    setRedoStack([])

    lastCapturedJson = snapshotJson
  }

  /**
   * Immediately push any pending (debounced) capture.
   */
  function flushPending() {
    if (debounceTimeout !== null) {
      clearTimeout(debounceTimeout)
      debounceTimeout = null
    }
    if (pendingEntry) {
      const { snapshot, description } = pendingEntry
      pendingEntry = null
      pushEntry(snapshot, description)
    }
  }

  /**
   * Capture the current state as an undo point, with debouncing.
   * The snapshot is taken eagerly; the push is debounced. Coalesced calls
   * keep the earliest snapshot so a burst of edits is one undo step.
   */
  function captureState(description?: string) {
    if (isApplyingHistory) return

    const currentFile = untrack(() => file())
    if (!currentFile) return

    if (!pendingEntry) {
      pendingEntry = {
        snapshot: untrack(() => cloneEsmFile(currentFile)),
        description,
      }
    }

    // Debounce the push to avoid excessive history entries
    if (debounceTimeout !== null) {
      clearTimeout(debounceTimeout)
    }
    debounceTimeout = window.setTimeout(() => {
      debounceTimeout = null
      flushPending()
    }, debounceMs)
  }

  /**
   * Restore the newest state on `sourceStack` that differs from the current
   * file, saving the current state onto `destStack` first. Shared body for
   * undo (undo→redo) and redo (redo→undo), which are mirror images differing
   * only in the stacks involved and the saved entry's description.
   */
  function restoreFrom(
    sourceStack: Accessor<StackEntry[]>,
    setSourceStack: Setter<StackEntry[]>,
    setDestStack: Setter<StackEntry[]>,
    destDescription: string,
  ) {
    flushPending()

    const stack = sourceStack()
    const currentFile = untrack(() => file())
    if (!currentFile || stack.length === 0) return

    // Skip over entries identical to the current state (e.g. the capture of
    // the state we are currently in) so a single step visibly changes state.
    const currentJson = untrack(() => JSON.stringify(currentFile))
    let idx = stack.length - 1
    while (idx >= 0 && stack[idx].stateJson === currentJson) {
      idx--
    }
    if (idx < 0) return

    const targetEntry = stack[idx]

    // Save the current state onto the destination stack (reusing currentJson)
    setDestStack((prev) => [
      ...prev,
      {
        state: untrack(() => cloneEsmFile(currentFile)),
        stateJson: currentJson,
        timestamp: Date.now(),
        description: destDescription,
      },
    ])

    // Remove the restored entry (and any skipped duplicates) from the source
    setSourceStack(stack.slice(0, idx))

    // Apply the target state
    isApplyingHistory = true
    setFile(cloneEsmFile(targetEntry.state))
    isApplyingHistory = false

    // The next capture should always be pushed relative to the restored state
    lastCapturedJson = null
  }

  /**
   * Undo the last change
   */
  function undo() {
    restoreFrom(undoStack, setUndoStack, setRedoStack, 'Current state')
  }

  /**
   * Redo the next change
   */
  function redo() {
    restoreFrom(redoStack, setRedoStack, setUndoStack, 'Redo checkpoint')
  }

  /**
   * Check if undo is available
   */
  function canUndo(): boolean {
    return undoStack().length > 0
  }

  /**
   * Check if redo is available
   */
  function canRedo(): boolean {
    return redoStack().length > 0
  }

  /**
   * Clear all history
   */
  function clear() {
    // Cancel any pending debounced captures
    if (debounceTimeout !== null) {
      clearTimeout(debounceTimeout)
      debounceTimeout = null
    }
    pendingEntry = null

    setUndoStack([])
    setRedoStack([])
  }

  /**
   * Get current history length
   */
  function historyLength(): number {
    return undoStack().length + redoStack().length
  }

  // Capture the initial state so the first mutation can be undone.
  captureState('Initial state')

  // Register keyboard shortcuts only when explicitly opted in. Each call
  // installs its OWN document keydown listener bound to THIS history, so
  // enabling it on multiple instances double-fires; prefer a single call at
  // the app root. Off by default (see `registerKeyboardShortcuts`).
  if (registerKeyboardShortcuts && typeof window !== 'undefined') {
    createUndoKeyboardHandler(undo, redo, canUndo, canRedo)
  }

  onCleanup(() => {
    if (debounceTimeout !== null) {
      clearTimeout(debounceTimeout)
      debounceTimeout = null
    }
  })

  return {
    undo,
    redo,
    canUndo,
    canRedo,
    clear,
    historyLength,
    capture: captureState,
  }
}

/**
 * Keyboard shortcut handler for undo/redo (Ctrl/Cmd+Z, Ctrl/Cmd+Y,
 * Ctrl/Cmd+Shift+Z). This is the single keyboard-binding implementation —
 * `createUndoHistory` registers it when `registerKeyboardShortcuts` is on,
 * and it can also be used independently.
 */
export function createUndoKeyboardHandler(
  undoFn: () => void,
  redoFn: () => void,
  canUndo: () => boolean,
  canRedo: () => boolean,
) {
  const handleKeydown = (event: KeyboardEvent) => {
    if (event.ctrlKey || event.metaKey) {
      if (event.key === 'z' && !event.shiftKey && canUndo()) {
        event.preventDefault()
        undoFn()
      } else if ((event.key === 'y' || (event.key === 'z' && event.shiftKey)) && canRedo()) {
        event.preventDefault()
        redoFn()
      }
    }
  }

  if (typeof window !== 'undefined') {
    document.addEventListener('keydown', handleKeydown)

    onCleanup(() => {
      document.removeEventListener('keydown', handleKeydown)
    })
  }

  return handleKeydown
}
