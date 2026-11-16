#!/usr/bin/env python3
"""Minifies Lua 5.2 source (as used by CC: Tweaked).

* removes comments and unneeded whitespace (lines are wrapped at ~200
  characters so error messages and editors stay usable),
* renames local variables (and parameters) to short names.

Globals, table fields and strings are never touched, so the program behaves
exactly the same. Renaming relies on a full parse of the source: any syntax
the parser doesn't understand raises an error rather than producing broken
output.

    python3 tools/luamin.py in.lua [out.lua]
"""
import re
import sys

KEYWORDS = {
    "and", "break", "do", "else", "elseif", "end", "false", "for", "function", "goto", "if", "in",
    "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while",
}
NAME, KW, NUM, STR, OP, EOF = "name", "kw", "num", "str", "op", "eof"
OPS = ["...", "..", "==", "~=", "<=", ">=", "::", "+", "-", "*", "/", "%", "^", "#", "&", "~", "|",
       "<", ">", "=", "(", ")", "{", "}", "[", "]", ";", ":", ",", "."]
NUM_RE = re.compile(r"0[xX](?:[0-9a-fA-F]*\.?[0-9a-fA-F]*)(?:[pP][+-]?\d+)?|(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?")
NAME_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
LONG_OPEN = re.compile(r"\[(=*)\[")


class LuaSyntaxError(Exception):
    pass


def tokenize(src):
    """Returns a list of (kind, text, line) tokens; comments are dropped."""
    toks, i, n, line = [], 0, len(src), 1
    while i < n:
        c = src[i]
        if c == "\n":
            line += 1; i += 1; continue
        if c in " \t\r\f\v":
            i += 1; continue
        if src.startswith("--", i):
            m = LONG_OPEN.match(src, i + 2)
            if m:
                close = "]" + m.group(1) + "]"
                j = src.find(close, m.end())
                if j < 0:
                    raise LuaSyntaxError("unfinished long comment on line %d" % line)
                line += src.count("\n", i, j)
                i = j + len(close)
            else:
                j = src.find("\n", i)
                i = n if j < 0 else j
            continue
        if c == "[":
            m = LONG_OPEN.match(src, i)
            if m:
                close = "]" + m.group(1) + "]"
                j = src.find(close, m.end())
                if j < 0:
                    raise LuaSyntaxError("unfinished long string on line %d" % line)
                text = src[i:j + len(close)]
                toks.append((STR, text, line))
                line += text.count("\n")
                i = j + len(close)
                continue
        if c in "\"'":
            j = i + 1
            while True:
                if j >= n or src[j] == "\n":
                    raise LuaSyntaxError("unfinished string on line %d" % line)
                if src[j] == "\\":
                    if src.startswith("z", j + 1):  # \z skips following whitespace
                        j += 2
                        while j < n and src[j] in " \t\r\n\f\v":
                            j += 1
                        continue
                    j += 2
                    continue
                if src[j] == c:
                    break
                j += 1
            text = src[i:j + 1]
            toks.append((STR, text, line))
            line += text.count("\n")
            i = j + 1
            continue
        if c.isdigit() or (c == "." and i + 1 < n and src[i + 1].isdigit()):
            m = NUM_RE.match(src, i)
            toks.append((NUM, m.group(0), line))
            i = m.end()
            continue
        m = NAME_RE.match(src, i)
        if m:
            w = m.group(0)
            toks.append((KW if w in KEYWORDS else NAME, w, line))
            i = m.end()
            continue
        for op in OPS:
            if src.startswith(op, i):
                toks.append((OP, op, line))
                i += len(op)
                break
        else:
            raise LuaSyntaxError("unexpected character %r on line %d" % (c, line))
    toks.append((EOF, "", line))
    return toks


class Var:
    __slots__ = ("name", "decl", "refs", "start", "end", "new")

    def __init__(self, name, decl):
        self.name, self.decl, self.refs = name, decl, []
        self.start = self.end = None
        self.new = None


