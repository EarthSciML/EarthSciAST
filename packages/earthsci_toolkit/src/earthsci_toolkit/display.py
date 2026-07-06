"""
Pretty-printing formatters for ESM format expressions, equations, models, and files.

Implements output formats:
- to_unicode(): Unicode mathematical notation with chemical subscripts
- to_latex(): LaTeX mathematical notation

Based on ESM Format Specification Section 6.1
"""

import re
from typing import Union, Dict, Any
try:
    from .esm_types import Expr, ExprNode, Equation, Model, ReactionSystem, EsmFile
except ImportError:
    # For direct imports when testing
    from types import Expr, ExprNode, Equation, Model, ReactionSystem, EsmFile


# Greek letter to LaTeX mapping
GREEK_LATEX = {
    'α': '\\alpha', 'β': '\\beta', 'γ': '\\gamma', 'δ': '\\delta',
    'ε': '\\epsilon', 'ζ': '\\zeta', 'η': '\\eta', 'θ': '\\theta',
    'ι': '\\iota', 'κ': '\\kappa', 'λ': '\\lambda', 'μ': '\\mu',
    'ν': '\\nu', 'ξ': '\\xi', 'π': '\\pi', 'ρ': '\\rho',
    'σ': '\\sigma', 'τ': '\\tau', 'υ': '\\upsilon', 'φ': '\\phi',
    'χ': '\\chi', 'ψ': '\\psi', 'ω': '\\omega',
    'Γ': '\\Gamma', 'Δ': '\\Delta', 'Θ': '\\Theta', 'Λ': '\\Lambda',
    'Ξ': '\\Xi', 'Π': '\\Pi', 'Σ': '\\Sigma', 'Φ': '\\Phi',
    'Ψ': '\\Psi', 'Ω': '\\Omega',
}


# Element lookup table for chemical subscript detection (118 elements)
ELEMENTS = {
    # Period 1
    'H', 'He',
    # Period 2
    'Li', 'Be', 'B', 'C', 'N', 'O', 'F', 'Ne',
    # Period 3
    'Na', 'Mg', 'Al', 'Si', 'P', 'S', 'Cl', 'Ar',
    # Period 4
    'K', 'Ca', 'Sc', 'Ti', 'V', 'Cr', 'Mn', 'Fe', 'Co', 'Ni', 'Cu', 'Zn',
    'Ga', 'Ge', 'As', 'Se', 'Br', 'Kr',
    # Period 5
    'Rb', 'Sr', 'Y', 'Zr', 'Nb', 'Mo', 'Tc', 'Ru', 'Rh', 'Pd', 'Ag', 'Cd',
    'In', 'Sn', 'Sb', 'Te', 'I', 'Xe',
    # Period 6
    'Cs', 'Ba', 'La', 'Ce', 'Pr', 'Nd', 'Pm', 'Sm', 'Eu', 'Gd', 'Tb', 'Dy',
    'Ho', 'Er', 'Tm', 'Yb', 'Lu',
    'Hf', 'Ta', 'W', 'Re', 'Os', 'Ir', 'Pt', 'Au', 'Hg', 'Tl', 'Pb', 'Bi',
    'Po', 'At', 'Rn',
    # Period 7
    'Fr', 'Ra', 'Ac', 'Th', 'Pa', 'U', 'Np', 'Pu', 'Am', 'Cm', 'Bk', 'Cf',
    'Es', 'Fm', 'Md', 'No', 'Lr',
    'Rf', 'Db', 'Sg', 'Bh', 'Hs', 'Mt', 'Ds', 'Rg', 'Cn', 'Nh', 'Fl', 'Mc',
    'Lv', 'Ts', 'Og'
}

# Unicode subscripts for digits 0-9
SUBSCRIPT_DIGITS = '₀₁₂₃₄₅₆₇₈₉'


def _to_subscript(n: int) -> str:
    """Convert integer to Unicode subscript digits."""
    return ''.join(SUBSCRIPT_DIGITS[int(d)] for d in str(n))


