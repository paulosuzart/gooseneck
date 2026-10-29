# gooseneck

**Handlebars templates for Goose, compiled once and rendered fast.**

gooseneck is a Handlebars engine written in pure Goose. Compile a template
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
- **`{{#each path}}`** over arrays and objects, with `@index`, `@key`,
  `@first` and `@last`, and `@../index` (and so on) for an enclosing each.
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

### Not yet

- Partials, inline partials and decorators.
- `{{^}}`. Block parameters on `#if` and `#unless` are a compile error
  (handlebars.js accepts them and leaves them empty).
- A user block helper's block parameters are always its body's context and
  the item's `@key` (as `#each`'s): it can't pass values of its own, as
  handlebars.js's `blockParams` can. Its body's context is a node the
  arguments find (`this`, a param, an item), never a computed value.
- `@root`. Any `@name` other than `index`, `key`, `first` and `last` is a
  compile error.
- User helper answers that are objects or arrays. Answers are scalars for now
  (the built-in `lookup` is the exception).
- A user helper named `lookup` is never called: the built-in wins
  (handlebars.js lets `registerHelper` replace it). A `lookup` without exactly
  two params renders nothing (handlebars.js throws).
- `{{this}}` on an object or array writes nothing (handlebars.js writes
  `[object Object]` or a comma-joined list).
- A call no registered helper answers renders nothing and is falsy
  (handlebars.js throws `Missing helper`).
