import { describe, it, expect, vi } from 'vitest'
import { render, screen, fireEvent } from '@solidjs/testing-library'
import type { Component } from 'solid-js'
import { createSignal } from 'solid-js'
import {
  SelectionProvider,
  useSelectionContext,
  createSelectionContext,
  getVariableSuggestions,
} from './selection'
// Path helpers now have a single canonical source (path-utils); selection no
// longer re-exports them.
import { pathsEqual, pathToString, stringToPath } from './path-utils'
import type { Expression, EsmFile } from '@earthsciml/ast'

describe('Selection primitives', () => {
  describe('Helper functions', () => {
    it('pathsEqual compares paths correctly', () => {
      expect(pathsEqual(['args', 0], ['args', 0])).toBe(true)
      expect(pathsEqual(['args', 0], ['args', 1])).toBe(false)
      expect(pathsEqual(['args'], ['args', 0])).toBe(false)
      expect(pathsEqual([], [])).toBe(true)
    })

    it('pathToString converts paths to strings', () => {
      expect(pathToString(['args', 0])).toBe('args.0')
      expect(pathToString(['args', 0, 'args', 1])).toBe('args.0.args.1')
      expect(pathToString([])).toBe('')
    })

    it('stringToPath converts strings to paths', () => {
      expect(stringToPath('args.0')).toEqual(['args', 0])
      expect(stringToPath('args.0.args.1')).toEqual(['args', 0, 'args', 1])
      expect(stringToPath('')).toEqual([])
    })
  })

  describe('getVariableSuggestions', () => {
    const mockEsmFile: EsmFile = {
      esm: '0.8.0',
      metadata: { name: 'Selection test file' },
      models: {
        TestModel: {
          variables: {
            temperature: { type: 'state', units: 'K' },
            pressure: { type: 'state', units: 'Pa' },
          },
          equations: [],
        },
      },
      reaction_systems: {
        Chemistry: {
          species: {
            O3: {},
            NO2: {},
          },
          parameters: {},
          reactions: [
            {
              id: 'R1',
              substrates: [{ species: 'O3', stoichiometry: 1 }],
              products: [{ species: 'NO2', stoichiometry: 1 }],
              rate: 'k1',
            },
          ],
        },
      },
    }

    it('returns all variables when no search term', () => {
      const suggestions = getVariableSuggestions(mockEsmFile)
      expect(suggestions).toEqual(['NO2', 'O3', 'pressure', 'temperature'])
    })

    it('filters variables by search term', () => {
      const suggestions = getVariableSuggestions(mockEsmFile, 'O')
      expect(suggestions).toEqual(['NO2', 'O3'])
    })

    it('handles null ESM file', () => {
      const suggestions = getVariableSuggestions(null)
      expect(suggestions).toEqual([])
    })

    it('is case insensitive', () => {
      const suggestions = getVariableSuggestions(mockEsmFile, 'temp')
      expect(suggestions).toEqual(['temperature'])
    })
  })

  describe('createSelectionContext', () => {
    it('creates selection context with correct initial state', () => {
      const [rootExpr] = createSignal<Expression>(42)
      const onRootReplace = vi.fn()

      const context = createSelectionContext(rootExpr, onRootReplace)

      expect(context.selectedPath()).toBeNull()
      expect(context.isInlineEditing()).toBe(false)
      expect(context.selectedNodeDetails()).toBeNull()
    })

    it('tracks selected path', () => {
      const [rootExpr] = createSignal<Expression>({ op: '+', args: [1, 2] })
      const onRootReplace = vi.fn()

      const context = createSelectionContext(rootExpr, onRootReplace)

      context.setSelectedPath(['args', 0])
      expect(context.selectedPath()).toEqual(['args', 0])
      expect(context.isSelected(['args', 0])).toBe(true)
      expect(context.isSelected(['args', 1])).toBe(false)
    })

    it('provides node details for selected number', () => {
      const [rootExpr] = createSignal<Expression>({ op: '+', args: [42, 'x'] })
      const onRootReplace = vi.fn()

      const context = createSelectionContext(rootExpr, onRootReplace)
      context.setSelectedPath(['args', 0])

      const details = context.selectedNodeDetails()
      expect(details).toEqual({
        type: 'number',
        value: 42,
        parentContext: {
          type: 'operator',
          operator: '+',
          argIndex: 0,
        },
        availableActions: ['Edit Value', 'Convert to Variable', 'Wrap in Operator'],
        path: ['args', 0],
        expression: 42,
      })
    })

    it('provides node details for selected variable', () => {
      const [rootExpr] = createSignal<Expression>({ op: '*', args: ['y', 3] })
      const onRootReplace = vi.fn()

      const context = createSelectionContext(rootExpr, onRootReplace)
      context.setSelectedPath(['args', 0])

      const details = context.selectedNodeDetails()
      expect(details).toEqual({
        type: 'variable',
        value: 'y',
        parentContext: {
          type: 'operator',
          operator: '*',
          argIndex: 0,
        },
        availableActions: ['Edit Variable', 'Convert to Number', 'Wrap in Operator'],
        path: ['args', 0],
        expression: 'y',
      })
    })

    it('provides node details for selected operator', () => {
      const [rootExpr] = createSignal<Expression>({ op: 'sin', args: ['x'] })
      const onRootReplace = vi.fn()

      const context = createSelectionContext(rootExpr, onRootReplace)
      context.setSelectedPath([])

      const details = context.selectedNodeDetails()
      expect(details).toEqual({
        type: 'operator',
        value: 'sin',
        parentContext: {
          type: 'root',
        },
        availableActions: ['Change Operator', 'Add Argument', 'Remove Argument', 'Unwrap'],
        path: [],
        expression: { op: 'sin', args: ['x'] },
      })
    })

    it('handles node replacement', () => {
      const [rootExpr, setRootExpr] = createSignal<Expression>({ op: '+', args: [1, 2] })
      const onRootReplace = vi.fn((newExpr) => setRootExpr(newExpr))

      const context = createSelectionContext(rootExpr, onRootReplace)

      context.onReplace(['args', 0], 42)

      expect(onRootReplace).toHaveBeenCalledWith({ op: '+', args: [42, 2] })
      expect(rootExpr()).toEqual({ op: '+', args: [42, 2] })
    })

    it('handles inline editing for numbers', () => {
      const [rootExpr] = createSignal<Expression>(42)
      const onRootReplace = vi.fn()

      const context = createSelectionContext(rootExpr, onRootReplace)
      context.setSelectedPath([])

      context.startInlineEdit()
      expect(context.isInlineEditing()).toBe(true)
      expect(context.inlineEditValue()).toBe('42')

      context.setInlineEditValue('100')
      context.confirmInlineEdit('100')

      expect(onRootReplace).toHaveBeenCalledWith(100)
      expect(context.isInlineEditing()).toBe(false)
    })

    it('handles inline editing for variables', () => {
      const [rootExpr] = createSignal<Expression>('oldVar')
      const onRootReplace = vi.fn()

      const context = createSelectionContext(rootExpr, onRootReplace)
      context.setSelectedPath([])

      context.startInlineEdit()
      expect(context.isInlineEditing()).toBe(true)
      expect(context.inlineEditValue()).toBe('oldVar')

      context.confirmInlineEdit('newVar')

      expect(onRootReplace).toHaveBeenCalledWith('newVar')
      expect(context.isInlineEditing()).toBe(false)
    })

    it('validates number input during inline editing', () => {
      const [rootExpr] = createSignal<Expression>(42)
      const onRootReplace = vi.fn()

      const context = createSelectionContext(rootExpr, onRootReplace)
      context.setSelectedPath([])

      context.startInlineEdit()
      context.confirmInlineEdit('invalid')

      expect(onRootReplace).not.toHaveBeenCalled()
      expect(context.isInlineEditing()).toBe(true) // Still editing due to invalid input
    })

    it('validates variable input during inline editing', () => {
      const [rootExpr] = createSignal<Expression>('oldVar')
      const onRootReplace = vi.fn()

      const context = createSelectionContext(rootExpr, onRootReplace)
      context.setSelectedPath([])

      context.startInlineEdit()
      context.confirmInlineEdit('   ') // Empty/whitespace

      expect(onRootReplace).not.toHaveBeenCalled()
      expect(context.isInlineEditing()).toBe(true) // Still editing due to empty input
    })

    it('cancels inline editing', () => {
      const [rootExpr] = createSignal<Expression>(42)
      const onRootReplace = vi.fn()

      const context = createSelectionContext(rootExpr, onRootReplace)
      context.setSelectedPath([])

      context.startInlineEdit()
      expect(context.isInlineEditing()).toBe(true)

      context.cancelInlineEdit()
      expect(context.isInlineEditing()).toBe(false)
      expect(context.inlineEditValue()).toBe('')
    })
  })

  describe('SelectionProvider', () => {
    const TestComponent: Component = () => {
      const selection = useSelectionContext()

      return (
        <div>
          <div data-testid="selected-path">{selection.selectedPath()?.join('.') || 'none'}</div>
          <div data-testid="is-editing">{selection.isInlineEditing() ? 'yes' : 'no'}</div>
          <div data-testid="edit-value">{selection.inlineEditValue()}</div>
          <button data-testid="select-btn" onClick={() => selection.setSelectedPath(['args', 0])}>
            Select
          </button>
          <button data-testid="edit-btn" onClick={() => selection.startInlineEdit()}>
            Edit
          </button>
          <button data-testid="cancel-btn" onClick={() => selection.cancelInlineEdit()}>
            Cancel
          </button>
        </div>
      )
    }

    it('provides context to child components', () => {
      const [rootExpr] = createSignal<Expression>({ op: '+', args: [1, 2] })
      const onRootReplace = vi.fn()

      render(() => (
        <SelectionProvider rootExpression={rootExpr} onRootReplace={onRootReplace}>
          <TestComponent />
        </SelectionProvider>
      ))

      expect(screen.getByTestId('selected-path')).toHaveTextContent('none')
      expect(screen.getByTestId('is-editing')).toHaveTextContent('no')

      fireEvent.click(screen.getByTestId('select-btn'))
      expect(screen.getByTestId('selected-path')).toHaveTextContent('args.0')
    })

    it('handles inline editing through provider', () => {
      const [rootExpr] = createSignal<Expression>({ op: '+', args: [42, 2] })
      const onRootReplace = vi.fn()

      render(() => (
        <SelectionProvider rootExpression={rootExpr} onRootReplace={onRootReplace}>
          <TestComponent />
        </SelectionProvider>
      ))

      // Select a node first
      fireEvent.click(screen.getByTestId('select-btn'))
      expect(screen.getByTestId('selected-path')).toHaveTextContent('args.0')

      // Start editing
      fireEvent.click(screen.getByTestId('edit-btn'))
      expect(screen.getByTestId('is-editing')).toHaveTextContent('yes')
      expect(screen.getByTestId('edit-value')).toHaveTextContent('42')

      // Cancel editing
      fireEvent.click(screen.getByTestId('cancel-btn'))
      expect(screen.getByTestId('is-editing')).toHaveTextContent('no')
      expect(screen.getByTestId('edit-value')).toHaveTextContent('')
    })

    it('throws error when used outside provider', () => {
      expect(() => {
        render(() => <TestComponent />)
      }).toThrow('useSelectionContext must be used within a SelectionProvider')
    })
  })

  describe('Expression manipulation', () => {
    it('handles deep nested expressions', () => {
      const complexExpr: Expression = {
        op: '+',
        args: [
          { op: '*', args: [2, 'x'] },
          { op: 'sin', args: ['y'] },
        ],
      }

      const [rootExpr] = createSignal(complexExpr)
      const onRootReplace = vi.fn()

      const context = createSelectionContext(rootExpr, onRootReplace)

      // Select the 'x' variable in the nested multiplication
      context.setSelectedPath(['args', 0, 'args', 1])

      const details = context.selectedNodeDetails()
      expect(details?.type).toBe('variable')
      expect(details?.value).toBe('x')
      expect(details?.parentContext?.operator).toBe('*')
      expect(details?.parentContext?.argIndex).toBe(1)

      // Replace 'x' with a number
      context.onReplace(['args', 0, 'args', 1], 5)

      expect(onRootReplace).toHaveBeenCalledWith({
        op: '+',
        args: [
          { op: '*', args: [2, 5] },
          { op: 'sin', args: ['y'] },
        ],
      })
    })

    it('handles root expression replacement', () => {
      const [rootExpr] = createSignal<Expression>(42)
      const onRootReplace = vi.fn()

      const context = createSelectionContext(rootExpr, onRootReplace)

      context.setSelectedPath([])
      context.onReplace([], { op: 'sqrt', args: [42] })

      expect(onRootReplace).toHaveBeenCalledWith({ op: 'sqrt', args: [42] })
    })
  })
})
