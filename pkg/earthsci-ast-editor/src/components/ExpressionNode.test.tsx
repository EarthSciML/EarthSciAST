import { describe, it, beforeEach, expect, vi } from 'vitest'
import { render, screen, fireEvent } from '@solidjs/testing-library'
import { createSignal } from 'solid-js'
import { ExpressionNode } from './ExpressionNode'

describe('ExpressionNode', () => {
  const mockProps = {
    path: ['test'],
    highlightedVars: new Set<string>(),
    onHoverVar: vi.fn(),
    onSelect: vi.fn(),
    onReplace: vi.fn(),
  }

  beforeEach(() => {
    vi.clearAllMocks()
  })

  it('renders number literals correctly', () => {
    render(() => <ExpressionNode expr={42} {...mockProps} />)

    const element = screen.getByText('42')
    expect(element).toBeInTheDocument()
    expect(element).toHaveClass('esm-num')
  })

  it('renders variable references correctly', () => {
    render(() => <ExpressionNode expr="CO2" {...mockProps} />)

    const element = screen.getByText('CO₂')
    expect(element).toBeInTheDocument()
    expect(element).toHaveClass('esm-var')
  })

  it('handles hover events for variables', () => {
    const onHoverVar = vi.fn()
    render(() => <ExpressionNode expr="H2O" {...mockProps} onHoverVar={onHoverVar} />)

    const element = screen.getByText('H₂O')

    fireEvent.mouseEnter(element.parentElement!)
    expect(onHoverVar).toHaveBeenCalledWith('H2O')

    fireEvent.mouseLeave(element.parentElement!)
    expect(onHoverVar).toHaveBeenCalledWith(null)
  })

  it('handles click events', () => {
    const onSelect = vi.fn()
    render(() => <ExpressionNode expr="x" {...mockProps} onSelect={onSelect} />)

    const element = screen.getByRole('button')
    fireEvent.click(element)

    expect(onSelect).toHaveBeenCalledWith(['test'])
  })

  it('highlights variables when they are in highlightedVars set', () => {
    const [highlightedVars] = createSignal(new Set(['x']))

    render(() => <ExpressionNode expr="x" {...mockProps} highlightedVars={highlightedVars()} />)

    const element = screen.getByRole('button')
    expect(element).toHaveClass('highlighted')
  })

  it('renders operator nodes with OperatorLayout', () => {
    const operatorExpr = {
      op: '+' as const,
      args: [1, 2],
    }

    render(() => <ExpressionNode expr={operatorExpr} {...mockProps} />)

    const element = screen.getByText('+')
    expect(element).toBeInTheDocument()
    expect(element.parentElement).toHaveAttribute('data-operator', '+')
  })

  it('formats numbers with scientific notation for large numbers', () => {
    render(() => <ExpressionNode expr={1234567} {...mockProps} />)

    // Scientific notation uses the same Unicode superscript style as the
    // component's chemical formula / exponent rendering (e.g. CO₂, x²).
    const element = screen.getByText('1.234567×10⁶')
    expect(element).toBeInTheDocument()
  })

  it('formats numbers with scientific notation for small numbers', () => {
    render(() => <ExpressionNode expr={0.0001} {...mockProps} />)

    const element = screen.getByText('1×10⁻⁴')
    expect(element).toBeInTheDocument()
  })

  it('renders division with the shared Fraction layout component, not prefix notation', () => {
    const divisionExpr = {
      op: '/' as const,
      args: ['numerator', 'denominator'],
    }

    const { container } = render(() => <ExpressionNode expr={divisionExpr} {...mockProps} />)

    // Should use the Fraction layout component, not prefix notation like
    // "/(numerator, denominator)"
    const fractionElement = container.querySelector('.esm-fraction')
    const numeratorElement = container.querySelector('.esm-fraction-numerator')
    const barElement = container.querySelector('.esm-fraction-bar')
    const denominatorElement = container.querySelector('.esm-fraction-denominator')

    expect(fractionElement).toBeInTheDocument()
    expect(fractionElement).toHaveAttribute('role', 'math')
    expect(numeratorElement).toBeInTheDocument()
    expect(barElement).toBeInTheDocument()
    expect(denominatorElement).toBeInTheDocument()

    // Should NOT have generic function layout (prefix notation)
    const genericFunction = container.querySelector('.esm-generic-function')
    expect(genericFunction).not.toBeInTheDocument()
  })

  it('renders exponentiation with the shared Superscript layout component, not prefix notation', () => {
    const exponentExpr = {
      op: '^' as const,
      args: ['x', 2],
    }

    const { container } = render(() => <ExpressionNode expr={exponentExpr} {...mockProps} />)

    // Should use the Superscript layout component, not prefix notation
    // like "^(x, 2)"
    const superscriptElement = container.querySelector('.esm-superscript')
    const baseElement = container.querySelector('.esm-superscript-base')
    const exponentElement = container.querySelector('.esm-superscript-exponent')

    expect(superscriptElement).toBeInTheDocument()
    expect(superscriptElement).toHaveAttribute('role', 'math')
    expect(baseElement).toBeInTheDocument()
    expect(exponentElement).toBeInTheDocument()

    // Should NOT have generic function layout (prefix notation)
    const genericFunction = container.querySelector('.esm-generic-function')
    expect(genericFunction).not.toBeInTheDocument()
  })

  it('renders sqrt with the shared Radical layout component, not prefix notation', () => {
    const sqrtExpr = {
      op: 'sqrt' as const,
      args: ['x'],
    }

    const { container } = render(() => <ExpressionNode expr={sqrtExpr} {...mockProps} />)

    // Should use the Radical layout component, not prefix notation like "sqrt(x)"
    const sqrtElement = container.querySelector('.esm-sqrt')
    const radicalElement = container.querySelector('.esm-radical')
    const symbolElement = container.querySelector('.esm-radical-symbol')
    const contentElement = container.querySelector('.esm-radical-content')

    expect(sqrtElement).toBeInTheDocument()
    expect(radicalElement).toBeInTheDocument()
    expect(radicalElement).toHaveAttribute('role', 'math')
    expect(symbolElement?.textContent).toBe('√')
    expect(contentElement?.textContent).toBe('x')

    // Should NOT have generic function layout (prefix notation)
    const genericFunction = container.querySelector('.esm-generic-function')
    expect(genericFunction).not.toBeInTheDocument()
  })

  describe('Field editor integration', () => {
    it('shows the edit-fields button for a selected op that has editable fields', () => {
      render(() => (
        <ExpressionNode
          expr={{ op: 'D', args: ['u'], wrt: 't' }}
          {...mockProps}
          path={['test']}
          selectedPath={['test']}
        />
      ))

      expect(screen.getByTitle('Edit D fields')).toBeInTheDocument()
    })

    it('does not show the edit-fields button for a plain arithmetic op', () => {
      render(() => (
        <ExpressionNode
          expr={{ op: '+', args: [1, 2] }}
          {...mockProps}
          path={['test']}
          selectedPath={['test']}
        />
      ))

      expect(screen.queryByTitle('Edit + fields')).not.toBeInTheDocument()
    })

    it('opens the field editor and round-trips an edit to onReplace', () => {
      const onReplace = vi.fn()
      render(() => (
        <ExpressionNode
          expr={{ op: 'D', args: ['u'], wrt: 't' }}
          {...mockProps}
          path={['test']}
          selectedPath={['test']}
          onReplace={onReplace}
        />
      ))

      fireEvent.click(screen.getByTitle('Edit D fields'))

      const input = screen.getByDisplayValue('t')
      fireEvent.input(input, { target: { value: 'x' } })
      fireEvent.click(screen.getByText('Apply'))

      expect(onReplace).toHaveBeenCalledWith(['test'], { op: 'D', args: ['u'], wrt: 'x' })
    })
  })
})