# Unicode superscripts for digits 0-9 and signs
SUPERSCRIPT_MAP = {
    '0': '⁰', '1': '¹', '2': '²', '3': '³', '4': '⁴',
    '5': '⁵', '6': '⁶', '7': '⁷', '8': '⁸', '9': '⁹',
    '+': '⁺', '-': '⁻'
}


def _to_superscript(text: str) -> str:
    """Convert text to Unicode superscript."""
    return ''.join(SUPERSCRIPT_MAP.get(c, c) for c in text)


def _has_element_pattern(variable: str) -> bool:
    """Check if a variable has element patterns (for chemical formula detection)."""
    i = 0
    has_element = False

    while i < len(variable):
        # Skip non-alphabetic characters at the start
        while i < len(variable) and not variable[i].isalpha():
            i += 1

        if i >= len(variable):
            break

        # Try 2-character element first
        if i + 1 < len(variable):
            two_char = variable[i:i+2]
            if two_char in ELEMENTS:
                has_element = True
                i += 2
                # Skip digits
                while i < len(variable) and variable[i].isdigit():
                    i += 1
                continue

        # Try 1-character element
        one_char = variable[i]
        if one_char in ELEMENTS:
            has_element = True
            i += 1
            # Skip digits
            while i < len(variable) and variable[i].isdigit():
                i += 1
            continue

        # Not an element, move to next character
        i += 1

    return has_element


def _find_first_element_index(variable: str) -> int:
    """Find the index of the first chemical element in the variable name."""
    i = 0
    while i < len(variable):
        if not variable[i].isalpha():
            i += 1
            continue
        if i + 1 < len(variable):
            two_char = variable[i:i+2]
            if two_char in ELEMENTS:
                return i
        if variable[i] in ELEMENTS:
            return i
        i += 1
    return -1


def _latex_subscript_digits(s: str) -> str:
    """Convert digit sequences in a string to LaTeX subscripts.
    Single digits: _N, multi-digit: _{NN}"""
    return re.sub(
        r'(\d+)',
        lambda m: f'_{{{m.group(1)}}}' if len(m.group(1)) > 1 else f'_{m.group(1)}',
        s
    )


def _format_chemical_subscripts(variable: str, format_type: str) -> str:
    """
    Apply element-aware chemical subscript formatting to a variable name.
    Uses greedy 2-char-before-1-char matching for element detection.
    """
    # Check for Greek letters in latex mode
    if format_type == 'latex' and variable in GREEK_LATEX:
        return GREEK_LATEX[variable]

    # Check if variable looks like a chemical formula
    has_elements = _has_element_pattern(variable)

    if format_type == 'latex':
        if has_elements:
            elem_start = _find_first_element_index(variable)
            if elem_start > 0:
                # Mixed variable: non-element prefix + chemical part
                prefix = variable[:elem_start].rstrip('_')
                chemical = variable[elem_start:]
                formatted_chemical = _latex_subscript_digits(chemical)
                return f'{prefix}_{{\\mathrm{{{formatted_chemical}}}}}'
            else:
                # Pure chemical formula
                formatted = _latex_subscript_digits(variable)
                return f'\\mathrm{{{formatted}}}'
        else:
            # Non-chemical with mixed alpha+digits: wrap in \mathrm for consistent display
            has_alpha = any(c.isalpha() for c in variable)
            has_digit = any(c.isdigit() for c in variable)
            if has_alpha and has_digit:
                return f'\\mathrm{{{variable}}}'
            return variable

    if format_type == 'ascii':
        # For ASCII, just return as-is (no special formatting for chemical subscripts)
        return variable

    if not has_elements:
        # No element pattern found, return as-is
        return variable

    # For unicode: element-aware subscript detection
    result = ''
    i = 0

    while i < len(variable):
        matched = False

        # Try 2-character element first
        if i + 1 < len(variable):
            two_char = variable[i:i+2]
            if two_char in ELEMENTS:
                result += two_char
                i += 2
                # Convert following digits to subscripts
                while i < len(variable) and variable[i].isdigit():
                    result += SUBSCRIPT_DIGITS[int(variable[i])]
                    i += 1
                matched = True

        # Try 1-character element if 2-char didn't match
        if not matched and i < len(variable):
            one_char = variable[i]
            if one_char in ELEMENTS:
                result += one_char
                i += 1
                # Convert following digits to subscripts
                while i < len(variable) and variable[i].isdigit():
                    result += SUBSCRIPT_DIGITS[int(variable[i])]
                    i += 1
                matched = True

        # If not an element, copy character as-is
        if not matched:
            result += variable[i]
            i += 1

    return result


