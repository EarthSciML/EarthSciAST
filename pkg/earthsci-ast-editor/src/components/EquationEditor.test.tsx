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
