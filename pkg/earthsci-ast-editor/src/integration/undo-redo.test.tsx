/**
 * Integration tests for undo/redo functionality across the full ESM editor
 *
 * These tests verify that undo/redo operations work correctly across:
 * - Multiple editor components simultaneously
 * - Complex nested operations
 * - State synchronization during history navigation
 */

import { describe, it, beforeEach, expect, vi } from 'vitest'
import { render, screen, fireEvent } from '@solidjs/testing-library'
import { createSignal, createEffect } from 'solid-js'
// Import components
import { ExpressionEditor } from '../components/ExpressionEditor'
import { ModelEditor } from '../components/ModelEditor'
import { EquationEditor } from '../components/EquationEditor'
import type { Expression, Model, Equation } from '@earthsciml/ast'

/**
 * Simple history management for integration testing
 */
interface HistoryState {
  model: Model
  selectedExpression?: Expression
  timestamp: number
}

class EditorHistory {
  private history: HistoryState[] = []
  private currentIndex = -1

  push(state: HistoryState) {
    // Remove any future history when adding new state
    this.history = this.history.slice(0, this.currentIndex + 1)
    this.history.push({ ...state, timestamp: Date.now() })
    this.currentIndex = this.history.length - 1
  }

  canUndo(): boolean {
    return this.currentIndex > 0
  }

  canRedo(): boolean {
    return this.currentIndex < this.history.length - 1
  }

  undo(): HistoryState | null {
    if (this.canUndo()) {
      this.currentIndex--
      return this.history[this.currentIndex]
    }
    return null
  }

  redo(): HistoryState | null {
    if (this.canRedo()) {
      this.currentIndex++
      return this.history[this.currentIndex]
    }
    return null
  }

  getCurrentState(): HistoryState | null {
    return this.currentIndex >= 0 ? this.history[this.currentIndex] : null
  }

  getHistoryLength(): number {
    return this.history.length
  }
}

