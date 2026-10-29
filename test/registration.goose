// How registrations dispatch: helper(reg, name) and block_helper(reg, name),
// a block that does not answer leaves a bare name to the field, names match
// whole, a helper beats a field of its name, a name may be both a helper
// and a block helper, get_engine and load_engine take the block helper
// names from the registrations, and a name registered twice is an error:
// the engine's for block helpers given to get_engine or load_engine, the
// render's otherwise. Each case asserts, then prints its name;
// scripts/test.sh compares that list with test/expected/registration.out.
import handlebars from "../gooseneck";

struct Item { name: const u8[:] }

struct Page {
    name: const u8[:],
    title: const u8[:],
    flag: bool,
    items: const Item[:],
}

// The same data as Page, as JSON.
const CONTEXT_JSON: const u8[:] = "{\"name\":\"ada <3\",\"title\":\"field\",\"flag\":true,\"items\":[{\"name\":\"pen\"},{\"name\":\"ink\"}]}";

// The first param in upper case, made in cx.text; anything but a string
// as it is.
fn loud(cx: gooseneck::HelperContext&) -> json::Value {
    let value = gooseneck::param(cx, 0);
    match value {
        Str t => {
            let start = cx.text.len;
            for c in t.s {
                if c >= 'a' && c <= 'z' { cx.text.push(c - 32); } else { cx.text.push(c); }
            }
            return json::Value.Str { s: cx.text[start..] };
        },
        _ => { return value; },
    }
}

// Whether a value is a string.
fn is_string(value: json::Value) -> bool {
    match value {
        Str => { return true; },
        _ => { return false; },
    }
}

// Whether a value is the boolean true.
fn is_true(value: json::Value) -> bool {
    match value {
        Bool b => { return b.v; },
        _ => { return false; },
    }
}

fn helpers(reg) {
    gooseneck::helper(reg, "loud") { cx => gooseneck::answer(cx, loud(cx)); };
    gooseneck::helper(reg, "count") { cx => gooseneck::answer(cx, json::Value.Int { v: gooseneck::param_count(cx) }); };
    // A helper with the name of a field wins over it, as in handlebars.js.
    gooseneck::helper(reg, "title") { cx => gooseneck::answer(cx, json::Value.Str { s: "helper" }); };
    // kind answers strings, and leaves anything else unanswered.
    gooseneck::helper(reg, "kind") { cx =>
        if is_string(gooseneck::param(cx, 0)) { gooseneck::answer(cx, json::Value.Str { s: "string" }); }
    };
    // flag answers only a call with arguments: a bare {{flag}} is the field.
    gooseneck::helper(reg, "flag") { cx =>
        if gooseneck::param_count(cx) > 0 { gooseneck::answer(cx, json::Value.Str { s: "helper" }); }
    };
    // bold is a block helper too.
    gooseneck::helper(reg, "bold") { cx => gooseneck::answer(cx, json::Value.Str { s: "B" }); };
}

// Registers count twice.
fn twice_helpers(reg) {
    gooseneck::helper(reg, "loud") { cx => gooseneck::answer(cx, loud(cx)); };
    gooseneck::helper(reg, "count") { cx => gooseneck::answer(cx, json::Value.Int { v: 1 }); };
    gooseneck::helper(reg, "count") { cx => gooseneck::answer(cx, json::Value.Int { v: 2 }); };
}

// Registers bold twice.
fn twice_blocks<B>(reg) {
    gooseneck::block_helper(reg, "bold") { cx => B(gooseneck::this()); };
    gooseneck::block_helper(reg, "raw") { cx => B(gooseneck::this()); };
    gooseneck::block_helper(reg, "bold") { cx => B(gooseneck::this()); };
}