- Iterating a *typed struct* as an object, or looking up one of its fields
  with a dynamic key (`{{lookup person field}}`), only sees the fields the
  template names elsewhere: in a path, or as a literal lookup key such as
  `{{lookup person "city"}}` (see [typed contexts](#c-typed-structs-as-contexts)).
  JSON objects have all their members.

## Quick start

Import the `gooseneck` directory as a package (the path is relative to
your file), compile, render:

```goose
import handlebars from "../gooseneck";

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

### Compiling

| call | what it does |
|---|---|
| `get_engine(template)` | Compiles template text. |
| `load_engine(path)` | Reads and compiles a template file. Errors are prefixed with the path. |
| `get_engine(template, blocks)`, `load_engine(path, blocks)` | The same, with your block helpers: their names come from the registrations. |

Either way you get an `Engine`. When the template is malformed,
`engine.error` holds the message and every render returns it instead of
rendering. The `Engine` owns a copy of everything it needs, so the template
text may go away.

### Rendering

```goose
// Typed context: append to a buffer you own (returns how many document nodes the context took).
let out: u8[>..] = [];
gooseneck::render_into(engine, shelf, out);

// Typed context: get a fresh buffer and the error back.
let text, err = gooseneck::render(engine, shelf);

// JSON text, or a JSON file. Both return the error, empty on success.
let json_err = gooseneck::render_json(engine, "{\"owner\":\"Grace\",\"books\":[{\"title\":\"Emma\",\"year\":1815}]}", out);
let file_err = gooseneck::render_json_file(engine, "context.json", out);
```

### Helpers

Every render function also takes your helpers as one more, last argument.
That's one function taking a `gooseneck::HelperContext`, the call being
rendered, in which each helper is registered the way
[plod](https://github.com/kaitk/plod) registers routes:

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

fn helpers(cx) {
    gooseneck::helper(cx, "shout") { gooseneck::answer(cx, shout(cx)); };
    gooseneck::helper(cx, "older") {
        match gooseneck::param(cx, 0) {
            Int year => { gooseneck::answer(cx, json::Value.Bool { v: year.v < 1900 }); },
            _ => { gooseneck::answer(cx, json::Value.Bool { v: false }); },
        }
    };
}

let page = gooseneck::get_engine("{{#each books}}{{shout title}}{{#if (older year)}} (classic){{/if}}; {{/each}}");
gooseneck::render_into(page, shelf, out, helpers);   // FRANKENSTEIN (classic); DUNE;
```

`cx` is untyped, as in a plod handler (`fn handle(cx)`). The renderer
passes the context with `&` so that a block gets it by reference, not a
copy, and a function that types it as `gooseneck::HelperContext&` would
turn that `&` into a "redundant &" compiler warning.

`helper(cx, "shout") { ... }` runs its block when the template calls
`shout`, and the block answers with `answer(cx, value)`. Nothing is
returned: like a plod handler, the helper fills in the context it was
given. The first registration that answers wins. A block that doesn't
answer leaves the call to the registrations after it, and a call nobody
answers renders nothing.

The helpers can also be a block, which can keep state in your locals:

```goose
let counted = gooseneck::get_engine("{{owner}}{{#each books}} {{next}}{{/each}}");
var calls: i64 = 0;
gooseneck::render_into(counted, shelf, out) { cx =>
    gooseneck::helper(cx, "next") {
        calls += 1;
        gooseneck::answer(cx, json::Value.Int { v: calls });
    };
};   // Ada 1 2
```

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
fail at compile time. It comes from the registrations (see below).

`test/helpers.goose`, `test/registration.goose` and
`examples/http/helpers.goose` have more examples.

### Block helpers

Block helpers are a second function, passed after the helpers. It takes
the same context and registers each helper with `block_helper`. Give the
same function to `get_engine` (or `load_engine`) as well. The engine reads
the registered names from it, like handlebars.js's `knownHelpers`. So
`{{#typo}}` fails at compile time with `unknown block helper #typo`, and
the list can't drift from the helpers:

```goose
fn blocks<B>(cx) {
    gooseneck::block_helper(cx, "bold") {
        cx.out.append("<b>");
        B(gooseneck::this());               // the body, on the block's context
        cx.out.append("</b>");
    };
    gooseneck::block_helper(cx, "list") {
        cx.out.append("<ul>");
        for k in gooseneck::length(gooseneck::param(cx, 0)) {
            cx.out.append("<li>");
            B(gooseneck::element(0, k));    // the body on item k of param 0
            cx.out.append("</li>");
        }
        cx.out.append("</ul>");
    };
}

let engine = gooseneck::get_engine("{{#list books as |book i|}}{{#bold}}{{book.title}}{{/bold}} #{{i}}{{/list}}", blocks);
gooseneck::render_into(engine, shelf, out, helpers, blocks);
// <ul><li><b>Frankenstein</b> #0</li><li><b>Dune</b> #1</li></ul>
```

The matching registration's block runs, and that answers the call. To get
the names, `get_engine` calls the function once with `cx.listing` set.
Each `block_helper` then adds its name and skips its block, so nothing is
written and no body runs.

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

**CLI.** `main.goose` renders a template file with a JSON file as its context:

```sh
goose run main.goose -- test/fixtures/greeting.hbs test/fixtures/greeting.json
# hello John, 21! Springfield (John)

goose build main.goose -o build/gooseneck && build/gooseneck template.hbs context.json
```

**HTTP example.** `examples/http` serves a page rendered from
`hello.html.hbs` with [goose-http](https://github.com/kaitk/goose-http) and
[plod](https://github.com/kaitk/plod). Each worker compiles its `Engine` once
at startup. The page uses `#if`, `#with`, `#each`, and two registered helpers:
`ordinal` and `now`, the render time in Unix seconds.
Build it and run the binary:

```sh
goose build examples/http/main.goose -o examples/http/hello
examples/http/hello            # port 9997; pass another port as the first argument
curl http://localhost:9997/hello/Paulo
```

**Benchmark.** `benchmark/run.sh` compares gooseneck with Go (raymond) and
Python (pybars3) on the same templates. It first checks that every
implementation renders byte-identical output. See
[benchmark/README.md](benchmark/README.md) for what is measured, how to run
it and the latest results.

## Design

### (a) Helpers are one static function that fills in a context

Goose has no runtime function pointers: a function value is a compile-time
argument, and it can't be stored, returned or put in data (spec §7.6). So
gooseneck has no helper registry. You pass one function, and the renderer
calls it directly. That makes each helper call a direct, inlinable call,
specialized for your function, with nothing to register or look up at
runtime. A block can capture your locals, so per-render state needs no
extra API. Renders without helpers use a built-in function that answers
nothing.

The name match happens inside your function. `helper` and `block_helper`
give it the shape of plod's routes: one registration per helper, built from
trailing blocks that are inlined into your function. It still compiles to a
chain of name comparisons and direct calls.

The function takes one `HelperContext` and fills it in, the way a plod
handler takes `cx` and answers through it. It doesn't return a result, for
three reasons:

- **No `return` in your code.** A `return` in a trailing block returns from
  the function the block is written in (§7.6). A returned result would make
  every registration end in `return ...`, and a forgotten one would fall
  through. With `answer(cx, value)` the context records the answer, and
  later registrations see it and skip.
- **One place for the call.** The name, the arguments, the scratch text,
  the output and the answer all live in the context. The function has no
  separate `name` and `args` parameters that repeat what the context holds.
- **It survives the recursion.** Block helpers run inside the render's
  recursive walk, where references may only be passed down, never stored
  in a struct built there (§7.8). A per-call struct holding the name, or
  the name passed as a block parameter, is rejected there. So the
  renderer builds the context once, outside the walk, fills in each call's
  name and arguments, and passes it down by reference. A block helper gets
  a copy, because its body makes calls of its own.

Your function's `cx` is untyped, as in plod. The renderer passes the
context with `&` so that a block given as helpers gets it by reference
(a block's parameter is otherwise a copy, and its answer would be lost).
Against a parameter typed `HelperContext&`, that `&` is a "redundant &"
compiler warning (§4.1). Against an untyped one it isn't.

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
gooseneck/handlebars.goose   the engine: tokenizer, parser, conversion, renderer
main.goose                   CLI: template + JSON file -> stdout
examples/http/               the engine inside an HTTP service
test/                        test suites, fixtures and expected outputs
scripts/test.sh              runs the suites
benchmark/                   gooseneck vs Go vs Python
```
