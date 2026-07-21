/**
 * ExpressionNode - Read-only recursive AST renderer
 *
 * Renders an expression AST as pretty math. This is a PURE renderer: it never
 * mutates the AST and has no editing affordances (no click-to-select, no gear /
 * field editor, no drag-and-drop / context menu). Editing happens exclusively
 * through the text DSL surfaces (see {@link createTextEditMode}); this component
 * is what the editors show in `readonly` mode.
 *
 * It renders:
 * - Number literals (with scientific-notation formatting)
 * - Variable references with chemical subscript rendering (shared module)
 * - Operator nodes that dispatch to the layout components in src/layout
 *   (Fraction, Superscript, Radical) for mathematical typography
 *
 * The only interactive affordance retained is variable hover-highlighting
 * (`onHoverVar` + `highlightedVars`), a read-only navigation aid that highlights
 * every occurrence of the hovered variable across the document.
 */

import type { Component, JSX } from 'solid-js'
import { createSignal, createMemo, Show, Switch, Match, Index } from 'solid-js'
import type { Expression, ExpressionNode as ExprNode } from '@earthsciml/ast'
import { renderChemicalName } from '../primitives/chemical-formula'
import { pathToString } from '../primitives/path-utils'
import { isNumericString, formatNumber } from './number-format'
import { Fraction } from '../layout/Fraction'
import { Superscript } from '../layout/Superscript'
import { Radical } from '../layout/Radical'

/** Operators rendered as infix comparison chains (e.g. `a > b`). */
const COMPARISON_OPS = ['>', '<', '>=', '<=', '==', '!=']

export interface ExpressionNodeProps {
  /** The expression to render (reactive from Solid store) */
  expr: Expression

  /** AST path for unique identification (rendered as `data-path`) */
  path: (string | number)[]

  /** Currently highlighted variable equivalence class */
  highlightedVars: Set<string>

  /** Callback when hovering over a variable (read-only navigation aid) */
  onHoverVar?: (name: string | null) => void
}

/**
 * Operator layout dispatcher with proper mathematical layout. Fractions,
 * exponents, and radicals render via the shared layout components
 * (Section 5.2.3) instead of hand-rolled markup.
 */
function OperatorLayout(props: {
  node: ExprNode
  path: (string | number)[]
  highlightedVars: Set<string>
  onHoverVar?: (name: string | null) => void
}) {
  const op = () => props.node.op
  const args = () => (props.node.args as Expression[] | undefined) ?? []

  // Helper to render child nodes.
  const child = (arg: () => Expression, index: number): JSX.Element => (
    <ExpressionNode
      expr={arg()}
      path={[...props.path, 'args', index]}
      highlightedVars={props.highlightedVars}
      onHoverVar={props.onHoverVar}
    />
  )

  /** Render args as a separated infix sequence */
  const infixArgs = (separator: () => JSX.Element) => (
    <Index each={args()}>
      {(arg, index) => (
        <>
          <Show when={index > 0}>{separator()}</Show>
          {child(arg, index)}
        </>
      )}
    </Index>
  )

  /** Render args as a parenthesized function argument list */
  const functionArgs = () => (
    <span class="esm-function-args">
      (
      <Index each={args()}>
        {(arg, index) => (
          <>
            <Show when={index > 0}>, </Show>
            {child(arg, index)}
          </>
        )}
      </Index>
      )
    </span>
  )

  // Handle different operators with appropriate CSS layouts per Section 5.2.4
  return (
    <Switch
      fallback={
        // Function notation: the fallback for every op without a dedicated
        // typographic layout below (named functions like sin/exp and unknown
        // ops alike render identically as `name(args…)`).
        <span class="esm-generic-function" data-operator={op()}>
          <span class="esm-function-name">{op()}</span>
          {functionArgs()}
        </span>
      }
    >
      <Match when={op() === '+' || op() === '-'}>
        <span class="esm-infix-op" data-operator={op()}>
          {infixArgs(() => (
            <span class="esm-operator"> {op()} </span>
          ))}
        </span>
      </Match>

      <Match when={op() === '*'}>
        <span class="esm-multiplication" data-operator={op()}>
          {infixArgs(() => (
            <span class="esm-multiply">⋅</span>
          ))}
        </span>
      </Match>

      <Match when={op() === '/'}>
        <Fraction numerator={child(() => args()[0], 0)} denominator={child(() => args()[1], 1)} />
      </Match>

      <Match when={op() === '^'}>
        <Superscript base={child(() => args()[0], 0)} exponent={child(() => args()[1], 1)} />
      </Match>

      <Match when={op() === 'sqrt'}>
        <Radical class="esm-sqrt" content={child(() => args()[0], 0)} />
      </Match>

      <Match when={op() === 'D'}>
        <span class="esm-derivative" data-operator={op()}>
          <span class="esm-d-operator">d</span>
          <span class="esm-derivative-body">{child(() => args()[0], 0)}</span>
          <Show when={props.node.wrt}>
            <span class="esm-derivative-wrt">
              <span class="esm-d-operator">d</span>
              <span class="esm-variable">{props.node.wrt}</span>
            </span>
          </Show>
        </span>
      </Match>

      <Match when={COMPARISON_OPS.includes(op())}>
        <span class="esm-comparison" data-operator={op()}>
          {infixArgs(() => (
            <span class="esm-operator"> {op()} </span>
          ))}
        </span>
      </Match>
    </Switch>
  )
}