def _format_number(num: Union[int, float], format_type: str) -> str:
    """Format a number in scientific notation with appropriate formatting."""
    if isinstance(num, int) and abs(num) < 1e6:
        s = str(num)
        if format_type == 'unicode':
            s = s.replace('-', '−')
        return s

    if isinstance(num, float) and abs(num) >= 1e-4 and abs(num) < 1e5 and num.is_integer():
        s = str(int(num))
        if format_type == 'unicode':
            s = s.replace('-', '−')
        return s

    # For regular-sized floats, return as-is without scientific notation
    if isinstance(num, float) and abs(num) >= 1e-4 and abs(num) < 1e5:
        # Use reasonable precision for display
        s = f"{num:.12g}".rstrip('0').rstrip('.')
        if format_type == 'unicode':
            s = s.replace('-', '−')
        return s

    # Use scientific notation for very large or very small numbers
    str_repr = f"{num:.6e}"
    if 'e' not in str_repr:
        return str_repr

    mantissa, exponent = str_repr.split('e')
    exp = int(exponent)

    # Convert mantissa to float to handle it properly
    mantissa_val = float(mantissa)
    # If mantissa is a whole number, format it with one decimal place to preserve precision like "2.0"
    if mantissa_val == int(mantissa_val):
        mantissa = f"{int(mantissa_val)}.0"
    else:
        mantissa = str(mantissa_val)

    if format_type == 'unicode':
        return f"{mantissa}×10{_to_superscript(str(exp))}"
    elif format_type == 'latex':
        return f"{mantissa} \\times 10^{{{exp}}}"
    elif format_type == 'ascii':
        return f"{mantissa}*10^{exp}"
    else:
        return str_repr  # Plain scientific notation


def _get_operator_precedence(op: str) -> int:
    """Get operator precedence for proper parenthesization."""
    precedence_map = {
        'or': 1,
        'and': 2,
        '=': 3, '==': 3, '!=': 3, '<': 3, '>': 3, '<=': 3, '>=': 3,
        '+': 4, '-': 4,
        '*': 5, '/': 5,
        'not': 6,  # Unary
        '^': 7,
    }
    return precedence_map.get(op, 8)  # Functions get highest precedence


def _needs_parentheses(parent: ExprNode, child: Expr, is_right_operand: bool = False) -> bool:
    """Check if parentheses are needed around a subexpression."""
    if isinstance(child, (int, float, str)):
        return False

    # Handle dict-style expression nodes
    if isinstance(child, dict) and 'op' in child:
        parent_prec = _get_operator_precedence(parent.op)
        child_prec = _get_operator_precedence(child['op'])
        if child_prec < parent_prec:
            return True
        if child_prec > parent_prec:
            return False
        if is_right_operand and parent.op in ['-', '/', '^']:
            return True
        return False

    if not isinstance(child, ExprNode):
        return False

    parent_prec = _get_operator_precedence(parent.op)
    child_prec = _get_operator_precedence(child.op)

    if child_prec < parent_prec:
        return True
    if child_prec > parent_prec:
        return False

    # Same precedence: need parens if child is right operand and operator is not associative
    if is_right_operand and parent.op in ['-', '/', '^']:
        return True

    # Special cases for function arguments - no parens needed for simple expressions
    if parent.op in ['sin', 'cos', 'tan', 'exp', 'log', 'sqrt', 'abs']:
        # Only parenthesize for very low precedence operators
        return child_prec <= 2

    return False


