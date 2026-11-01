// Partials: {{> name}}, with a context and hash arguments, recursion,
// standalone indentation, scope inside a partial, partials from a list
// (get_engine) and from files next to the page (load_engine), the compile
// errors, and the depth limit. Every expected output below is what
// handlebars.js 4.7.10 renders for the same templates and data. Each case
// asserts, then prints its name; scripts/test.sh compares that list with
// test/expected/partials.out.
import gooseneck from "..";

struct City { name: const u8[:] }

struct Address {
    street: const u8[:],
    city: City,
}

struct Person {
    name: const u8[:],
    address: Address,
}

// The data most cases render, as JSON.
const CONTEXT_JSON: const u8[:] = "{\"x\": \"X\", \"y\": \"TOP\", \"label\": \"TL\", \"a\": {\"y\": \"AY\", \"a\": {\"y\": \"AAY\"}}, \"list\": [{\"y\": 1}, {\"y\": 2}], \"obj\": {\"k1\": {\"y\": \"v1\"}, \"k2\": {\"y\": \"v2\"}}, \"t\": {\"name\": \"r\", \"kids\": [{\"name\": \"a\", \"kids\": [{\"name\": \"b\"}]}, {\"name\": \"c\"}]}, \"items\": [\"i1\", \"i2\"]}";

fn show(s: const u8[:]) -> u8[>..] {
    let out: u8[>..] = [];
    for c in s {
        if c == '\n' { out.append("\\n"); } else if c == '\t' { out.append("\\t"); } else { out.push(c); }
    }
    return out;
}

fn fail(label: const u8[:], err: const u8[:], got: const u8[:], want: const u8[:]) {
    print(label);
    print("err:  ", err);
    print("got:  ", show(got));
    print("want: ", show(want));
    assert(false);
}

fn expect(label: const u8[:], err: const u8[:], got: const u8[:], want: const u8[:]) {
    if err.len > 0 || got != want { fail(label, err, got, want); }
    print(label);
}

// The partials the cases call.
fn partials() -> gooseneck::Partial[22] {
    return [
        gooseneck::Partial { name: "p", text: "[{{../x}}|{{y}}|{{@root.x}}|{{@index}}|{{@key}}|{{@first}}|{{it}}]" },
        gooseneck::Partial { name: "h", text: "<{{label}}:{{y}}:{{x}}:{{../x}}>" },
        gooseneck::Partial { name: "tree", text: "{{name}}{{#if kids}}({{#each kids}}{{> tree}}{{/each}}){{/if}}" },
        gooseneck::Partial { name: "ind", text: "a\n{{y}}\nb\n" },
        gooseneck::Partial { name: "ind2", text: "x\n  {{> ind}}\ny\n" },
        gooseneck::Partial { name: "noeol", text: "one\ntwo" },
        gooseneck::Partial { name: "bp", text: "{{item}}-{{y}}" },
        gooseneck::Partial { name: "layout/base", text: "B:{{y}}" },
        gooseneck::Partial { name: "nest", text: "{{#with a}}<{{y}}|{{../y}}|{{../../y}}>{{/with}}" },
        gooseneck::Partial { name: "deep", text: "{{> h label=label}}" },
        gooseneck::Partial { name: "list", text: "<ul>\n  {{#each items}}\n  <li>{{this}}</li>\n  {{/each}}\n</ul>\n" },
        gooseneck::Partial { name: "code", text: "fn {\n    {{> ind}}\n}\n" },
        gooseneck::Partial { name: "h2", text: "[{{label}}|{{n}}|{{y}}]" },
        gooseneck::Partial { name: "inh", text: "{{label}}/{{> h2}}" },
        gooseneck::Partial { name: "inh2", text: "{{#with a}}{{> h2}}{{/with}}" },
        gooseneck::Partial { name: "inh3", text: "{{> h2 a}}" },
        gooseneck::Partial { name: "inh4", text: "{{> h2 this n=5}}" },
        gooseneck::Partial { name: "inh5", text: "{{#each list}}{{> h2}}{{/each}}" },
        gooseneck::Partial { name: "e", text: "" },
        gooseneck::Partial { name: "dots", text: "{{> h2 .}}" },
        gooseneck::Partial { name: "bad", text: "ok\n{{/if}}" },
        gooseneck::Partial { name: "calls_nope", text: "x{{> nope}}" },
    ];
}

