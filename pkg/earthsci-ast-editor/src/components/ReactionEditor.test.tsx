import { describe, it, beforeEach, expect, vi } from 'vitest'
import { render, screen, fireEvent } from '@solidjs/testing-library'
import type { ReactionSystem } from '@earthsciml/ast'
import { ReactionEditor } from './ReactionEditor'

describe('ReactionEditor', () => {
  const mockReactionSystem: ReactionSystem = {
    species: {
      NO: {
        description: 'Nitrogen monoxide',
      },
      O3: {
        description: 'Ozone',
      },
      NO2: {
        description: 'Nitrogen dioxide',
      },
    },
    parameters: {},
    reactions: [
      {
        id: 'R1',
        name: 'NO oxidation',
        substrates: [
          { species: 'NO', stoichiometry: 1 },
          { species: 'O3', stoichiometry: 1 },
        ],
        products: [{ species: 'NO2', stoichiometry: 1 }],
        rate: 'k_NO_O3',
      },
    ],
  }

  const mockProps = {
    reactionSystem: mockReactionSystem,
    onReactionSystemChange: vi.fn(),
    highlightedVars: new Set<string>(),
    readonly: false,
  }

  beforeEach(() => {
    vi.clearAllMocks()
  })

  it('renders reaction count in header', () => {
    render(() => <ReactionEditor {...mockProps} />)

    expect(screen.getByText('Reactions (1)')).toBeInTheDocument()
  })

  it('renders a reaction as clickable rendered math when not editing', () => {
    const { container } = render(() => <ReactionEditor {...mockProps} />)

    // The reaction reads as rendered chemistry (MathML), and the whole line is a
    // click-to-edit affordance — not the old plain-string reactants/products.
    const equation = container.querySelector('.reaction-equation') as HTMLElement
    expect(equation).toBeInTheDocument()
    expect(equation).toHaveAttribute('role', 'button')
    expect(equation.querySelector('.esm-math')).toBeInTheDocument()
  })

  it('renders species panel', () => {
    render(() => <ReactionEditor {...mockProps} />)

    expect(screen.getByText(/Species \(3\)/)).toBeInTheDocument()
    expect(screen.getByText('NO')).toBeInTheDocument()
    expect(screen.getByText('Nitrogen monoxide')).toBeInTheDocument()
  })

  it('renders parameters panel', () => {
    render(() => <ReactionEditor {...mockProps} />)

    expect(screen.getByText(/Parameters \(0\)/)).toBeInTheDocument()
  })

  it('shows add buttons in non-readonly mode', () => {
    render(() => <ReactionEditor {...mockProps} />)

    expect(screen.getByText('+ Add Reaction')).toBeInTheDocument()

    // Species and parameters panels should also have add buttons
    const addButtons = screen.getAllByText('+')
    expect(addButtons.length).toBeGreaterThan(0)
  })

  it('hides add buttons in readonly mode', () => {
    render(() => <ReactionEditor {...mockProps} readonly={true} />)

    expect(screen.queryByText('+ Add Reaction')).not.toBeInTheDocument()
  })

  it('displays empty state for reaction system without reactions', () => {
    const emptySystem = {
      species: {},
      parameters: {},
      reactions: [],
    } as unknown as ReactionSystem

    render(() => <ReactionEditor {...mockProps} reactionSystem={emptySystem} />)

    expect(screen.getByText('No reactions defined')).toBeInTheDocument()
    expect(screen.getByText('No species defined')).toBeInTheDocument()
  })

  it('applies custom CSS classes', () => {
    const { container } = render(() => <ReactionEditor {...mockProps} class="custom-class" />)

    const editor = container.querySelector('.reaction-editor')
    expect(editor).toHaveClass('custom-class')
  })

  it('includes readonly class when in readonly mode', () => {
    const { container } = render(() => <ReactionEditor {...mockProps} readonly={true} />)

    const editor = container.querySelector('.reaction-editor')
    expect(editor).toHaveClass('readonly')
  })

  it('renders reaction name when provided', () => {
    render(() => <ReactionEditor {...mockProps} />)

    expect(screen.getByText('NO oxidation')).toBeInTheDocument()
  })

  it('shows all parameters regardless of naming convention', () => {
    const paramSystem: ReactionSystem = {
      ...mockReactionSystem,
      parameters: {
        alpha: { default: 2 },
        k_NO_O3: { default: 1 },
        temperature_ref: { default: 298.15 },
      },
    }

    render(() => <ReactionEditor {...mockProps} reactionSystem={paramSystem} />)

    // Previously the panel filtered parameters by name spelling (k_/rate/const),
    // hiding everything else. All parameters must be listed.
    expect(screen.getByText(/Parameters \(3\)/)).toBeInTheDocument()
    expect(screen.getByText('alpha')).toBeInTheDocument()
    expect(screen.getByText('k_NO_O3')).toBeInTheDocument()
    expect(screen.getByText('temperature_ref')).toBeInTheDocument()
  })

  it('adds a parameter through the inline form (no prompt dialogs)', () => {
    const onReactionSystemChange = vi.fn()
    render(() => <ReactionEditor {...mockProps} onReactionSystemChange={onReactionSystemChange} />)

    fireEvent.click(screen.getByLabelText('Add new parameter'))
    fireEvent.input(screen.getByLabelText('Name'), { target: { value: 'j_photo' } })
    fireEvent.input(screen.getByLabelText('Default value'), { target: { value: '2.5' } })
    fireEvent.click(screen.getByText('Add'))

    expect(onReactionSystemChange).toHaveBeenCalledWith(
      expect.objectContaining({
        parameters: expect.objectContaining({
          j_photo: expect.objectContaining({ default: 2.5 }),
        }),
      }),
    )
  })

  it('adds a species with default value and units through the inline form', () => {
    const onReactionSystemChange = vi.fn()
    render(() => <ReactionEditor {...mockProps} onReactionSystemChange={onReactionSystemChange} />)

    fireEvent.click(screen.getByLabelText('Add new species'))
    fireEvent.input(screen.getByLabelText('Name (chemical formula)'), { target: { value: 'SO2' } })
    fireEvent.input(screen.getByLabelText('Default value'), { target: { value: '5' } })
    fireEvent.input(screen.getByLabelText('Units'), { target: { value: 'ppb' } })
    fireEvent.click(screen.getByText('Add'))

    expect(onReactionSystemChange).toHaveBeenCalledWith(
      expect.objectContaining({
        species: expect.objectContaining({
          SO2: expect.objectContaining({ default: 5, units: 'ppb' }),
        }),
      }),
    )
  })

  it('edits a species default value and units through the inline form', () => {
    const onReactionSystemChange = vi.fn()
    render(() => <ReactionEditor {...mockProps} onReactionSystemChange={onReactionSystemChange} />)

    // Click the NO species item to open the inline edit form
    const speciesItem = screen.getByText('Nitrogen monoxide').closest('.species-item')!
    fireEvent.click(speciesItem)

    expect(screen.getByText('Edit species NO')).toBeInTheDocument()

    fireEvent.input(screen.getByLabelText('Default value'), { target: { value: '12.5' } })
    fireEvent.input(screen.getByLabelText('Units'), { target: { value: 'ppb' } })
    fireEvent.click(screen.getByText('Save'))

    expect(onReactionSystemChange).toHaveBeenCalledWith(
      expect.objectContaining({
        species: expect.objectContaining({
          NO: expect.objectContaining({
            default: 12.5,
            units: 'ppb',
            description: 'Nitrogen monoxide',
          }),
        }),
      }),
    )
  })

  it('assigns the first unused R-id when adding after a deletion (regression)', () => {
    // R1 and R3 exist (R2 was deleted). The old `R${length+1}` scheme would
    // reuse R3; the fix assigns the first free id, R2.
    const gappedSystem = {
      species: {},
      parameters: {},
      reactions: [
        { id: 'R1', substrates: [{ species: 'A' }], products: [{ species: 'B' }], rate: 'k1' },
        { id: 'R3', substrates: [{ species: 'C' }], products: [{ species: 'D' }], rate: 'k3' },
      ],
    } as unknown as ReactionSystem

    const onReactionSystemChange = vi.fn()
    render(() => (
      <ReactionEditor
        {...mockProps}
        reactionSystem={gappedSystem}
        onReactionSystemChange={onReactionSystemChange}
      />
    ))

    fireEvent.click(screen.getByText('+ Add Reaction'))

    expect(onReactionSystemChange).toHaveBeenCalledTimes(1)
    const updated = onReactionSystemChange.mock.calls[0][0] as ReactionSystem
    expect(updated.reactions).toHaveLength(3)
    expect(updated.reactions[2].id).toBe('R2')
  })
})

