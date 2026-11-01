// Contexts and engines: the same Engine rendered with a typed struct, with
// JSON text and with a JSON file; an Engine kept in a struct and copied;
// and the errors, from compiling a template and from reading a context.
// See README.md beside this file. Run it from the repository root:
//
//   goose run examples/json/main.goose
//
// scripts/test.sh runs it and compares its output with expected.out.
import gooseneck from "../..";

struct City { name: const u8[:] }

struct Address { street: const u8[:], city: City }

// A typed context: only the fields the template names are converted.
struct Person {
    name: const u8[:],
    age: i64,
    address: Address,
    notes: const u8[:],
}

// What a service's state might look like: engines compiled once at
// startup, kept for as long as the state lives.
struct Service {
    card: gooseneck::Engine,
    banner: gooseneck::Engine,
}

fn section(title: const u8[:]) {
    print("== ", title);
}

fn main() {
    section("one engine, three kinds of context");
    // embed_file reads the template when this program is compiled.
    let card = gooseneck::get_engine(embed_file("card.hbs"));
    let john = Person { name: "John", age: 21, address: Address { street: "Main St", city: City { name: "Springfield" } }, notes: "not converted" };
    // render: a fresh buffer and the error.
    let text, err = gooseneck::render(card, john);
    write_stdout(text);
    // render_into appends to a buffer you own, and says how many document
    // nodes the typed context took: the fields the template reads.
    let out: u8[>..] = [];
    let nodes, into_err = gooseneck::render_into(card, john, out);
    print("render_into took ", nodes, " nodes");
    out.clear();
    gooseneck::render_json(card, "{\"name\": \"Mary\", \"age\": 34, \"address\": {\"city\": {\"name\": \"Shelbyville\"}}}", out);
    gooseneck::render_json_file(card, str(resource_dir(), "ana.json"), out);
    write_stdout(out);

    section("engines in a struct, copied, and owning their text");
    var template: u8[>..] = [];
    template.append("[{{name}}]");
    let service = Service { card: copy(card), banner: gooseneck::get_engine(template) };
    template.clear();
    let copied = copy(service.banner);
    let banner, banner_err = gooseneck::render(copied, john);
    print(banner);

    section("compile errors: line:column: why");
    let bad: const u8[:][6] = [
        "{{#with a}}\n  {{name}}\n{{/each}}",
        "{{#each items}}",
        "{{#if (eq a b}}{{/if}}",
        "{{#if a b}}{{/if}}",
        "{{name!}}",
        "{{name} text",
    ];
    for template in bad {
        print(gooseneck::get_engine(template).error);
    }
    let broken = gooseneck::get_engine("{{/if}}");
    let failed, failed_err = gooseneck::render(broken, john);
    print("a render of a broken engine returns its error: ", failed_err);

    section("context errors");
    print(gooseneck::render_json(card, "{\"name\": }", out));
    print(gooseneck::render_json_file(card, "no/such/file.json", out));
}
