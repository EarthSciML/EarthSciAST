import { describe, it, expect, vi } from 'vitest'
import { render, screen, fireEvent } from '@solidjs/testing-library'
import type { Component } from 'solid-js'
import { createSignal } from 'solid-js'
import {
  StructuralEditingProvider,
  useStructuralEditingContext,
  StructuralEditingMenu,
  WRAP_OPERATORS,
  COMMUTATIVE_OPERATORS,
} from './structural-editing'
import type { Expression } from '@earthsciml/ast'

describe('Structural editing operations', () => {
  describe('StructuralEditingProvider', () => {
    const TestComponent: Component = () => {
      const structuralEditing = useStructuralEditingContext()

      return (
        <div>
          <div data-testid="can-unwrap">
            {structuralEditing.canUnwrap({ op: 'sin', args: ['x'] }) ? 'yes' : 'no'}
          </div>
          <div data-testid="can-reorder">
            {structuralEditing.canReorderArgs({ op: 'sin', args: ['x'] }) ? 'yes' : 'no'}
          </div>
          <button
            data-testid="wrap-btn"
            onClick={() => structuralEditing.wrapNode(['args', 0], 'sin')}
          >
            Wrap
          </button>
          <button data-testid="unwrap-btn" onClick={() => structuralEditing.unwrapNode([])}>
            Unwrap
          </button>
          <button
            data-testid="delete-btn"
            onClick={() => structuralEditing.deleteTerm(['args', 0])}
          >
            Delete
          </button>
          <button data-testid="reorder-btn" onClick={() => structuralEditing.reorderArgs([], 0, 1)}>
            Reorder
          </button>
        </div>
      )
    }

    it('provides structural editing context', () => {
      const [rootExpr] = createSignal<Expression>({ op: 'sin', args: ['x'] })
      const onRootReplace = vi.fn()

      render(() => (
        <StructuralEditingProvider rootExpression={rootExpr} onRootReplace={onRootReplace}>
          <TestComponent />
        </StructuralEditingProvider>
      ))

      expect(screen.getByTestId('can-unwrap')).toHaveTextContent('yes')
      expect(screen.getByTestId('can-reorder')).toHaveTextContent('no')
    })

    it('handles wrap operation', () => {
      const [rootExpr] = createSignal<Expression>({ op: '+', args: [42, 'x'] })
      const onRootReplace = vi.fn()

      render(() => (
        <StructuralEditingProvider rootExpression={rootExpr} onRootReplace={onRootReplace}>
          <TestComponent />
        </StructuralEditingProvider>
      ))

      fireEvent.click(screen.getByTestId('wrap-btn'))

      expect(onRootReplace).toHaveBeenCalledWith({
        op: '+',
        args: [{ op: 'sin', args: [42] }, 'x'],
      })
    })

    it('handles unwrap operation for unary operators', () => {
      const [rootExpr] = createSignal<Expression>({ op: 'sin', args: ['x'] })
      const onRootReplace = vi.fn()

      render(() => (
        <StructuralEditingProvider rootExpression={rootExpr} onRootReplace={onRootReplace}>
          <TestComponent />
        </StructuralEditingProvider>
      ))

      fireEvent.click(screen.getByTestId('unwrap-btn'))

      expect(onRootReplace).toHaveBeenCalledWith('x')
    })

    it('handles delete term operation', () => {
      const [rootExpr] = createSignal<Expression>({ op: '+', args: [1, 2, 3] })
      const onRootReplace = vi.fn()

      render(() => (
        <StructuralEditingProvider rootExpression={rootExpr} onRootReplace={onRootReplace}>
          <TestComponent />
        </StructuralEditingProvider>
      ))

      fireEvent.click(screen.getByTestId('delete-btn'))

      expect(onRootReplace).toHaveBeenCalledWith({
        op: '+',
        args: [2, 3],
      })
    })

    it('handles reorder operation', () => {
      const [rootExpr] = createSignal<Expression>({ op: '*', args: [1, 2, 3] })
      const onRootReplace = vi.fn()

      render(() => (
        <StructuralEditingProvider rootExpression={rootExpr} onRootReplace={onRootReplace}>
          <TestComponent />
        </StructuralEditingProvider>
      ))

      fireEvent.click(screen.getByTestId('reorder-btn'))

      expect(onRootReplace).toHaveBeenCalledWith({
        op: '*',
        args: [2, 1, 3],
      })
    })

    it('throws error when used outside provider', () => {
      expect(() => {
        render(() => <TestComponent />)
      }).toThrow('useStructuralEditingContext must be used within a StructuralEditingProvider')
    })
  })

  describe('Wrap operations', () => {
    it('wraps number with unary operator', () => {
      const [rootExpr] = createSignal<Expression>(42)
      const onRootReplace = vi.fn()

      const TestWrapComponent: Component = () => {
        const structuralEditing = useStructuralEditingContext()
        return <button onClick={() => structuralEditing.wrapNode([], '-')}>Negate</button>
      }

      render(() => (
        <StructuralEditingProvider rootExpression={rootExpr} onRootReplace={onRootReplace}>
          <TestWrapComponent />
        </StructuralEditingProvider>
      ))

      fireEvent.click(screen.getByRole('button'))

      expect(onRootReplace).toHaveBeenCalledWith({
        op: '-',
        args: [42],
      })
    })

    it('wraps expression with binary operator', () => {
      const [rootExpr] = createSignal<Expression>('x')
      const onRootReplace = vi.fn()

      const TestWrapComponent: Component = () => {
        const structuralEditing = useStructuralEditingContext()
        return <button onClick={() => structuralEditing.wrapNode([], '+')}>Add</button>
      }

      render(() => (
        <StructuralEditingProvider rootExpression={rootExpr} onRootReplace={onRootReplace}>
          <TestWrapComponent />
        </StructuralEditingProvider>
      ))

      fireEvent.click(screen.getByRole('button'))

      // Binary operator: wrapped as a well-formed 2-argument node (operand plus
      // a placeholder the user then edits), respecting WRAP_OPERATORS arity.
      expect(onRootReplace).toHaveBeenCalledWith({
        op: '+',
        args: ['x', 0],
      })
    })
  })

  describe('Unwrap operations', () => {
    it('unwraps unary operation', () => {
      const [rootExpr] = createSignal<Expression>({ op: 'abs', args: [-5] })
      const onRootReplace = vi.fn()

      const TestUnwrapComponent: Component = () => {
        const structuralEditing = useStructuralEditingContext()
        return <button onClick={() => structuralEditing.unwrapNode([])}>Unwrap</button>
      }

      render(() => (
        <StructuralEditingProvider rootExpression={rootExpr} onRootReplace={onRootReplace}>
          <TestUnwrapComponent />
        </StructuralEditingProvider>
      ))

      fireEvent.click(screen.getByRole('button'))

      expect(onRootReplace).toHaveBeenCalledWith(-5)
    })

    it('cannot unwrap binary operation', () => {
      const [rootExpr] = createSignal<Expression>({ op: '+', args: [1, 2] })
      const onRootReplace = vi.fn()

      const TestUnwrapComponent: Component = () => {
        const structuralEditing = useStructuralEditingContext()
        return <button onClick={() => structuralEditing.unwrapNode([])}>Unwrap</button>
      }

      render(() => (
        <StructuralEditingProvider rootExpression={rootExpr} onRootReplace={onRootReplace}>
          <TestUnwrapComponent />
        </StructuralEditingProvider>
      ))

      fireEvent.click(screen.getByRole('button'))

      expect(onRootReplace).not.toHaveBeenCalled()
    })

    it('cannot unwrap non-operation', () => {
      const [rootExpr] = createSignal<Expression>(42)
      const onRootReplace = vi.fn()

      const TestUnwrapComponent: Component = () => {
        const structuralEditing = useStructuralEditingContext()
        return <button onClick={() => structuralEditing.unwrapNode([])}>Unwrap</button>
      }

      render(() => (
        <StructuralEditingProvider rootExpression={rootExpr} onRootReplace={onRootReplace}>
          <TestUnwrapComponent />
        </StructuralEditingProvider>
      ))

      fireEvent.click(screen.getByRole('button'))

      expect(onRootReplace).not.toHaveBeenCalled()
    })
  })

  describe('Delete term operations', () => {
    it('deletes term from addition with 3+ args', () => {
      const [rootExpr] = createSignal<Expression>({ op: '+', args: [1, 2, 3, 4] })
      const onRootReplace = vi.fn()

      const TestDeleteComponent: Component = () => {
        const structuralEditing = useStructuralEditingContext()
        return (
          <button onClick={() => structuralEditing.deleteTerm(['args', 1])}>
            Delete Second Term
          </button>
        )
      }

      render(() => (
        <StructuralEditingProvider rootExpression={rootExpr} onRootReplace={onRootReplace}>
          <TestDeleteComponent />
        </StructuralEditingProvider>
      ))

      fireEvent.click(screen.getByRole('button'))

      expect(onRootReplace).toHaveBeenCalledWith({
        op: '+',
        args: [1, 3, 4],
      })
    })

    it('collapses binary addition when deleting to single arg', () => {
      const [rootExpr] = createSignal<Expression>({ op: '+', args: [1, 2] })
      const onRootReplace = vi.fn()

      const TestDeleteComponent: Component = () => {
        const structuralEditing = useStructuralEditingContext()
        return (
          <button onClick={() => structuralEditing.deleteTerm(['args', 0])}>
            Delete First Term
          </button>
        )
      }

      render(() => (
        <StructuralEditingProvider rootExpression={rootExpr} onRootReplace={onRootReplace}>
          <TestDeleteComponent />
        </StructuralEditingProvider>
      ))

      fireEvent.click(screen.getByRole('button'))

      expect(onRootReplace).toHaveBeenCalledWith(2)
    })

    it('cannot delete from non-commutative operation', () => {
      const [rootExpr] = createSignal<Expression>({ op: 'sin', args: ['x'] })
      const onRootReplace = vi.fn()

      const TestDeleteComponent: Component = () => {
        const structuralEditing = useStructuralEditingContext()
        return <button onClick={() => structuralEditing.deleteTerm(['args', 0])}>Delete</button>
      }

      render(() => (
        <StructuralEditingProvider rootExpression={rootExpr} onRootReplace={onRootReplace}>
          <TestDeleteComponent />
        </StructuralEditingProvider>
      ))

      fireEvent.click(screen.getByRole('button'))

      expect(onRootReplace).not.toHaveBeenCalled()
    })
  })

  describe('Capability checks', () => {
    it('correctly identifies unwrappable expressions', () => {
      const [rootExpr] = createSignal<Expression>({ op: 'sin', args: ['x'] })
      const onRootReplace = vi.fn()

      const TestCapabilityComponent: Component = () => {
        const structuralEditing = useStructuralEditingContext()
        return (
          <div>
            <div data-testid="can-unwrap-unary">
              {structuralEditing.canUnwrap({ op: 'sin', args: ['x'] }) ? 'yes' : 'no'}
            </div>
            <div data-testid="can-unwrap-binary">
              {structuralEditing.canUnwrap({ op: '+', args: [1, 2] }) ? 'yes' : 'no'}
            </div>
            <div data-testid="can-unwrap-number">
              {structuralEditing.canUnwrap(42) ? 'yes' : 'no'}
            </div>
          </div>
        )
      }

      render(() => (
        <StructuralEditingProvider rootExpression={rootExpr} onRootReplace={onRootReplace}>
          <TestCapabilityComponent />
        </StructuralEditingProvider>
      ))

      expect(screen.getByTestId('can-unwrap-unary')).toHaveTextContent('yes')
      expect(screen.getByTestId('can-unwrap-binary')).toHaveTextContent('no')
      expect(screen.getByTestId('can-unwrap-number')).toHaveTextContent('no')
    })

    it('correctly identifies reorderable expressions', () => {
      const [rootExpr] = createSignal<Expression>({ op: '+', args: [1, 2] })
      const onRootReplace = vi.fn()

      const TestCapabilityComponent: Component = () => {
        const structuralEditing = useStructuralEditingContext()
        return (
          <div>
            <div data-testid="can-reorder-addition">
              {structuralEditing.canReorderArgs({ op: '+', args: [1, 2, 3] }) ? 'yes' : 'no'}
            </div>
            <div data-testid="can-reorder-multiplication">
              {structuralEditing.canReorderArgs({ op: '*', args: ['x', 'y'] }) ? 'yes' : 'no'}
            </div>
            <div data-testid="can-reorder-division">
              {structuralEditing.canReorderArgs({ op: '/', args: [1, 2] }) ? 'yes' : 'no'}
            </div>
            <div data-testid="can-reorder-single">
              {structuralEditing.canReorderArgs({ op: '+', args: [1] }) ? 'yes' : 'no'}
            </div>
          </div>
        )
      }

      render(() => (
        <StructuralEditingProvider rootExpression={rootExpr} onRootReplace={onRootReplace}>
          <TestCapabilityComponent />
        </StructuralEditingProvider>
      ))

      expect(screen.getByTestId('can-reorder-addition')).toHaveTextContent('yes')
      expect(screen.getByTestId('can-reorder-multiplication')).toHaveTextContent('yes')
      expect(screen.getByTestId('can-reorder-division')).toHaveTextContent('no')
      expect(screen.getByTestId('can-reorder-single')).toHaveTextContent('no')
    })

    it('correctly identifies deletable terms', () => {
      const [rootExpr] = createSignal<Expression>({
        op: '+',
        args: [1, { op: '*', args: [2, 3] }, { op: 'sin', args: ['x'] }],
      })
      const onRootReplace = vi.fn()

      const TestCapabilityComponent: Component = () => {
        const structuralEditing = useStructuralEditingContext()
        return (
          <div>
            <div data-testid="can-delete-from-addition">
              {structuralEditing.canDeleteTerm(['args', 0]) ? 'yes' : 'no'}
            </div>
            <div data-testid="can-delete-from-multiplication">
              {structuralEditing.canDeleteTerm(['args', 1, 'args', 0]) ? 'yes' : 'no'}
            </div>
            <div data-testid="can-delete-from-sin">
              {structuralEditing.canDeleteTerm(['args', 2, 'args', 0]) ? 'yes' : 'no'}
            </div>
          </div>
        )
      }

      render(() => (
        <StructuralEditingProvider rootExpression={rootExpr} onRootReplace={onRootReplace}>
          <TestCapabilityComponent />
        </StructuralEditingProvider>
      ))

      expect(screen.getByTestId('can-delete-from-addition')).toHaveTextContent('yes')
      expect(screen.getByTestId('can-delete-from-multiplication')).toHaveTextContent('yes')
      expect(screen.getByTestId('can-delete-from-sin')).toHaveTextContent('no')
    })
  })

  describe('Reorder operations', () => {
    it('reorders arguments in commutative operations', () => {
      const [rootExpr] = createSignal<Expression>({ op: '+', args: ['a', 'b', 'c', 'd'] })
      const onRootReplace = vi.fn()

      const TestReorderComponent: Component = () => {
        const structuralEditing = useStructuralEditingContext()
        return (
          <button onClick={() => structuralEditing.reorderArgs([], 0, 2)}>
            Move First to Third
          </button>
        )
      }

      render(() => (
        <StructuralEditingProvider rootExpression={rootExpr} onRootReplace={onRootReplace}>
          <TestReorderComponent />
        </StructuralEditingProvider>
      ))

      fireEvent.click(screen.getByRole('button'))

      expect(onRootReplace).toHaveBeenCalledWith({
        op: '+',
        args: ['b', 'c', 'a', 'd'],
      })
    })

    it('handles edge case reordering (move to end)', () => {
      const [rootExpr] = createSignal<Expression>({ op: '*', args: [1, 2, 3] })
      const onRootReplace = vi.fn()

      const TestReorderComponent: Component = () => {
        const structuralEditing = useStructuralEditingContext()
        return (
          <button onClick={() => structuralEditing.reorderArgs([], 0, 2)}>
            Move First to Last
          </button>
        )
      }

      render(() => (
        <StructuralEditingProvider rootExpression={rootExpr} onRootReplace={onRootReplace}>
          <TestReorderComponent />
        </StructuralEditingProvider>
      ))

      fireEvent.click(screen.getByRole('button'))

      expect(onRootReplace).toHaveBeenCalledWith({
        op: '*',
        args: [2, 3, 1],
      })
    })

    it('cannot reorder non-commutative operations', () => {
      const [rootExpr] = createSignal<Expression>({ op: '/', args: [1, 2] })
      const onRootReplace = vi.fn()

      const TestReorderComponent: Component = () => {
        const structuralEditing = useStructuralEditingContext()
        return (
          <button onClick={() => structuralEditing.reorderArgs([], 0, 1)}>
            Try Reorder Division
          </button>
        )
      }

      render(() => (
        <StructuralEditingProvider rootExpression={rootExpr} onRootReplace={onRootReplace}>
          <TestReorderComponent />
        </StructuralEditingProvider>
      ))

      fireEvent.click(screen.getByRole('button'))

      expect(onRootReplace).not.toHaveBeenCalled()
    })
  })

  describe('Constants and configurations', () => {
    it('has correct wrap operators', () => {
      expect(WRAP_OPERATORS.length).toBeGreaterThan(0)

      const negateOp = WRAP_OPERATORS.find((op) => op.op === '-')
      expect(negateOp).toEqual({ op: '-', label: 'Negate', arity: 1 })

      const addOp = WRAP_OPERATORS.find((op) => op.op === '+')
      expect(addOp).toEqual({ op: '+', label: 'Addition', arity: 2 })

      const sinOp = WRAP_OPERATORS.find((op) => op.op === 'sin')
      expect(sinOp).toEqual({ op: 'sin', label: 'Sine', arity: 1 })
    })

    it('has correct commutative operators', () => {
      expect(COMMUTATIVE_OPERATORS.has('+')).toBe(true)
      expect(COMMUTATIVE_OPERATORS.has('*')).toBe(true)
      expect(COMMUTATIVE_OPERATORS.has('-')).toBe(false)
      expect(COMMUTATIVE_OPERATORS.has('/')).toBe(false)
      expect(COMMUTATIVE_OPERATORS.has('^')).toBe(false)
    })
  })

  describe('StructuralEditingMenu', () => {
    it('renders menu when visible', () => {
      const [rootExpr] = createSignal<Expression>({ op: 'sin', args: ['x'] })
      const onRootReplace = vi.fn()
      const onClose = vi.fn()

      render(() => (
        <StructuralEditingProvider rootExpression={rootExpr} onRootReplace={onRootReplace}>
          <StructuralEditingMenu
            selectedPath={[]}
            selectedExpr={{ op: 'sin', args: ['x'] }}
            isVisible={true}
            onClose={onClose}
          />
        </StructuralEditingProvider>
      ))

      expect(screen.getByText('Wrap in Operator')).toBeInTheDocument()
      expect(screen.getByText('Unwrap')).toBeInTheDocument()
    })

    it('does not render when not visible', () => {
      const [rootExpr] = createSignal<Expression>({ op: 'sin', args: ['x'] })
      const onRootReplace = vi.fn()
      const onClose = vi.fn()

      render(() => (
        <StructuralEditingProvider rootExpression={rootExpr} onRootReplace={onRootReplace}>
          <StructuralEditingMenu
            selectedPath={[]}
            selectedExpr={{ op: 'sin', args: ['x'] }}
            isVisible={false}
            onClose={onClose}
          />
        </StructuralEditingProvider>
      ))

      expect(screen.queryByText('Wrap in Operator')).not.toBeInTheDocument()
    })

    it('handles wrap button clicks', () => {
      const [rootExpr] = createSignal<Expression>('x')
      const onRootReplace = vi.fn()
      const onClose = vi.fn()

      render(() => (
        <StructuralEditingProvider rootExpression={rootExpr} onRootReplace={onRootReplace}>
          <StructuralEditingMenu
            selectedPath={[]}
            selectedExpr={'x'}
            isVisible={true}
            onClose={onClose}
          />
        </StructuralEditingProvider>
      ))

      fireEvent.click(screen.getByText('Negate'))

      expect(onRootReplace).toHaveBeenCalledWith({
        op: '-',
        args: ['x'],
      })
      expect(onClose).toHaveBeenCalled()
    })
  })
})