describe('ReactionEditor — whole-reaction text editing (the DSL surface)', () => {
  const system: ReactionSystem = {
    species: { NO: {}, O3: {}, NO2: {}, O2: {} },
    parameters: {},
    reactions: [
      {
        id: 'R1',
        substrates: [{ species: 'NO', stoichiometry: 1 }],
        products: [{ species: 'NO2', stoichiometry: 1 }],
        rate: 'k_NO_O3',
      },
    ],
  }

  const clickEquation = (container: HTMLElement) =>
    fireEvent.click(container.querySelector('.reaction-equation') as HTMLElement)
  const textarea = () => screen.getByLabelText('Reaction text') as HTMLTextAreaElement

  beforeEach(() => vi.clearAllMocks())

  it('opens a textarea seeded with the reaction ascii form on click', () => {
    const { container } = render(() => (
      <ReactionEditor reactionSystem={system} onReactionSystemChange={vi.fn()} />
    ))
    clickEquation(container)
    expect(textarea()).toBeInTheDocument()
    expect(textarea().value).toBe('NO -> [k_NO_O3] NO2')
  })

  it('commits a reactant/stoichiometry edit on blur, routing the whole reaction through onReactionSystemChange', () => {
    const onReactionSystemChange = vi.fn()
    const { container } = render(() => (
      <ReactionEditor reactionSystem={system} onReactionSystemChange={onReactionSystemChange} />
    ))
    clickEquation(container)
    fireEvent.input(textarea(), { target: { value: '2 NO + O3 -> [k_NO_O3] NO2 + O2' } })
    fireEvent.blur(textarea())

    expect(onReactionSystemChange).toHaveBeenCalledTimes(1)
    const updated = onReactionSystemChange.mock.calls[0][0] as ReactionSystem
    expect(updated.reactions[0].substrates).toEqual([
      { species: 'NO', stoichiometry: 2 },
      { species: 'O3', stoichiometry: 1 },
    ])
    expect(updated.reactions[0].products).toEqual([
      { species: 'NO2', stoichiometry: 1 },
      { species: 'O2', stoichiometry: 1 },
    ])
    // Untouched id survives the merge.
    expect(updated.reactions[0].id).toBe('R1')
  })

  it('commits a rate edit made on the same line', () => {
    const onReactionSystemChange = vi.fn()
    const { container } = render(() => (
      <ReactionEditor reactionSystem={system} onReactionSystemChange={onReactionSystemChange} />
    ))
    clickEquation(container)
    fireEvent.input(textarea(), { target: { value: 'NO -> [k_NO_O3 * 2] NO2' } })
    fireEvent.blur(textarea())

    const updated = onReactionSystemChange.mock.calls[0][0] as ReactionSystem
    expect(updated.reactions[0].rate).toEqual({ op: '*', args: ['k_NO_O3', 2] })
  })

  it('blocks emit on a parse error and surfaces the error', () => {
    const onReactionSystemChange = vi.fn()
    const { container } = render(() => (
      <ReactionEditor reactionSystem={system} onReactionSystemChange={onReactionSystemChange} />
    ))
    clickEquation(container)
    fireEvent.input(textarea(), { target: { value: 'NO -> NO2' } }) // no rate
    fireEvent.blur(textarea())

    expect(onReactionSystemChange).not.toHaveBeenCalled()
    expect(screen.getByRole('alert')).toBeInTheDocument()
  })

  it('does not emit when the reprint is unchanged (reaction AST left untouched)', () => {
    const onReactionSystemChange = vi.fn()
    const { container } = render(() => (
      <ReactionEditor reactionSystem={system} onReactionSystemChange={onReactionSystemChange} />
    ))
    clickEquation(container)
    fireEvent.blur(textarea())
    expect(onReactionSystemChange).not.toHaveBeenCalled()
  })

  it('does not open a text editor in readonly mode', () => {
    const { container } = render(() => (
      <ReactionEditor reactionSystem={system} onReactionSystemChange={vi.fn()} readonly={true} />
    ))
    clickEquation(container)
    expect(screen.queryByLabelText('Reaction text')).not.toBeInTheDocument()
  })
})