def to_unicode(target: Union[Expr, Equation, Model, ReactionSystem, EsmFile]) -> str:
    """
    Format target as Unicode mathematical notation with chemical subscripts.

    Args:
        target: Expression, equation, model, reaction system, or ESM file to format

    Returns:
        Unicode string representation
    """
    if target is None:
        return "None"

    if isinstance(target, (int, float)):
        return _format_number(target, 'unicode')

    if isinstance(target, str):
        return _format_chemical_subscripts(target, 'unicode')

    if isinstance(target, ExprNode):
        return _format_expression_node(target, 'unicode')

    if isinstance(target, dict) and 'op' in target:
        # Handle dictionary-style expressions for compatibility
        args = target.get('args') or []
        node = ExprNode(op=target['op'], args=args,
                        wrt=target.get('wrt'), dim=target.get('dim'))
        return _format_expression_node(node, 'unicode')

    if isinstance(target, dict):
        # Handle malformed dict expressions gracefully
        return str(target)

    if isinstance(target, Equation):
        return f"{to_unicode(target.lhs)} = {to_unicode(target.rhs)}"

    if isinstance(target, EsmFile):
        return _format_esm_file_summary(target, 'unicode')

    if isinstance(target, Model):
        return _format_model_summary(target, 'unicode')

    if isinstance(target, ReactionSystem):
        return _format_reaction_system_summary(target, 'unicode')

    raise ValueError(f"Unsupported type for Unicode formatting: {type(target)}")


def to_latex(target: Union[Expr, Equation, Model, ReactionSystem, EsmFile]) -> str:
    """
    Format target as LaTeX mathematical notation.

    Args:
        target: Expression, equation, model, reaction system, or ESM file to format

    Returns:
        LaTeX string representation
    """
    if target is None:
        return "None"

    if isinstance(target, (int, float)):
        return _format_number(target, 'latex')

    if isinstance(target, str):
        return _format_chemical_subscripts(target, 'latex')

    if isinstance(target, ExprNode):
        return _format_expression_node(target, 'latex')

    if isinstance(target, dict) and 'op' in target:
        # Handle dictionary-style expressions for compatibility
        args = target.get('args') or []
        node = ExprNode(op=target['op'], args=args,
                        wrt=target.get('wrt'), dim=target.get('dim'))
        return _format_expression_node(node, 'latex')

    if isinstance(target, dict):
        # Handle malformed dict expressions gracefully
        return str(target)

    if isinstance(target, Equation):
        return f"{to_latex(target.lhs)} = {to_latex(target.rhs)}"

    if isinstance(target, EsmFile):
        # ESM files not typically formatted as LaTeX, return plain text
        return _format_esm_file_summary(target, 'ascii')

    if isinstance(target, Model):
        # Models not typically formatted as LaTeX, return plain text
        return _format_model_summary(target, 'ascii')

    if isinstance(target, ReactionSystem):
        # Reaction systems not typically formatted as LaTeX, return plain text
        return _format_reaction_system_summary(target, 'ascii')

    raise ValueError(f"Unsupported type for LaTeX formatting: {type(target)}")