class Resolver:
    """Recursive-descent parser that only tracks scopes: which token is a
    declaration or a use of which local variable."""

    def __init__(self, toks):
        self.t, self.i = toks, 0
        self.scopes = []
        self.vars, self.globals = [], set()

    # -- helpers ----------------------------------------------------------
    def peek(self, k=0):
        return self.t[self.i + k]

    def check(self, text, k=0):
        tok = self.t[self.i + k]
        return tok[0] in (KW, OP) and tok[1] == text

    def next(self):
        tok = self.t[self.i]
        self.i += 1
        return tok

    def expect(self, text):
        tok = self.next()
        if tok[0] not in (KW, OP) or tok[1] != text:
            raise LuaSyntaxError("'%s' expected near '%s' on line %d" % (text, tok[1], tok[2]))

    def name(self):
        tok = self.next()
        if tok[0] != NAME:
            raise LuaSyntaxError("name expected near '%s' on line %d" % (tok[1], tok[2]))
        return self.i - 1

    def open_scope(self):
        self.scopes.append([])

    def close_scope(self):
        for v in self.scopes.pop():
            v.end = self.i  # visible until here
        # (a variable's range is [start, end) in token positions)

    def declare(self, idx, start=None):
        v = Var(self.t[idx][1], idx)
        v.start = self.i if start is None else start
        self.scopes[-1].append(v)
        self.vars.append(v)
        return v

    def reference(self, idx):
        name = self.t[idx][1]
        for scope in reversed(self.scopes):
            for v in reversed(scope):
                if v.name == name and v.start <= idx:
                    v.refs.append(idx)
                    return
        self.globals.add(name)

    # -- grammar ----------------------------------------------------------
    def chunk(self):
        self.open_scope()
        self.block()
        if self.peek()[0] != EOF:
            tok = self.peek()
            raise LuaSyntaxError("'<eof>' expected near '%s' on line %d" % (tok[1], tok[2]))
        self.close_scope()

    def block_end(self):
        tok = self.peek()
        return tok[0] == EOF or (tok[0] == KW and tok[1] in ("end", "else", "elseif", "until"))

    def block(self):
        while not self.block_end():
            if self.check("return"):
                self.next()
                if not self.block_end() and not self.check(";"):
                    self.explist()
                if self.check(";"):
                    self.next()
                return
            self.statement()

    def scoped_block(self):
        self.open_scope()
        self.block()
        self.close_scope()

    def statement(self):
        tok = self.peek()
        kind, text = tok[0], tok[1]
        if kind == OP and text == ";":
            self.next()
        elif kind == OP and text == "::":
            self.next(); self.next(); self.expect("::")  # label: names untouched
        elif kind == KW and text == "if":
            self.next(); self.expr(); self.expect("then"); self.scoped_block()
            while self.check("elseif"):
                self.next(); self.expr(); self.expect("then"); self.scoped_block()
            if self.check("else"):
                self.next(); self.scoped_block()
            self.expect("end")
        elif kind == KW and text == "while":
            self.next(); self.expr(); self.expect("do"); self.scoped_block(); self.expect("end")
        elif kind == KW and text == "do":
            self.next(); self.scoped_block(); self.expect("end")
        elif kind == KW and text == "for":
            self.next()
            first = self.name()
            if self.check("="):
                self.next(); self.expr(); self.expect(","); self.expr()
                if self.check(","):
                    self.next(); self.expr()
                names = [first]
            else:
                names = [first]
                while self.check(","):
                    self.next(); names.append(self.name())
                self.expect("in"); self.explist()
            self.expect("do")
            self.open_scope()
            for idx in names:
                self.declare(idx)
            self.block()
            self.close_scope()
            self.expect("end")
        elif kind == KW and text == "repeat":
            self.next()
            self.open_scope()
            self.block()
            self.expect("until")
            self.expr()  # the condition still sees the body's locals
            self.close_scope()
        elif kind == KW and text == "function":
            self.next()
            self.reference(self.name())
            method = False
            while self.check("."):
                self.next(); self.name()
            if self.check(":"):
                self.next(); self.name(); method = True
            self.body(method)
        elif kind == KW and text == "local":
            self.next()
            if self.check("function"):
                self.next()
                idx = self.name()
                self.declare(idx)  # visible inside its own body (recursion)
                self.body(False)
            else:
                names = [self.name()]
                while self.check(","):
                    self.next(); names.append(self.name())
                if self.check("="):
                    self.next(); self.explist()
                for idx in names:
                    self.declare(idx)  # visible only after the statement
        elif kind == KW and text == "break":
            self.next()
        elif kind == KW and text == "goto":
            self.next(); self.next()
        else:
            self.suffixedexp()
            if self.check("=") or self.check(","):
                while self.check(","):
                    self.next(); self.suffixedexp()
                self.expect("="); self.explist()

    def body(self, method):
        self.expect("(")
        self.open_scope()
        # (a method's implicit "self" is not declared: its uses count as a
        # global name, so no local is ever renamed to "self")
        if not self.check(")"):
            while True:
                if self.check("..."):
                    self.next(); break
                self.declare(self.name())
                if not self.check(","):
                    break
                self.next()
        self.expect(")")
        self.block()
        self.close_scope()
        self.expect("end")

    def explist(self):
        self.expr()
        while self.check(","):
            self.next(); self.expr()

    UNOPS = ("not", "-", "#", "~")
    BINOPS = {"+", "-", "*", "/", "%", "^", "..", "==", "~=", "<", "<=", ">", ">=", "and", "or",
              "&", "|", "~", "<<", ">>", "//"}

    def expr(self):
        while self.peek()[0] in (KW, OP) and self.peek()[1] in self.UNOPS:
            self.next()
        self.simpleexp()
        while self.peek()[0] in (KW, OP) and self.peek()[1] in self.BINOPS:
            self.next()
            while self.peek()[0] in (KW, OP) and self.peek()[1] in self.UNOPS:
                self.next()
            self.simpleexp()

    def simpleexp(self):
        tok = self.peek()
        if tok[0] in (NUM, STR) or (tok[0] == KW and tok[1] in ("nil", "true", "false")) or \
                (tok[0] == OP and tok[1] == "..."):
            self.next()
        elif tok[0] == OP and tok[1] == "{":
            self.table()
        elif tok[0] == KW and tok[1] == "function":
            self.next(); self.body(False)
        else:
            self.suffixedexp()

    def primaryexp(self):
        tok = self.peek()
        if tok[0] == NAME:
            self.reference(self.name())
        elif tok[0] == OP and tok[1] == "(":
            self.next(); self.expr(); self.expect(")")
        else:
            raise LuaSyntaxError("unexpected symbol near '%s' on line %d" % (tok[1], tok[2]))

    def suffixedexp(self):
        self.primaryexp()
        while True:
            tok = self.peek()
            if tok[0] == OP and tok[1] == ".":
                self.next(); self.name()
            elif tok[0] == OP and tok[1] == "[":
                self.next(); self.expr(); self.expect("]")
            elif tok[0] == OP and tok[1] == ":":
                self.next(); self.name(); self.args()
            elif (tok[0] == OP and tok[1] in ("(", "{")) or tok[0] == STR:
                self.args()
            else:
                return

    def args(self):
        tok = self.peek()
        if tok[0] == STR:
            self.next()
        elif tok[0] == OP and tok[1] == "{":
            self.table()
        else:
            self.expect("(")
            if not self.check(")"):
                self.explist()
            self.expect(")")

    def table(self):
        self.expect("{")
        while not self.check("}"):
            if self.check("["):
                self.next(); self.expr(); self.expect("]"); self.expect("="); self.expr()
            elif self.peek()[0] == NAME and self.check("=", 1):
                self.next(); self.next(); self.expr()  # key = value (key is not a variable)
            else:
                self.expr()
            if self.check(",") or self.check(";"):
                self.next()
            else:
                break
        self.expect("}")


