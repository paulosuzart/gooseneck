// The built-in lookup helper: array elements by index, object members by
// key, keys from paths, literals, @index, @key and subexpressions, nested
// lookups, lookup inside #each with ../, #with, #each and #if on a lookup,
// missing keys, typed versus JSON contexts, and precedence over a user
// helper named lookup. Every expected output below is what handlebars.js
// 4.7.10 renders for the same template and data, except the cases under
// "gooseneck's own". Each case asserts, then prints its name;
// scripts/test.sh compares that list with test/expected/lookup.out.
import handlebars from "../gooseneck";

struct Home { city: const u8[:] }

struct Person {
    name: const u8[:],
    city: const u8[:],
    tags: const u8[:][:],
    home: Home,
}

struct Flags { on: bool, off: bool, none: i64 }

struct Html { x: const u8[:] }

struct Values {
    title: const u8[:],
    names: const u8[:][:],
    ages: const i64[:],
    index: i64,
    field: const u8[:],
    people: const Person[:],
    person: Person,
    flags: Flags,
    html: Html,
}

// The same data as Values, as JSON, plus what a struct cannot hold.
const CONTEXT_JSON: const u8[:] = "{\"title\":\"Hi\",\"names\":[\"Ada\",\"Grace\",\"Linus\"],\"ages\":[36,45,28],\"index\":1,\"field\":\"city\",\"people\":[{\"name\":\"Ada\",\"city\":\"London\",\"tags\":[],\"home\":{\"city\":\"London\"}},{\"name\":\"Grace\",\"city\":\"Arlington\",\"tags\":[],\"home\":{\"city\":\"Arlington\"}}],\"person\":{\"name\":\"Ada\",\"city\":\"London\",\"tags\":[\"math\",\"code\"],\"home\":{\"city\":\"London\"}},\"flags\":{\"on\":true,\"off\":false,\"none\":0},\"html\":{\"x\":\"<b>\"},\"cities\":{\"Ada\":\"London\",\"Grace\":\"Arlington\"},\"keys\":[\"Ada\",\"Grace\",\"Nobody\"],\"matrix\":[[1,2],[3,4]],\"numbered\":{\"1\":\"one\",\"2\":\"two\"}}";

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

fn check_struct(label: const u8[:], engine: const gooseneck::Engine&, context: const Values&, want: const u8[:]) {
    let out, err = gooseneck::render(engine, context);
    if err.len > 0 || out != want { fail(label, "struct", err, out, want); }
}

fn check_json(label: const u8[:], engine: const gooseneck::Engine&, want: const u8[:]) {
    let out: u8[>..] = [];
    let err = gooseneck::render_json(engine, CONTEXT_JSON, out);
    if err.len > 0 || out != want { fail(label, "json", err, out, want); }
}

// Renders template from the struct, the JSON, or both, and checks each
// against want.
fn check(label: const u8[:], template: const u8[:], context: const Values&, use_struct: bool, use_json: bool, want: const u8[:]) {
    let engine = gooseneck::get_engine(template);
    if use_struct { check_struct(label, engine, context, want); }
    if use_json { check_json(label, engine, want); }
    print(label);
}