def to_ascii(target: Union[Expr, Equation, Model, ReactionSystem, EsmFile]) -> str:
    """
    Format target as plain ASCII mathematical notation.

    Args:
        target: Expression, equation, model, reaction system, or ESM file to format

    Returns:
        Plain ASCII string representation (no Unicode symbols)
    """
    if target is None:
        return "None"

    if isinstance(target, (int, float)):
        return _format_number(target, 'ascii')

    if isinstance(target, str):
        return _format_chemical_subscripts(target, 'ascii')

    if isinstance(target, ExprNode):
        return _format_expression_node(target, 'ascii')

    if isinstance(target, dict) and 'op' in target:
        # Handle dictionary-style expressions for compatibility
        args = target.get('args') or []
        node = ExprNode(op=target['op'], args=args,
                        wrt=target.get('wrt'), dim=target.get('dim'))
        return _format_expression_node(node, 'ascii')

    if isinstance(target, dict):
        # Handle malformed dict expressions gracefully
        return str(target)

    if isinstance(target, Equation):
        return f"{to_ascii(target.lhs)} = {to_ascii(target.rhs)}"

    if isinstance(target, EsmFile):
        return _format_esm_file_summary(target, 'ascii')

    if isinstance(target, Model):
        return _format_model_summary(target, 'ascii')

    if isinstance(target, ReactionSystem):
        return _format_reaction_system_summary(target, 'ascii')

    raise ValueError(f"Unsupported type for ASCII formatting: {type(target)}")


