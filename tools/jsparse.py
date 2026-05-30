#!/usr/bin/env python3
"""
Parser for Claude's dialect of JavaScript (the "desire path" subset).

NOT a full ECMAScript parser. We parse what Claude actually writes in
this repo, inferred iteratively from chat/chat.js — the densest hand-
written browser script. The dialect is roughly ES5:

    var, function declarations + expressions, IIFEs, control flow
    (if/else/for/while/break/continue/return), object + array literals,
    regex literals, the ternary, &&/||, new, typeof, comparison +
    arithmetic, member access, call, assignment.

What Claude DOESN'T write here, and we therefore don't parse (yet):

    arrow functions, classes, template literals, destructuring,
    spread/rest, async/await, generators, with, let/const, for-of,
    labelled statements, hoisted function expressions in declaration
    position.

What's in the dialect but discovered after the chat.js seed parse,
extending to the siblings:

    throw, switch/case/default, try/catch[/finally], for-in. `catch(_)`
    (underscore as the bound name) appears in the try/catch idiom.

If a future script genuinely needs one of those, we either extend the
parser or decide Claude shouldn't write it.

AST is plain dicts with a 'kind' field and a 'loc' tuple (line, col).
Linters live as sibling scripts (tools/lint_*.py) walking by kind.

Zero-arg invocation parses chat/chat.js. Fail-fast on first unknown
construct, with line / column / source line printed for the offending
token.
"""

import re
import sys
import pathlib

REPO = pathlib.Path(__file__).resolve().parent.parent


# ---------------------------------------------------------------------------
# Tokenizer
# ---------------------------------------------------------------------------
#
# We hand-roll a tokenizer rather than use a regex sweep because of the
# regex-vs-division ambiguity: `/` starts a regex literal when an
# expression is expected, and is division when it follows one. The
# standard trick is to track the "last significant token" (skipping
# whitespace + comments) and use it to disambiguate. PREFIX_* names the
# token classes after which `/` opens a regex.

KEYWORDS = frozenset([
    "var", "function", "return", "if", "else",
    "for", "while", "do", "break", "continue",
    "new", "true", "false", "null", "undefined",
    "typeof", "instanceof", "in", "this",
    "void", "delete", "throw",
    "switch", "case", "default",
    "try", "catch", "finally",
])

# Longest-first so the tokenizer prefers `===` over `==` over `=`.
PUNCT = sorted([
    "===", "!==", "...", ">>>=", ">>>",
    "==", "!=", "<=", ">=", "&&", "||",
    "++", "--", "+=", "-=", "*=", "/=", "%=",
    "&=", "|=", "^=", "<<=", ">>=", "<<", ">>",
    "=>",  # tokenized but rejected by the parser (we don't want arrow fns)
    "=", "!", "+", "-", "*", "/", "%",
    "<", ">", "?", ":", ";", ",", ".",
    "(", ")", "{", "}", "[", "]",
    "~", "&", "|", "^",
], key=lambda s: -len(s))

# After one of these, `/` opens a regex literal. Everything else is division.
PREFIX_PUNCT = frozenset([
    "(", ",", "=", "+", "-", "*", "/", "%", "!", "~",
    "?", ":", ";", "{", "}", "[", "&", "|", "^",
    "==", "!=", "===", "!==", "<", "<=", ">", ">=",
    "&&", "||", "+=", "-=", "*=", "/=", "%=",
    "&=", "|=", "^=", "<<", ">>", "<<=", ">>=", ">>>=",
])
PREFIX_KEYWORD = frozenset([
    "return", "typeof", "new", "in", "instanceof", "if", "else",
    "while", "for", "var", "function", "do", "void", "delete",
    "throw",
])


class LexError(Exception):
    pass


