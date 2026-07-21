import { describe, it, beforeEach, expect, vi } from 'vitest'
import { render, screen, fireEvent } from '@solidjs/testing-library'
import { EquationEditor } from './EquationEditor'

describe('EquationEditor', () => {
  const mockEquation = {
    lhs: 'x',
    rhs: { op: '+', args: ['y', 2] },
  }

  const mockProps = {
    equation: mockEquation,
    onEquationChange: vi.fn(),
    highlightedVars: new Set<string>(),
    readonly: false,
  }

  beforeEach(() => {
    vi.clearAllMocks()
  })

  it('renders equation as pretty math with equals sign in readonly mode', () => {
    // The structural render is the read-only surface; editable is text-only.
    render(() => <EquationEditor {...mockProps} readonly={true} />)

    expect(screen.getByText('x')).toBeInTheDocument()
    expect(screen.getByText('=')).toBeInTheDocument()
    expect(screen.getByText('+')).toBeInTheDocument()
  })

  it('respects readonly mode (renders the lhs variable, no textarea)', () => {
    render(() => <EquationEditor {...mockProps} readonly={true} />)

    expect(screen.getByText('x')).toBeInTheDocument()
    expect(screen.queryByLabelText('Equation text')).not.toBeInTheDocument()
  })

  it('displays equation comment when provided', () => {
    const equationWithComment = {
      ...mockEquation,
      _comment: 'Test equation comment',
    }

    render(() => <EquationEditor {...mockProps} equation={equationWithComment} />)

    expect(screen.getByText('Test equation comment')).toBeInTheDocument()
  })

  it('applies custom CSS classes', () => {
    const { container } = render(() => <EquationEditor {...mockProps} class="custom-class" />)

    const editor = container.querySelector('.equation-editor')
    expect(editor).toHaveClass('custom-class')
  })

  it('includes readonly class when in readonly mode', () => {
    const { container } = render(() => <EquationEditor {...mockProps} readonly={true} />)

    const editor = container.querySelector('.equation-editor')
    expect(editor).toHaveClass('readonly')
  })
})

describe('EquationEditor — text mode (DSL, the only editable surface)', () => {
  const eq = { lhs: 'x', rhs: { op: '+', args: ['y', 2] } }
  const textarea = () => screen.getByLabelText('Equation text') as HTMLTextAreaElement

  it('editable mode shows a textarea seeded with the ascii form', () => {
    render(() => <EquationEditor equation={eq} onEquationChange={vi.fn()} />)
    expect(textarea()).toBeInTheDocument()
    expect(textarea().value).toBe('x = y + 2')
  })

  it('commits a valid edit on blur, emitting the parsed equation', () => {
    const onEquationChange = vi.fn()
    render(() => <EquationEditor equation={eq} onEquationChange={onEquationChange} />)
    fireEvent.input(textarea(), { target: { value: 'x = y + 3' } })
    fireEvent.blur(textarea())
    expect(onEquationChange).toHaveBeenCalledWith({ lhs: 'x', rhs: { op: '+', args: ['y', 3] } })
  })

  it('blocks emit on a parse error and surfaces the error', () => {
    const onEquationChange = vi.fn()
    render(() => <EquationEditor equation={eq} onEquationChange={onEquationChange} />)
    fireEvent.input(textarea(), { target: { value: 'x = y +' } }) // trailing operator
    fireEvent.blur(textarea())
    expect(onEquationChange).not.toHaveBeenCalled()
    expect(screen.getByRole('alert')).toBeInTheDocument()
  })

  it('does not emit when the reprint is unchanged (AST left untouched)', () => {
    const onEquationChange = vi.fn()
    render(() => <EquationEditor equation={eq} onEquationChange={onEquationChange} />)
    fireEvent.blur(textarea())
    expect(onEquationChange).not.toHaveBeenCalled()
  })

  it('does not emit on a no-edit blur even for a non-reprint-idempotent node', () => {
    // A wrt-less `D(O3, t)` seeds as `D(O3, t)` but reprints as `D(O3)/Dt`, so a
    // reprint-only guard would spuriously rewrite it on a focus+blur with no
    // edit. Gating emit on the buffer having actually changed prevents that.
    const nonIdempotent = { lhs: 'x', rhs: { op: 'D', args: ['O3', 't'] } }
    const onEquationChange = vi.fn()
    render(() => <EquationEditor equation={nonIdempotent} onEquationChange={onEquationChange} />)
    expect(textarea().value).toBe('x = D(O3, t)')
    fireEvent.blur(textarea()) // focus/blur with no edit
    expect(onEquationChange).not.toHaveBeenCalled()
  })

  it('preserves _comment (and other non-lhs/rhs fields) across a text edit', () => {
    const withComment = { lhs: 'x', rhs: { op: '+', args: ['y', 2] }, _comment: 'note' }
    const onEquationChange = vi.fn()
    render(() => <EquationEditor equation={withComment} onEquationChange={onEquationChange} />)
    fireEvent.input(textarea(), { target: { value: 'x = y + 3' } })
    fireEvent.blur(textarea())
    expect(onEquationChange).toHaveBeenCalledWith({
      lhs: 'x',
      rhs: { op: '+', args: ['y', 3] },
      _comment: 'note',
    })
  })

  it('renders no structural/text toggle (editing is text-only now)', () => {
    render(() => <EquationEditor equation={eq} onEquationChange={vi.fn()} />)
    expect(screen.queryByRole('button', { name: 'Edit as text' })).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Structural' })).not.toBeInTheDocument()
  })
})
