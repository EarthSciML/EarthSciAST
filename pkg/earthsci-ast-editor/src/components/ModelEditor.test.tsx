import { describe, it, beforeEach, expect, vi } from 'vitest'
import { render, screen, fireEvent, within } from '@solidjs/testing-library'
import type { Model } from '@earthsciml/ast'
import { ModelEditor } from './ModelEditor'

describe('ModelEditor', () => {
  const mockModel: Model = {
    variables: {
      x: {
        type: 'state',
        default: 1.0,
        units: 'm',
        description: 'Position variable',
      },
      k_rate: {
        type: 'parameter',
        default: 0.5,
        units: 's⁻¹',
        description: 'Rate constant',
      },
    },
    equations: [
      {
        lhs: 'x',
        rhs: { op: '+', args: ['y', 2] },
      },
    ],
    continuous_events: [],
    discrete_events: [],
  }

  const mockProps = {
    model: mockModel,
    name: 'Test Model',
    description: 'A test model for demonstration',
    onModelChange: vi.fn(),
    readonly: false,
    showPalette: true,
  }

  beforeEach(() => {
    vi.clearAllMocks()
  })

  it('renders model name and description', () => {
    render(() => <ModelEditor {...mockProps} />)

    expect(screen.getByText('Test Model')).toBeInTheDocument()
    expect(screen.getByText('A test model for demonstration')).toBeInTheDocument()
  })

  it('renders variables panel with grouped variables', () => {
    const { container } = render(() => <ModelEditor {...mockProps} />)

    // Scope the assertions to the variables panel so unrelated occurrences (in
    // the equation list or the palette) don't make the counts brittle.
    const panel = within(container.querySelector('.variables-panel') as HTMLElement)
    expect(panel.getByText(/Variables \(2\)/)).toBeInTheDocument()
    expect(panel.getAllByText('x')).toHaveLength(1)
    expect(panel.getAllByText('k_rate')).toHaveLength(1)
  })

  it('renders equations panel', () => {
    render(() => <ModelEditor {...mockProps} />)

    expect(screen.getByText(/Equations \(1\)/)).toBeInTheDocument()
  })

  it('renders events panel', () => {
    render(() => <ModelEditor {...mockProps} />)

    expect(screen.getByText(/Events \(0\)/)).toBeInTheDocument()
  })

  it('shows add buttons in non-readonly mode', () => {
    render(() => <ModelEditor {...mockProps} />)

    // Look for add buttons (they have '+' text)
    const addButtons = screen.getAllByText('+')
    expect(addButtons.length).toBeGreaterThan(0)
  })

  it('hides add buttons in readonly mode', () => {
    render(() => <ModelEditor {...mockProps} readonly={true} showPalette={false} />)

    // In readonly mode, main panel add buttons should not be present
    expect(screen.queryByLabelText('Add new variable')).not.toBeInTheDocument()
    expect(screen.queryByLabelText('Add new equation')).not.toBeInTheDocument()
  })

  it('handles panel expansion/collapse', () => {
    render(() => <ModelEditor {...mockProps} />)

    // Find a panel header (variables panel)
    const variablesHeader = screen.getByText(/Variables \(2\)/)
    expect(variablesHeader).toBeInTheDocument()

    // Click to collapse (the expand icon is part of the header)
    fireEvent.click(variablesHeader)

    // The panel should still be visible (since we're testing the basic interaction)
    expect(variablesHeader).toBeInTheDocument()
  })

  it('displays empty state for models without content', () => {
    const emptyModel: Model = {
      variables: {},
      equations: [],
      continuous_events: [],
      discrete_events: [],
    }

    render(() => <ModelEditor {...mockProps} model={emptyModel} name="Empty Model" />)

    expect(screen.getByText('No variables defined')).toBeInTheDocument()
    expect(screen.getByText('No equations defined')).toBeInTheDocument()
    expect(screen.getByText('No events defined')).toBeInTheDocument()
  })

  it('applies custom CSS classes', () => {
    const { container } = render(() => <ModelEditor {...mockProps} class="custom-class" />)

    const editor = container.querySelector('.model-editor')
    expect(editor).toHaveClass('custom-class')
  })

  it('includes readonly class when in readonly mode', () => {
    const { container } = render(() => <ModelEditor {...mockProps} readonly={true} />)

    const editor = container.querySelector('.model-editor')
    expect(editor).toHaveClass('readonly')
  })

  it('adds a variable through the inline form (no prompt dialogs)', () => {
    const onModelChange = vi.fn()
    render(() => <ModelEditor {...mockProps} onModelChange={onModelChange} />)

    // Open the inline add-variable form
    fireEvent.click(screen.getByLabelText('Add new variable'))
    expect(screen.getByText('Add variable')).toBeInTheDocument()

    // Fill in the name and confirm
    fireEvent.input(screen.getByLabelText('Name'), { target: { value: 'CO2' } })
    fireEvent.click(screen.getByText('Add'))

    expect(onModelChange).toHaveBeenCalledWith(
      expect.objectContaining({
        variables: expect.objectContaining({
          CO2: expect.objectContaining({ type: 'parameter', default: 0 }),
        }),
      }),
    )

    // The form closes after a successful add
    expect(screen.queryByText('Add variable')).not.toBeInTheDocument()
  })

  it('requires a variable name in the inline add form', () => {
    const onModelChange = vi.fn()
    render(() => <ModelEditor {...mockProps} onModelChange={onModelChange} />)

    fireEvent.click(screen.getByLabelText('Add new variable'))
    fireEvent.click(screen.getByText('Add'))

    expect(screen.getByText('Variable name is required')).toBeInTheDocument()
    expect(onModelChange).not.toHaveBeenCalled()
  })

  it('edits a variable through the inline form', () => {
    const onModelChange = vi.fn()
    render(() => <ModelEditor {...mockProps} onModelChange={onModelChange} />)

    // Click the k_rate variable item to open the edit form
    const variableName = screen
      .getAllByText('k_rate')
      .find((el) => el.classList.contains('variable-name'))!
    fireEvent.click(variableName.closest('.variable-item')!)

    expect(screen.getByText('Edit variable k_rate')).toBeInTheDocument()

    fireEvent.input(screen.getByLabelText('Default value'), { target: { value: '2.5' } })
    fireEvent.click(screen.getByText('Save'))

    expect(onModelChange).toHaveBeenCalledWith(
      expect.objectContaining({
        variables: expect.objectContaining({
          k_rate: expect.objectContaining({ default: 2.5 }),
        }),
      }),
    )
  })

  it('edits event conditions inline with JSON validation instead of alert()', () => {
    const eventModel: Model = {
      ...mockModel,
      continuous_events: [
        {
          name: 'Threshold event',
          conditions: ['c1'],
          affects: [{ lhs: 'x', rhs: 0 }],
        },
      ],
    }
    const onModelChange = vi.fn()
    render(() => <ModelEditor {...mockProps} model={eventModel} onModelChange={onModelChange} />)

    // The condition edit button comes before the affect edit button in DOM order
    fireEvent.click(screen.getAllByText('Edit')[0])
    const conditionInput = screen.getByLabelText('Condition (JSON)')

    // Invalid JSON shows an inline error and does not modify the model
    fireEvent.input(conditionInput, { target: { value: 'not json' } })
    fireEvent.click(screen.getByText('Save'))
    expect(screen.getByText('Invalid JSON format')).toBeInTheDocument()
    expect(onModelChange).not.toHaveBeenCalled()

    // Valid JSON updates the condition and closes the form
    fireEvent.input(conditionInput, { target: { value: '{"op":">","args":["x",1]}' } })
    fireEvent.click(screen.getByText('Save'))

    expect(onModelChange).toHaveBeenCalledWith(
      expect.objectContaining({
        continuous_events: [
          expect.objectContaining({
            conditions: [{ op: '>', args: ['x', 1] }],
          }),
        ],
      }),
    )
    expect(screen.queryByLabelText('Condition (JSON)')).not.toBeInTheDocument()
  })

  it('adds a continuous event through the inline form', () => {
    const onModelChange = vi.fn()
    render(() => <ModelEditor {...mockProps} onModelChange={onModelChange} />)

    fireEvent.click(screen.getByTitle('Add continuous event'))
    fireEvent.input(screen.getByLabelText('Name'), { target: { value: 'My Event' } })
    fireEvent.click(screen.getByText('Add'))

    expect(onModelChange).toHaveBeenCalledWith(
      expect.objectContaining({
        continuous_events: [expect.objectContaining({ name: 'My Event' })],
      }),
    )
  })

  it('highlights hovered variables in the equation list', () => {
    // Editing is text-only; equations render as structural nodes (where the
    // hover highlight is observable) only in readonly mode. Variable hovering in
    // the variables panel stays active regardless of readonly.
    const { container } = render(() => <ModelEditor {...mockProps} readonly={true} />)

    expect(container.querySelector('.esm-expression-node.highlighted')).toBeNull()

    // Hover the 'x' variable in the variables panel
    const variableName = screen
      .getAllByText('x')
      .find((el) => el.classList.contains('variable-name'))!
    const variableItem = variableName.closest('.variable-item')!
    fireEvent.mouseEnter(variableItem)

    const highlighted = container.querySelector('.esm-expression-node.highlighted')
    expect(highlighted).not.toBeNull()
    expect(highlighted!.textContent).toBe('x')

    // Leaving the variable clears the highlight
    fireEvent.mouseLeave(variableItem)
    expect(container.querySelector('.esm-expression-node.highlighted')).toBeNull()
  })

  it('shows expression palette when enabled', () => {
    render(() => <ModelEditor {...mockProps} showPalette={true} />)

    // The palette should be rendered (it has specific classes)
    const palette = document.querySelector('.palette-sidebar')
    expect(palette).toBeInTheDocument()
  })

  it('hides expression palette when disabled', () => {
    render(() => <ModelEditor {...mockProps} showPalette={false} />)

    // The palette should not be rendered
    const palette = document.querySelector('.palette-sidebar')
    expect(palette).not.toBeInTheDocument()
  })
})