def _format_expression_node(node: ExprNode, format_type: str) -> str:
    """Format an ExpressionNode (operator with arguments)."""
    op, args = node.op, node.args
    wrt = getattr(node, 'wrt', None)
    dim = getattr(node, 'dim', None)

    # Formatter dispatch
    _fmt = {'unicode': to_unicode, 'latex': to_latex, 'ascii': to_ascii}[format_type]

    def format_arg(arg: Expr, is_right_operand: bool = False) -> str:
        result = _fmt(arg)
        if _needs_parentheses(node, arg, is_right_operand):
            return f'({result})'
        return result

    def _latex_func(name, arg_str):
        """Wrap function call: use \\left/\\right when arg contains \\frac."""
        if '\\frac' in arg_str:
            return f'\\{name}\\left({arg_str}\\right)'
        return f'\\{name}({arg_str})'

    # ---- N-ary / Binary operators ----
    if len(args) >= 2:
        # Handle n-ary multiplication by folding
        if op == '*' and len(args) > 2:
            result = format_arg(args[0])
            for a in args[1:]:
                fa = format_arg(a, True)
                if format_type == 'unicode':
                    result = f"{result}·{fa}"
                elif format_type == 'latex':
                    result = f"{result} \\cdot {fa}"
                else:
                    result = f"{result} * {fa}"
            return result

        left, right = args[0], args[1]

        if op == '+':
            # Detect a + (-b) → render as a − b
            is_neg = False
            if isinstance(right, ExprNode) and right.op == '-' and len(right.args) == 1:
                is_neg = True
                neg_inner = right.args[0]
            elif isinstance(right, dict) and right.get('op') == '-' and len(right.get('args', [])) == 1:
                is_neg = True
                neg_inner = right['args'][0]
            if is_neg:
                sep = ' − ' if format_type == 'unicode' else ' - '
                return f"{format_arg(left)}{sep}{_fmt(neg_inner)}"
            return f"{format_arg(left)} + {format_arg(right, True)}"

        elif op == '-':
            sep = ' − ' if format_type == 'unicode' else ' - '
            return f"{format_arg(left)}{sep}{format_arg(right, True)}"

        elif op == '*':
            if format_type == 'unicode':
                return f"{format_arg(left)}·{format_arg(right, True)}"
            elif format_type == 'latex':
                return f"{format_arg(left)} \\cdot {format_arg(right, True)}"
            else:
                return f"{format_arg(left)} * {format_arg(right, True)}"

        elif op == '/':
            if format_type == 'latex':
                return f"\\frac{{{to_latex(left)}}}{{{to_latex(right)}}}"
            elif format_type == 'unicode':
                return f"{format_arg(left)}/{format_arg(right, True)}"
            else:
                return f"{format_arg(left)} / {format_arg(right, True)}"

        elif op == '^':
            if format_type == 'latex':
                return f"{format_arg(left)}^{{{to_latex(right)}}}"
            if format_type == 'unicode' and isinstance(right, int):
                return f"{format_arg(left)}{_to_superscript(str(right))}"
            return f"{format_arg(left)}^{format_arg(right, True)}"

        elif op in ('=', '=='):
            if format_type == 'unicode':
                return f"{format_arg(left)} = {format_arg(right, True)}"
            elif format_type == 'latex':
                return f"{format_arg(left)} = {format_arg(right, True)}"
            else:
                return f"{format_arg(left)} == {format_arg(right, True)}"

        elif op == '!=':
            if format_type == 'unicode':
                return f"{format_arg(left)} ≠ {format_arg(right, True)}"
            elif format_type == 'latex':
                return f"{format_arg(left)} \\neq {format_arg(right, True)}"
            else:
                return f"{format_arg(left)} != {format_arg(right, True)}"

        elif op in ('<', '>'):
            return f"{format_arg(left)} {op} {format_arg(right, True)}"

        elif op == '>=':
            if format_type == 'unicode':
                return f"{format_arg(left)} ≥ {format_arg(right, True)}"
            elif format_type == 'latex':
                return f"{format_arg(left)} \\geq {format_arg(right, True)}"
            else:
                return f"{format_arg(left)} >= {format_arg(right, True)}"

        elif op == '<=':
            if format_type == 'unicode':
                return f"{format_arg(left)} ≤ {format_arg(right, True)}"
            elif format_type == 'latex':
                return f"{format_arg(left)} \\leq {format_arg(right, True)}"
            else:
                return f"{format_arg(left)} <= {format_arg(right, True)}"

        elif op == 'and':
            if format_type == 'unicode':
                return f"{format_arg(left)} ∧ {format_arg(right, True)}"
            elif format_type == 'latex':
                return f"{format_arg(left)} \\land {format_arg(right, True)}"
            else:
                return f"({format_arg(left)}) && ({format_arg(right)})"

        elif op == 'or':
            if format_type == 'unicode':
                return f"{format_arg(left)} ∨ {format_arg(right, True)}"
            elif format_type == 'latex':
                return f"{format_arg(left)} \\lor {format_arg(right, True)}"
            else:
                return f"({format_arg(left)}) || ({format_arg(right)})"

        elif op in ('min', 'max'):
            if format_type == 'latex':
                return f"\\{op}({to_latex(left)}, {to_latex(right)})"
            return f"{op}({format_arg(left)}, {format_arg(right)})"

        elif op == 'binomial':
            if format_type == 'unicode':
                return f"C({_fmt(left)},{_fmt(right)})"
            elif format_type == 'latex':
                return f"\\binom{{{to_latex(left)}}}{{{to_latex(right)}}}"
            else:
                return f"binomial({_fmt(left)}, {_fmt(right)})"

        elif op == 'atan2':
            if format_type == 'latex':
                return f"\\mathrm{{atan2}}({to_latex(left)}, {to_latex(right)})"
            return f"atan2({_fmt(left)}, {_fmt(right)})"

    # ---- Unary operators ----
    if len(args) == 1:
        arg = args[0]
        fa = _fmt(arg)

        if op == '-':
            if format_type == 'unicode':
                return f"−{format_arg(arg)}"
            return f"-{format_arg(arg)}"

        elif op == 'not':
            if format_type == 'unicode':
                return f"¬{format_arg(arg)}"
            elif format_type == 'latex':
                return f"\\neg {format_arg(arg)}"
            else:
                return f"!({format_arg(arg)})"

        # Standard trig
        elif op in ('sin', 'cos', 'tan'):
            if format_type == 'latex':
                return _latex_func(op, to_latex(arg))
            return f"{op}({fa})"

        # Inverse trig
        elif op in ('asin', 'acos', 'atan'):
            base = op[1:]  # sin, cos, tan
            if format_type == 'unicode':
                return f"arc{base}({fa})"
            elif format_type == 'latex':
                return f"\\arc{base}({to_latex(arg)})"
            else:
                return f"{op}({fa})"

        # Hyperbolic
        elif op in ('sinh', 'cosh', 'tanh'):
            if format_type == 'latex':
                return _latex_func(op, to_latex(arg))
            return f"{op}({fa})"

        # Inverse hyperbolic
        elif op in ('asinh', 'acosh', 'atanh'):
            base = op[1:]  # sinh, cosh, tanh
            if format_type == 'unicode':
                return f"{base}⁻¹({fa})"
            elif format_type == 'latex':
                return f"\\{base}^{{-1}}({to_latex(arg)})"
            else:
                return f"{op}({fa})"

        elif op == 'exp':
            if format_type == 'latex':
                return _latex_func('exp', to_latex(arg))
            return f"exp({fa})"

        elif op == 'log':
            if format_type == 'unicode':
                return f"ln({fa})"
            elif format_type == 'latex':
                return _latex_func('ln', to_latex(arg))
            else:
                return f"log({fa})"

        elif op == 'log10':
            if format_type == 'unicode':
                return f"log₁₀({fa})"
            elif format_type == 'latex':
                return f"\\log_{{10}}({to_latex(arg)})"
            else:
                return f"log10({fa})"

        elif op == 'sqrt':
            if format_type == 'unicode':
                return f"√{fa}"
            elif format_type == 'latex':
                return f"\\sqrt{{{to_latex(arg)}}}"
            else:
                return f"sqrt({fa})"

        elif op == 'abs':
            return f"|{fa}|"

        elif op == 'floor':
            if format_type == 'unicode':
                return f"⌊{fa}⌋"
            elif format_type == 'latex':
                return f"\\lfloor {to_latex(arg)} \\rfloor"
            else:
                return f"floor({fa})"

        elif op == 'ceil':
            if format_type == 'unicode':
                return f"⌈{fa}⌉"
            elif format_type == 'latex':
                return f"\\lceil {to_latex(arg)} \\rceil"
            else:
                return f"ceil({fa})"

        elif op == 'gamma':
            if format_type == 'unicode':
                return f"Γ({fa})"
            elif format_type == 'latex':
                return f"\\Gamma({to_latex(arg)})"
            else:
                return f"gamma({fa})"

        elif op == 'div':
            if format_type == 'unicode':
                return f"∇·{fa}"
            elif format_type == 'latex':
                return f"\\nabla \\cdot {to_latex(arg)}"
            else:
                return f"div({fa})"

        elif op == 'laplacian':
            if format_type == 'unicode':
                return f"∇²{fa}"
            elif format_type == 'latex':
                return f"\\nabla^2 {to_latex(arg)}"
            else:
                return f"laplacian({fa})"

        elif op == 'grad':
            dim_var = dim or 't'
            if format_type == 'unicode':
                return f"∂{fa}/∂{dim_var}"
            elif format_type == 'latex':
                return f"\\frac{{\\partial {to_latex(arg)}}}{{\\partial {dim_var}}}"
            else:
                return f"d({fa})/d{dim_var}"

        elif op == 'D':
            wrt_var = wrt or 't'
            if format_type == 'unicode':
                return f"∂{to_unicode(arg)}/∂{wrt_var}"
            elif format_type == 'latex':
                return f"\\frac{{\\partial {to_latex(arg)}}}{{\\partial {wrt_var}}}"
            else:
                return f"D({fa})/D{wrt_var}"

        elif op == 'sign':
            if format_type == 'unicode':
                return f"sgn({fa})"
            elif format_type == 'latex':
                return f"\\mathrm{{sgn}}({to_latex(arg)})"
            return f"sign({fa})"

        elif op in ('erf', 'erfc', 'Pre'):
            if format_type == 'latex':
                return f"\\mathrm{{{op}}}({to_latex(arg)})"
            return f"{op}({fa})"

    # ---- Ternary: ifelse ----
    if op == 'ifelse' and len(args) == 3:
        cond, if_true, if_false = args
        if format_type == 'latex':
            return (f"\\begin{{cases}} {to_latex(if_true)} & "
                    f"\\text{{if }} {to_latex(cond)} \\\\ "
                    f"{to_latex(if_false)} & \\text{{otherwise}} \\end{{cases}}")
        return f"ifelse({_fmt(cond)}, {_fmt(if_true)}, {_fmt(if_false)})"

    # Fallback: function call notation
    if format_type == 'unicode':
        arg_list = ', '.join(to_unicode(arg) for arg in args)
    elif format_type == 'latex':
        arg_list = ', '.join(to_latex(arg) for arg in args)
        return f"\\mathrm{{{op}}}({arg_list})"
    elif format_type == 'ascii':
        arg_list = ', '.join(to_ascii(arg) for arg in args)
    else:
        arg_list = ', '.join(str(arg) for arg in args)

    return f"{op}({arg_list})"