def tokenize(src: str) -> list[dict]:
    """Lex `src` into a flat token list. Comments are stripped; newlines
    are tracked only for line/col reporting (Claude writes explicit
    semicolons, so we don't implement ASI)."""
    toks: list[dict] = []
    i, n = 0, len(src)
    line, col = 1, 1
    # `last` is the previous significant token's "form" — a punctuator
    # string, a keyword string, or a marker like "EXPR" (after a value-
    # bearing token: ident, number, string, regex, ), ], or postfix ++/--).
    last: str | None = None

    def advance(s: str) -> None:
        nonlocal i, line, col
        for ch in s:
            if ch == "\n":
                line += 1
                col = 1
            else:
                col += 1
        i += len(s)

    def push(kind: str, value, raw: str, last_form: str) -> None:
        nonlocal last
        toks.append({
            "kind": kind, "value": value, "raw": raw,
            "line": line, "col": col,
        })
        advance(raw)
        last = last_form

    while i < n:
        ch = src[i]

        # Whitespace
        if ch in " \t\r\n":
            advance(ch)
            continue

        # Line comment
        if src.startswith("//", i):
            j = src.find("\n", i)
            if j < 0:
                j = n
            advance(src[i:j])
            continue

        # Block comment
        if src.startswith("/*", i):
            j = src.find("*/", i + 2)
            if j < 0:
                raise LexError(f"unterminated block comment at {line}:{col}")
            advance(src[i:j + 2])
            continue

        # String literal (single or double quoted; \ escapes)
        if ch == "'" or ch == '"':
            quote = ch
            j = i + 1
            while j < n and src[j] != quote:
                if src[j] == "\\" and j + 1 < n:
                    j += 2
                    continue
                if src[j] == "\n":
                    raise LexError(f"newline in string literal at {line}:{col}")
                j += 1
            if j >= n:
                raise LexError(f"unterminated string at {line}:{col}")
            raw = src[i:j + 1]
            push("STRING", _decode_string(raw), raw, "EXPR")
            continue

        # Number (decimal; supports `.` and `e`/`E` exponents)
        if ch.isdigit() or (ch == "." and i + 1 < n and src[i + 1].isdigit()):
            j = i
            while j < n and src[j].isdigit():
                j += 1
            if j < n and src[j] == ".":
                j += 1
                while j < n and src[j].isdigit():
                    j += 1
            if j < n and src[j] in "eE":
                j += 1
                if j < n and src[j] in "+-":
                    j += 1
                while j < n and src[j].isdigit():
                    j += 1
            raw = src[i:j]
            push("NUMBER", float(raw) if ("." in raw or "e" in raw or "E" in raw) else int(raw), raw, "EXPR")
            continue

        # Identifier / keyword
        if ch.isalpha() or ch == "_" or ch == "$":
            j = i + 1
            while j < n and (src[j].isalnum() or src[j] in "_$"):
                j += 1
            raw = src[i:j]
            if raw in KEYWORDS:
                # `true`/`false`/`null`/`this`/`undefined` are value-bearing
                # for the regex/div heuristic; the rest are prefix.
                is_value = raw in ("true", "false", "null", "this", "undefined")
                push("KEYWORD", raw, raw, "EXPR" if is_value else raw)
            else:
                push("IDENT", raw, raw, "EXPR")
            continue

        # Regex literal — only when an expression is expected
        if ch == "/" and _is_regex_context(last):
            j = i + 1
            in_class = False
            while j < n:
                c = src[j]
                if c == "\\" and j + 1 < n:
                    j += 2
                    continue
                if c == "[":
                    in_class = True
                elif c == "]":
                    in_class = False
                elif c == "/" and not in_class:
                    break
                elif c == "\n":
                    raise LexError(f"newline in regex literal at {line}:{col}")
                j += 1
            if j >= n:
                raise LexError(f"unterminated regex at {line}:{col}")
            j += 1  # consume closing `/`
            # Flags
            while j < n and src[j].isalpha():
                j += 1
            raw = src[i:j]
            body = raw[1:raw.rfind("/")]
            flags = raw[raw.rfind("/") + 1:]
            push("REGEX", {"pattern": body, "flags": flags}, raw, "EXPR")
            continue

        # Punctuator (longest match first)
        matched = None
        for p in PUNCT:
            if src.startswith(p, i):
                matched = p
                break
        if matched is None:
            raise LexError(f"unexpected character {ch!r} at {line}:{col}")
        # Postfix `++`/`--` after a value yield EXPR; everything else is
        # the punctuator form.
        last_form = matched
        if matched in ("++", "--") and last == "EXPR":
            last_form = "EXPR"
        if matched in (")", "]"):
            last_form = "EXPR"
        push("PUNCT", matched, matched, last_form)

    toks.append({"kind": "EOF", "value": None, "raw": "", "line": line, "col": col})
    return toks


