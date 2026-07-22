/**
 * EquationEditor - Single equation editor with LHS = RHS format
 *
 * The default surface is **rendered math** (native MathML from `toMathML`),
 * even when editable — so an equation reads as an equation, not code. Clicking
 * it (when editable) reveals the **edit surface**: a wide textarea holding the
 * equation's ascii DSL form (`toAscii` ⇄ `parseEquation`, the inverse-of-print
 * syntax used everywhere else) plus an inline **description** field. Committing
 * (blur out of the surface, or ⌘/Ctrl+Enter) returns to the rendered math.
 *
 * Description (`_comment`) editing rides along in the same surface: if a
 * description exists, clicking it opens the surface focused there; if there is
 * none, clicking the equation still surfaces a blank description field to fill
 * in. Equation and description commit as a single atomic change.
 *
 * The edit surface **blocks emit until the equation parses**: on commit the
 * buffer is parsed; a parse error is surfaced and NOTHING is emitted, and the
 * surface stays open (Escape reverts). A clean commit emits only the parts that
 * actually changed — the lhs/rhs are overwritten only when the equation text
 * genuinely changed (its reprint differs from the seed), keeping an untouched
 * AST byte-identical even though the printer is non-injective (a wrt-less
 * `D(O3, t)` reprints to `D(O3)/Dt`; a float's last digit can shift through
 * `formatNumber`); the `_comment` is set/cleared only when the description
 * field changed. All other fields are preserved by merge.
 *
 * `readonly` renders the pretty math via the `ExpressionNode` renderer (which
 * carries the variable hover-highlighting used by ModelEditor) with no editing.
 */

import type { Component } from 'solid-js'
import { createEffect, createMemo, createSignal, Show } from 'solid-js'
import type { Equation } from '@earthsciml/ast'
import { toAscii, parseEquation, toMathML, ExpressionParseError } from '@earthsciml/ast'
import { ExpressionNode } from './ExpressionNode'
import { createMergedHighlight } from './merged-highlight'
import './equation-editor.css'

export interface EquationEditorProps {
  /** The equation to display and edit */
  equation: Equation

  /** Callback when the equation is modified */
  onEquationChange?: (newEquation: Equation) => void

  /** Currently highlighted variable equivalence class */
  highlightedVars?: Set<string>

  /** Whether the editor is in read-only mode */
  readonly?: boolean

  /** CSS class for styling */
  class?: string

  /** Unique identifier for this editor */
  id?: string
}

/** MathML for an equation, wrapped in a `<math>` root when needed; '' on failure. */
function toMathMLSafe(node: unknown): string {
  try {
    const ml = toMathML(node as Parameters<typeof toMathML>[0])
    if (!ml) return ''
    return ml.trimStart().startsWith('<math') ? ml : `<math>${ml}</math>`
  } catch {
    return ''
  }
}

/**
 * Main EquationEditor component
 */
