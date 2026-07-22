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
    render(() => <EquationEditor {...mockProps} readonly={true} />)

    expect(screen.getByText('x')).toBeInTheDocument()
    expect(screen.getByText('=')).toBeInTheDocument()
    expect(screen.getByText('+')).toBeInTheDocument()
  })

  it('respects readonly mode (renders the lhs variable, no editing affordance)', () => {
    const { container } = render(() => <EquationEditor {...mockProps} readonly={true} />)

    expect(screen.getByText('x')).toBeInTheDocument()
    expect(screen.queryByLabelText('Equation text')).not.toBeInTheDocument()
    expect(container.querySelector('.esm-eq-display')).toBeNull()
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

describe('EquationEditor — click-to-edit (math by default, DSL on click)', () => {
  const eq = { lhs: 'x', rhs: { op: '+', args: ['y', 2] } }
  const textarea = () => screen.getByLabelText('Equation text') as HTMLTextAreaElement
  const descInput = () => screen.getByLabelText('Equation description') as HTMLInputElement
  const openEditor = (container: HTMLElement) =>
    fireEvent.click(container.querySelector('.esm-eq-display') as HTMLElement)
  // ⌘/Ctrl+Enter commits (deterministic vs. focusout in jsdom).
  const commit = () => fireEvent.keyDown(textarea(), { key: 'Enter', ctrlKey: true })

  it('editable mode renders clickable math by default, not a textarea', () => {
    const { container } = render(() => <EquationEditor equation={eq} onEquationChange={vi.fn()} />)
    expect(container.querySelector('.esm-eq-display')).not.toBeNull()
    expect(screen.queryByLabelText('Equation text')).not.toBeInTheDocument()
  })

  it('clicking the math opens a textarea seeded with the ascii form + a description field', () => {
    const { container } = render(() => <EquationEditor equation={eq} onEquationChange={vi.fn()} />)
    openEditor(container)
    expect(textarea()).toBeInTheDocument()
    expect(textarea().value).toBe('x = y + 2')
    expect(descInput()).toBeInTheDocument()
    expect(descInput().value).toBe('')
  })

  it('commits a valid edit, emitting the parsed equation', () => {
    const onEquationChange = vi.fn()
    const { container } = render(() => (
      <EquationEditor equation={eq} onEquationChange={onEquationChange} />
    ))
    openEditor(container)
    fireEvent.input(textarea(), { target: { value: 'x = y + 3' } })
    commit()
    expect(onEquationChange).toHaveBeenCalledWith({ lhs: 'x', rhs: { op: '+', args: ['y', 3] } })
  })

  it('blocks emit on a parse error and surfaces it, staying open', () => {
    const onEquationChange = vi.fn()
    const { container } = render(() => (
      <EquationEditor equation={eq} onEquationChange={onEquationChange} />
    ))
    openEditor(container)
    fireEvent.input(textarea(), { target: { value: 'x = y +' } }) // trailing operator
    commit()
    expect(onEquationChange).not.toHaveBeenCalled()
    expect(screen.getByRole('alert')).toBeInTheDocument()
    expect(textarea()).toBeInTheDocument() // still editing
  })

  it('does not emit when nothing changed', () => {
    const onEquationChange = vi.fn()
    const { container } = render(() => (
      <EquationEditor equation={eq} onEquationChange={onEquationChange} />
    ))
    openEditor(container)
    commit()
    expect(onEquationChange).not.toHaveBeenCalled()
  })

  it('does not emit on open+commit with no edit even for a non-reprint-idempotent node', () => {
    // A wrt-less `D(O3, t)` seeds as `D(O3, t)` but reprints as `D(O3)/Dt`, so a
    // reprint-only guard would spuriously rewrite it. Gating emit on the buffer
    // having actually changed prevents that.
    const nonIdempotent = { lhs: 'x', rhs: { op: 'D', args: ['O3', 't'] } }
    const onEquationChange = vi.fn()
    const { container } = render(() => (
      <EquationEditor equation={nonIdempotent} onEquationChange={onEquationChange} />
    ))
    openEditor(container)
    expect(textarea().value).toBe('x = D(O3, t)')
    commit()
    expect(onEquationChange).not.toHaveBeenCalled()
  })

  it('preserves _comment across an equation-only edit', () => {
    const withComment = { lhs: 'x', rhs: { op: '+', args: ['y', 2] }, _comment: 'note' }
    const onEquationChange = vi.fn()
    const { container } = render(() => (
      <EquationEditor equation={withComment} onEquationChange={onEquationChange} />
    ))
    openEditor(container)
    fireEvent.input(textarea(), { target: { value: 'x = y + 3' } })
    commit()
    expect(onEquationChange).toHaveBeenCalledWith({
      lhs: 'x',
      rhs: { op: '+', args: ['y', 3] },
      _comment: 'note',
    })
  })

  it('edits the description alone and emits _comment (equation AST untouched)', () => {
    const onEquationChange = vi.fn()
    const { container } = render(() => (
      <EquationEditor equation={eq} onEquationChange={onEquationChange} />
    ))
    openEditor(container)
    fireEvent.input(descInput(), { target: { value: 'my note' } })
    commit()
    expect(onEquationChange).toHaveBeenCalledWith({
      lhs: 'x',
      rhs: { op: '+', args: ['y', 2] },
      _comment: 'my note',
    })
  })

  it('adds a description when none exists via the "+ description" affordance', () => {
    const onEquationChange = vi.fn()
    render(() => <EquationEditor equation={eq} onEquationChange={onEquationChange} />)
    fireEvent.click(screen.getByText('+ description'))
    fireEvent.input(descInput(), { target: { value: 'hello' } })
    commit()
    expect(onEquationChange).toHaveBeenCalledWith({
      lhs: 'x',
      rhs: { op: '+', args: ['y', 2] },
      _comment: 'hello',
    })
  })

  it('clears the description when blanked', () => {
    const withComment = { lhs: 'x', rhs: { op: '+', args: ['y', 2] }, _comment: 'note' }
    const onEquationChange = vi.fn()
    const { container } = render(() => (
      <EquationEditor equation={withComment} onEquationChange={onEquationChange} />
    ))
    // Clicking the description opens the editor focused there.
    fireEvent.click(screen.getByText('note'))
    fireEvent.input(descInput(), { target: { value: '' } })
    commit()
    expect(onEquationChange).toHaveBeenCalledWith({ lhs: 'x', rhs: { op: '+', args: ['y', 2] } })
  })

  it('reverts and closes on Escape without emitting', () => {
    const onEquationChange = vi.fn()
    const { container } = render(() => (
      <EquationEditor equation={eq} onEquationChange={onEquationChange} />
    ))
    openEditor(container)
    fireEvent.input(textarea(), { target: { value: 'x = y + 9' } })
    fireEvent.keyDown(textarea(), { key: 'Escape' })
    expect(onEquationChange).not.toHaveBeenCalled()
    expect(screen.queryByLabelText('Equation text')).not.toBeInTheDocument()
    expect(container.querySelector('.esm-eq-display')).not.toBeNull()
  })
})