def _is_regex_context(last: str | None) -> bool:
    if last is None:
        return True
    if last == "EXPR":
        return False
    if last in PREFIX_PUNCT:
        return True
    if last in PREFIX_KEYWORD:
        return True
    # Other keywords / punctuators: be conservative and treat as division.
    return False


_STRING_ESCAPES = {
    "n": "\n", "t": "\t", "r": "\r", "b": "\b", "f": "\f",
    "v": "\v", "0": "\0", "\\": "\\", "'": "'", '"': '"',
    "/": "/",
}


def _decode_string(raw: str) -> str:
    out = []
    i = 1
    while i < len(raw) - 1:
        c = raw[i]
        if c == "\\" and i + 1 < len(raw) - 1:
            nxt = raw[i + 1]
            if nxt in _STRING_ESCAPES:
                out.append(_STRING_ESCAPES[nxt])
                i += 2
                continue
            if nxt == "x" and i + 3 < len(raw):
                out.append(chr(int(raw[i + 2:i + 4], 16)))
                i += 4
                continue
            if nxt == "u" and i + 5 < len(raw):
                out.append(chr(int(raw[i + 2:i + 6], 16)))
                i += 6
                continue
            # Unknown escape: pass through the next char.
            out.append(nxt)
            i += 2
            continue
        out.append(c)
        i += 1
    return "".join(out)


# ---------------------------------------------------------------------------
# Parser
# ---------------------------------------------------------------------------
#
# Recursive descent over the token list. Each `parse_*` consumes tokens
# and returns an AST dict. Operator precedence is encoded as a ladder of
# parse functions (lowest precedence outermost): assignment → ternary →
# logical-or → logical-and → bitwise-or → bitwise-xor → bitwise-and →
# equality → relational → shift → additive → multiplicative → unary →
# postfix-update → call-member → primary.


class ParseError(Exception):
    pass


