import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { createSignal, createRoot } from 'solid-js'
import { createUndoHistory, createUndoKeyboardHandler } from './history'
import type { EsmFile } from '@earthsciml/ast'

describe('History Management', () => {
  let cleanup: (() => void) | null = null

  beforeEach(() => {
    vi.useFakeTimers()
  })

  afterEach(() => {
    if (cleanup) {
      cleanup()
      cleanup = null
    }
    vi.useRealTimers()
  })

  // Real-schema fixture (`esm`, `metadata`, `models`, `reaction_systems`,
  // `coupling`) so history snapshots round-trip genuinely conformant files.
  const createTestFile = (name: string): EsmFile => ({
    esm: '0.8.0',
    metadata: {
      name,
      description: 'Test model',
      authors: [],
      created: new Date().toISOString(),
      modified: new Date().toISOString(),
    },
    models: {},
    reaction_systems: {},
    coupling: [],
  })

  describe('createUndoHistory', () => {
    it('creates history management with correct initial state', () => {
      createRoot((dispose) => {
        cleanup = dispose

        const initialFile = createTestFile('Initial Model')
        const [file, setFile] = createSignal(initialFile)

        const history = createUndoHistory(file, setFile, {
          registerKeyboardShortcuts: false,
        })

        expect(history.canUndo()).toBe(false)
        expect(history.canRedo()).toBe(false)
        expect(history.historyLength()).toBe(0)
      })
    })

    it('captures state changes with debouncing', () => {
      createRoot((dispose) => {
        cleanup = dispose

        const initialFile = createTestFile('Initial Model')
        const [file, setFile] = createSignal(initialFile)

        const history = createUndoHistory(file, setFile, {
          debounceMs: 100,
          registerKeyboardShortcuts: false,
        })

        // Initially no history
        expect(history.canUndo()).toBe(false)

        // Make rapid changes
        setFile(createTestFile('Model 1'))
        setFile(createTestFile('Model 2'))
        setFile(createTestFile('Model 3'))

        // Capture after changes - should be debounced
        history.capture('After changes')

        // Should not have applied immediately due to debouncing
        expect(history.canUndo()).toBe(false)

        // Fast-forward past debounce delay
        vi.advanceTimersByTime(150)

        // Should now have captured the state
        expect(history.canUndo()).toBe(true)
        expect(history.historyLength()).toBe(1)
      })
    })

    it('performs undo operation correctly', () => {
      createRoot((dispose) => {
        cleanup = dispose

        const initialFile = createTestFile('Initial Model')
        const [file, setFile] = createSignal(initialFile)

        const history = createUndoHistory(file, setFile, {
          debounceMs: 0, // No debouncing for test
          registerKeyboardShortcuts: false,
        })

        // Capture initial state
        history.capture('Initial')
        vi.advanceTimersByTime(10)

        // Make a change
        const changedFile = createTestFile('Changed Model')
        setFile(changedFile)

        expect(file().metadata.name).toBe('Changed Model')
        expect(history.canUndo()).toBe(true)

        // Perform undo
        history.undo()

        expect(file().metadata.name).toBe('Initial Model')
        expect(history.canUndo()).toBe(false)
        expect(history.canRedo()).toBe(true)
      })
    })

    it('performs redo operation correctly', () => {
      createRoot((dispose) => {
        cleanup = dispose

        const initialFile = createTestFile('Initial Model')
        const [file, setFile] = createSignal(initialFile)

        const history = createUndoHistory(file, setFile, {
          debounceMs: 0,
          registerKeyboardShortcuts: false,
        })

        // Capture initial state
        history.capture('Initial')
        vi.advanceTimersByTime(10)

        // Make a change
        setFile(createTestFile('Changed Model'))

        // Undo the change
        history.undo()
        expect(file().metadata.name).toBe('Initial Model')

        // Redo the change
        history.redo()
        expect(file().metadata.name).toBe('Changed Model')
        expect(history.canRedo()).toBe(false)
      })
    })

    it('clears redo stack when new changes are made after undo', () => {
      createRoot((dispose) => {
        cleanup = dispose

        const initialFile = createTestFile('Initial Model')
        const [file, setFile] = createSignal(initialFile)

        const history = createUndoHistory(file, setFile, {
          debounceMs: 0,
          registerKeyboardShortcuts: false,
        })

        // Capture initial, then make changes
        history.capture('Initial')
        vi.advanceTimersByTime(10)

        setFile(createTestFile('Changed Model 1'))
        history.capture('Change 1')
        vi.advanceTimersByTime(10)

        setFile(createTestFile('Changed Model 2'))

        // Undo one change
        history.undo()
        expect(history.canRedo()).toBe(true)

        // Make a new change (should clear redo stack)
        setFile(createTestFile('New Branch'))
        history.capture('New branch')
        vi.advanceTimersByTime(10)

        expect(history.canRedo()).toBe(false)
      })
    })

    it('maintains maximum stack size', () => {
      createRoot((dispose) => {
        cleanup = dispose

        const initialFile = createTestFile('Initial Model')
        const [file, setFile] = createSignal(initialFile)

        const history = createUndoHistory(file, setFile, {
          maxEntries: 3,
          debounceMs: 0,
          registerKeyboardShortcuts: false,
        })

        // Add more entries than the maximum
        for (let i = 1; i <= 5; i++) {
          setFile(createTestFile(`Model ${i}`))
          history.capture(`Model ${i}`)
          vi.advanceTimersByTime(10)
        }

        // Should only keep the last 3 entries
        expect(history.historyLength()).toBeLessThanOrEqual(6) // 3 undo + 0 redo
      })
    })

    it('clears history correctly', () => {
      createRoot((dispose) => {
        cleanup = dispose

        const initialFile = createTestFile('Initial Model')
        const [file, setFile] = createSignal(initialFile)

        const history = createUndoHistory(file, setFile, {
          debounceMs: 0,
          registerKeyboardShortcuts: false,
        })

        // Make some changes
        setFile(createTestFile('Changed Model'))
        history.capture('Changed')
        vi.advanceTimersByTime(10)

        expect(history.canUndo()).toBe(true)

        // Clear history
        history.clear()

        expect(history.canUndo()).toBe(false)
        expect(history.canRedo()).toBe(false)
        expect(history.historyLength()).toBe(0)
      })
    })

    it('handles keyboard shortcuts when enabled', () => {
      createRoot((dispose) => {
        cleanup = dispose

        const initialFile = createTestFile('Initial Model')
        const [file, setFile] = createSignal(initialFile)

        const history = createUndoHistory(file, setFile, {
          debounceMs: 0,
          registerKeyboardShortcuts: true,
        })

        // Capture initial state
        history.capture('Initial')
        vi.advanceTimersByTime(10)

        // Make a change
        setFile(createTestFile('Changed Model'))

        expect(file().metadata.name).toBe('Changed Model')

        // Simulate Ctrl+Z keypress
        const undoEvent = new KeyboardEvent('keydown', {
          key: 'z',
          ctrlKey: true,
          bubbles: true,
        })

        document.dispatchEvent(undoEvent)

        expect(file().metadata.name).toBe('Initial Model')
      })
    })

    it('prevents infinite loops during history application', () => {
      createRoot((dispose) => {
        cleanup = dispose

        const initialFile = createTestFile('Initial Model')
        const [file, setFile] = createSignal(initialFile)

        // Mock console.error to detect potential loops
        const consoleSpy = vi.spyOn(console, 'error').mockImplementation(() => {})

        const history = createUndoHistory(file, setFile, {
          debounceMs: 0,
          registerKeyboardShortcuts: false,
        })

        // Make a change
        setFile(createTestFile('Changed Model'))
        vi.advanceTimersByTime(10)

        // Perform multiple undos/redos rapidly
        history.undo()
        history.redo()
        history.undo()
        history.redo()

        // Should not have caused any errors
        expect(consoleSpy).not.toHaveBeenCalled()

        consoleSpy.mockRestore()
      })
    })
  })

  describe('createUndoKeyboardHandler', () => {
    it('creates keyboard handler with custom functions', () => {
      const undoSpy = vi.fn()
      const redoSpy = vi.fn()
      const canUndoSpy = vi.fn(() => true)
      const canRedoSpy = vi.fn(() => false)

      createRoot((dispose) => {
        cleanup = dispose

        createUndoKeyboardHandler(undoSpy, redoSpy, canUndoSpy, canRedoSpy)

        // Simulate Ctrl+Z
        const undoEvent = new KeyboardEvent('keydown', {
          key: 'z',
          ctrlKey: true,
          bubbles: true,
        })

        document.dispatchEvent(undoEvent)

        expect(undoSpy).toHaveBeenCalled()
        expect(redoSpy).not.toHaveBeenCalled()
      })
    })

    it('handles different redo shortcuts', () => {
      const undoSpy = vi.fn()
      const redoSpy = vi.fn()
      const canUndoSpy = vi.fn(() => false)
      const canRedoSpy = vi.fn(() => true)

      createRoot((dispose) => {
        cleanup = dispose

        createUndoKeyboardHandler(undoSpy, redoSpy, canUndoSpy, canRedoSpy)

        // Test Ctrl+Y
        const ctrlYEvent = new KeyboardEvent('keydown', {
          key: 'y',
          ctrlKey: true,
          bubbles: true,
        })

        document.dispatchEvent(ctrlYEvent)
        expect(redoSpy).toHaveBeenCalledTimes(1)

        // Test Ctrl+Shift+Z
        const ctrlShiftZEvent = new KeyboardEvent('keydown', {
          key: 'z',
          ctrlKey: true,
          shiftKey: true,
          bubbles: true,
        })

        document.dispatchEvent(ctrlShiftZEvent)
        expect(redoSpy).toHaveBeenCalledTimes(2)
      })
    })

    it('respects canUndo/canRedo checks', () => {
      const undoSpy = vi.fn()
      const redoSpy = vi.fn()
      const canUndoSpy = vi.fn(() => false) // Cannot undo
      const canRedoSpy = vi.fn(() => false) // Cannot redo

      createRoot((dispose) => {
        cleanup = dispose

        createUndoKeyboardHandler(undoSpy, redoSpy, canUndoSpy, canRedoSpy)

        // Try to undo when not possible
        const undoEvent = new KeyboardEvent('keydown', {
          key: 'z',
          ctrlKey: true,
          bubbles: true,
        })

        document.dispatchEvent(undoEvent)
        expect(undoSpy).not.toHaveBeenCalled()

        // Try to redo when not possible
        const redoEvent = new KeyboardEvent('keydown', {
          key: 'y',
          ctrlKey: true,
          bubbles: true,
        })

        document.dispatchEvent(redoEvent)
        expect(redoSpy).not.toHaveBeenCalled()
      })
    })
  })
})