def _format_model_summary(model: Model, format_type: str) -> str:
    """Format model summary (implementation per spec Section 6.3)."""
    name = getattr(model, 'name', 'unnamed')
    eq_count = len(model.equations) if model.equations else 0

    if not model.variables:
        return f"Model: {name} (0 variables, {eq_count} equations)"

    # Count variables by type according to spec Section 6.3
    type_counts = {"state": 0, "parameter": 0, "observed": 0}

    for var_name, var_info in model.variables.items():
        var_type = getattr(var_info, 'type', 'unknown')
        if var_type in type_counts:
            type_counts[var_type] += 1

    # Create the type summary according to spec Section 6.3 format
    type_parts = []
    if type_counts["state"] > 0:
        if type_counts["state"] == 1:
            type_parts.append("1 state")
        else:
            type_parts.append(f"{type_counts['state']} state")

    if type_counts["parameter"] > 0:
        if type_counts["parameter"] == 1:
            type_parts.append("1 parameter")
        else:
            type_parts.append(f"{type_counts['parameter']} parameters")

    if type_counts["observed"] > 0:
        if type_counts["observed"] == 1:
            type_parts.append("1 observed")
        else:
            type_parts.append(f"{type_counts['observed']} observed")

    type_summary = ", ".join(type_parts) if type_parts else "0 variables"
    eq_text = "equation" if eq_count == 1 else "equations"
    return f"Model: {name} ({type_summary}, {eq_count} {eq_text})"


