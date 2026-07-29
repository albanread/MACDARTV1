# MACVM Smalltalk (`.mst`) reader — Sprint 0

This is **Sprint 0 of `ST_PLAN.md`**: a standalone, pure-C++17 **language
reader** for the GNU-Smalltalk-style bracketed `.mst` dialect used by MACVM.

It is **completely self-contained** — lexer, AST, recursive-descent parser, and
a pretty-printing dumper. **There are no Dart-VM dependencies whatsoever.** It
compiles and runs on its own. Wiring the AST into the Dart VM is a later sprint;
this sprint just proves we can read the syntax and produce a faithful tree.

## Files

| File | Purpose |
|------|---------|
| `st_ast.h` | AST node types (header-only, std-lib only). |
| `st_lexer.h` / `st_lexer.cc` | Tokenizer. |
| `st_parser.h` / `st_parser.cc` | Recursive-descent parser producing the AST. |
| `st_dump.cc` | CLI: parse a `.mst` file/stdin, print the AST as S-expressions. |
| `build.sh` | One-command build → `./st_dump`. |
| `examples/` | Three `.mst` files exercising the supported grammar. |

## Build & run

```sh
bash build.sh                 # -> ./st_dump  (clang++ -std=c++17 -Wall -Wextra)
./st_dump examples/posix.mst  # dump one file's AST
./st_dump < some.mst          # or read from stdin
```

On a lexer/parser error the tool prints `file:line:col: message`, the offending
source line, and a caret, then exits non-zero.

## Examples

- **`examples/posix.mst`** — a full class definition: instance variables, a
  class-body pragma (`<classVars: …>`), comments, a keyword-selector instance
  method with temporaries/assignment/return, a class-side method
  (`Posix class >> kqueue`) whose body is a `<primitive: …>` pragma, a method
  using blocks + `whileTrue:` + a `[:i | … ]` block-argument block + a cascade
  (`self flush; sync; close`), and a binary method (`= other`).
- **`examples/external.mst`** — top-level (external) definitions: external
  class-side method `PosixFile class >> oRdOnly [ ^0 ]`, external instance
  method `PosixFile >> isReadable [ … ]`, `Posix extend [ … ]` and
  `Posix class extend [ … ]`, plus bare do-it statements.
- **`examples/literals.mst`** — the literal and expression zoo: integers,
  negative integers, radix `16rFF`, floats `3.14159` / `1.0e3`, strings with
  an escaped quote, `$a` chars, symbols (`#foo #at:put: #+ #'x y'`), literal
  arrays with nested arrays and bare-identifier-as-symbol plus literal
  `nil/true/false`, byte arrays `#[ … ]`, dynamic arrays `{ … }`, precedence
  (unary > binary > keyword), a block with args + temps, and a cascade.

## Grammar coverage

- Comments `"…"` with `""` as an escaped quote; whitespace-insensitive.
- Tokens: identifiers, keywords (`ident:`), binary-selector runs
  (`+ - * / ~ < > = & | @ % , ? ! \`), `:=`, `^`, `.`, `;`, `[]`, `()`, `{}`,
  `|`, and `:` (block-argument introducer).
- Literals: integers (incl. radix `16rFF` and leading-`-` negatives), floats
  (`1.5`, `1.0e3`, exponent forms), strings (`'it''s'`), symbols
  (`#foo #at:put: #+ #'x y'`), chars (`$a`), literal arrays
  `#(1 $a foo 'bar' #sym (nested))` (bare identifiers → symbols; `nil/true/false`
  → literal objects), byte arrays `#[1 2 3]`, and pseudo-vars
  `nil true false self super thisContext`.
- Class def: `<super> subclass: Name [ body ]` — special-cased from an ordinary
  `subclass:` keyword send. Class body = instance-var decls `| a b |`, class-body
  pragmas `< … >`, instance methods, and class-side methods `Name class >> …`.
- External / top-level defs: `Name >> pattern [ … ]`,
  `Name class >> pattern [ … ]`, `Name extend [ … ]`,
  `Name class extend [ … ]`.
- Method patterns: unary, binary (`+ arg`), keyword (`at: a put: b`).
- Method body: optional pragmas, optional temps `| t u |`, statements separated
  by `.`; a statement is `^expr` or an expr; assignment `id := expr` (chained).
- Expression precedence unary > binary > keyword; cascades via `;` (shared
  receiver = the receiver of the last message before the `;`).
- Primary: literal | variable | `( expr )` | block | dynamic array `{ e. e. }`.
- Block: `[ (:arg)* | (| temps |)? statements ]` — the `:x :y |` args form and
  the separate optional `| t |` temps.
- Top-level bare statements ("do-its").

### Disambiguations handled

- `|` — block-args terminator vs. temporaries bar vs. the binary `|` operator,
  resolved by parse context (prologue temps vs. expression position).
- Negative-number literal vs. binary `-` — `-` starts a number literal only when
  a digit immediately follows; otherwise it is a binary selector.
- `:` — bare `:` (block arg `:x`) vs. `:=` (assignment) vs. `ident:` (keyword).
- `subclass:` is parsed as a normal keyword message and special-cased into a
  `ClassDef` when followed by `[`.
- Pragma `<…>` vs. a `<`-named binary method — a `<` binary token followed by a
  keyword is treated as a pragma opener.

## Known TODOs (the long tail, deferred)

- **No VM integration** — this is a reader only (that is the whole point of
  Sprint 0). No compilation, name resolution, or bytecode.
- Pragmas are captured as raw text, not interpreted; a pragma body containing a
  bare `>` (other than its closer) is not handled, and non-keyword pragmas
  (`<primitive>`) aren't specially recognized.
- `#(at:put:)` written contiguously yields two symbol elements (`#at:` `#put:`)
  rather than one combined `#at:put:` symbol.
- Empty temporaries/args `||` lexes as a single binary `||` token, so an empty
  `| |` temp list is not recognized (real code uses `| a b |` with names).
- `a -3` (space before, none after `-`) reads `-3` as a negative literal rather
  than `a - 3`; this dialect ambiguity is intentionally left as-is.
- `ClassName class [ … ]` class-side *grouping* blocks are not parsed (only
  `ClassName class >> selector` class-side methods are).
- Scaled decimals (`3.14s2`), `radix` exponent letters beyond `e/E/d/D`, and
  extended/Unicode identifiers are not handled.
- No semantic checks (duplicate temps, arg/selector arity, undeclared vars).
