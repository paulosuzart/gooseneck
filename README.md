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

## Install

Declare gooseneck as a package in your program's root file, from GitHub at
a tag or from a local checkout (a path relative to your file):

```goose
import gooseneck from "github.com/paulosuzart/gooseneck@<tag>";
// or, from a checkout: import gooseneck from "../gooseneck";
```

The name after `import` must be `gooseneck`: it names the package's entry
file, `gooseneck.goose`. Everything is in the namespace `gooseneck`, so
calls read `gooseneck::render(...)`.

## Quick start

```goose
struct Book { title: const u8[:], year: i64 }

struct Shelf {
    owner: const u8[:],
    books: const Book[:],
}

fn main() {
    let engine = gooseneck::get_engine("{{owner}}'s shelf:{{#each books}} {{@index}}. {{title}}{{#if (older year)}} (classic){{/if}}{{/each}}");
    if engine.error.len > 0 {
        print(engine.error);   // where and why, such as 1:1: unclosed #each
        return;
    }

    let books: Book[>..] = [Book { title: "Frankenstein", year: 1818 }, Book { title: "Dune", year: 1965 }];
    let shelf = Shelf { owner: "Ada", books: books };
    let out: u8[>..] = [];
    let nodes, err = gooseneck::render_into(engine, shelf, out) { reg =>
        gooseneck::helper(reg, "older") { cx =>
            match gooseneck::param(cx, 0) {
                Int year => { gooseneck::answer(cx, json::Value.Bool { v: year.v < 1900 }); },
                _ => {},
            }
        };
    };
    print(out);   // Ada's shelf: 0. Frankenstein (classic) 1. Dune
}
```

| call | what it does |
|---|---|
| `get_engine(template)` | Compiles template text. |
| `get_engine(template, partials)` | The same, with the partials it calls from a list of `gooseneck::Partial { name, text }`. |
| `load_engine(path)` | Reads and compiles a template file, and the partials it calls from the files next to it. |
| `render_into(engine, context, out)` | Renders a typed struct, appending to `out`. |
| `render(engine, context)` | The same, into a new buffer. |
| `render_json(engine, json, out)`, `render_json_file(engine, path, out)` | Renders a JSON context. |

Every render returns its error, empty when it rendered, and takes your
helpers, then your block helpers, as optional last arguments.

## CLI

```sh
goose build main.goose -o build/gooseneck
build/gooseneck render page.hbs context.json          # to stdout
build/gooseneck render page.html.hbs people/ -o out/  # one file per *.json
```

`main.goose`'s header has the details.

## What works today

- **Paths**: `{{name}}`, `{{a.b}}`, `this`, `./`, `../`, `@root`, and
  bracketed segments, `{{[odd key].[a.b]}}`.
- **Output**: HTML escaping as in handlebars.js, `{{{raw}}}`, `\{{literal}}`,
  comments, and whitespace control: `~` and standalone lines.
- **Built-in blocks**: `#if` (with `includeZero`), `#unless`, `#with`,
  `#each` over arrays and objects, `{{else}}` and chains such as
  `{{else if b}}`, and `lookup`.
- **Data variables and block parameters**: `@index`, `@key`, `@first`,
  `@last`, `@../index`, and `{{#each items as |item i|}}`.
- **Helpers**: with params, hash arguments and subexpressions,
  `{{#if (eq (lower a) b)}}`; a bare `{{name}}` tries a helper before the
  field.
- **Block helpers**: walk their body any number of times, on any context,
  or the inverse, with `@index` and block parameters; raw blocks,
  `{{{{raw}}}}...{{{{/raw}}}}`. A helper registered twice and an unknown
  block are render errors, found before anything is written.
- **Partials**: `{{> name}}`, with a context and hash arguments,
  recursive, indented when standalone, from a list or from the files next
  to the page, at most `engine.partial_depth` (100) calls deep.
- **Contexts**: a typed struct, converted at compile time with only the
  fields the template names, or JSON text and files.
- **Compile errors** with where and why: `3:5: unexpected /each`, and
  `page.hbs:3:5: ...` from a file, or from the partial at fault.
- **CLI**: `gooseneck render` with one JSON file or a folder of them.

## Not yet

- **Ahead-of-time compilation** (planned): generating a `.goose` function
  per template that writes straight into `out`, with no parsing at run
  time, taking its helpers as `render_into` does.
- **Private data** passed with the render, read as `{{@user}}`, and helpers
  reading the data variables. Any `@name` other than the ones above is a
  compile error, `@level` included, and `{{log}}` renders nothing.
- Partial blocks, `@partial-block`, inline partials, dynamic partials and
  decorators. The partial forms are compile errors saying so.
- `{{^}}`, `{{^name}}...{{/name}}` and `{{&name}}`.
- Helper answers that are objects or arrays: answers are scalars, except
  the built-in `lookup`'s.
- Block helpers passing block parameters of their own, or running their
  body on a computed value.
- A typed struct iterated as an object, or read with a dynamic `lookup`
  key, only shows the fields the template names.
- Where gooseneck differs from handlebars.js:
  - an unknown partial is a compile error, and a missing helper renders
    nothing and is falsy, where handlebars.js throws while rendering;
  - helper and block helper registrations are checked when a render runs,
    not when the template or your program compiles;
  - `lookup` can't be replaced, and with other than two params renders
    nothing;
  - `{{this}}` on an object or array, and `.length`, write nothing;
  - `/` separates segments only after `this` and `..`, and block
    parameters on `#if` and `#unless` are a compile error;
  - a partial's hash is not merged into its context, and partials stop at
    `partial_depth` instead of the JavaScript stack.

## Examples

Each runs with `goose run examples/<name>/main.goose`; `scripts/test.sh`
checks its output.

- [examples/templates](examples/templates/README.md): a tour of the template
  language, byte for byte what handlebars.js renders, and its differences.
- [examples/helpers](examples/helpers/README.md): helpers and block helpers,
  how to register them, `lookup`, raw blocks and their errors.
- [examples/partials](examples/partials/README.md): partials from files and
  from a list, scope, indentation and depth.
- [examples/json](examples/json/README.md): typed and JSON contexts, engines
  as values, and the error messages.
- [examples/http](examples/http/README.md): the engine inside an HTTP
  service (Linux; `goose build` only).

[docs/internals.md](docs/internals.md) explains the design, the source
layout, the tests and CI.

## License

MIT, see [LICENSE](LICENSE).
