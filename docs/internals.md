# gooseneck internals

Why gooseneck is built the way it is, where things are, and how it is
tested. The [README](../README.md) is the user's guide;
[examples/](../examples/) has runnable walkthroughs.

## Design

### (a) Helpers are one static function that fills in a context

Goose has no runtime function pointers: a function value is a compile-time
argument, and it can't be stored, returned or put in data (spec §7.6). So
gooseneck keeps no table of helpers: the `Registry` your function receives
holds the current call, not your helpers. You pass one function, and the
renderer calls it directly. That makes each helper call a direct, inlinable call,
specialized for your function, with nothing to register or look up at
runtime. A block can capture your locals, so per-render state needs no
extra API. Renders without helpers use a built-in function that answers
nothing.

The name match happens inside your function. `helper` and `block_helper`
give it the shape of plod's routes: one registration per helper, built from
trailing blocks that are inlined into your function. It still compiles to a
chain of name comparisons and direct calls.

The function takes a `Registry`, and each registration's block takes the
call's `HelperContext` and fills it in, the way a plod handler takes `cx`
and answers through it. The registry is the outer part, which guarantees
each name is registered once; the context is the call. Splitting them
keeps listing (for the duplicate check and the block names) out of the
call. It doesn't return a result, for three reasons:

- **No `return` in your code.** A `return` in a trailing block returns from
  the function the block is written in (§7.6). A returned result would make
  every registration end in `return ...`, and a forgotten one would fall
  through. With `answer(cx, value)` the context records the answer.
- **One place for the call.** The name, the arguments, the scratch text,
  the output and the answer all live in the context. The function has no
  separate `name` and `args` parameters that repeat what the context holds.
- **It survives the recursion.** Block helpers run inside the render's
  recursive walk, where references may only be passed down, never stored
  in a struct built there (§7.8). A per-call struct holding the name, or
  the name passed as a block parameter, is rejected there. So the
  renderer builds the registry, with its context, once, outside the walk,
  fills in each call's name and arguments, and passes it down by
  reference. A block helper gets a copy, because its body makes calls of
  its own.

