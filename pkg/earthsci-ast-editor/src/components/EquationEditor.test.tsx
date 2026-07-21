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

  it('renders equation with equals sign', () => {
    render(() => <EquationEditor {...mockProps} />)

    expect(screen.getByText('x')).toBeInTheDocument()
    expect(screen.getByText('=')).toBeInTheDocument()
    expect(screen.getByText('+')).toBeInTheDocument()
  })

  it('handles equation changes, including nested edits deep in the RHS tree', () => {
    // Edit a `D` node nested inside the RHS (path ['rhs','args',0]) and confirm
    // the change is applied via the shared document-path replace — nested edits
    // used to be dropped by a hand-rolled walker.
    const equation = {
      lhs: 'x',
      rhs: { op: '+', args: [{ op: 'D', args: ['u'], wrt: 't' }, 'k'] },
    }
    const onEquationChange = vi.fn()
    const { container } = render(() => (
      <EquationEditor {...mockProps} equation={equation} onEquationChange={onEquationChange} />
    ))

    const nestedD = container.querySelector('[data-path="rhs.args.0"]')!
    fireEvent.click(nestedD)
    fireEvent.click(screen.getByTitle('Edit D fields'))
    fireEvent.input(screen.getByDisplayValue('t'), { target: { value: 'x' } })
    fireEvent.click(screen.getByText('Apply'))

    expect(onEquationChange).toHaveBeenCalledWith({
      lhs: 'x',
      rhs: { op: '+', args: [{ op: 'D', args: ['u'], wrt: 'x' }, 'k'] },
    })
  })

  it('respects readonly mode', () => {
    render(() => <EquationEditor {...mockProps} readonly={true} />)

    const editor = screen.getByRole('button', { name: /x/ })
    expect(editor).toBeInTheDocument()
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

describe('EquationEditor — text mode (DSL)', () => {
  const eq = { lhs: 'x', rhs: { op: '+', args: ['y', 2] } }
  const toText = () => fireEvent.click(screen.getByRole('button', { name: 'Edit as text' }))
  const textarea = () => screen.getByLabelText('Equation text') as HTMLTextAreaElement

  it('toggles to a textarea seeded with the ascii form', () => {
    render(() => <EquationEditor equation={eq} onEquationChange={vi.fn()} />)
    toText()
    expect(textarea()).toBeInTheDocument()
    expect(textarea().value).toBe('x = y + 2')
  })

  it('commits a valid edit on blur, emitting the parsed equation', () => {
    const onEquationChange = vi.fn()
    render(() => <EquationEditor equation={eq} onEquationChange={onEquationChange} />)
    toText()
    fireEvent.input(textarea(), { target: { value: 'x = y + 3' } })
    fireEvent.blur(textarea())
    expect(onEquationChange).toHaveBeenCalledWith({ lhs: 'x', rhs: { op: '+', args: ['y', 3] } })
  })

  it('blocks emit on a parse error and surfaces the error', () => {
    const onEquationChange = vi.fn()
    render(() => <EquationEditor equation={eq} onEquationChange={onEquationChange} />)
    toText()
    fireEvent.input(textarea(), { target: { value: 'x = y +' } }) // trailing operator
    fireEvent.blur(textarea())
    expect(onEquationChange).not.toHaveBeenCalled()
    expect(screen.getByRole('alert')).toBeInTheDocument()
  })

  it('does not emit when the reprint is unchanged (AST left untouched)', () => {
    const onEquationChange = vi.fn()
    render(() => <EquationEditor equation={eq} onEquationChange={onEquationChange} />)
    toText()
    fireEvent.blur(textarea())
    expect(onEquationChange).not.toHaveBeenCalled()
  })

  it('preserves _comment (and other non-lhs/rhs fields) across a text edit', () => {
    const withComment = { lhs: 'x', rhs: { op: '+', args: ['y', 2] }, _comment: 'note' }
    const onEquationChange = vi.fn()
    render(() => <EquationEditor equation={withComment} onEquationChange={onEquationChange} />)
    toText()
    fireEvent.input(textarea(), { target: { value: 'x = y + 3' } })
    fireEvent.blur(textarea())
    expect(onEquationChange).toHaveBeenCalledWith({
      lhs: 'x',
      rhs: { op: '+', args: ['y', 3] },
      _comment: 'note',
    })
  })

  it('blocks leaving text mode while the buffer is unparseable', () => {
    render(() => <EquationEditor equation={eq} onEquationChange={vi.fn()} />)
    toText()
    fireEvent.input(textarea(), { target: { value: 'x = y +' } })
    // The toggle now reads "Structural"; clicking it must NOT switch back.
    fireEvent.click(screen.getByRole('button', { name: 'Structural' }))
    expect(textarea()).toBeInTheDocument() // still in text mode
    expect(screen.getByRole('alert')).toBeInTheDocument()
  })

  it('does not show the text toggle in readonly mode', () => {
    render(() => <EquationEditor equation={eq} readonly onEquationChange={vi.fn()} />)
    expect(screen.queryByRole('button', { name: 'Edit as text' })).not.toBeInTheDocument()
  })
})
