# Contexts and engines

`main.goose` renders one `Engine` with a typed struct, JSON text and a JSON
file, keeps engines in a struct and copies one, and prints the errors a
template or a context can give. Run it from the repository root:

```sh
goose run examples/json/main.goose
```

`expected.out` is what it prints; `scripts/test.sh` checks it.

## Rendering

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

A typed struct is converted through compile-time reflection, and only the
fields the template names are converted (see
[docs/internals.md](../../docs/internals.md#c-typed-structs-as-contexts)).
A JSON context has all its members.

## Engines

The `Engine` owns a copy of everything it needs, so the template text may
go away. Keep it for as long as you like: a global, a struct, an HTTP
worker's state. It is a plain value, so `copy(engine)` copies it.

## Errors

When the template is malformed, `engine.error` holds the message and every
render returns it instead of rendering. The message says where and why, as
a compiler does: `3:5: unexpected /each` is line 3, column 5 (in bytes,
both from 1), and `load_engine` puts the path first,
`page.hbs:3:5: unexpected /each`. The place is the tag's `{{`, or the
argument at fault inside it. The compile stops at the first error. A tag
closed wrong fails at the stray brace, as in handlebars.js:
`{{name} text` gives `1:7: expected }}: {{name}`.

A context that can't be read is the render's error too: json::parse's
message, such as `json: expected a value at byte 9`, or
`cannot read JSON <path>`. On those errors, and on the helper errors (see
[examples/helpers](../helpers/README.md)), nothing is written.
