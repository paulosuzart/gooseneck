# Partials

`main.goose` renders `views/page.hbs`, which calls `views/header.hbs`,
`views/layout/head.hbs` and `views/chapter.hbs`, a partial that calls
itself for nested sections. Then it shows hash and context arguments,
scope inside a partial, standalone indentation and the errors, with
partials from a list. Run it from the repository root:

```sh
goose run examples/partials/main.goose
```

`expected.out` is what it prints, the same as handlebars.js 4.7.10 renders;
`scripts/test.sh` checks it.

`{{> name}}` renders the partial `name` in place. They are found when the
template compiles, and the `Engine` holds them, so a render needs nothing
more:

```goose
let partials: gooseneck::Partial[2] = [
    gooseneck::Partial { name: "header", text: "<h1>{{title}}</h1>" },
    gooseneck::Partial { name: "tree", text: "{{name}}{{#if kids}}({{#each kids}}{{> tree}}{{/each}}){{/if}}" },
];
let engine = gooseneck::get_engine("{{> header}}\n{{> tree root}}", partials);
```

`load_engine("views/page.hbs")` reads `{{> header}}` from
`views/header.hbs` and `{{> layout/base}}` from `views/layout/base.hbs`,
always next to the page, also when a partial calls another. Only the
partials the page calls are read, and those they call in turn. A partial
nobody has is a compile error, `2:7: unknown partial "nope"`; an error in a
partial names it, `views/header.hbs:1:4: ...` (or `header:1:4: ...` from a
list).

As in handlebars.js:

- `{{> name}}` renders on the current context, `{{> name person}}` on
  `person`. A partial named like a path, `{{> layout/base}}`, may also be
  written `{{> "layout/base"}}` or `{{> [layout/base]}}`.
- Hash arguments, `{{> name title="Hi" who=person.name}}`, are resolved where
  the call is and come before the context's fields inside the partial.
- Inside a partial, `../` finds nothing past its context; `@root`, `@index`,
  `@key`, `@first` and `@last` still read; the caller's block parameters
  are not seen.
- A partial alone on its line indents every line it writes by that line's
  indentation, so nested layouts stay aligned.
- A partial may call itself. Calls nest at most `engine.partial_depth`
  deep, 100 by default; past that the render stops with
  `partial depth over 100: tree` (handlebars.js runs until the JavaScript
  stack overflows). Set the field on the engine to change it.

Not supported yet, each a compile error saying so: partial blocks
(`{{#> layout}}...{{/layout}}`, `{{> @partial-block}}`), inline partials
(`{{#*inline "name"}}`) and dynamic partials (`{{> (helper)}}`).

Where gooseneck differs from handlebars.js:

- An unknown partial is a compile error; handlebars.js throws when the
  render reaches it.
- Past `partial_depth` the render stops where it is, and the output keeps
  what was written up to there.
- A partial's hash is not merged into its context: paths read its keys,
  but `{{this}}` and `{{#each this}}` don't see them.
