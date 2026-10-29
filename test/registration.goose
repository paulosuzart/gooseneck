// Helpers written as registrations, as plod writes routes:
// gooseneck::helpers with one gooseneck::helper per name, and
// gooseneck::block_helpers with one gooseneck::block_helper per name. The
// engines come from get_engine and load_engine given the block helpers,
// which take the names a Config would list from the registrations. Each
// case asserts, then prints its name; scripts/test.sh compares that list
// with test/expected/registration.out.
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

// The first param in upper case, made in args.text; anything but a string
// as it is.
fn loud(args: const gooseneck::Args&) -> json::Value {
    let value = gooseneck::param(args, 0);
    match value {
        Str t => {
            let start = args.text.len;
            for c in t.s {
                if c >= 'a' && c <= 'z' { args.text.push(c - 32); } else { args.text.push(c); }
            }
            return json::Value.Str { s: args.text[start..] };
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

fn helpers(name: const u8[:], args: const gooseneck::Args&) -> gooseneck::Result {
    return gooseneck::helpers(args) { call =>
        gooseneck::helper(call, "loud") { return gooseneck::known(loud(args)); };
        gooseneck::helper(call, "count") {
            return gooseneck::known(json::Value.Int { v: gooseneck::param_count(args) });
        };
        // A helper with the name of a field wins over it, as in handlebars.js.
        gooseneck::helper(call, "title") { return gooseneck::known(json::Value.Str { s: "helper" }); };
        // kind answers strings here; the block falls through for anything
        // else, to the next registration of kind.
        gooseneck::helper(call, "kind") {
            if is_string(gooseneck::param(args, 0)) {
                return gooseneck::known(json::Value.Str { s: "string" });
            }
        };
        gooseneck::helper(call, "kind") { return gooseneck::known(json::Value.Str { s: "other" }); };
    };
}

fn blocks<B>(name: const u8[:], args: const gooseneck::Args&, out: u8[>..]&) -> bool {
    return gooseneck::block_helpers(args) { call =>
        gooseneck::block_helper(call, "bold") {
            out.append("<b>");
            B(gooseneck::this());
            out.append("</b>");
        };
        gooseneck::block_helper(call, "list") {
            out.append("<ul>");
            for k in gooseneck::length(gooseneck::param(args, 0)) {
                out.append("<li>");
                B(gooseneck::element(0, k));
                out.append("</li>");
            }
            out.append("</ul>");
        };
        gooseneck::block_helper(call, "when") {
            if is_true(gooseneck::param(args, 0)) {
                B(gooseneck::this());
            } else {
                B(gooseneck::inverse(gooseneck::this()));
            }
        };
        gooseneck::block_helper(call, "raw") { B(gooseneck::this()); };
    };
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

fn main() {
    let items: Item[>..] = [Item { name: "pen" }, Item { name: "ink" }];
    let context = Page { name: "ada <3", title: "field", flag: true, items: items };

    // Helpers.
    check("registered helper", "{{loud name}}", context, "ADA &lt;3");
    check("second registration", "{{count 1 2 3}}", context, "3");
    check("unknown helper renders nothing", "[{{nope 1}}]", context, "[]");
    check("bare name without a helper is the field", "{{name}}", context, "ada &lt;3");
    check("helper wins over a field", "{{title}}", context, "helper");
    check("helper wins over a field, ./ is the field", "{{./title}}", context, "field");
    check("block that returns answers", "{{kind name}}", context, "string");
    check("block that falls through leaves the next", "{{kind 1}}", context, "other");
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

    // load_engine takes the names the same way.
    let engine = gooseneck::load_engine(str(resource_dir(), "fixtures/registered.hbs"), blocks);
    let out, err = gooseneck::render(engine, context, helpers, blocks);
    if err.len > 0 || out != "<b>ADA &lt;3</b>\n" { fail("load_engine", "struct", err, out, "<b>ADA &lt;3</b>\n"); }
    print("load_engine");
}
