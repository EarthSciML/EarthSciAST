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

    const paletteToggle = screen.getByTitle('Toggle expression palette')
    expect(paletteToggle).toBeInTheDocument()
  })

  it('hides palette toggle when showPalette=false', () => {
    render(() => <ExpressionEditor {...mockProps} showPalette={false} />)

    const paletteToggle = screen.queryByTitle('Toggle expression palette')
    expect(paletteToggle).not.toBeInTheDocument()
  })

  it('updates expression when initialExpression prop changes', () => {
    // Controlled: the rendered expression tracks the prop, so a parent updating
    // it re-renders the editor.
    const [expression, setExpression] = createSignal<Expression>(7)

    render(() => <ExpressionEditor {...mockProps} initialExpression={expression()} />)

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

    expect(screen.getByText('x')).toBeInTheDocument()
    expect(screen.queryByText('+')).not.toBeInTheDocument()
  })

  it('handles number expression', () => {
    const numberExpression = 42
    render(() => <ExpressionEditor {...mockProps} initialExpression={numberExpression} />)

    expect(screen.getByText('42')).toBeInTheDocument()
  })
})

describe('ExpressionEditor — text mode (DSL)', () => {
  const expr = { op: '+', args: ['x', 2] }
  const toText = () => fireEvent.click(screen.getByRole('button', { name: 'Edit as text' }))
  const textarea = () => screen.getByLabelText('Expression text') as HTMLTextAreaElement

  it('toggles to a textarea seeded with the ascii form', () => {
    render(() => <ExpressionEditor initialExpression={expr} onChange={vi.fn()} />)
    toText()
    expect(textarea()).toBeInTheDocument()
    expect(textarea().value).toBe('x + 2')
  })

  it('commits a valid edit on blur, emitting the parsed expression', () => {
    const onChange = vi.fn()
    render(() => <ExpressionEditor initialExpression={expr} onChange={onChange} />)
    toText()
    fireEvent.input(textarea(), { target: { value: 'x + 3' } })
    fireEvent.blur(textarea())
    expect(onChange).toHaveBeenCalledWith({ op: '+', args: ['x', 3] })
  })

  it('blocks emit on a parse error and surfaces the error', () => {
    const onChange = vi.fn()
    render(() => <ExpressionEditor initialExpression={expr} onChange={onChange} />)
    toText()
    fireEvent.input(textarea(), { target: { value: 'x +' } }) // trailing operator
    fireEvent.blur(textarea())
    expect(onChange).not.toHaveBeenCalled()
    expect(screen.getByRole('alert')).toBeInTheDocument()
  })

  it('does not emit when the reprint is unchanged (AST left untouched)', () => {
    const onChange = vi.fn()
    render(() => <ExpressionEditor initialExpression={expr} onChange={onChange} />)
    toText()
    fireEvent.blur(textarea())
    expect(onChange).not.toHaveBeenCalled()
  })

  it('blocks leaving text mode while the buffer is unparseable', () => {
    render(() => <ExpressionEditor initialExpression={expr} onChange={vi.fn()} />)
    toText()
    fireEvent.input(textarea(), { target: { value: 'x +' } })
    // The toggle now reads "Structural"; clicking it must NOT switch back.
    fireEvent.click(screen.getByRole('button', { name: 'Structural' }))
    expect(textarea()).toBeInTheDocument() // still in text mode
    expect(screen.getByRole('alert')).toBeInTheDocument()
  })

  it('does not show the text toggle in readonly mode', () => {
    render(() => <ExpressionEditor initialExpression={expr} readonly onChange={vi.fn()} />)
    expect(screen.queryByRole('button', { name: 'Edit as text' })).not.toBeInTheDocument()
  })
})