fn blocks<B>(reg) {
    gooseneck::block_helper(reg, "bold") { cx =>
        cx.out.append("<b>");
        B(gooseneck::this());
        cx.out.append("</b>");
    };
    gooseneck::block_helper(reg, "list") { cx =>
        cx.out.append("<ul>");
        for k in gooseneck::length(gooseneck::param(cx, 0)) {
            cx.out.append("<li>");
            B(gooseneck::element(0, k));
            cx.out.append("</li>");
        }
        cx.out.append("</ul>");
    };
    gooseneck::block_helper(reg, "when") { cx =>
        if is_true(gooseneck::param(cx, 0)) {
            B(gooseneck::this());
        } else {
            B(gooseneck::inverse(gooseneck::this()));
        }
    };
    gooseneck::block_helper(reg, "raw") { cx => B(gooseneck::this()); };
}

fn show(s: const u8[:]) -> u8[>..] {
    let out: u8[>..] = [];
    for c in s {
        if c == '\n' { out.append("\\n"); } else { out.push(c); }
    }
    return out;
}

fn fail(label: const u8[:], how: const u8[:], err: const u8[:], got: const u8[:], want: const u8[:]) {
    print(label, " (", how, ")");
    print("err:  ", err);
    print("got:  ", show(got));
    print("want: ", show(want));
    assert(false);
}

// Renders template, compiled with the registered block helpers, with the
// struct and with the JSON; both must give want.
fn check(label: const u8[:], template: const u8[:], context: const Page&, want: const u8[:]) {
    let engine = gooseneck::get_engine(template, blocks);
    let out, err = gooseneck::render(engine, context, helpers, blocks);
    if err.len > 0 || out != want { fail(label, "struct", err, out, want); }
    let json_out: u8[>..] = [];
    let json_err = gooseneck::render_json(engine, CONTEXT_JSON, json_out, helpers, blocks);
    if json_err.len > 0 || json_out != want { fail(label, "json", json_err, json_out, want); }
    print(label);
}

// Compiles template with the registered block helpers; it must fail with
// want.
fn check_rejected(label: const u8[:], template: const u8[:], want: const u8[:]) {
    let engine = gooseneck::get_engine(template, blocks);
    if engine.error != want { fail(label, "error", engine.error, "", want); }
    print(label);
}

// Renders template with helpers F and block helpers G, one of which
// registers a name twice, through each render function; each must fail with want and
// write nothing. The engine is compiled with the registered block helpers.
fn check_render_error<F, G>(label: const u8[:], template: const u8[:], context: const Page&, want: const u8[:]) {
    let engine = gooseneck::get_engine(template, blocks);
    let out, err = gooseneck::render(engine, context, F, G);
    if err != want || out.len > 0 { fail(label, "render", err, out, want); }
    let into: u8[>..] = [];
    let nodes, into_err = gooseneck::render_into(engine, context, into, F, G);
    if into_err != want || into.len > 0 || nodes != 0 { fail(label, "render_into", into_err, into, want); }
    let json_out: u8[>..] = [];
    let json_err = gooseneck::render_json(engine, CONTEXT_JSON, json_out, F, G);
    if json_err != want || json_out.len > 0 { fail(label, "render_json", json_err, json_out, want); }
    let file_err = gooseneck::render_json_file(engine, "no such file.json", json_out, F, G);
    if file_err != want || json_out.len > 0 { fail(label, "render_json_file", file_err, json_out, want); }
    print(label);
}