def short_names():
    first = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_"
    rest = first + "0123456789"
    for c in first:
        yield c
    for c in first:
        for d in rest:
            yield c + d
    for c in first:
        for d in rest:
            for e in rest:
                yield c + d + e


def rename(toks):
    """Returns a {token index: new name} map for all local variables."""
    r = Resolver(toks)
    r.chunk()
    names = [n for n in short_names() if n not in KEYWORDS and n not in r.globals]
    # Most used variables first, so they get the shortest names. A variable
    # can't share a name with any other variable whose visible range
    # overlaps its own (that's what keeps shadowing correct).
    vs = sorted(r.vars, key=lambda v: -len(v.refs))
    order = sorted(r.vars, key=lambda v: v.start)
    for v in vs:
        used = set()
        for w in order:
            if w.start >= v.end:
                break
            if w.new is not None and w.end > v.start:
                used.add(w.new)
        for n in names:
            if n not in used:
                v.new = n
                break
    out = {}
    for v in r.vars:
        out[v.decl] = v.new
        for idx in v.refs:
            out[idx] = v.new
    return out


def needs_space(a, b):
    """Whether tokens a and b would lex differently when written together."""
    # Lua reads a number greedily up to the next non-alphanumeric character
    # ("1e" or "1a" is a malformed number), so keep numbers apart.
    if NUM_RE.fullmatch(a) and (b[0].isalnum() or b[0] in "_."):
        return True
    try:
        t = tokenize(a + b)
    except LuaSyntaxError:
        return True
    return len(t) != 3 or t[0][1] != a or t[1][1] != b


def minify(src, rename_locals=True, width=200):
    if src.startswith("#!"):
        src = src[src.find("\n"):]
    toks = tokenize(src)
    names = rename(toks) if rename_locals else {}
    out, line, prev = [], [], None
    cache = {}
    for idx, tok in enumerate(toks[:-1]):
        text = names.get(idx, tok[1])
        if prev is not None:
            key = (prev, text) if tok[0] != STR else None
            if key is not None and key in cache:
                sep = cache[key]
            else:
                sep = needs_space(prev, text)
                if key is not None:
                    cache[key] = sep
            length = sum(len(s) for s in line)
            # Any token boundary may become a line break, except before "(":
            # Lua 5.1-derived parsers reject "f\n(...)" as ambiguous.
            if length + len(text) > width and text != "(":
                out.append("".join(line)); line = []
            elif sep:
                line.append(" ")
        line.append(text)
        prev = text
    out.append("".join(line))
    return "\n".join(out) + "\n"


def main():
    if len(sys.argv) < 2:
        print(__doc__.strip())
        sys.exit(1)
    with open(sys.argv[1]) as f:
        src = f.read()
    result = minify(src)
    if len(sys.argv) > 2:
        with open(sys.argv[2], "w") as f:
            f.write(result)
    else:
        sys.stdout.write(result)


if __name__ == "__main__":
    main()
