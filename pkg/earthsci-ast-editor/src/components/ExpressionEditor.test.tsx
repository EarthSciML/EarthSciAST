import { describe, it, beforeEach, expect, vi } from 'vitest'
import { render, screen, fireEvent } from '@solidjs/testing-library'
import { createSignal } from 'solid-js'
import type { Expression } from '@earthsciml/ast'
import { ExpressionEditor } from './ExpressionEditor'

describe('ExpressionEditor', () => {
  const mockExpression = { op: '+', args: ['x', 2] }

  const mockProps = {
    initialExpression: mockExpression,
    onChange: vi.fn(),
    highlightedVars: new Set<string>(),
    readonly: false,
    showPalette: false,
  }

  beforeEach(() => {
    vi.clearAllMocks()
  })

  it('renders expression without equals sign', () => {
    render(() => <ExpressionEditor {...mockProps} />)
    // Text is the default surface now; switch to structural to assert the render.
    fireEvent.click(screen.getByRole('button', { name: 'Structural' }))

    expect(screen.getByText('+')).toBeInTheDocument()
    expect(screen.getByText('x')).toBeInTheDocument()
    expect(screen.getByText('2')).toBeInTheDocument()
    // Should NOT have equals sign (unlike EquationEditor)
    expect(screen.queryByText('=')).not.toBeInTheDocument()
  })

  it('handles expression changes', () => {
    // Drive a real edit through the node's field editor and confirm the new
    // expression flows out via onChange (controlled: parent owns the value).
    const onChange = vi.fn()
    const { container } = render(() => (
      <ExpressionEditor
        {...mockProps}
        initialExpression={{ op: 'D', args: ['u'], wrt: 't' }}
        onChange={onChange}
      />
    ))
    // Structural editing is now opt-in behind the toggle.
    fireEvent.click(screen.getByRole('button', { name: 'Structural' }))

    const rootNode = container.querySelector('.esm-expression-node')!
    fireEvent.click(rootNode)
    fireEvent.click(screen.getByTitle('Edit D fields'))
    fireEvent.input(screen.getByDisplayValue('t'), { target: { value: 'x' } })
    fireEvent.click(screen.getByText('Apply'))

    expect(onChange).toHaveBeenCalledWith({ op: 'D', args: ['u'], wrt: 'x' })
  })

  it('respects readonly=true mode', () => {
    render(() => <ExpressionEditor {...mockProps} readonly={true} />)

    const editor = screen.getByRole('button', { name: /\+/ })
    expect(editor).toBeInTheDocument()
    expect(screen.getByText('+')).toBeInTheDocument()
  })

  it('shows palette toggle when showPalette=true', () => {
    render(() => <ExpressionEditor {...mockProps} showPalette={true} />)
    // The palette is a structural-editing affordance; reveal the structural surface.
    fireEvent.click(screen.getByRole('button', { name: 'Structural' }))

    const paletteToggle = screen.getByTitle('Toggle expression palette')
    expect(paletteToggle).toBeInTheDocument()
  })

  it('hides palette toggle when showPalette=false', () => {
    render(() => <ExpressionEditor {...mockProps} showPalette={false} />)

    const paletteToggle = screen.queryByTitle('Toggle expression palette')
    expect(paletteToggle).not.toBeInTheDocument()
  })

  it('updates expression when initialExpression prop changes', () => {
    // Controlled: the rendered expression tracks the prop. Asserted on the
    // structural surface — once seeded, the text buffer is an independent edit
    // buffer, so prop reactivity is observed structurally.
    const [expression, setExpression] = createSignal<Expression>(7)

    render(() => <ExpressionEditor {...mockProps} initialExpression={expression()} />)
    fireEvent.click(screen.getByRole('button', { name: 'Structural' }))

    expect(screen.getByText('7')).toBeInTheDocument()

    setExpression(9)

    expect(screen.getByText('9')).toBeInTheDocument()
    expect(screen.queryByText('7')).not.toBeInTheDocument()
  })

  it('applies custom CSS class', () => {
    render(() => <ExpressionEditor {...mockProps} class="custom-expression-editor" />)

    const editor = document.querySelector('.expression-editor')
    expect(editor).toHaveClass('expression-editor')
    expect(editor).toHaveClass('custom-expression-editor')
  })

  it('applies readonly class when readonly=true', () => {
    render(() => <ExpressionEditor {...mockProps} readonly={true} />)

    const editor = document.querySelector('.expression-editor')
    expect(editor).toHaveClass('readonly')
  })

  it('handles simple expression (non-operator)', () => {
    const simpleExpression = 'x'
    render(() => <ExpressionEditor {...mockProps} initialExpression={simpleExpression} />)
    fireEvent.click(screen.getByRole('button', { name: 'Structural' }))

    expect(screen.getByText('x')).toBeInTheDocument()
    expect(screen.queryByText('+')).not.toBeInTheDocument()
  })

  it('handles number expression', () => {
    const numberExpression = 42
    render(() => <ExpressionEditor {...mockProps} initialExpression={numberExpression} />)
    fireEvent.click(screen.getByRole('button', { name: 'Structural' }))

    expect(screen.getByText('42')).toBeInTheDocument()
  })
})

describe('ExpressionEditor — text mode (DSL, the default surface)', () => {
  const expr = { op: '+', args: ['x', 2] }
  const textarea = () => screen.getByLabelText('Expression text') as HTMLTextAreaElement

  it('defaults to a textarea seeded with the ascii form', () => {
    render(() => <ExpressionEditor initialExpression={expr} onChange={vi.fn()} />)
    expect(textarea()).toBeInTheDocument()
    expect(textarea().value).toBe('x + 2')
  })

  it('commits a valid edit on blur, emitting the parsed expression', () => {
    const onChange = vi.fn()
    render(() => <ExpressionEditor initialExpression={expr} onChange={onChange} />)
    fireEvent.input(textarea(), { target: { value: 'x + 3' } })
    fireEvent.blur(textarea())
    expect(onChange).toHaveBeenCalledWith({ op: '+', args: ['x', 3] })
  })

  it('blocks emit on a parse error and surfaces the error', () => {
    const onChange = vi.fn()
    render(() => <ExpressionEditor initialExpression={expr} onChange={onChange} />)
    fireEvent.input(textarea(), { target: { value: 'x +' } }) // trailing operator
    fireEvent.blur(textarea())
    expect(onChange).not.toHaveBeenCalled()
    expect(screen.getByRole('alert')).toBeInTheDocument()
  })

  it('does not emit when the reprint is unchanged (AST left untouched)', () => {
    const onChange = vi.fn()
    render(() => <ExpressionEditor initialExpression={expr} onChange={onChange} />)
    fireEvent.blur(textarea())
    expect(onChange).not.toHaveBeenCalled()
  })

  it('blocks leaving text mode while the buffer is unparseable', () => {
    render(() => <ExpressionEditor initialExpression={expr} onChange={vi.fn()} />)
    fireEvent.input(textarea(), { target: { value: 'x +' } })
    // The toggle reads "Structural"; clicking it must NOT switch away from text.
    fireEvent.click(screen.getByRole('button', { name: 'Structural' }))
    expect(textarea()).toBeInTheDocument() // still in text mode
    expect(screen.getByRole('alert')).toBeInTheDocument()
  })

  it('does not show the toggle at all in readonly mode', () => {
    render(() => <ExpressionEditor initialExpression={expr} readonly onChange={vi.fn()} />)
    expect(screen.queryByRole('button', { name: 'Edit as text' })).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Structural' })).not.toBeInTheDocument()
  })
})
