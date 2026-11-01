# Helpers and block helpers

`main.goose` renders a shelf of books with helpers registered in a trailing
block and in a named function, hash arguments, subexpressions, state kept
in a local, a helper that shadows a field, `lookup`, block helpers with
block parameters and an inverse, a raw block, and the errors a render gives before it
writes anything. Run it from the repository root:

```sh
goose run examples/helpers/main.goose
```

`expected.out` is what it prints; `scripts/test.sh` checks it.

## Helpers

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

`main.goose` here runs every snippet on this page; `test/helpers.goose`,
`test/registration.goose` and `examples/http` have more.

## Lookup and subexpressions

`{{lookup target key}}` is built in: an array element by index or an
object member by key, with the key from a path, a literal, `@index`/`@key`
or a subexpression: `{{#each names}}{{this}} is {{lookup ../ages @index}}{{/each}}`.
A lookup resolves to a context node, so `{{#with (lookup people 0)}}` and
`{{#each (lookup person "tags")}}` step into what it finds.
Subexpressions nest: `{{#if (eq (lower a) b)}}`.

## Block helpers

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

**Raw blocks.** `{{{{name}}}} {{not parsed}} {{{{/name}}}}` hands the block
helper `name` its content as plain text: `B(this())` writes it as it is.