describe('Undo/Redo Integration', () => {
  const initialModel: Model = {
    variables: {
      O3: {
        type: 'state',
        units: 'mol/mol',
        description: 'Ozone concentration',
      },
      NO: {
        type: 'state',
        units: 'mol/mol',
        description: 'Nitric oxide concentration',
      },
    },
    equations: [
      {
        lhs: { op: 'D', args: ['O3', 't'] },
        rhs: { op: '*', args: [-0.1, 'O3'] },
      },
      {
        lhs: { op: 'D', args: ['NO', 't'] },
        rhs: { op: '*', args: [0.05, 'NO'] },
      },
    ],
  }

  let history: EditorHistory

  beforeEach(() => {
    vi.clearAllMocks()
    history = new EditorHistory()
  })

  describe('Basic Undo/Redo Operations', () => {
    it('should track changes and support undo/redo', async () => {
      const [currentModel, setCurrentModel] = createSignal(initialModel)
      const [currentExpression, setCurrentExpression] = createSignal<Expression>({
        op: '+',
        args: [1, 2],
      })

      // Initialize history with initial state
      history.push({
        model: currentModel(),
        selectedExpression: currentExpression(),
        timestamp: Date.now(),
      })

      const handleModelChange = (newModel: Model) => {
        setCurrentModel(newModel)
        history.push({
          model: newModel,
          selectedExpression: currentExpression(),
          timestamp: Date.now(),
        })
      }

      const handleExpressionChange = (newExpr: Expression) => {
        setCurrentExpression(newExpr)
        history.push({
          model: currentModel(),
          selectedExpression: newExpr,
          timestamp: Date.now(),
        })
      }

      const handleUndo = () => {
        const previousState = history.undo()
        if (previousState) {
          setCurrentModel(previousState.model)
          if (previousState.selectedExpression) {
            setCurrentExpression(previousState.selectedExpression)
          }
        }
      }

      const handleRedo = () => {
        const nextState = history.redo()
        if (nextState) {
          setCurrentModel(nextState.model)
          if (nextState.selectedExpression) {
            setCurrentExpression(nextState.selectedExpression)
          }
        }
      }

      const { container } = render(() => (
        <div>
          <ModelEditor model={currentModel()} onModelChange={handleModelChange} />
          <ExpressionEditor
            initialExpression={currentExpression()}
            onChange={handleExpressionChange}
            readonly={false}
          />
          <div class="history-controls">
            <button onClick={handleUndo} disabled={!history.canUndo()} data-testid="undo-button">
              Undo
            </button>
            <button onClick={handleRedo} disabled={!history.canRedo()} data-testid="redo-button">
              Redo
            </button>
            <span data-testid="history-length">{history.getHistoryLength()}</span>
          </div>
        </div>
      ))

      // Initial state should be rendered
      expect(screen.getByText('O3')).toBeInTheDocument()
      expect(container.querySelector('.esm-infix-op[data-operator="+"]')).toBeInTheDocument()
      expect(screen.getByTestId('history-length')).toHaveTextContent('1')

      // Undo should be disabled initially
      expect(screen.getByTestId('undo-button')).toBeDisabled()
      expect(screen.getByTestId('redo-button')).toBeDisabled()

      // Simulate a change to create history
      const newExpression: Expression = { op: '*', args: [3, 4] }
      handleExpressionChange(newExpression)

      // History should have grown
      expect(history.getHistoryLength()).toBe(2)
      expect(history.canUndo()).toBe(true)

      // Test undo
      handleUndo()
      expect(currentExpression()).toEqual({ op: '+', args: [1, 2] })
      expect(history.canRedo()).toBe(true)

      // Test redo
      handleRedo()
      expect(currentExpression()).toEqual({ op: '*', args: [3, 4] })
    })

    it('should handle complex multi-component state changes', async () => {
      const [editorState, setEditorState] = createSignal({
        model: initialModel,
        selectedEquationIndex: 0,
        editingExpression: null as Expression | null,
      })

      // Track complete editor state in history
      history.push({
        model: editorState().model,
        selectedExpression: editorState().editingExpression || undefined,
        timestamp: Date.now(),
      })

      const updateEditorState = (updates: Partial<ReturnType<typeof editorState>>) => {
        const newState = { ...editorState(), ...updates }
        setEditorState(newState)
        history.push({
          model: newState.model,
          selectedExpression: newState.editingExpression || undefined,
          timestamp: Date.now(),
        })
      }

      const handleUndo = () => {
        const previousState = history.undo()
        if (previousState) {
          setEditorState({
            model: previousState.model,
            selectedEquationIndex: 0,
            editingExpression: previousState.selectedExpression || null,
          })
        }
      }

      render(() => (
        <div>
          <ModelEditor
            model={editorState().model}
            onModelChange={(newModel) => updateEditorState({ model: newModel })}
          />

          {editorState().model.equations[editorState().selectedEquationIndex] && (
            <EquationEditor
              equation={editorState().model.equations[editorState().selectedEquationIndex]}
              onEquationChange={(newEquation: Equation) => {
                const updatedModel = { ...editorState().model }
                updatedModel.equations = [...updatedModel.equations]
                updatedModel.equations[editorState().selectedEquationIndex] = newEquation
                updateEditorState({ model: updatedModel })
              }}
            />
          )}

          <button onClick={handleUndo} data-testid="complex-undo">
            Undo
          </button>
          <div data-testid="equation-count">{editorState().model.equations.length}</div>
        </div>
      ))

      // Verify initial state
      expect(screen.getByText('O3')).toBeInTheDocument()
      expect(screen.getByTestId('equation-count')).toHaveTextContent('2')

      // Simulate complex state change
      const modifiedModel: Model = {
        ...editorState().model,
        variables: {
          ...editorState().model.variables,
          CO2: {
            type: 'state',
            units: 'mol/mol',
            description: 'Carbon dioxide',
          },
        },
      }

      updateEditorState({ model: modifiedModel })

      // Verify change was applied
      expect(history.getHistoryLength()).toBe(2)

      // Test undo of complex change
      fireEvent.click(screen.getByTestId('complex-undo'))
      expect(editorState().model.variables).not.toHaveProperty('CO2')
    })
  })

  describe('History State Validation', () => {
    it('should maintain consistent state during rapid changes', async () => {
      const [model, setModel] = createSignal(initialModel)
      const changeLog: string[] = []

      const trackChange = (type: string, detail: unknown) => {
        changeLog.push(`${type}:${JSON.stringify(detail).substring(0, 50)}`)
      }

      // Initialize history
      history.push({
        model: model(),
        timestamp: Date.now(),
      })

      const applyChange = (newModel: Model, changeType: string) => {
        setModel(newModel)
        trackChange(changeType, { variableCount: Object.keys(newModel.variables).length })
        history.push({
          model: newModel,
          timestamp: Date.now(),
        })
      }

      render(() => (
        <div>
          <ModelEditor
            model={model()}
            onModelChange={(newModel) => applyChange(newModel, 'model-edit')}
          />
          <div data-testid="change-log">{changeLog.join(', ')}</div>
          <div data-testid="history-size">{history.getHistoryLength()}</div>
        </div>
      ))

      // Apply rapid changes
      for (let i = 0; i < 5; i++) {
        const newModel: Model = {
          ...model(),
          variables: {
            ...model().variables,
            [`Variable_${i}`]: {
              type: 'state',
              units: 'units',
              description: `Generated variable ${i}`,
            },
          },
        }
        applyChange(newModel, `rapid-change-${i}`)
      }

      // Verify history grew correctly
      expect(history.getHistoryLength()).toBe(6) // initial + 5 changes

      // Verify all changes were tracked
      expect(changeLog).toHaveLength(5)

      // Test multiple undos
      history.undo() // Should work
      history.undo() // Should work
      const previousState = history.undo() // Should work

      expect(previousState).toBeTruthy()
      expect(history.canUndo()).toBe(true) // Should still be able to undo more
    })

    it('should handle edge cases in history navigation', async () => {
      const [state, setState] = createSignal(initialModel)

      // Don't add initial state to history for this test

      const handleChange = (newModel: Model) => {
        setState(newModel)
        history.push({
          model: newModel,
          timestamp: Date.now(),
        })
      }

      render(() => (
        <div>
          <ModelEditor model={state()} onModelChange={handleChange} />
        </div>
      ))

      // Initially should not be able to undo or redo (empty history)
      expect(history.canUndo()).toBe(false)
      expect(history.canRedo()).toBe(false)

      // Add one state to history
      handleChange(initialModel)
      expect(history.canUndo()).toBe(false) // Still can't undo (only one state)
      expect(history.canRedo()).toBe(false)

      // Add second state
      const modifiedModel: Model = {
        ...initialModel,
        variables: {
          ...initialModel.variables,
          TEST: { type: 'state', units: 'test', description: 'Test variable' },
        },
      }
      handleChange(modifiedModel)

      expect(history.canUndo()).toBe(true) // Now can undo
      expect(history.canRedo()).toBe(false)

      // Test undo
      const undoResult = history.undo()
      expect(undoResult).toBeTruthy()
      expect(history.canUndo()).toBe(false)
      expect(history.canRedo()).toBe(true)

      // Test redo
      const redoResult = history.redo()
      expect(redoResult).toBeTruthy()
      expect(history.canUndo()).toBe(true)
      expect(history.canRedo()).toBe(false)
    })
  })

  describe('Cross-Component State Consistency', () => {
    it('should maintain referential consistency during undo/redo', async () => {
      const [appState, setAppState] = createSignal({
        model: initialModel,
        selectedVariable: 'O3' as string,
        editingEquation: 0,
      })

      // Track complete application state
      history.push({
        model: appState().model,
        timestamp: Date.now(),
      })

      const stateUpdateCount = createSignal(0)

      // Effect to track state updates
      createEffect(() => {
        appState()
        stateUpdateCount[1]((prev) => prev + 1)
      })

      const updateAppState = (updates: Partial<ReturnType<typeof appState>>) => {
        const newState = { ...appState(), ...updates }
        setAppState(newState)
        history.push({
          model: newState.model,
          timestamp: Date.now(),
        })
      }

      const performUndo = () => {
        const previousState = history.undo()
        if (previousState) {
          setAppState((current) => ({
            ...current,
            model: previousState.model,
          }))
        }
      }

      render(() => (
        <div>
          <ModelEditor
            model={appState().model}
            onModelChange={(newModel) => updateAppState({ model: newModel })}
          />

          <ExpressionEditor
            initialExpression={appState().model.equations[appState().editingEquation]?.rhs || 0}
            onChange={(newExpr) => {
              const newModel = { ...appState().model, equations: [...appState().model.equations] }
              if (newModel.equations[appState().editingEquation]) {
                newModel.equations[appState().editingEquation] = {
                  ...newModel.equations[appState().editingEquation],
                  rhs: newExpr,
                }
                updateAppState({ model: newModel })
              }
            }}
            readonly={false}
            highlightedVars={new Set([appState().selectedVariable])}
          />

          <button onClick={performUndo} data-testid="consistency-undo">
            Undo
          </button>
          <div data-testid="selected-var">{appState().selectedVariable}</div>
          <div data-testid="update-count">{stateUpdateCount[0]()}</div>
        </div>
      ))

      // Verify initial state consistency ('O3' appears in both the variables
      // panel and the selected-var indicator)
      expect(screen.getByTestId('selected-var')).toHaveTextContent('O3')
      expect(screen.getAllByText('O3').length).toBeGreaterThan(0)

      // Make a change that affects both editors
      const newModel: Model = {
        ...appState().model,
        variables: {
          ...appState().model.variables,
          O3: {
            ...appState().model.variables.O3,
            description: 'Updated ozone concentration',
          },
        },
      }

      updateAppState({ model: newModel })

      // Verify change was applied
      expect(history.getHistoryLength()).toBe(2)

      // Perform undo and verify consistency
      fireEvent.click(screen.getByTestId('consistency-undo'))

      // State should be consistent after undo
      expect(appState().selectedVariable).toBe('O3') // Selected variable unchanged
      expect(appState().model.variables.O3.description).toBe('Ozone concentration') // Description reverted
    })
  })
})
