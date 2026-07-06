/**
 * Tests for ExpressionPalette component
 */

import { render, screen, fireEvent } from '@solidjs/testing-library';
import { describe, it, expect, vi } from 'vitest';
import { ExpressionPalette } from './ExpressionPalette';
import type { Model } from 'earthsci-toolkit';

describe('ExpressionPalette', () => {
  const mockModel: Model = {
    variables: {
      temperature: { type: 'state', units: 'K' },
      pressure: { type: 'state', units: 'Pa' },
      CO2: { type: 'state', units: 'mol/mol' },
      H2O: { type: 'state', units: 'mol/mol' },
      O3: { type: 'state', units: 'mol/mol' }
    },
    equations: []
  };

  describe('Basic rendering', () => {
    it('renders the expression palette', () => {
      const onInsert = vi.fn();
      render(() => <ExpressionPalette onInsertExpression={onInsert} />);

      // Check for category sections
      expect(screen.getByText('Calculus')).toBeInTheDocument();
      expect(screen.getByText('Arithmetic')).toBeInTheDocument();
      expect(screen.getByText('Functions')).toBeInTheDocument();
      expect(screen.getByText('Logic')).toBeInTheDocument();
    });

    it('renders expression templates', () => {
      const onInsert = vi.fn();
      render(() => <ExpressionPalette onInsertExpression={onInsert} />);

      // Check for some specific templates
      expect(screen.getByText('D(_, t)')).toBeInTheDocument();
      expect(screen.getByText('_ + _')).toBeInTheDocument();
      expect(screen.getByText('exp(_)')).toBeInTheDocument();
      expect(screen.getByText('ifelse(_, _, _)')).toBeInTheDocument();
    });

    it('renders context suggestions when model is provided', () => {
      const onInsert = vi.fn();
      render(() => <ExpressionPalette currentModel={mockModel} onInsertExpression={onInsert} />);

      // Check for model context section
      expect(screen.getByText('Model Context')).toBeInTheDocument();

      // Check for variables and species
      expect(screen.getByText('temperature')).toBeInTheDocument();
      expect(screen.getByText('pressure')).toBeInTheDocument();
      expect(screen.getByText('CO2')).toBeInTheDocument();
      expect(screen.getByText('H2O')).toBeInTheDocument();
      expect(screen.getByText('O3')).toBeInTheDocument();
    });

    it('can be hidden', () => {
      const onInsert = vi.fn();
      render(() => <ExpressionPalette visible={false} onInsertExpression={onInsert} />);

      const palette = document.querySelector('.expression-palette');
      expect(palette).toHaveClass('hidden');
    });
  });

  describe('Search functionality', () => {
    it('filters templates based on search query', () => {
      const onInsert = vi.fn();
      render(() => (
        <ExpressionPalette
          searchQuery="exp"
          onInsertExpression={onInsert}
        />
      ));

      // Should show exponential and power (exp) templates
      expect(screen.getByText('exp(_)')).toBeInTheDocument();
      expect(screen.getByText('_ ^ _')).toBeInTheDocument(); // Power has 'exp' in keywords

      // Should not show unrelated templates
      expect(screen.queryByText('sin(_)')).not.toBeInTheDocument();
    });

    it('shows no results message when search has no matches', () => {
      const onInsert = vi.fn();
      render(() => (
        <ExpressionPalette
          searchQuery="nonexistent"
          onInsertExpression={onInsert}
        />
      ));

      expect(screen.getByText('No expressions found for "nonexistent"')).toBeInTheDocument();
      expect(screen.getByText('Try searching for operators, functions, or keywords')).toBeInTheDocument();
    });

    it('calls onSearchQueryChange when search input changes', () => {
      const onInsert = vi.fn();
      const onSearchChange = vi.fn();
      render(() => (
        <ExpressionPalette
          onInsertExpression={onInsert}
          onSearchQueryChange={onSearchChange}
          searchQuery=""
        />
      ));

      // Initially no search input should be visible
      expect(screen.queryByPlaceholderText(/Search expressions/)).not.toBeInTheDocument();

      // Re-render with search query to show search input
      render(() => (
        <ExpressionPalette
          onInsertExpression={onInsert}
          onSearchQueryChange={onSearchChange}
          searchQuery="test"
        />
      ));

      const searchInput = screen.getByDisplayValue('test');
      fireEvent.input(searchInput, { target: { value: 'new query' } });

      expect(onSearchChange).toHaveBeenCalledWith('new query');
    });
  });

  describe('Quick insert mode', () => {
    it('shows search input and help text in quick insert mode', () => {
      const onInsert = vi.fn();
      const onClose = vi.fn();
      render(() => (
        <ExpressionPalette
          quickInsertMode={true}
          onInsertExpression={onInsert}
          onCloseQuickInsert={onClose}
        />
      ));

      expect(screen.getByPlaceholderText(/Search expressions/)).toBeInTheDocument();
      // Check for the existence of the help section by looking for key text components
      expect(document.querySelector('.quick-insert-help')).toBeInTheDocument();
    });

    it('applies quick-insert-mode class', () => {
      const onInsert = vi.fn();
      const onClose = vi.fn();
      render(() => (
        <ExpressionPalette
          quickInsertMode={true}
          onInsertExpression={onInsert}
          onCloseQuickInsert={onClose}
        />
      ));

      const palette = document.querySelector('.expression-palette');
      expect(palette).toHaveClass('quick-insert-mode');
    });

    it('calls onCloseQuickInsert when Escape is pressed', () => {
      const onInsert = vi.fn();
      const onClose = vi.fn();
      render(() => (
        <ExpressionPalette
          quickInsertMode={true}
          onInsertExpression={onInsert}
          onCloseQuickInsert={onClose}
        />
      ));

      fireEvent.keyDown(document.querySelector('.expression-palette')!, { key: 'Escape' });
      expect(onClose).toHaveBeenCalled();
    });

    it('calls onCloseQuickInsert after inserting an expression', () => {
      const onInsert = vi.fn();
      const onClose = vi.fn();
      render(() => (
        <ExpressionPalette
          quickInsertMode={true}
          onInsertExpression={onInsert}
          onCloseQuickInsert={onClose}
        />
      ));

      // Click on a template
      fireEvent.click(screen.getByText('D(_, t)'));

      expect(onInsert).toHaveBeenCalled();
      expect(onClose).toHaveBeenCalled();
    });
  });

  describe('Expression insertion', () => {
    it('calls onInsertExpression when template is clicked', () => {
      const onInsert = vi.fn();
      render(() => <ExpressionPalette onInsertExpression={onInsert} />);

      fireEvent.click(screen.getByText('D(_, t)'));

      expect(onInsert).toHaveBeenCalledWith({
        op: 'D',
        args: ['_placeholder_', 't']
      });
    });

    it('calls onInsertExpression when context item is clicked', () => {
      const onInsert = vi.fn();
      render(() => <ExpressionPalette currentModel={mockModel} onInsertExpression={onInsert} />);

      fireEvent.click(screen.getByText('temperature'));

      expect(onInsert).toHaveBeenCalledWith('temperature');
    });
  });

  describe('Drag and drop functionality', () => {
    it('makes templates draggable', () => {
      const onInsert = vi.fn();
      render(() => <ExpressionPalette onInsertExpression={onInsert} />);

      const template = screen.getByText('D(_, t)').closest('.expression-template');
      expect(template).toHaveAttribute('draggable', 'true');
    });

    it('sets correct drag data on drag start', () => {
      const onInsert = vi.fn();
      render(() => <ExpressionPalette onInsertExpression={onInsert} />);

      const template = screen.getByText('D(_, t)').closest('.expression-template')!;
      const dataTransfer = { effectAllowed: '', setData: vi.fn() };

      fireEvent.dragStart(template, { dataTransfer });

      expect(dataTransfer.effectAllowed).toBe('copy');
      expect(dataTransfer.setData).toHaveBeenCalledWith(
        'application/json',
        JSON.stringify({
          type: 'expression-template',
          expression: { op: 'D', args: ['_placeholder_', 't'] },
          templateId: 'derivative'
        })
      );
    });
  });

  describe('Accessibility', () => {
    it('provides proper ARIA labels for templates', () => {
      const onInsert = vi.fn();
      render(() => <ExpressionPalette onInsertExpression={onInsert} />);

      const derivativeTemplate = screen.getByLabelText(/Insert D\(_, t\): Time derivative/);
      expect(derivativeTemplate).toBeInTheDocument();
    });

    it('provides proper ARIA labels for context items', () => {
      const onInsert = vi.fn();
      render(() => <ExpressionPalette currentModel={mockModel} onInsertExpression={onInsert} />);

      const temperatureItem = screen.getByLabelText(/Insert variable temperature/);
      expect(temperatureItem).toBeInTheDocument();
    });

    it('makes templates focusable with tabindex', () => {
      const onInsert = vi.fn();
      render(() => <ExpressionPalette onInsertExpression={onInsert} />);

      const template = screen.getByText('D(_, t)').closest('.expression-template');
      expect(template).toHaveAttribute('tabindex', '0');
      expect(template).toHaveAttribute('role', 'button');
    });
  });

  describe('Custom CSS classes', () => {
    it('applies custom CSS class', () => {
      const onInsert = vi.fn();
      render(() => <ExpressionPalette class="custom-class" onInsertExpression={onInsert} />);

      const palette = document.querySelector('.expression-palette');
      expect(palette).toHaveClass('custom-class');
    });
  });
});