class Parser:
    def __init__(self, toks: list[dict], src: str) -> None:
        self.toks = toks
        self.src = src
        self.pos = 0
        # The "no_in" flag suppresses the `in` keyword as a binary operator
        # while parsing a `for (...)` header's left-hand side, so that
        # `for (var k in obj)` doesn't get eaten by parse_relational.
        self.no_in = False

    # ---- core helpers ----

    def peek(self, offset: int = 0) -> dict:
        return self.toks[self.pos + offset]

    def at_end(self) -> bool:
        return self.peek()["kind"] == "EOF"

    def loc(self, t: dict | None = None) -> tuple[int, int]:
        t = t if t is not None else self.peek()
        return (t["line"], t["col"])

    def fail(self, msg: str, tok: dict | None = None) -> "ParseError":
        t = tok if tok is not None else self.peek()
        line = t["line"]
        # Recover the source line for context.
        lines = self.src.splitlines()
        ctx = lines[line - 1] if 0 < line <= len(lines) else ""
        pointer = " " * (t["col"] - 1) + "^"
        return ParseError(
            f"jsparse: {msg} at line {line}:{t['col']} "
            f"(token {t['kind']} {t['raw']!r})\n  {ctx}\n  {pointer}"
        )

    def eat_punct(self, p: str) -> dict:
        t = self.peek()
        if t["kind"] == "PUNCT" and t["value"] == p:
            self.pos += 1
            return t
        raise self.fail(f"expected '{p}'")

    def eat_keyword(self, kw: str) -> dict:
        t = self.peek()
        if t["kind"] == "KEYWORD" and t["value"] == kw:
            self.pos += 1
            return t
        raise self.fail(f"expected keyword '{kw}'")

    def eat_ident(self) -> dict:
        t = self.peek()
        if t["kind"] == "IDENT":
            self.pos += 1
            return t
        raise self.fail("expected identifier")

    def match_punct(self, *ps: str) -> bool:
        t = self.peek()
        return t["kind"] == "PUNCT" and t["value"] in ps

    def match_keyword(self, *kws: str) -> bool:
        t = self.peek()
        return t["kind"] == "KEYWORD" and t["value"] in kws

    def consume_punct(self, p: str) -> bool:
        if self.match_punct(p):
            self.pos += 1
            return True
        return False

    # ---- top level ----

    def parse_program(self) -> dict:
        start = self.peek()
        body = []
        while not self.at_end():
            body.append(self.parse_statement())
        return {"kind": "Program", "body": body, "loc": self.loc(start)}

    # ---- statements ----

    def parse_statement(self) -> dict:
        t = self.peek()
        if t["kind"] == "KEYWORD":
            kw = t["value"]
            if kw == "var":
                return self.parse_var_statement()
            if kw == "function":
                return self.parse_function_declaration()
            if kw == "if":
                return self.parse_if_statement()
            if kw == "for":
                return self.parse_for_statement()
            if kw == "while":
                return self.parse_while_statement()
            if kw == "do":
                return self.parse_do_statement()
            if kw == "return":
                return self.parse_return_statement()
            if kw == "break":
                return self.parse_break_continue("Break")
            if kw == "continue":
                return self.parse_break_continue("Continue")
            if kw == "throw":
                return self.parse_throw_statement()
            if kw == "switch":
                return self.parse_switch_statement()
            if kw == "try":
                return self.parse_try_statement()
        if t["kind"] == "PUNCT":
            if t["value"] == "{":
                return self.parse_block()
            if t["value"] == ";":
                self.pos += 1
                return {"kind": "Empty", "loc": self.loc(t)}
        return self.parse_expression_statement()

    def parse_block(self) -> dict:
        start = self.eat_punct("{")
        body = []
        while not self.match_punct("}"):
            if self.at_end():
                raise self.fail("unterminated block")
            body.append(self.parse_statement())
        self.eat_punct("}")
        return {"kind": "Block", "body": body, "loc": self.loc(start)}

    def parse_var_statement(self) -> dict:
        start = self.eat_keyword("var")
        decls = [self.parse_var_declarator()]
        while self.consume_punct(","):
            decls.append(self.parse_var_declarator())
        self.eat_punct(";")
        return {"kind": "VarDecl", "decls": decls, "loc": self.loc(start)}

    def parse_var_declarator(self) -> dict:
        name_t = self.eat_ident()
        init = None
        if self.consume_punct("="):
            init = self.parse_assignment()
        return {
            "kind": "VarDeclarator", "name": name_t["value"],
            "init": init, "loc": self.loc(name_t),
        }

    def parse_function_declaration(self) -> dict:
        start = self.eat_keyword("function")
        name_t = self.eat_ident()
        params = self.parse_params()
        body = self.parse_block()
        return {
            "kind": "FunctionDecl",
            "name": name_t["value"],
            "params": params,
            "body": body,
            "loc": self.loc(start),
        }

    def parse_params(self) -> list[str]:
        self.eat_punct("(")
        params: list[str] = []
        if not self.match_punct(")"):
            params.append(self.eat_ident()["value"])
            while self.consume_punct(","):
                params.append(self.eat_ident()["value"])
        self.eat_punct(")")
        return params

    def parse_if_statement(self) -> dict:
        start = self.eat_keyword("if")
        self.eat_punct("(")
        test = self.parse_expression()
        self.eat_punct(")")
        then_branch = self.parse_statement()
        else_branch = None
        if self.match_keyword("else"):
            self.pos += 1
            else_branch = self.parse_statement()
        return {
            "kind": "If",
            "test": test,
            "then": then_branch,
            "else": else_branch,
            "loc": self.loc(start),
        }

    def parse_for_statement(self) -> dict:
        start = self.eat_keyword("for")
        self.eat_punct("(")
        # Three shapes:
        #   for ( ;cond; update ) body                         (no init)
        #   for ( init ; cond ; update ) body                  (C-style)
        #   for ( var? lhs in obj ) body                       (for-in)
        # The for-in commitment is made when we see `in` AFTER parsing the
        # left-hand side. While doing so, no_in suppresses `in` as a binary
        # operator (otherwise parse_relational would eat it).
        if self.consume_punct(";"):
            return self._parse_c_for_tail(start, None)
        prev_no_in = self.no_in
        self.no_in = True
        try:
            if self.match_keyword("var"):
                kw = self.eat_keyword("var")
                decls = [self.parse_var_declarator()]
                if (len(decls) == 1 and decls[0]["init"] is None
                        and self.match_keyword("in")):
                    return self._parse_for_in_tail(
                        start, {"kind": "VarDecl", "decls": decls, "loc": self.loc(kw)})
                while self.consume_punct(","):
                    decls.append(self.parse_var_declarator())
                init = {"kind": "VarDecl", "decls": decls, "loc": self.loc(kw)}
            else:
                init_expr = self.parse_expression()
                if self.match_keyword("in"):
                    return self._parse_for_in_tail(start, init_expr)
                init = {
                    "kind": "Expression", "expr": init_expr,
                    "loc": self.loc(start),
                }
        finally:
            self.no_in = prev_no_in
        self.eat_punct(";")
        return self._parse_c_for_tail(start, init)

    def _parse_c_for_tail(self, start: dict, init) -> dict:
        test = None
        if not self.match_punct(";"):
            test = self.parse_expression()
        self.eat_punct(";")
        update = None
        if not self.match_punct(")"):
            update = self.parse_expression()
        self.eat_punct(")")
        body = self.parse_statement()
        return {
            "kind": "For", "init": init, "test": test,
            "update": update, "body": body, "loc": self.loc(start),
        }

    def _parse_for_in_tail(self, start: dict, left) -> dict:
        self.eat_keyword("in")
        right = self.parse_expression()
        self.eat_punct(")")
        body = self.parse_statement()
        return {
            "kind": "ForIn", "left": left, "right": right,
            "body": body, "loc": self.loc(start),
        }

    def parse_while_statement(self) -> dict:
        start = self.eat_keyword("while")
        self.eat_punct("(")
        test = self.parse_expression()
        self.eat_punct(")")
        body = self.parse_statement()
        return {"kind": "While", "test": test, "body": body, "loc": self.loc(start)}

    def parse_do_statement(self) -> dict:
        start = self.eat_keyword("do")
        body = self.parse_statement()
        self.eat_keyword("while")
        self.eat_punct("(")
        test = self.parse_expression()
        self.eat_punct(")")
        self.eat_punct(";")
        return {"kind": "DoWhile", "body": body, "test": test, "loc": self.loc(start)}

    def parse_return_statement(self) -> dict:
        start = self.eat_keyword("return")
        value = None
        if not self.match_punct(";"):
            value = self.parse_expression()
        self.eat_punct(";")
        return {"kind": "Return", "value": value, "loc": self.loc(start)}

    def parse_break_continue(self, kind: str) -> dict:
        start = self.peek()
        self.pos += 1
        self.eat_punct(";")
        return {"kind": kind, "loc": self.loc(start)}

    def parse_throw_statement(self) -> dict:
        start = self.eat_keyword("throw")
        value = self.parse_expression()
        self.eat_punct(";")
        return {"kind": "Throw", "value": value, "loc": self.loc(start)}

    def parse_switch_statement(self) -> dict:
        start = self.eat_keyword("switch")
        self.eat_punct("(")
        disc = self.parse_expression()
        self.eat_punct(")")
        self.eat_punct("{")
        cases: list[dict] = []
        while not self.match_punct("}"):
            if self.match_keyword("case"):
                case_t = self.eat_keyword("case")
                test = self.parse_expression()
                self.eat_punct(":")
                body = self._parse_case_body()
                cases.append({
                    "kind": "Case", "test": test, "body": body,
                    "loc": self.loc(case_t),
                })
            elif self.match_keyword("default"):
                def_t = self.eat_keyword("default")
                self.eat_punct(":")
                body = self._parse_case_body()
                cases.append({
                    "kind": "Default", "body": body, "loc": self.loc(def_t),
                })
            else:
                raise self.fail("expected 'case' or 'default'")
        self.eat_punct("}")
        return {
            "kind": "Switch", "disc": disc, "cases": cases,
            "loc": self.loc(start),
        }

    def _parse_case_body(self) -> list[dict]:
        body: list[dict] = []
        while not (self.match_keyword("case", "default") or self.match_punct("}")):
            if self.at_end():
                raise self.fail("unterminated switch")
            body.append(self.parse_statement())
        return body

    def parse_try_statement(self) -> dict:
        start = self.eat_keyword("try")
        block = self.parse_block()
        handler = None
        finalizer = None
        if self.match_keyword("catch"):
            cat_t = self.eat_keyword("catch")
            self.eat_punct("(")
            param = self.eat_ident()["value"]
            self.eat_punct(")")
            cbody = self.parse_block()
            handler = {
                "kind": "CatchClause", "param": param, "body": cbody,
                "loc": self.loc(cat_t),
            }
        if self.match_keyword("finally"):
            self.eat_keyword("finally")
            finalizer = self.parse_block()
        if handler is None and finalizer is None:
            raise self.fail("try without catch or finally")
        return {
            "kind": "Try", "block": block,
            "handler": handler, "finalizer": finalizer,
            "loc": self.loc(start),
        }

    def parse_expression_statement(self) -> dict:
        start = self.peek()
        expr = self.parse_expression()
        self.eat_punct(";")
        return {"kind": "Expression", "expr": expr, "loc": self.loc(start)}

    # ---- expressions (precedence ladder) ----

    def parse_expression(self) -> dict:
        # Comma operator (sequence). Rare in our dialect outside `for`
        # headers, but supported for completeness.
        expr = self.parse_assignment()
        if self.match_punct(","):
            exprs = [expr]
            while self.consume_punct(","):
                exprs.append(self.parse_assignment())
            return {"kind": "Sequence", "exprs": exprs, "loc": expr["loc"]}
        return expr

    _ASSIGN_OPS = frozenset([
        "=", "+=", "-=", "*=", "/=", "%=",
        "&=", "|=", "^=", "<<=", ">>=", ">>>=",
    ])

    def parse_assignment(self) -> dict:
        left = self.parse_conditional()
        t = self.peek()
        if t["kind"] == "PUNCT" and t["value"] in self._ASSIGN_OPS:
            self.pos += 1
            right = self.parse_assignment()  # right-assoc
            return {
                "kind": "Assign",
                "op": t["value"],
                "target": left,
                "value": right,
                "loc": left["loc"],
            }
        return left

    def parse_conditional(self) -> dict:
        test = self.parse_logical_or()
        if self.consume_punct("?"):
            then_e = self.parse_assignment()
            self.eat_punct(":")
            else_e = self.parse_assignment()
            return {
                "kind": "Conditional",
                "test": test, "then": then_e, "else": else_e,
                "loc": test["loc"],
            }
        return test

    def _binary_left(self, sub, ops, node_kind="Binary"):
        left = sub()
        while True:
            t = self.peek()
            if t["kind"] == "PUNCT" and t["value"] in ops:
                self.pos += 1
                right = sub()
                left = {
                    "kind": node_kind, "op": t["value"],
                    "left": left, "right": right,
                    "loc": left["loc"],
                }
            else:
                break
        return left

    def parse_logical_or(self) -> dict:
        return self._binary_left(self.parse_logical_and, {"||"}, "Logical")

    def parse_logical_and(self) -> dict:
        return self._binary_left(self.parse_bit_or, {"&&"}, "Logical")

    def parse_bit_or(self) -> dict:
        return self._binary_left(self.parse_bit_xor, {"|"})

    def parse_bit_xor(self) -> dict:
        return self._binary_left(self.parse_bit_and, {"^"})

    def parse_bit_and(self) -> dict:
        return self._binary_left(self.parse_equality, {"&"})

    def parse_equality(self) -> dict:
        return self._binary_left(self.parse_relational, {"==", "!=", "===", "!=="})

    def parse_relational(self) -> dict:
        # `in` and `instanceof` are relational keywords; handle them as
        # binary operators.
        left = self.parse_shift()
        while True:
            t = self.peek()
            if t["kind"] == "PUNCT" and t["value"] in {"<", "<=", ">", ">="}:
                self.pos += 1
                right = self.parse_shift()
                left = {
                    "kind": "Binary", "op": t["value"],
                    "left": left, "right": right,
                    "loc": left["loc"],
                }
            elif (t["kind"] == "KEYWORD" and t["value"] == "instanceof") or (
                    t["kind"] == "KEYWORD" and t["value"] == "in" and not self.no_in):
                self.pos += 1
                right = self.parse_shift()
                left = {
                    "kind": "Binary", "op": t["value"],
                    "left": left, "right": right,
                    "loc": left["loc"],
                }
            else:
                break
        return left

    def parse_shift(self) -> dict:
        return self._binary_left(self.parse_additive, {"<<", ">>", ">>>"})

    def parse_additive(self) -> dict:
        return self._binary_left(self.parse_multiplicative, {"+", "-"})

    def parse_multiplicative(self) -> dict:
        return self._binary_left(self.parse_unary, {"*", "/", "%"})

    def parse_unary(self) -> dict:
        t = self.peek()
        if t["kind"] == "PUNCT" and t["value"] in {"!", "~", "+", "-", "++", "--"}:
            self.pos += 1
            operand = self.parse_unary()
            node_kind = "Update" if t["value"] in {"++", "--"} else "Unary"
            return {
                "kind": node_kind, "op": t["value"], "prefix": True,
                "operand": operand, "loc": self.loc(t),
            }
        if t["kind"] == "KEYWORD" and t["value"] in {"typeof", "void", "delete"}:
            self.pos += 1
            operand = self.parse_unary()
            return {
                "kind": "Unary", "op": t["value"], "prefix": True,
                "operand": operand, "loc": self.loc(t),
            }
        return self.parse_postfix()

    def parse_postfix(self) -> dict:
        expr = self.parse_call_member(allow_new=True)
        t = self.peek()
        if t["kind"] == "PUNCT" and t["value"] in {"++", "--"}:
            self.pos += 1
            return {
                "kind": "Update", "op": t["value"], "prefix": False,
                "operand": expr, "loc": expr["loc"],
            }
        return expr

    def parse_call_member(self, allow_new: bool) -> dict:
        # `new` is parsed as a prefix that absorbs ONE call-expression
        # tail (its argument list). Member access continues afterward.
        if allow_new and self.match_keyword("new"):
            start = self.eat_keyword("new")
            callee = self.parse_call_member(allow_new=True)
            # If callee already has a Call at its OUTERMOST, that's the
            # `new` argument list. Otherwise `new Foo` with no parens.
            if callee.get("kind") == "Call":
                node = {
                    "kind": "New", "callee": callee["callee"],
                    "args": callee["args"], "loc": self.loc(start),
                }
                # Re-attach trailing member/call chain that followed the
                # `new`'s own call. (Not common in this dialect; skip.)
                return node
            return {
                "kind": "New", "callee": callee, "args": [],
                "loc": self.loc(start),
            }
        expr = self.parse_primary()
        while True:
            if self.consume_punct("."):
                name_t = self.eat_ident_or_keyword_as_name()
                expr = {
                    "kind": "Member", "object": expr,
                    "property": name_t["value"], "computed": False,
                    "loc": expr["loc"],
                }
            elif self.consume_punct("["):
                index = self.parse_expression()
                self.eat_punct("]")
                expr = {
                    "kind": "Member", "object": expr,
                    "property": index, "computed": True,
                    "loc": expr["loc"],
                }
            elif self.match_punct("("):
                args = self.parse_arguments()
                expr = {
                    "kind": "Call", "callee": expr, "args": args,
                    "loc": expr["loc"],
                }
            else:
                break
        return expr

    def eat_ident_or_keyword_as_name(self) -> dict:
        # After `.`, keywords like `delete`, `new`, `default` are valid
        # member names. Treat any identifier-shaped token as a name.
        t = self.peek()
        if t["kind"] in ("IDENT", "KEYWORD"):
            self.pos += 1
            return t
        raise self.fail("expected property name")

    def parse_arguments(self) -> list[dict]:
        self.eat_punct("(")
        args: list[dict] = []
        if not self.match_punct(")"):
            args.append(self.parse_assignment())
            while self.consume_punct(","):
                args.append(self.parse_assignment())
        self.eat_punct(")")
        return args

    def parse_primary(self) -> dict:
        t = self.peek()
        if t["kind"] == "IDENT":
            self.pos += 1
            return {"kind": "Identifier", "name": t["value"], "loc": self.loc(t)}
        if t["kind"] == "NUMBER":
            self.pos += 1
            return {"kind": "Number", "value": t["value"], "raw": t["raw"], "loc": self.loc(t)}
        if t["kind"] == "STRING":
            self.pos += 1
            return {"kind": "String", "value": t["value"], "raw": t["raw"], "loc": self.loc(t)}
        if t["kind"] == "REGEX":
            self.pos += 1
            return {
                "kind": "Regex",
                "pattern": t["value"]["pattern"],
                "flags": t["value"]["flags"],
                "raw": t["raw"],
                "loc": self.loc(t),
            }
        if t["kind"] == "KEYWORD":
            if t["value"] in ("true", "false"):
                self.pos += 1
                return {"kind": "Bool", "value": t["value"] == "true", "loc": self.loc(t)}
            if t["value"] == "null":
                self.pos += 1
                return {"kind": "Null", "loc": self.loc(t)}
            if t["value"] == "undefined":
                self.pos += 1
                return {"kind": "Undefined", "loc": self.loc(t)}
            if t["value"] == "this":
                self.pos += 1
                return {"kind": "This", "loc": self.loc(t)}
            if t["value"] == "function":
                return self.parse_function_expression()
        if t["kind"] == "PUNCT":
            if t["value"] == "(":
                self.pos += 1
                expr = self.parse_expression()
                self.eat_punct(")")
                # Flatten parens — no Paren node, the precedence is
                # already encoded structurally.
                return expr
            if t["value"] == "[":
                return self.parse_array_literal()
            if t["value"] == "{":
                return self.parse_object_literal()
        raise self.fail("expected expression")

    def parse_function_expression(self) -> dict:
        start = self.eat_keyword("function")
        name = None
        if self.peek()["kind"] == "IDENT":
            name = self.eat_ident()["value"]
        params = self.parse_params()
        body = self.parse_block()
        return {
            "kind": "FunctionExpr",
            "name": name, "params": params, "body": body,
            "loc": self.loc(start),
        }

    def parse_array_literal(self) -> dict:
        start = self.eat_punct("[")
        elements: list[dict | None] = []
        while not self.match_punct("]"):
            if self.consume_punct(","):
                elements.append(None)  # elision
                continue
            elements.append(self.parse_assignment())
            if not self.match_punct("]"):
                self.eat_punct(",")
        self.eat_punct("]")
        return {"kind": "Array", "elements": elements, "loc": self.loc(start)}

    def parse_object_literal(self) -> dict:
        start = self.eat_punct("{")
        props = []
        if not self.match_punct("}"):
            props.append(self.parse_property())
            while self.consume_punct(","):
                if self.match_punct("}"):
                    break  # trailing comma
                props.append(self.parse_property())
        self.eat_punct("}")
        return {"kind": "Object", "properties": props, "loc": self.loc(start)}

    def parse_property(self) -> dict:
        t = self.peek()
        if t["kind"] in ("IDENT", "KEYWORD"):
            self.pos += 1
            key = {"kind": "Identifier", "name": t["value"], "loc": self.loc(t)}
        elif t["kind"] == "STRING":
            self.pos += 1
            key = {"kind": "String", "value": t["value"], "raw": t["raw"], "loc": self.loc(t)}
        elif t["kind"] == "NUMBER":
            self.pos += 1
            key = {"kind": "Number", "value": t["value"], "raw": t["raw"], "loc": self.loc(t)}
        else:
            raise self.fail("expected property key")
        self.eat_punct(":")
        value = self.parse_assignment()
        return {"kind": "Property", "key": key, "value": value, "loc": key["loc"]}