Your function's `reg` is untyped, as in plod. The renderer passes the
registry with `&` so that a block given as helpers gets it by reference,
and each registration passes the context to its block the same way (a
block's parameter is otherwise a copy, and its answer would be lost).
Against a parameter typed `Registry&`, that `&` is a "redundant &"
compiler warning (§4.1). Against an untyped one it isn't.

Duplicate names can't be found while Goose compiles your code: your
function is just code, and only running it says which names it
registers. So each render runs it once on a listing registry first, where
every registration gives its name instead of running its block, and a
name given twice is the render's error. The same listing gives the block
helper names, so a block of the template that none of them registers is
the render's error too.

That's also why the helpers are given to the render, not to `get_engine`.
The engine would have to keep them to use them later, and a function value
can't be stored in a struct (§7.6). Giving the block helpers to
`get_engine` only for their names, and again to the render to run them,
would be two places to keep in sync; so the render takes both and checks
everything before it writes.

Block helpers are a separate function for the same reason, plus one more:
a block helper gets its body, `B`, as a static function value too. The
renderer defines it as a nested function around the block's node and hands
it over, so a helper's `B(...)` call walks the template directly, with no
closure object in between. That's also why `B` takes a small descriptor
(`this()`, `element(0, k)`) rather than a context reference: references may
only be passed down into the recursive walk, never stored by code in the
middle of it (§7.8). The renderer resolves the descriptor itself.

### (b) Helpers speak JSON values

Both kinds of context end up in one data model: the stdlib's
`json::Node` document, with `json::Value` for each value. A JSON context is
`json::parse`'s document as it is. A typed struct is converted into the same
kind of document. Because the renderer only ever walks that one model,
helpers receive their arguments as `json::Value`s (a path's value, a
literal, or another helper's result) and return one. The same helper works
for every context, and results compose in subexpressions. For now results
are scalars: `Str`, `Int`, `Num`, `Bool` or `Null`.

### (c) Typed structs as contexts

`render(engine, my_struct)` walks your struct's fields at compile time with
`const for <N, A> in fields<T>` reflection, so there's no hand-written JSON,
no serializer, and no stringly-typed map. The compiler checks that every
field type converts: strings, integers, floats, bools, optionals, slices
and nested structs. The engine also records every field name the template's
paths use, and conversion skips every other field, so a large struct
behind a small template costs only what the template reads. A literal
`lookup` key counts as a name. A dynamic key is only known while rendering,
so it can't add one. That's why iterating a struct as an object, or looking up
its fields with a dynamic key, only sees named fields.

### (d) Internals: indices, not references

A compiled `Engine` is a plain value: nodes, roots, arguments and names
live in arrays, link to each other by `i64` index, and point into the
template copy by `Span { start, len }`. The partials' text follows the
page's in that copy, and a partial call holds its template's index. We chose this on purpose:

- **The Engine must be returnable and copyable.** A returned reference must
  point at something the caller supplied (§9.2), so an engine full of
  references into its own storage couldn't be returned from `get_engine`.
- **Self-relative references don't fit either.** Goose has relative
  references for exactly this kind of structure, but a value holding them
  can't be copied, and both ends of a link must sit in the same root (§3.9).
- **We prototyped the alternative**: a caller-owned arena linked with
  relative references. It worked, but it pushed lifetime bookkeeping onto
  every caller. Plain indices keep the API simple: compile, keep, copy, render.

Raw index arithmetic hurts readability, so it sits behind a few small names:
`NONE` for "no node", `innermost(open)` for the block being filled,
`arg_at(args, range, i)` for a call's arguments, and `Children` /
`append_child` for building document nodes. Rendering is a recursive walk over
those indices, with the context frames, `#each` loops, block parameters and
resolved helper arguments on grow-shrink stacks that each step pushes and
pops. A path that starts with a block parameter carries a `ParamRef`, found
while parsing: how many blocks with parameters up its declaring block is,
and which parameter. Rendering reads it straight off the stack.

## Layout

```
gooseneck.goose              the library's entry: its public interface, what a program calls as gooseneck::*
internal/tokenizer.goose     a template into Text and tag tokens, whitespace control, a tag's body into TagTokens
internal/paths.goose         ../, ./ and this, @root and the data variables, the checks on path segments
internal/template.goose      the parts of a compiled template: nodes, arguments, spans
internal/parser.goose        tokens into an Engine's nodes and arguments, checked
internal/compile.goose       a page and the partials it calls into one Engine; compile errors
internal/context.goose       a typed context converted into the JSON document rendering reads
internal/registration.goose  the checks before a render: duplicate helpers, unknown block helpers
internal/builtins.goose      the built-in helpers: lookup, if, unless, with, each
internal/render.goose        the walk over the nodes: paths, helper calls, block helpers, output
main.goose                   CLI: gooseneck render <template> <JSON file or folder>
examples/helpers/            helpers, block helpers, lookup, raw blocks, and their errors
examples/partials/           partials from files and from a list
examples/json/               typed and JSON contexts, engines as values, compile and context errors
examples/templates/          a tour of the template language, checked against handlebars.js
examples/http/               the engine inside an HTTP service
docs/internals.md            this file
test/                        test suites, fixtures and expected outputs
scripts/test.sh              runs the suites and the examples that have an expected.out, then scripts/test_cli.sh
scripts/test_cli.sh          builds the CLI and checks gooseneck render
.github/workflows/ci.yml     CI: tests and builds on pushes to main and on pull requests
benchmark/                   gooseneck vs Go vs Python (local, git-ignored)
```

The library sits at the root because Goose's `import name from "source";`
loads the entry `name.goose` from the package's directory, which for a git
source is the repository root; there is no way to point at a subdirectory
(Goose `docs/packages.md`, "Using a package"). The CLI is a program of its
own beside it, which imports the library as a module of its directory and
is never part of what a user's program imports.

The entry imports the files under `internal/` with `import internal.parser;`
and so on, which resolves from the package's root wherever the package is
used (Goose spec §11.1). They declare the same namespace, `gooseneck`, as
several files of one package may: Goose has no private declarations, so a
second namespace would hide nothing and only add `ns::` to every call
between the entry and the engine. `internal/` keeps them apart from the
interface; it is a convention, not a boundary.

## Tests and CI

All commands run from the repository root and expect `goose` on your `PATH`.
`scripts/test.sh` also accepts `GOOSE=/path/to/goose`.

**Tests.** Each `test/*.goose` program asserts its cases and prints their
names. `scripts/test.sh` diffs that list against `test/expected/<name>.out`:

```sh
scripts/test.sh
```

The suites cover the engine API, paths, values, rendering, JSON, whitespace
control, `#if` and `#unless`, `#each`, `lookup`, helpers, block helpers,
registered helpers and partials. Expected outputs come from handlebars.js
4.7.10, rendering the same template and data. Then it runs each
`examples/<name>/main.goose` that has an `expected.out` and diffs its
output, and `scripts/test_cli.sh` builds the CLI and checks
`gooseneck render`, the cases its header lists.

**CI.** `.github/workflows/ci.yml` runs on every push to `main` and on
every pull request, on Ubuntu: it installs the Goose v2026.3 release and
liburing (which goose-http needs on Linux), runs `scripts/test.sh` (the
suites, the examples and the CLI checks), and builds the CLI and `examples/http`. It
publishes nothing; there is no release or badge yet.

**Benchmark.** `benchmark/run.sh` compares gooseneck with Go (raymond) and
Python (pybars3) on the same templates, after checking that every
implementation renders byte-identical output. The folder is git-ignored:
it lives in the author's checkout only, with its own README.
