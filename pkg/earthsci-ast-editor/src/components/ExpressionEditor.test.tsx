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
  }

  beforeEach(() => {
    vi.clearAllMocks()
  })

  it('renders expression as pretty math (readonly), without an equals sign', () => {
    // The structural render is the read-only surface; editable is text-only.
    render(() => <ExpressionEditor {...mockProps} readonly={true} />)

    expect(screen.getByText('+')).toBeInTheDocument()
    expect(screen.getByText('x')).toBeInTheDocument()
    expect(screen.getByText('2')).toBeInTheDocument()
    // Should NOT have equals sign (unlike EquationEditor)
    expect(screen.queryByText('=')).not.toBeInTheDocument()
  })

  it('respects readonly=true mode', () => {
    render(() => <ExpressionEditor {...mockProps} readonly={true} />)

    expect(screen.getByText('+')).toBeInTheDocument()
    expect(screen.queryByLabelText('Expression text')).not.toBeInTheDocument()
  })

  it('updates the readonly render when initialExpression prop changes', () => {
    // Controlled: the rendered (readonly) expression tracks the prop. In editable
    // mode the text buffer is an independent edit buffer, so prop reactivity is
    // observed on the structural render.
    const [expression, setExpression] = createSignal<Expression>(7)

    render(() => (
      <ExpressionEditor {...mockProps} readonly={true} initialExpression={expression()} />
    ))

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

  it('handles simple expression (non-operator) in readonly render', () => {
    const simpleExpression = 'x'
    render(() => (
      <ExpressionEditor {...mockProps} readonly={true} initialExpression={simpleExpression} />
    ))

    expect(screen.getByText('x')).toBeInTheDocument()
    expect(screen.queryByText('+')).not.toBeInTheDocument()
  })

  it('handles number expression in readonly render', () => {
    const numberExpression = 42
    render(() => (
      <ExpressionEditor {...mockProps} readonly={true} initialExpression={numberExpression} />
    ))

    expect(screen.getByText('42')).toBeInTheDocument()
  })
})

describe('ExpressionEditor — text mode (DSL, the only editable surface)', () => {
  const expr = { op: '+', args: ['x', 2] }
  const textarea = () => screen.getByLabelText('Expression text') as HTMLTextAreaElement

  it('editable mode shows a textarea seeded with the ascii form', () => {
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

  it('renders no structural/text toggle (editing is text-only now)', () => {
    render(() => <ExpressionEditor initialExpression={expr} onChange={vi.fn()} />)
    expect(screen.queryByRole('button', { name: 'Edit as text' })).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Structural' })).not.toBeInTheDocument()
  })
})
