// Partials: a page and the partials it calls read from the files next to
// it, a recursive partial, hash arguments, a context argument, partials
// from a list, standalone indentation, scope inside a partial, and the
// errors. See README.md beside this file. Run it from the repository root:
//
//   goose run examples/partials/main.goose
//
// scripts/test.sh runs it and compares its output with expected.out.
import gooseneck from "../..";

struct Author { name: const u8[:] }

struct Section { title: const u8[:] }

struct Chapter { title: const u8[:], sections: const Section[:] }

struct Book {
    book: const u8[:],
    author: Author,
    chapters: const Chapter[:],
}

fn section(title: const u8[:]) {
    print("== ", title);
}

// Renders template, with partials, on the JSON context, and prints it.
fn show(template: const u8[:], partials: const gooseneck::Partial[:], context: const u8[:]) {
    let engine = gooseneck::get_engine(template, partials);
    let out: u8[>..] = [];
    let err = gooseneck::render_json(engine, context, out);
    print(out, err);
}

fn main() {
    section("files: views/page.hbs and the partials it calls, a typed context");
    // resource_dir() is this file's directory under goose run.
    let page = gooseneck::load_engine(str(resource_dir(), "views/page.hbs"));
    if page.error.len > 0 { print(page.error); return; }
    let none: Section[>..] = [];
    let parts: Section[>..] = [Section { title: "Walton's letters" }, Section { title: "Victor's tale" }];
    let chapters: Chapter[>..] = [
        Chapter { title: "Letters", sections: parts },
        Chapter { title: "The creature", sections: none },
    ];
    let book = Book { book: "Frankenstein", author: Author { name: "Mary Shelley" }, chapters: chapters };
    let text, err = gooseneck::render(page, book);
    print(text, err);

    // The rest use partials from a list.
    let partials: gooseneck::Partial[4] = [
        gooseneck::Partial { name: "card", text: "[{{label}}: {{name}}{{#if note}}, {{note}}{{/if}}]" },
        gooseneck::Partial { name: "scope", text: "{{name}}|{{../name}}|{{@root.name}}|{{item}}" },
        gooseneck::Partial { name: "lines", text: "one\ntwo\n" },
        gooseneck::Partial { name: "loop", text: "{{> loop}}" },
    ];
    let context = "{\"name\": \"Ada\", \"pet\": {\"name\": \"Rex\"}, \"list\": [1, 2]}";

    section("hash arguments and a context argument");
    show("{{> card label=\"me\"}} {{> card pet label=\"pet\" note=name}}", partials, context);

    section("scope: ../ stops at the partial, @root reads, block params do not pass");
    show("{{#with pet}}{{> scope}}{{/with}} {{#each list as |item|}}<{{> scope}}>{{/each}}", partials, context);

    section("a partial alone on its line indents what it writes");
    show("<pre>\n    {{> lines}}\n</pre>", partials, context);

    section("errors");
    show("ok\n  {{> nope}}", partials, context);
    show("{{#> card}}x{{/card}}", partials, context);
    show("{{> loop}}", partials, context);
    var shallow = gooseneck::get_engine("{{> loop}}", partials);
    shallow.partial_depth = 5;
    let shallow_out: u8[>..] = [];
    print(gooseneck::render_json(shallow, "{}", shallow_out));
    // From a file, the error names the partial's file: here
    // views/typo.hbs calls a partial that has no file.
    let typo = gooseneck::load_engine(str(resource_dir(), "views/typo.hbs"));
    print(typo.error[resource_dir().len..]);
}
