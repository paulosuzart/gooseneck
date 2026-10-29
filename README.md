# gooseneck

**Handlebars _inspired_ templates for Goose, compiled once and rendered fast.**

`gooseneck` is a Handlebars engine written in pure Goose. Compile a template
into an `Engine`, keep it for as long as you like (a global, a struct,
an HTTP worker's state), and render it with a typed Goose struct or with
JSON. Output matches [handlebars.js](https://handlebarsjs.com) 4.7.10 for
everything it supports: the test suites check it case by case.

```handlebars
<ul>
  {{#each books}}
  <li>{{@index}}. {{shout title}}{{#if (older year)}} (classic){{/if}}</li>
  {{else}}
  <li>Nothing on the shelf yet.</li>
  {{/each}}
</ul>
```

## Quick start

Declare gooseneck as a package in your program's root file, from GitHub at
a tag or from a local checkout (a path relative to your file), then
compile and render:

```goose
import gooseneck from "github.com/paulosuzart/gooseneck@<tag>";
// or, from a checkout: import gooseneck from "../gooseneck";

struct Book { title: const u8[:], year: i64 }

struct Shelf {
    owner: const u8[:],
    books: const Book[:],
}

fn main() {
    let engine = gooseneck::get_engine("{{owner}}'s shelf:{{#each books}} {{@index}}. {{title}} ({{year}}){{/each}}");
    if engine.error.len > 0 {
        print(engine.error);
        return;
    }

    let books: Book[>..] = [Book { title: "Frankenstein", year: 1818 }, Book { title: "Dune", year: 1965 }];
    let shelf = Shelf { owner: "Ada", books: books };
    let text, err = gooseneck::render(engine, shelf);
    print(text);   // Ada's shelf: 0. Frankenstein (1818) 1. Dune (1965)
}
```

The name after `import` must be `gooseneck`: it names the package's entry
file, `gooseneck.goose` at the root of this repository. Everything in it is
in the namespace `gooseneck`, so calls read `gooseneck::render(...)`. (The
import name does not rename a namespace; it only picks the package.)

### Preparing the template

| call | what it does |
|---|---|
| `get_engine(template)` | Compiles template text. |
| `load_engine(path)` | Reads and compiles a template file. Errors are prefixed with the path. |

Either way you get an `Engine`. When the template is malformed,
`engine.error` holds the message and every render returns it instead of
rendering. The `Engine` owns a copy of everything it needs, so the template
text may go away. Helpers and block helpers aren't given here but to each
render (see [Helpers](#helpers)): an `Engine` can't hold a function.

### Rendering

```goose
// Typed context: append to a buffer you own (returns how many document nodes the context took, and the error).
let out: u8[>..] = [];
let nodes, err = gooseneck::render_into(engine, shelf, out);

// Typed context: get a fresh buffer and the error back.
let text, err = gooseneck::render(engine, shelf);

// JSON text, or a JSON file. Both return the error, empty on success.
let json_err = gooseneck::render_json(engine, "{\"owner\":\"Grace\",\"books\":[{\"title\":\"Emma\",\"year\":1815}]}", out);
let file_err = gooseneck::render_json_file(engine, "context.json", out);
```

### Helpers

Every render function also takes your helpers as one more, last argument.
The simplest way is a trailing block on the render call, in which each
helper is registered the way [plod](https://github.com/kaitk/plod)
registers routes:

```goose
fn shout(cx: gooseneck::HelperContext&) -> json::Value {
    match gooseneck::param(cx, 0) {
        Str s => {
            let start = cx.text.len;
            for c in s.s {
                if c >= 'a' && c <= 'z' { cx.text.push(c - 32); } else { cx.text.push(c); }
            }
            return json::Value.Str { s: cx.text[start..] };
        },
        _ => { return json::Value.Null; },
    }
}

fn older(cx: gooseneck::HelperContext&) -> json::Value {
    match gooseneck::param(cx, 0) {
        Int year => { return json::Value.Bool { v: year.v < 1900 }; },
        _ => { return json::Value.Bool { v: false }; },
    }
}

let page = gooseneck::get_engine("{{#each books}}{{shout title}}{{#if (older year)}} (classic){{/if}}; {{/each}}");
gooseneck::render_into(page, shelf, out) { reg =>
    gooseneck::helper(reg, "shout") { cx => gooseneck::answer(cx, shout(cx)); };
    gooseneck::helper(reg, "older") { cx => gooseneck::answer(cx, older(cx)); };
};   // FRANKENSTEIN (classic); DUNE;
```

`reg` is what the helpers register on, a `gooseneck::Registry`, and `cx`
is the call being rendered, a `gooseneck::HelperContext`.
`helper(reg, "shout") { cx => ... }` runs its block when the template calls
`shout`, and the block answers with `answer(cx, value)`. Nothing is
returned: like a plod handler, the helper fills in the context it was
given. A call nobody answers renders nothing.

Each name is registered once. A name registered twice is an error, not a
silent "first one wins": before it renders anything, each render runs your
registrations once to list their names, and a duplicate makes the render
return `duplicate helper "shout"` and write nothing. Helpers given inline
are only seen by the render, so that is where the check runs, on every
render (one extra call of your function), and the first render shows it.

The block can keep state in your locals:

```goose
let counted = gooseneck::get_engine("{{owner}}{{#each books}} {{next}}{{/each}}");
var calls: i64 = 0;
gooseneck::render_into(counted, shelf, out) { reg =>
    gooseneck::helper(reg, "next") { cx =>
        calls += 1;
        gooseneck::answer(cx, json::Value.Int { v: calls });
    };
};   // Ada 1 2
```

To share the same helpers between several render calls, put the
registrations in a named function and pass it instead of the block:

```goose
fn book_helpers(reg) {
    gooseneck::helper(reg, "shout") { cx => gooseneck::answer(cx, shout(cx)); };
    gooseneck::helper(reg, "older") { cx => gooseneck::answer(cx, older(cx)); };
}

gooseneck::render_into(page, shelf, out, book_helpers);
```

Leave its `reg` untyped, as in a plod handler (`fn handle(cx)`). The
renderer passes the registry with `&` so that a block gets it by reference,
not a copy, and a function that types it as `gooseneck::Registry&`
would turn that `&` into a "redundant &" compiler warning. Functions that
only take the context from a registration, like `shout`, can type it.

The context holds everything about the call. `cx.name` is the helper being
called. `param(cx, i)` (Null past the end), `param_count(cx)` and
`hash_arg(cx, "key")` (Null when absent) read the resolved arguments. When
a helper makes new text, it appends it to `cx.text`, a buffer that lives
until the render ends, and answers with a slice of it.

**Helper or field?** As in handlebars.js, a bare `{{name}}` (or
`{{{name}}}`) asks your helpers first. If one answers, its value is
written, even when it is Null. Otherwise `name` is looked up as a field.
To force the field, write `{{./name}}` or `{{this.name}}`. Dotted paths
(`{{user.name}}`), `../` paths, data variables, block parameters and every
helper *argument* are always paths.

The cost is one call to your function, with its name comparisons, per bare
mustache rendered, and only when you pass helpers. The render functions
without helpers pass a built-in function that answers nothing. Nothing
else changes.

Expression helpers have no list of names. handlebars.js also decides a
bare name at runtime by default (its `knownHelpers` list is an
optimization). Block helpers do have one, because an unknown block has to
fail. It comes from the registrations, and the render checks it before
writing anything (see below).

`test/helpers.goose`, `test/registration.goose` and `examples/http` have
more examples.

### Block helpers

Block helpers are a second function, passed after the helpers. It takes
the same registry and registers each helper with `block_helper`. It has to
be a named function: it's generic over its body `B`, which a block can't
be. A render call takes one trailing block, the last argument, so with
block helpers the expression helpers are a named function too. The render
reads the registered names from it, like handlebars.js's `knownHelpers`.
So `{{#typo}}` makes the render fail with `unknown block helper "typo"`
before it writes anything, and the list can't drift from the helpers:

```goose
fn blocks<B>(reg) {
    gooseneck::block_helper(reg, "bold") { cx =>
        cx.out.append("<b>");
        B(gooseneck::this());               // the body, on the block's context
        cx.out.append("</b>");
    };
    gooseneck::block_helper(reg, "list") { cx =>
        cx.out.append("<ul>");
        for k in gooseneck::length(gooseneck::param(cx, 0)) {
            cx.out.append("<li>");
            B(gooseneck::element(0, k));    // the body on item k of param 0
            cx.out.append("</li>");
        }
        cx.out.append("</ul>");
    };
}

let engine = gooseneck::get_engine("{{#list books as |book i|}}{{#bold}}{{book.title}}{{/bold}} #{{i}}{{/list}}");
gooseneck::render_into(engine, shelf, out, book_helpers, blocks);
// <ul><li><b>Frankenstein</b> #0</li><li><b>Dune</b> #1</li></ul>
```

The matching registration's block runs, and that answers the call. To get
the names, the render calls the function once on a listing registry.
Each `block_helper` then adds its name and skips its block, so nothing is
written and no body runs.

Each block helper name is registered once, too: a name registered twice
makes the render fail with `duplicate block helper "bold"`, as for
helpers. A name may be both a helper and a block helper: `{{bold}}` and
`{{#bold}}...{{/bold}}` can't be confused.

The helper writes straight into `cx.out`, the render's own buffer, and calls
`B`, its body, as often as it likes. What it passes says which context the
body runs on:

| call | the body runs on |
|---|---|
| `B(this())` | the context the block was written in |
| `B(param(i))` | what param `i` finds (a path or a `lookup`) |
| `B(element(i, k))` | item `k` of the array or object param `i` finds, with `@index`, `@key`, `@first`, `@last` |
| `B(inverse(...))` | the part after `{{else}}`, on any of the above |

`B` returns whether that context was there (a missing param, a scalar or
an item past the end walk nothing). Arguments and hash come through `cx`
as for helpers, and `append_escaped(out, text)` writes text escaped as
`{{value}}` would. Block parameters (`as |item key|`) work on any block
helper and name the body's context and the item's `@key`.

The body runs inside the render's recursive walk, so Goose's recursion
rules apply to the helper (spec §7.8): no growable local, such as a
`u8[>..]` buffer, may be in scope where it calls `B`. Build text in `cx.out`
or `cx.text` instead. Each `B` call finds its context again from the
arguments, so `element(i, k)` steps over `k` items: an iterator over `n`
items costs about n²/2 steps, which only matters for long lists.
`test/blocks.goose` has a helper of every kind.

## Running things

All commands run from the repository root and expect `goose` on your `PATH`.
`scripts/test.sh` and `benchmark/run.sh` also accept `GOOSE=/path/to/goose`.

**Tests.** Each `test/*.goose` program asserts its cases and prints their
names. `scripts/test.sh` diffs that list against `test/expected/<name>.out`:

```sh
scripts/test.sh
```

The suites cover the engine API, paths, values, rendering, JSON, whitespace
control, `#if` and `#unless`, `#each`, `lookup`, helpers, block helpers,
and registered helpers. Expected outputs
come from handlebars.js 4.7.10, rendering the same template and data.
Then `scripts/test_cli.sh` builds the CLI and checks it (see below).

**CLI.** `main.goose` is the `gooseneck` command. `gooseneck render`
renders a template file with a JSON file as its context, or with every
JSON file in a folder:

```sh
goose build main.goose -o build/gooseneck      # build/ is ignored by git

build/gooseneck render test/fixtures/greeting.hbs test/fixtures/greeting.json
# hello John, 21! Springfield (John)

build/gooseneck render test/fixtures/cli/card.html.hbs test/fixtures/cli/people -o build/out
# wrote build/out/ana.html
# wrote build/out/bo.html
# gooseneck: test/fixtures/cli/people/broken.json: json: expected a key at byte 15
```

- **One JSON file**: the result goes to stdout, followed by a newline.
- **A folder**: the template is compiled once and rendered with each
  `*.json` file in the folder (not its subfolders), in name order. Each
  result is written as it is to its own file, named after the JSON file
  with the template's extension once a trailing `.hbs` is dropped:
  `page.html.hbs` and `ana.json` give `ana.html`; a template named only
  `x.hbs` gives `ana.out`. The files go into `-o <dir>` (created if
  missing) or, without `-o`, beside the JSON files. Each written file is
  reported on stderr as `wrote <path>`.
- **Errors**: a template error stops everything. In a folder, a file that
  fails is reported on stderr with its path and the others still render.
  The exit code is 0 when everything rendered, 1 when anything failed, and
  2 for wrong arguments, which print the usage.

`goose run main.goose -- render <template> <json>` works too, with the
compiler's progress on stderr. `scripts/test_cli.sh`, which
`scripts/test.sh` runs, builds the CLI and checks these cases.

**HTTP example.** `examples/http` serves a page rendered from
`hello.html.hbs` with [goose-http](https://github.com/kaitk/goose-http) and
[plod](https://github.com/kaitk/plod). Each worker compiles its `Engine` once
at startup. The page uses `#if`, `#with`, `#each`, and two helpers registered
inline on `render_into`: `ordinal` and `now`, the render time in Unix
seconds. Build it and run the binary (`goose run` can't run it, since the
JIT has no threads); [examples/http/README.md](examples/http/README.md) has
the details:

```sh
goose build examples/http/main.goose -o examples/http/hello
examples/http/hello            # port 9997; pass another port as the first argument
curl http://localhost:9997/hello/Paulo
```

**CI.** `.github/workflows/ci.yml` runs on every push to `main` and on
every pull request, on Ubuntu: it installs the Goose v2026.3 release and
liburing (which goose-http needs on Linux), runs `scripts/test.sh` (the
suites and the CLI checks), and builds the CLI and `examples/http`. It
publishes nothing; there is no release or badge yet.

**Benchmark.** `benchmark/run.sh` compares gooseneck with Go (raymond) and
Python (pybars3) on the same templates. It first checks that every
implementation renders byte-identical output. See
[benchmark/README.md](benchmark/README.md) for what is measured, how to run
it and the latest results.


## What works today

- **Expressions**: `{{name}}`, dotted paths `{{address.city}}`, `this`, `.`,
  `./name`, `this.name`, and parent lookups with `../`.
- **Escaping**: `{{x}}` is HTML-escaped exactly like handlebars.js
  (`&`, `<`, `>`, `"`, `'`, `` ` `` and `=`); `{{{x}}}` writes raw.
  `\{{x}}` writes the mustache itself, as text.
- **Comments**: `{{! ... }}` and `{{!-- ... --}}`.
- **Whitespace control**: `{{~x~}}` and standalone lines for block tags,
  `{{else}}` and comments.
- **`{{#with path}}`** to step into an object.
- **`{{#if value}}`** with handlebars.js truthiness and `includeZero=true`,
  and its inverse **`{{#unless value}}`**.
- **`{{#each path}}`** over arrays and objects.
- **Data variables**: `@index`, `@key`, `@first` and `@last` of the
  innermost `#each` (or of a user block helper's item), `@../index` (and so
  on) for an enclosing each, and `@root`, the context the render began
  with: `{{@root.title}}` from any depth, `{{#with @root}}`,
  `{{#each @root.items}}`, or as a helper or `lookup` argument. Fields of a
  typed struct named only after `@root.` are converted too.
- **Block parameters**: `{{#each items as |item i|}}` names the item and its
  index (its key, for an object), and `{{#with person as |p|}}` the object, so
  `{{item.name}}` or `{{g.name}}` reach them from any depth below. They are
  tied to their block when the template compiles, not looked up by name.
- **`{{else}}`** on `#if`, `#unless`, `#with` and `#each`, and chains such as
  `{{#if a}}A{{else if b}}B{{else each items}}{{this}}{{else}}none{{/if}}`:
  any block helper after `else`, closed by the first block's tag.
- **`{{lookup target key}}`**: an array element by index or an object member by
  key, with the key coming from a path, a literal, `@index`/`@key` or a
  subexpression: `{{#each names}}{{this}} is {{lookup ../ages @index}}{{/each}}`.
  A lookup resolves to a context node, so `{{#with (lookup people 0)}}` and
  `{{#each (lookup person "tags")}}` step into what it finds.
- **User helpers**: `{{helper arg key=value}}`, `{{{helper ...}}}`,
  zero-argument `{{helper}}`, and nested subexpressions such as
  `{{#if (eq (lower a) b)}}`. A bare `{{name}}` calls a helper of that name
  before it looks up the field, as in handlebars.js.
- **User block helpers**: `{{#list items}}...{{else}}...{{/list}}` that write
  around their body, walk it any number of times on any context, iterate
  with `@index`/`@key`/`@first`/`@last` and block parameters, or walk the
  inverse instead.
- **Raw blocks**: `{{{{raw}}}} {{not parsed}} {{{{/raw}}}}` hands a block
  helper its content as plain text.
- **Two kinds of context**: a typed Goose struct (converted through
  compile-time reflection) or JSON text and files.
- **Clear compile errors**: `unexpected /with`, `unclosed #each`,
  `unclosed subexpression: (eq a b`, `#if takes exactly one argument`, and more.
  Render errors for the helpers, before anything is written:
  `unknown block helper "typo"`, `duplicate helper "now"`.

### Not yet

- Partials, inline partials and decorators.
- `{{^}}`. Block parameters on `#if` and `#unless` are a compile error
  (handlebars.js accepts them and leaves them empty).
- A user block helper's block parameters are always its body's context and
  the item's `@key` (as `#each`'s): it can't pass values of its own, as
  handlebars.js's `blockParams` can. Its body's context is a node the
  arguments find (`this`, a param, an item), never a computed value.
- Any other `@name` is a compile error, and so is `@../root`. In
  particular:
  - Private data passed with the render, as handlebars.js's `data` option
    (`template(context, { data: { user: ... } })`, read as `{{@user}}`). It
    is a second input, separate from the context, which no render function
    takes.
  - Helpers reading the data variables (handlebars.js's `options.data`): a
    helper gets `@index` and the others only as arguments,
    `{{helper @index}}`.
  - `@level`: there is no logger and no `{{log}}` helper.
- `{{@root/name}}`: only `.` separates the segments after `@root`
  (handlebars.js accepts `/` too).
- User helper answers that are objects or arrays. Answers are scalars for now
  (the built-in `lookup` is the exception).
- A user helper named `lookup` is never called: the built-in wins
  (handlebars.js lets `registerHelper` replace it). A `lookup` without exactly
  two params renders nothing (handlebars.js throws).
- A bracketed segment with a space or a dot, such as `{{a.[x y]}}` or
  `{{a.[x.y]}}`, compiles but finds nothing (handlebars.js reads it as one
  literal key).
- `{{this}}` on an object or array writes nothing (handlebars.js writes
  `[object Object]` or a comma-joined list).
- A call no registered helper answers renders nothing and is falsy
  (handlebars.js throws `Missing helper`).
- A helper registered twice, or a block no block helper registers, is only
  found when a render runs, not when the template compiles or when Goose
  compiles your code (see [Design (a)](#a-helpers-are-one-static-function-that-fills-in-a-context)).
- Iterating a *typed struct* as an object, or looking up one of its fields
  with a dynamic key (`{{lookup person field}}`), only sees the fields the
  template names elsewhere: in a path, or as a literal lookup key such as
  `{{lookup person "city"}}` (see [typed contexts](#c-typed-structs-as-contexts)).
  JSON objects have all their members.

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
template copy by `Span { start, len }`. We chose this on purpose:

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
`NONE` for "no node", `_innermost(open)` for the block being filled,
`_arg_at(args, range, i)` for a call's arguments, and `Children` /
`_append_child` for building document nodes. Rendering is a recursive walk over
those indices, with the context frames, `#each` loops, block parameters and
resolved helper arguments on grow-shrink stacks that each step pushes and
pops. A path that starts with a block parameter carries a `ParamRef`, found
while parsing: how many blocks with parameters up its declaring block is,
and which parameter. Rendering reads it straight off the stack.

## Layout

```
gooseneck.goose              the library, the package's entry: tokenizer, tag lexer, parser, conversion, renderer
main.goose                   CLI: gooseneck render <template> <JSON file or folder>
examples/http/               the engine inside an HTTP service
test/                        test suites, fixtures and expected outputs
scripts/test.sh              runs the suites, then scripts/test_cli.sh
scripts/test_cli.sh          builds the CLI and checks gooseneck render
.github/workflows/ci.yml     CI: tests and builds on pushes to main and on pull requests
benchmark/                   gooseneck vs Go vs Python
```

The library sits at the root because Goose's `import name from "source";`
loads the entry `name.goose` from the package's directory, which for a git
source is the repository root; there is no way to point at a subdirectory
(Goose `docs/packages.md`, "Using a package"). The CLI is a program of its
own beside it, which imports the library as a module of its directory and
is never part of what a user's program imports.