fn main() {
    let names: const u8[:][>..] = ["Ada", "Grace", "Linus"];
    let ages: i64[>..] = [36, 45, 28];
    let no_tags: const u8[:][>..] = [];
    let tags: const u8[:][>..] = ["math", "code"];
    let people: Person[>..] = [
        Person { name: "Ada", city: "London", tags: no_tags, home: Home { city: "London" } },
        Person { name: "Grace", city: "Arlington", tags: no_tags, home: Home { city: "Arlington" } },
    ];
    let context = Values {
        title: "Hi",
        names: names,
        ages: ages,
        index: 1,
        field: "city",
        people: people,
        person: Person { name: "Ada", city: "London", tags: tags, home: Home { city: "London" } },
        flags: Flags { on: true, off: false, none: 0 },
        html: Html { x: "<b>" },
    };

    // Arrays by index.
    check("index literal", "{{lookup names 1}}", context, true, true, "Grace");
    check("index path", "{{lookup names index}}", context, true, true, "Grace");
    check("index string", "{{lookup names \"2\"}}", context, true, true, "Linus");
    check("index past end", "[{{lookup names 3}}]", context, true, true, "[]");
    check("negative index", "[{{lookup names -1}}]", context, true, true, "[]");
    check("index with leading zero", "[{{lookup names \"01\"}}]", context, true, true, "[]");

    // Objects by key.
    check("key literal", "{{lookup person \"city\"}}", context, true, true, "London");
    check("missing key", "[{{lookup person \"nope\"}}]", context, true, true, "[]");
    check("lookup on a string", "[{{lookup title \"x\"}}]", context, true, true, "[]");
    check("lookup on nothing", "[{{lookup nope \"x\"}}]", context, true, true, "[]");
    check("escaped and raw", "{{lookup html \"x\"}}{{{lookup html \"x\"}}}", context, true, true, "&lt;b&gt;<b>");

    // Inside #each and #with.
    check("parallel arrays", "{{#each names}}{{this}} is {{lookup ../ages @index}}; {{/each}}", context, true, true, "Ada is 36; Grace is 45; Linus is 28; ");
    check("inside with", "{{#with person}}{{lookup ../names 0}} {{lookup this \"name\"}}{{/with}}", context, true, true, "Ada Ada");

    // Nested lookups, and lookups as block targets.
    check("nested lookup", "{{lookup (lookup people 1) \"city\"}}", context, true, true, "Arlington");
    check("with lookup", "{{#with (lookup people 0)}}{{name}} from {{city}}{{/with}}", context, true, true, "Ada from London");
    check("with lookup missing", "{{#with (lookup people 5)}}x{{else}}none{{/with}}", context, true, true, "none");
    check("each lookup", "{{#each (lookup person \"tags\")}}{{@index}}:{{this}} {{/each}}", context, true, true, "0:math 1:code ");
    check("if lookup", "{{#if (lookup flags \"on\")}}on{{/if}}{{#if (lookup flags \"off\")}}off{{/if}}", context, true, true, "on");
    check("if lookup includeZero", "{{#if (lookup flags \"none\") includeZero=true}}zero{{/if}}", context, true, true, "zero");

    // JSON only: dynamic keys into objects (see below for structs), nested
    // arrays, numeric keys.
    check("key from each item", "{{#each keys}}{{this}}: {{lookup ../cities this}}; {{/each}}", context, false, true, "Ada: London; Grace: Arlington; Nobody: ; ");
    check("key from @key", "{{#each cities}}{{@key}}={{lookup ../cities @key}} {{/each}}", context, false, true, "Ada=London Grace=Arlington ");
    check("nested arrays", "{{lookup (lookup matrix 1) 0}}", context, false, true, "3");
    check("each nested array", "{{#each (lookup matrix 1)}}{{this}},{{/each}}", context, false, true, "3,4,");
    check("numeric keys", "{{lookup numbered 1}}{{lookup numbered \"2\"}}", context, false, true, "onetwo");
    check("dynamic key", "{{lookup person field}}", context, false, true, "London");
    check("nested lookup with path key", "{{lookup (lookup person \"home\") field}}", context, false, true, "London");
    check("key from parent", "{{#each people}}{{lookup this ../field}} {{/each}}", context, false, true, "London Arlington ");

    // gooseneck's own. A typed struct converts only the fields the
    // template names: field holds "city" only when rendering, so person's
    // city is there only when a path or a literal key names it.
    check("dynamic key on a struct", "[{{lookup person field}}]", context, true, false, "[]");
    check("dynamic key on a named field", "[{{lookup person field}}] {{person.city}}", context, true, true, "[London] London");
    // handlebars.js throws at render time for these; gooseneck renders
    // nothing, as for any call that finds nothing.
    check("one param", "[{{lookup names}}]", context, true, true, "[]");
    check("three params", "[{{lookup names 0 1}}]", context, true, true, "[]");

    // The built-in wins over a user helper named lookup.
    let engine = gooseneck::get_engine("{{lookup names 0}} {{shout names}}");
    let out: u8[>..] = [];
    let nodes, err = gooseneck::render_into(engine, context, out) { reg =>
        gooseneck::helper(reg, "lookup") { cx => gooseneck::answer(cx, json::Value.Str { s: "user" }); };
        gooseneck::helper(reg, "shout") { cx => gooseneck::answer(cx, json::Value.Str { s: "user" }); };
    };
    if err.len > 0 || out != "Ada user" { fail("built-in wins", "struct", err, out, "Ada user"); }
    print("built-in wins");
}
