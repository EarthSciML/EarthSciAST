import { describe, it, beforeEach, expect, vi } from 'vitest';
import { render, screen } from '@solidjs/testing-library';
import { createSignal } from 'solid-js';
import { ExpressionEditor } from './ExpressionEditor';

describe('ExpressionEditor', () => {
  const mockExpression = { op: '+', args: ['x', 2] };

  const mockProps = {
    initialExpression: mockExpression,
    onChange: vi.fn(),
    highlightedVars: new Set<string>(),
    allowEditing: true,
    showPalette: false,
    showValidation: false,
  };

  beforeEach(() => {
    vi.clearAllMocks();
  });

  it('renders expression without equals sign', () => {
    render(() => <ExpressionEditor {...mockProps} />);

    expect(screen.getByText('+')).toBeInTheDocument();
    expect(screen.getByText('x')).toBeInTheDocument();
    expect(screen.getByText('2')).toBeInTheDocument();
    // Should NOT have equals sign (unlike EquationEditor)
    expect(screen.queryByText('=')).not.toBeInTheDocument();
  });

  it('handles expression changes', () => {
    const onChange = vi.fn();
    render(() => <ExpressionEditor {...mockProps} onChange={onChange} />);

    // This is a basic test - more complex interaction testing would require
    // mocking the ExpressionNode component's replace functionality
    expect(screen.getByText('+')).toBeInTheDocument();
  });

  it('respects allowEditing=false mode', () => {
    render(() => <ExpressionEditor {...mockProps} allowEditing={false} />);

    const editor = screen.getByRole('button', { name: /\+/ });
    expect(editor).toBeInTheDocument();
    expect(screen.getByText('+')).toBeInTheDocument();
  });

  it('shows palette toggle when showPalette=true', () => {
    render(() => <ExpressionEditor {...mockProps} showPalette={true} />);

    const paletteToggle = screen.getByTitle('Toggle expression palette');
    expect(paletteToggle).toBeInTheDocument();
  });

  it('hides palette toggle when showPalette=false', () => {
    render(() => <ExpressionEditor {...mockProps} showPalette={false} />);

    const paletteToggle = screen.queryByTitle('Toggle expression palette');
    expect(paletteToggle).not.toBeInTheDocument();
  });

  it('shows validation container when showValidation=true', () => {
    render(() => <ExpressionEditor {...mockProps} showValidation={true} />);

    const validationContainer = document.querySelector('.expression-validation');
    expect(validationContainer).toBeInTheDocument();
  });

  it('updates expression when initialExpression prop changes', () => {
    const [expression] = createSignal(mockExpression);

    render(() => <ExpressionEditor {...mockProps} initialExpression={expression()} />);

    expect(screen.getByText('+')).toBeInTheDocument();
    expect(screen.getByText('x')).toBeInTheDocument();

    // Note: This test would need more sophisticated prop update handling
    // in a real scenario, SolidJS components don't automatically re-render
    // when props change like React components do
  });

  it('applies custom CSS class', () => {
    render(() => <ExpressionEditor {...mockProps} class="custom-expression-editor" />);

    const editor = document.querySelector('.expression-editor');
    expect(editor).toHaveClass('expression-editor');
    expect(editor).toHaveClass('custom-expression-editor');
  });

  it('applies readonly class when allowEditing=false', () => {
    render(() => <ExpressionEditor {...mockProps} allowEditing={false} />);

    const editor = document.querySelector('.expression-editor');
    expect(editor).toHaveClass('readonly');
  });

  it('handles simple expression (non-operator)', () => {
    const simpleExpression = 'x';
    render(() => <ExpressionEditor {...mockProps} initialExpression={simpleExpression} />);

    expect(screen.getByText('x')).toBeInTheDocument();
    expect(screen.queryByText('+')).not.toBeInTheDocument();
  });

  it('handles number expression', () => {
    const numberExpression = 42;
    render(() => <ExpressionEditor {...mockProps} initialExpression={numberExpression} />);

    expect(screen.getByText('42')).toBeInTheDocument();
  });
});