def parse(src: str) -> dict:
    toks = tokenize(src)
    return Parser(toks, src).parse_program()


# ---------------------------------------------------------------------------
# AST walker (used by the CLI summary; linters will use this too)
# ---------------------------------------------------------------------------

def walk(node):
    """Yield every dict-shaped AST node reachable from `node`, depth-
    first. Used by linters and by the CLI to summarize what parsed."""
    if isinstance(node, dict) and "kind" in node:
        yield node
        for v in node.values():
            yield from walk(v)
    elif isinstance(node, list):
        for item in node:
            yield from walk(item)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main() -> int:
    from collections import Counter
    files = sorted((REPO / "chat").glob("*.js"))
    total: Counter = Counter()
    fails = 0
    for path in files:
        src = path.read_text()
        try:
            program = parse(src)
        except (LexError, ParseError) as e:
            print(f"FAIL {path.relative_to(REPO)}", file=sys.stderr)
            print(str(e), file=sys.stderr)
            fails += 1
            continue
        kinds = Counter(n["kind"] for n in walk(program))
        total.update(kinds)
        print(f"OK   {path.relative_to(REPO)}: {sum(kinds.values())} nodes")
    if fails:
        return 1
    print()
    print(f"Aggregate AST kinds ({sum(total.values())} nodes across {len(files)} files):")
    for kind, count in sorted(total.items(), key=lambda kv: -kv[1]):
        print(f"  {kind:14s} {count}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