// Renders template, with partials(), on CONTEXT_JSON.
fn check(label: const u8[:], template: const u8[:], want: const u8[:]) {
    let engine = gooseneck::get_engine(template, partials());
    let out: u8[>..] = [];
    let err = gooseneck::render_json(engine, CONTEXT_JSON, out);
    expect(label, err, out, want);
}

// get_engine must give an engine whose error is want.
fn check_error(label: const u8[:], template: const u8[:], want: const u8[:]) {
    let engine = gooseneck::get_engine(template, partials());
    if engine.error != want { fail(label, engine.error, "", want); }
    print(label);
}

// load_engine must give an engine whose error ends with want.
fn check_load_error(label: const u8[:], file: const u8[:], want: const u8[:]) {
    let engine = gooseneck::load_engine(str(resource_dir(), "fixtures/partials/", file));
    if !ends_with(engine.error, want) { fail(label, engine.error, "", want); }
    print(label);
}

fn main() {
    check("scope at the top",
          "{{> p}}",
          "[|TOP|X||||]");
    check("no ../ past the partial's frame",
          "{{#with a}}{{> p}}{{/with}}",
          "[|AY|X||||]");
    check("context argument",
          "{{> p a}}",
          "[|AY|X||||]");
    check("@index and @first in each",
          "{{#each list}}{{> p}}{{/each}}",
          "[|1|X|0|0|true|][|2|X|1|1|false|]");
    check("@key in each over an object",
          "{{#each obj}}{{> p}}{{/each}}",
          "[|v1|X|0|k1|true|][|v2|X|1|k2|false|]");
    check("block params do not pass",
          "{{#each list as |it|}}{{> p}}{{/each}}",
          "[|1|X|0|0|true|][|2|X|1|1|false|]");
    check("block param not seen",
          "{{#each list as |item|}}{{> bp}}{{/each}}",
          "-1-2");
    check("block param as context",
          "{{#each list as |item|}}{{> bp item}}{{/each}}",
          "-1-2");
    check("hash, none",
          "{{> h}}",
          "<TL:TOP:X:>");
    check("hash, string",
          "{{> h label=\"L\"}}",
          "<L:TOP:X:>");
    check("hash over a context",
          "{{> h a label=\"L\"}}",
          "<L:AY::>");
    check("hash shadows the context",
          "{{> h a y=x}}",
          "<:X::>");
    check("hash, path",
          "{{> h label=a.y}}",
          "<AY:TOP:X:>");
    check("hash, parent path",
          "{{#with a}}{{> h label=../x}}{{/with}}",
          "<X:AY::>");
    check("hash, number and boolean",
          "{{> h label=1 y=true}}",
          "<1:true:X:>");
    check("hash passed on by name",
          "{{> deep label=\"D\"}}",
          "<D:TOP:X:>");
    check("hash, missing value shadows",
          "{{> h y=missing}}",
          "<TL::X:>");
    check("hash, @root",
          "{{> h label=@root.x}}",
          "<X:TOP:X:>");
    check("recursion",
          "{{> tree t}}",
          "r(a(b)c)");
    check("standalone indents",
          "  {{> ind a}}\nend",
          "  a\n  AY\n  b\nend");
    check("standalone after a line",
          "x\n  {{> ind a}}\nend",
          "x\n  a\n  AY\n  b\nend");
    check("nested indentation",
          "{{> ind2 a}}",
          "x\n  a\n  AY\n  b\ny\n");
    check("not standalone, no indent",
          "a {{> ind a}} b",
          "a a\nAY\nb\n b");
    check("no final newline",
          "  {{> noeol}}\nz",
          "  one\n  twoz");
    check("tilde drops the indentation",
          "\t{{~> ind a}}\nz",
          "a\nAY\nb\nz");
    check("name with a slash",
          "{{> layout/base}}",
          "B:TOP");
    check("no space after >",
          "{{>p}}",
          "[|TOP|X||||]");
    check("this as context",
          "{{> p this}}",
          "[|TOP|X||||]");
    check("context that is not an object",
          "{{> p a.y}}",
          "[||X||||]");
    check("missing context",
          "{{> h missing}}",
          "<:::>");
    check("context and hash",
          "{{> p a y=1}}",
          "[|1|X||||]");
    check("standalone in each",
          "{{#each list}}\n  {{> bp}}\n{{/each}}",
          "  -1  -2");
    check("../ inside a partial",
          "{{> nest}}",
          "<AY|TOP|>");
    check("../ inside a partial, with context",
          "{{> nest a}}",
          "<AAY|AY|>");
    check("double-quoted name",
          "{{> \"p\"}}",
          "[|TOP|X||||]");
    check("single-quoted name",
          "{{> 'h'}}",
          "<TL:TOP:X:>");
    check("bracketed name",
          "{{> [p]}}",
          "[|TOP|X||||]");
    check("indented standalone blocks inside",
          "  {{> list}}",
          "  <ul>\n    <li>i1</li>\n    <li>i2</li>\n  </ul>\n");
    check("indentation adds up",
          "{{> code a}}",
          "fn {\n    a\n    AY\n    b\n}\n");
    check("standalone in a block",
          "{{#if x}}\n  {{> ind a}}\n{{/if}}\n",
          "  a\n  AY\n  b\n");
    check("same partial twice",
          "{{> h}}{{> h}}",
          "<TL:TOP:X:><TL:TOP:X:>");
    check("nested partial sees the hash",
          "{{> inh label=\"L\" n=1}}",
          "L/[L|1|TOP]");
    check("nested partial in a with does not",
          "{{> inh2 label=\"L\" n=1}}",
          "[||AY]");
    check("nested partial with context does not",
          "{{> inh3 label=\"L\" n=1}}",
          "[||AY]");
    check("this with a hash keeps the hash",
          "{{> inh4 label=\"L\" n=1}}",
          "[L|5|TOP]");
    check("nested partial in each does not",
          "{{> inh5 label=\"L\" n=1}}",
          "[||1][||2]");
    check("empty partial",
          "[{{> e}}]",
          "[]");
    check(". as context",
          "{{> dots n=2}}",
          "[TL|2|TOP]");
    check("hash, @index",
          "{{#each list}}{{> h2 this label=@index}}{{/each}}",
          "[0||1][1||2]");
    check("hash resolved where the call is",
          "{{> h2 a label=y}}",
          "[TOP||AY]");
    check("hash zero",
          "{{> inh label=\"L\" y=0}}",
          "L/[L||0]");

    // Partials of a typed context see its fields, as the page does.
    let john = Person { name: "John", address: Address { street: "123 Main St", city: City { name: "Springfield" } } };
    let person: gooseneck::Partial[1] = [
        gooseneck::Partial { name: "person", text: "{{name}} lives at {{address.street}}, {{address.city.name}}{{#if note}} ({{note}}){{/if}}" },
    ];
    let typed = gooseneck::get_engine("{{> person}}; {{> person address note=\"moved\"}}", person);
    let typed_out, typed_err = gooseneck::render(typed, john);
    expect("typed context", typed_err, typed_out, "John lives at 123 Main St, Springfield;  lives at ,  (moved)");

    let count: gooseneck::Partial[1] = [gooseneck::Partial { name: "count", text: "{{v}}{{#if n}},{{> count n}}{{/if}}" }];
    let counting = gooseneck::get_engine("{{> count c}}", count);
    let count_out: u8[>..] = [];
    let count_err = gooseneck::render_json(counting, "{\"c\": {\"v\": 1, \"n\": {\"v\": 2, \"n\": {\"v\": 3}}}}", count_out);
    expect("recursion on a list", count_err, count_out, "1,2,3");

    let item: gooseneck::Partial[1] = [gooseneck::Partial { name: "item", text: "{{#if done}}[x]{{else}}[ ]{{/if}} {{title}}\n" }];
    let todo = gooseneck::get_engine("<ul>\n{{#each items}}\n  {{> item}}\n{{/each}}\n</ul>\n", item);
    let todo_out: u8[>..] = [];
    let todo_err = gooseneck::render_json(todo, "{\"items\": [{\"title\": \"a\", \"done\": true}, {\"title\": \"b <i>\"}]}", todo_out);
    expect("partial per item", todo_err, todo_out, "<ul>\n  [x] a\n  [ ] b &lt;i&gt;\n</ul>\n");

    // Files: {{> header}} is header.hbs next to the page, {{> layout/base}}
    // layout/base.hbs, and the footer base.hbs calls is next to the page
    // too. unused.hbs does not compile, and is never read.
    let page = gooseneck::load_engine(str(resource_dir(), "fixtures/partials/page.hbs"));
    let page_out: u8[>..] = [];
    let page_err = gooseneck::render_json(page, "{\"title\": \"Hi <3\", \"name\": \"Ada\"}", page_out);
    expect("partials from files", page_err, page_out, "<h1>Hi &lt;3</h1>\n<main>\n  <p>Ada</p>\n  <small>Hi &lt;3</small>\n</main>\n");

    // The depth limit: handlebars.js recurses until the JavaScript stack
    // runs out; gooseneck stops at engine.partial_depth calls under way.
    let looping: gooseneck::Partial[1] = [gooseneck::Partial { name: "loop", text: "x{{> loop}}" }];
    let loop_engine = gooseneck::get_engine("{{> loop}}", looping);
    let loop_out: u8[>..] = [];
    let loop_err = gooseneck::render_json(loop_engine, "{}", loop_out);
    if loop_err != "partial depth over 100: loop" || loop_out.len != 100 { fail("depth limit", loop_err, "", "partial depth over 100: loop"); }
    print("depth limit");

    var shallow = gooseneck::get_engine("{{> count c}}", count);
    shallow.partial_depth = 2;
    let shallow_out: u8[>..] = [];
    let shallow_err = gooseneck::render_json(shallow, "{\"c\": {\"v\": 1, \"n\": {\"v\": 2, \"n\": {\"v\": 3}}}}", shallow_out);
    if shallow_err != "partial depth over 2: count" { fail("depth limit set on the engine", shallow_err, shallow_out, "partial depth over 2: count"); }
    let deep_enough_out: u8[>..] = [];
    shallow.partial_depth = 3;
    let deep_enough_err = gooseneck::render_json(shallow, "{\"c\": {\"v\": 1, \"n\": {\"v\": 2, \"n\": {\"v\": 3}}}}", deep_enough_out);
    expect("depth limit set on the engine", deep_enough_err, deep_enough_out, "1,2,3");

    // Compile errors. handlebars.js finds an unknown partial when it
    // renders; gooseneck when it compiles.
    check_error("unknown partial", "a\n  {{> nope}}", "2:7: unknown partial \"nope\"");
    check_error("error inside a partial", "{{> p}}{{> bad}}", "bad:2:1: unexpected /if");
    check_error("two contexts", "{{> p a b}}", "1:1: a partial takes one context at most: p a b");
    check_error("missing name", "{{>}}", "1:1: missing partial name");
    check_error("dynamic partial", "{{> (pick)}}", "1:5: dynamic partials are not supported yet");
    check_error("@partial-block", "{{> @partial-block}}", "1:5: @partial-block is not supported yet");
    check_error("partial block", "{{#> p}}x{{/p}}", "1:1: partial blocks are not supported yet");
    check_error("inline partial", "{{#*inline \"p\"}}x{{/inline}}", "1:1: inline partials are not supported yet");
    check_error("unknown partial inside a partial", "{{> calls_nope}}", "calls_nope:1:6: unknown partial \"nope\"");
    check_load_error("unknown partial in a file", "missing.hbs", "fixtures/partials/missing.hbs:2:7: unknown partial \"nope\"");
    check_load_error("error in a partial file", "calls_broken.hbs", "fixtures/partials/broken.hbs:2:1: unexpected /if");
}