def _format_reaction_system_summary(reaction_system: ReactionSystem, format_type: str) -> str:
    """Format reaction system summary showing reactions in chemical notation."""
    name = getattr(reaction_system, 'name', 'unnamed')
    species_count = len(reaction_system.species) if reaction_system.species else 0
    reaction_count = len(reaction_system.reactions) if reaction_system.reactions else 0
    return f"ReactionSystem: {name} ({species_count} species, {reaction_count} reactions)"


def _format_esm_file_summary(esm_file: EsmFile, format_type: str) -> str:
    """Format ESM file summary (implementation per spec Section 6.3)."""
    models_count = len(esm_file.models) if esm_file.models else 0
    reaction_systems_count = len(esm_file.reaction_systems) if esm_file.reaction_systems else 0
    data_loaders_count = len(esm_file.data_loaders) if esm_file.data_loaders else 0
    title = getattr(esm_file.metadata, 'title', 'Untitled')

    return f"ESM v{esm_file.version}: {title} ({models_count} models, {reaction_systems_count} reaction systems, {data_loaders_count} data loaders)"


# Add _repr_latex_ methods for Jupyter notebook rich display

def _add_repr_methods():
    """Add _repr_latex_ methods to classes for Jupyter rich display."""

    def esm_file_repr_latex(self) -> str:
        return to_latex(self)

    def model_repr_latex(self) -> str:
        return to_latex(self)

    def reaction_system_repr_latex(self) -> str:
        return to_latex(self)

    def equation_repr_latex(self) -> str:
        return to_latex(self)

    # Add methods to classes
    EsmFile._repr_latex_ = esm_file_repr_latex
    Model._repr_latex_ = model_repr_latex
    ReactionSystem._repr_latex_ = reaction_system_repr_latex
    Equation._repr_latex_ = equation_repr_latex


# Initialize the _repr_latex_ methods when the module is imported
_add_repr_methods()

