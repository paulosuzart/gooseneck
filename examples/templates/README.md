# The template language

`main.goose` renders `tour.hbs` with `tour.json`, both beside it: paths,
escaping, bracketed segments, `#with`, `#each` over arrays and objects,
the data variables, `#if` with an else chain and `includeZero`, `#unless`,
block parameters, `lookup`, comments and whitespace control. Run it from
the repository root:

```sh
goose run examples/templates/main.goose
```

`expected.out` is what it prints, byte for byte what handlebars.js 4.7.10
renders for the same files; `scripts/test.sh` checks it.

## What it covers

- **Expressions**: `{{name}}`, dotted paths `{{address.city}}`, `this`, `.`,
  `./name`, `this.name`, and parent lookups with `../`. A bracketed segment
  is one literal name, as in handlebars.js: `{{x.[a b]}}`, `{{[a.b]}}`,
  `{{[this]}}` (a member named "this"), anywhere a path goes.
- **Escaping**: `{{x}}` is HTML-escaped exactly like handlebars.js
  (`&`, `<`, `>`, `"`, `'`, `` ` `` and `=`); `{{{x}}}` writes raw.
  `\{{x}}` writes the mustache itself, as text.
- **Comments**: `{{! ... }}` and `{{!-- ... --}}`.
- **Whitespace control**: `{{~x~}}` and standalone lines for block tags,
  `{{else}}`, partials and comments.
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
  `{{item.name}}` or `{{p.name}}` reach them from any depth below. They are
  tied to their block when the template compiles, not looked up by name.
- **`{{else}}`** on `#if`, `#unless`, `#with` and `#each`, and chains such as
  `{{#if a}}A{{else if b}}B{{else each items}}{{this}}{{else}}none{{/if}}`:
  any block helper after `else`, closed by the first block's tag.
- **`{{lookup target key}}`**: an array element by index or an object member by
  key, with the key coming from a path, a literal, `@index`/`@key` or a
  subexpression: `{{#each names}}{{this}} is {{lookup ../ages @index}}{{/each}}`.
  A lookup resolves to a context node, so `{{#with (lookup people 0)}}` and
  `{{#each (lookup person "tags")}}` step into what it finds.

Helpers, block helpers and raw blocks are in
[examples/helpers](../helpers/README.md), partials in
[examples/partials](../partials/README.md).

## Where it differs from handlebars.js

- `{{^}}` and inverse sections, `{{^name}}...{{/name}}`, are not supported;
  nor is `{{&name}}` (write `{{{name}}}`). Each is a compile error.
- Block parameters on `#if` and `#unless` are a compile error
  (handlebars.js accepts them, and throws when one is used).
- Any `@name` other than `@root`, `@index`, `@key`, `@first` and `@last`
  is a compile error, and so is `@../root`. In particular:
  - Private data passed with the render, as handlebars.js's `data` option
    (`template(context, { data: { user: ... } })`, read as `{{@user}}`). It
    is a second input, separate from the context, which no render function
    takes.
  - Helpers reading the data variables (handlebars.js's `options.data`): a
    helper gets `@index` and the others only as arguments,
    `{{helper @index}}`.
  - `@level`: there is no logger, and `{{log}}` renders nothing.
- `/` separates segments only after `this` and `..` (`{{this/name}}`,
  `{{../name}}`): `{{a/b}}`, `{{a/[x y]}}` and `{{@root/name}}` are compile
  errors (handlebars.js reads them as `a.b`, `a.[x y]` and `@root.name`).
- Inside a bracketed segment, `\\` is one backslash. handlebars.js's lexer
  reads `\\]` either way, so `{{[a\\]}}` may run on to a later `]` there.
- `{{this}}` on an object or array writes nothing (handlebars.js writes
  `[object Object]` or a comma-joined list), and `.length` is no field:
  `{{items.length}}` writes nothing.
- A `lookup` without exactly two params renders nothing (handlebars.js
  throws).