fn main() {
    let items: Item[>..] = [Item { name: "pen" }, Item { name: "ink" }];
    let context = Page { name: "ada <3", title: "field", flag: true, items: items };

    // Helpers.
    check("registered helper", "{{loud name}}", context, "ADA &lt;3");
    check("helper counts its params", "{{count 1 2 3}}", context, "3");
    check("unknown helper renders nothing", "[{{nope 1}}]", context, "[]");
    check("bare name without a helper is the field", "{{name}}", context, "ada &lt;3");
    check("helper wins over a field", "{{title}}", context, "helper");
    check("helper wins over a field, ./ is the field", "{{./title}}", context, "field");
    check("block that answers", "{{kind name}}", context, "string");
    check("block that does not answer gives nothing", "[{{kind 1}}]", context, "[]");
    check("block that does not answer leaves the field", "{{flag}}|{{flag 1}}", context, "true|helper");
    check("subexpressions", "{{loud (loud name)}} {{count (count 1 2) 3}}", context, "ADA &lt;3 2");
    check("helper feeds #if", "{{#if (count)}}x{{else}}none{{/if}}", context, "none");
    check("name must match whole", "[{{lou name}}][{{louder name}}]", context, "[][]");

    // Block helpers, with their names from the registrations.
    check("registered block helper", "{{#bold}}{{name}}{{/bold}}", context, "<b>ada &lt;3</b>");
    check("iterator", "{{#list items}}{{loud name}}{{/list}}", context, "<ul><li>PEN</li><li>INK</li></ul>");
    check("inverse", "{{#when flag}}yes{{else}}no{{/when}}|{{#when name}}yes{{else}}no{{/when}}", context, "yes|no");
    check("raw block", "{{{{raw}}}}{{name}}{{{{/raw}}}}", context, "{{name}}");
    check("nested block helpers", "{{#bold}}{{#list items}}{{#bold}}{{name}}{{/bold}}{{/list}}{{/bold}}", context,
          "<b><ul><li><b>pen</b></li><li><b>ink</b></li></ul></b>");
    check("block helper beside built-ins", "{{#each items}}{{#bold}}{{@index}}{{name}}{{/bold}}{{/each}}", context,
          "<b>0pen</b><b>1ink</b>");
    check_rejected("unknown block helper", "{{#nope}}x{{/nope}}", "unknown block helper #nope");
    check_rejected("block name must match whole", "{{#bol}}x{{/bol}}", "unknown block helper #bol");
    check("helper and block helper of one name", "{{bold}}{{#bold}}x{{/bold}}", context, "B<b>x</b>");

    // load_engine takes the names the same way.
    let engine = gooseneck::load_engine(str(resource_dir(), "fixtures/registered.hbs"), blocks);
    let out, err = gooseneck::render(engine, context, helpers, blocks);
    if err.len > 0 || out != "<b>ADA &lt;3</b>\n" { fail("load_engine", "struct", err, out, "<b>ADA &lt;3</b>\n"); }
    print("load_engine");

    // A name registered twice.
    check_render_error("duplicate helper", "{{count}}", context, "duplicate helper \"count\"", twice_helpers, blocks);
    check_render_error("duplicate block helper in a render", "{{name}}", context, "duplicate block helper \"bold\"", helpers, twice_blocks);
    let twice_engine = gooseneck::get_engine("{{name}}", twice_blocks);
    if twice_engine.error != "duplicate block helper \"bold\"" { fail("duplicate block helper", "get_engine", twice_engine.error, "", "duplicate block helper \"bold\""); }
    print("duplicate block helper");
    let twice_loaded = gooseneck::load_engine(str(resource_dir(), "fixtures/registered.hbs"), twice_blocks);
    if twice_loaded.error != "duplicate block helper \"bold\"" { fail("duplicate block helper", "load_engine", twice_loaded.error, "", "duplicate block helper \"bold\""); }
    print("duplicate block helper in load_engine");

    // Inline, the check is the render's too.
    let inline_engine = gooseneck::get_engine("{{now}}");
    let inline_out: u8[>..] = [];
    let nodes, inline_err = gooseneck::render_into(inline_engine, context, inline_out) { reg =>
        gooseneck::helper(reg, "now") { cx => gooseneck::answer(cx, json::Value.Int { v: 1 }); };
        gooseneck::helper(reg, "now") { cx => gooseneck::answer(cx, json::Value.Int { v: 2 }); };
    };
    if inline_err != "duplicate helper \"now\"" || inline_out.len > 0 || nodes != 0 {
        fail("duplicate inline helper", "render_into", inline_err, inline_out, "");
    }
    print("duplicate inline helper");
}