export const EquationEditor: Component<EquationEditorProps> = (props) => {
  const [hoveredVar, setHoveredVar] = createSignal<string | null>(null)

  // Edit-surface state: whether it's open, and the buffers for the equation's
  // ascii form and its description, plus the last parse error.
  const [editing, setEditing] = createSignal(false)
  const [eqText, setEqText] = createSignal('')
  const [descText, setDescText] = createSignal('')
  const [error, setError] = createSignal<string | null>(null)
  const [focusDesc, setFocusDesc] = createSignal(false)

  const seedEq = () => toAscii(props.equation)
  const origDesc = () => props.equation._comment ?? ''
  const mathml = createMemo(() => toMathMLSafe(props.equation))

  let eqRef: HTMLTextAreaElement | undefined
  let descRef: HTMLInputElement | undefined

  const enterEdit = (toDescription = false) => {
    if (props.readonly) return
    setEqText(seedEq())
    setDescText(origDesc())
    setError(null)
    setFocusDesc(toDescription)
    setEditing(true)
  }

  // Focus the relevant field when the surface opens.
  createEffect(() => {
    if (!editing()) return
    const wantDesc = focusDesc()
    queueMicrotask(() => (wantDesc ? descRef : eqRef)?.focus())
  })

  const revert = () => {
    setError(null)
    setEditing(false)
  }

  /**
   * Parse the equation buffer and, if it's clean, emit only the parts that
   * actually changed. Returns false (and stays open) on a parse error.
   */
  const commit = (): boolean => {
    let parsed: { lhs: Equation['lhs']; rhs: Equation['rhs'] }
    try {
      parsed = parseEquation(eqText())
    } catch (e) {
      if (e instanceof ExpressionParseError) {
        setError(e.message)
        return false
      }
      throw e
    }
    setError(null)

    // The equation changed only if the buffer differs from the seed AND its
    // reprint differs too — the second clause keeps a non-reprint-idempotent
    // node untouched on a focus+blur with no real edit.
    const eqChanged = eqText() !== seedEq() && toAscii(parsed) !== seedEq()
    const descChanged = descText() !== origDesc()

    if (!props.readonly && (eqChanged || descChanged)) {
      const next: Equation = { ...props.equation }
      if (eqChanged) {
        next.lhs = parsed.lhs
        next.rhs = parsed.rhs
      }
      if (descChanged) {
        if (descText().trim() === '') delete next._comment
        else next._comment = descText()
      }
      props.onEquationChange?.(next)
    }
    setEditing(false)
    return true
  }

  // Commit when focus leaves the whole edit surface (tabbing between the
  // equation and description fields stays inside, so it doesn't commit).
  const onSurfaceFocusOut = (e: FocusEvent & { currentTarget: HTMLElement }) => {
    const next = e.relatedTarget as Node | null
    if (next && e.currentTarget.contains(next)) return
    commit()
  }

  const handleKeyDown = (e: KeyboardEvent) => {
    if ((e.metaKey || e.ctrlKey) && e.key === 'Enter') {
      e.preventDefault()
      commit()
    } else if (e.key === 'Escape') {
      e.preventDefault()
      revert()
    }
  }

  // Base highlight set merged with the locally hovered variable.
  const highlightedVars = createMergedHighlight(() => props.highlightedVars, hoveredVar)
  const handleHoverVar = (varName: string | null) => setHoveredVar(varName)

  const editorClasses = () => {
    const classes = ['equation-editor']
    if (props.readonly) classes.push('readonly')
    if (props.class) classes.push(props.class)
    return classes.join(' ')
  }

  // Read-only render: the pretty math via ExpressionNode (keeps hover-highlight).
  const readonlyMath = (
    <div class="equation-content">
      <div class="equation-lhs">
        <ExpressionNode
          expr={props.equation.lhs}
          path={['lhs']}
          highlightedVars={highlightedVars()}
          onHoverVar={handleHoverVar}
        />
      </div>
      <div class="equation-equals" aria-label="equals">
        =
      </div>
      <div class="equation-rhs">
        <ExpressionNode
          expr={props.equation.rhs}
          path={['rhs']}
          highlightedVars={highlightedVars()}
          onHoverVar={handleHoverVar}
        />
      </div>
    </div>
  )

  return (
    <div class={editorClasses()} id={props.id}>
      <Show when={editing() && !props.readonly} fallback={<DisplayView />}>
        <div class="esm-eq-edit" onFocusOut={onSurfaceFocusOut} onKeyDown={handleKeyDown}>
          <textarea
            ref={eqRef}
            class="esm-eq-textarea"
            classList={{ 'has-error': error() != null }}
            value={eqText()}
            spellcheck={false}
            rows={2}
            aria-label="Equation text"
            aria-invalid={error() != null}
            onInput={(e) => {
              setEqText(e.currentTarget.value)
              if (error()) setError(null)
            }}
          />
          <input
            ref={descRef}
            class="esm-eq-desc-input"
            type="text"
            value={descText()}
            placeholder="Add a description…"
            aria-label="Equation description"
            onInput={(e) => setDescText(e.currentTarget.value)}
          />
          <Show when={error()}>
            <div class="esm-eq-error" role="alert">
              {error()}
            </div>
          </Show>
          <div class="esm-eq-hint">⌘⏎ to save · Esc to cancel</div>
        </div>
      </Show>
    </div>
  )

  /** The non-editing surface: readonly pretty-math, or clickable MathML + description. */
  function DisplayView() {
    return (
      <Show when={!props.readonly} fallback={<>{readonlyMath}<DescriptionDisplay /></>}>
        <div
          class="esm-eq-display"
          role="button"
          tabindex="0"
          title="Click to edit"
          onClick={() => enterEdit(false)}
          onKeyDown={(e) => {
            if (e.key === 'Enter' || e.key === ' ') {
              e.preventDefault()
              enterEdit(false)
            }
          }}
        >
          <Show
            when={mathml()}
            fallback={<div class="esm-math esm-eq-ascii">{seedEq()}</div>}
          >
            <div class="esm-math" innerHTML={mathml()} />
          </Show>
        </div>
        <DescriptionDisplay />
      </Show>
    )
  }

  /** Description line under the math: clickable when editable; add-affordance when absent. */
  function DescriptionDisplay() {
    return (
      <Show
        when={origDesc()}
        fallback={
          <Show when={!props.readonly}>
            <button type="button" class="esm-eq-add-desc" onClick={() => enterEdit(true)}>
              + description
            </button>
          </Show>
        }
      >
        <div
          class="equation-description"
          classList={{ 'esm-eq-desc-clickable': !props.readonly }}
          title={props.readonly ? 'Equation comment' : 'Click to edit description'}
          onClick={() => !props.readonly && enterEdit(true)}
        >
          {origDesc()}
        </div>
      </Show>
    )
  }
}

export default EquationEditor
