# gooseneck over HTTP

A small web service that renders a Handlebars page with gooseneck. It's
built on [goose-http](https://github.com/kaitk/goose-http) and
[plod](https://github.com/kaitk/plod). `GET /hello/:name` answers an HTML
page rendered from `hello.html.hbs` with a typed context, `HelloPage`.

Each worker loads the template into a `gooseneck::Engine` once, at startup,
and keeps it in its state for the server's life. Every request only
renders.

## What it shows

- `{{name}}` and `{{../name}}`, HTML-escaped, so the name from the URL
  can't inject markup.
- `{{#if first}}`, a line only the worker's first request shows.
- `{{#with server}}` for nested fields.
- `{{#each links}}` over a list of structs.
- Two helpers, registered inline in a trailing block on `render_into`:
  - `{{ordinal requests}}` writes the worker's request count as "1st",
    "2nd", "3rd"...
  - `{{now}}` writes the time of the render in Unix seconds.

```goose
let nodes, err = gooseneck::render_into(page, context, out) { reg =>
    gooseneck::helper(reg, "ordinal") { cx => gooseneck::answer(cx, helpers::ordinal(cx)); };
    gooseneck::helper(reg, "now") { cx => gooseneck::answer(cx, helpers::now()); };
};
```

`reg` is where the helpers register, and `cx` is the call a helper
answers. Registering a name twice makes the render fail with
`duplicate helper "now"`; the example then logs
`cannot render: duplicate helper "now"` and answers 500
`{"error":"render_failed"}`.

The helpers' code is in `helpers.goose`, and the routes and the server are
in `main.goose`.

## Prerequisites

- Goose v2026.3, with `goose` on your `PATH`.
- `git` and a C compiler. The first build fetches goose-http v0.5.12 and
  plod v0.5.9 into `~/.goose/pkg` and builds goose-http's C shim. If a tool
  is missing, the error names it. To fetch ahead of time, for example to
  work offline later, run `goose fetch examples/http/main.goose`.

## Build and run

From the repository root:

```sh
goose build examples/http/main.goose -o examples/http/hello
examples/http/hello          # serves on port 9997
examples/http/hello 8080     # or on another port
```

Build the executable into `examples/http/`, as above: it reads
`hello.html.hbs` from its own directory. It prints
`Serving http://localhost:9997/hello/:name` once per worker (there are
two), and runs until Ctrl-C.

`goose run examples/http/main.goose` doesn't work for this example. The
JIT that `goose run` uses has no threads yet, and the server runs its
workers on threads.

## Try it

```sh
curl http://localhost:9997/hello/Paulo
```

The first request a worker serves gives:

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>Hello, Paulo</title>
</head>
<body>
  <h1>Hello, Paulo!</h1>
  <p>You are this worker's first visitor.</p>
  <p>Served to Paulo by gooseneck on goose-http + plod, the 1st request on this worker.</p>
  <p>Rendered at 1793240292 (Unix time).</p>
  <ul>
    <li><a href="https://handlebarsjs.com/guide/">Handlebars guide</a></li>
    <li><a href="https://github.com/kaitk/goose-http">goose-http</a></li>
    <li><a href="https://github.com/kaitk/plod">plod</a></li>
  </ul>
</body>
</html>
```

The timestamp is the current time. Each worker counts its own requests,
so with two workers the counts go "1st", "1st", "2nd", ... depending on
which worker takes each request. Only a worker's first request shows the
"first visitor" line.

A name longer than 20 bytes is refused with `400`
`{"error":"name_too_long"}`, and any other path gets `404`.