/**
 * Core ExpressionNode component - recursive read-only AST renderer
 */
export const ExpressionNode: Component<ExpressionNodeProps> = (props) => {
  const [isHovered, setIsHovered] = createSignal(false)

  // Determine if this expression is a variable reference
  const isVariable = createMemo(
    () => typeof props.expr === 'string' && !isNumericString(props.expr),
  )

  // Check if this variable should be highlighted
  const shouldHighlight = createMemo(
    () => isVariable() && props.highlightedVars.has(props.expr as string),
  )

  // CSS classes for styling
  const nodeClasses = createMemo(() => {
    const classes = ['esm-expression-node']

    if (isHovered()) classes.push('hovered')
    if (shouldHighlight()) classes.push('highlighted')
    if (isVariable()) classes.push('variable')
    if (typeof props.expr === 'number') classes.push('number')
    if (typeof props.expr === 'object') classes.push('operator')

    return classes.join(' ')
  })

  // Handle mouse events (variable hover-highlighting only)
  const handleMouseEnter = () => {
    setIsHovered(true)
    if (isVariable()) {
      props.onHoverVar?.(props.expr as string)
    }
  }

  const handleMouseLeave = () => {
    setIsHovered(false)
    if (isVariable()) {
      props.onHoverVar?.(null)
    }
  }

  // Get ARIA label for accessibility
  const ariaLabel = (): string => {
    if (typeof props.expr === 'number') {
      return `Number: ${props.expr}`
    }
    if (typeof props.expr === 'string') {
      return `Variable: ${props.expr}`
    }
    if (typeof props.expr === 'object' && props.expr !== null && 'op' in props.expr) {
      return `Operator: ${(props.expr as ExprNode).op}`
    }
    return 'Expression'
  }

  const isOperatorNode = () =>
    typeof props.expr === 'object' && props.expr !== null && 'op' in props.expr

  return (
    <span
      class={nodeClasses()}
      onMouseEnter={handleMouseEnter}
      onMouseLeave={handleMouseLeave}
      aria-label={ariaLabel()}
      data-path={pathToString(props.path)}
    >
      <Switch fallback={<span class="esm-unknown">?</span>}>
        <Match when={typeof props.expr === 'number'}>
          <span class="esm-num" title={`Number: ${props.expr}`}>
            {formatNumber(props.expr as number)}
          </span>
        </Match>

        <Match when={typeof props.expr === 'string'}>
          <span class="esm-var" title={`Variable: ${props.expr}`}>
            {renderChemicalName(props.expr as string)}
          </span>
        </Match>

        <Match when={isOperatorNode()}>
          <OperatorLayout
            node={props.expr as ExprNode}
            path={props.path}
            highlightedVars={props.highlightedVars}
            onHoverVar={props.onHoverVar}
          />
        </Match>
      </Switch>
    </span>
  )
}

export default ExpressionNode
