// User helpers: {{helper args}} mustaches, (helper args) subexpressions,
// nested ones, hash arguments, literals, helpers feeding {{#if}}, state a
// helper block captures, and the compile errors of subexpressions. The
// helpers below mirror these handlebars.js ones:
//
//     loud:   s => typeof s === "string" ? s.toUpperCase() : s
//     eq:     (a, b) => a === b
//     id:     a => a
//     add:    (a, b) => a + b
//     concat: (...params, options) => params.join(options.hash.sep ?? "")
//     first:  () => "F<"
//     count:  (...params, options) => params.length
//     zero:   () => undefined
//
// and every expected output under "same as handlebars.js" is what
// handlebars.js 4.7.10 renders for the same template and data. The other
// cases are gooseneck's own: an unknown helper renders nothing where
// handlebars.js throws "Missing helper", {{#with}} takes only a path, and
// the errors are gooseneck's messages. Each case asserts, then prints its
// name; scripts/test.sh compares that list with test/expected/helpers.out.
import handlebars from "../gooseneck";

struct User { first: const u8[:], last: const u8[:] }

struct Page {
    name: const u8[:],
    title: const u8[:],
    a: i64,
    b: i64,
    c: i64,
    zero: i64,
    user: User,
}

// The same data as Page, as JSON.
const CONTEXT_JSON: const u8[:] = "{\"name\":\"Paulo <3\",\"title\":\"hello\",\"a\":1,\"b\":1,\"c\":2,\"zero\":0,\"user\":{\"first\":\"Ada\",\"last\":\"Lovelace\"}}";

// Whether two values are the same kind and equal, as === is for these.
fn same(x: json::Value, y: json::Value) -> bool {
    match x {
        Str a => {
            match y {
                Str b => { return a.s == b.s; },
                _ => { return false; },
            }
        },
        Int a => {
            match y {
                Int b => { return a.v == b.v; },
                _ => { return false; },
            }
        },
        Bool a => {
            match y {
                Bool b => { return a.v == b.v; },
                _ => { return false; },
            }
        },
        _ => { return false; },
    }
}

// Appends the text of a string or an integer to text.
fn append_text(text: u8[>..]&, value: json::Value) {
    match value {
        Str t => { text.append(t.s); },
        Int i => { format(text, i.v); },
        _ => {},
    }
}

// The upper-case copy of a string, appended to text; Null for anything
// else. Its result views only text, never value.
fn upper(text: u8[>..]&, value: json::Value) -> json::Value {
    let start = text.len;
    match value {
        Str t => {
            for c in t.s {
                if c >= 'a' && c <= 'z' { text.push(c - 32); } else { text.push(c); }
            }
        },
        _ => { return json::Value.Null; },
    }
    return json::Value.Str { s: text[start..] };
}

// The first param in upper case, made in cx.text; anything but a string
// as it is.
fn loud(cx: gooseneck::HelperContext&) -> json::Value {
    let value = gooseneck::param(cx, 0);
    match value {
        Str => { return upper(cx.text, value); },
        _ => { return value; },
    }
}

// The params joined by the hash argument sep, "" without one.
fn concat(cx: gooseneck::HelperContext&) -> json::Value {
    let start = cx.text.len;
    let sep = gooseneck::hash_arg(cx, "sep");
    for i in gooseneck::param_count(cx) {
        if i > 0 { append_text(cx.text, sep); }
        append_text(cx.text, gooseneck::param(cx, i));
    }
    return json::Value.Str { s: cx.text[start..] };
}

// The sum of two integers; Null for anything else.
fn add(cx: const gooseneck::HelperContext&) -> json::Value {
    match gooseneck::param(cx, 0) {
        Int x => {
            match gooseneck::param(cx, 1) {
                Int y => { return json::Value.Int { v: x.v + y.v }; },
                _ => {},
            }
        },
        _ => {},
    }
    return json::Value.Null;
}

fn helpers(cx) {
    gooseneck::helper(cx, "loud") { gooseneck::answer(cx, loud(cx)); };
    gooseneck::helper(cx, "eq") {
        gooseneck::answer(cx, json::Value.Bool { v: same(gooseneck::param(cx, 0), gooseneck::param(cx, 1)) });
    };
    gooseneck::helper(cx, "id") { gooseneck::answer(cx, gooseneck::param(cx, 0)); };
    gooseneck::helper(cx, "add") { gooseneck::answer(cx, add(cx)); };
    gooseneck::helper(cx, "concat") { gooseneck::answer(cx, concat(cx)); };
    gooseneck::helper(cx, "first") { gooseneck::answer(cx, json::Value.Str { s: "F<" }); };
    gooseneck::helper(cx, "count") { gooseneck::answer(cx, json::Value.Int { v: gooseneck::param_count(cx) }); };
    gooseneck::helper(cx, "zero") { gooseneck::answer(cx, json::Value.Null); };
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

// Renders template with helpers from the struct and from the JSON, and
// checks both against want.
fn check(label: const u8[:], template: const u8[:], context: const Page&, want: const u8[:]) {
    let engine = gooseneck::get_engine(template);
    let out, err = gooseneck::render(engine, context, helpers);
    if err.len > 0 || out != want { fail(label, "struct", err, out, want); }
    let json_out: u8[>..] = [];
    let json_err = gooseneck::render_json(engine, CONTEXT_JSON, json_out, helpers);
    if json_err.len > 0 || json_out != want { fail(label, "json", json_err, json_out, want); }
    print(label);
}

fn check_rejected(label: const u8[:], template: const u8[:], context: const Page&, want: const u8[:]) {
    let engine = gooseneck::get_engine(template);
    let out, err = gooseneck::render(engine, context, helpers);
    if err != want || out.len != 0 { fail(label, "error", err, out, want); }
    print(label);
}

fn main() {
    let context = Page {
        name: "Paulo <3",
        title: "hello",
        a: 1,
        b: 1,
        c: 2,
        zero: 0,
        user: User { first: "Ada", last: "Lovelace" },
    };

    // Same as handlebars.js.
    check("helper mustache", "{{loud title}}", context, "HELLO");
    check("helper result escaped", "{{loud name}}", context, "PAULO &lt;3");
    check("helper result raw", "{{{loud name}}}", context, "PAULO <3");
    check("helper with spaces", "{{ loud  title }}", context, "HELLO");
    check("if eq true", "{{#if (eq a b)}}same{{/if}}", context, "same");
    check("if eq false", "{{#if (eq a c)}}same{{/if}}", context, "");
    check("bool result", "{{eq a b}}", context, "true");
    check("string literal", "{{eq title \"hello\"}}", context, "true");
    check("number literal", "{{eq 1 a}}", context, "true");
    check("two literals", "{{eq \"x\" \"y\"}}", context, "false");
    check("int result", "{{add a c}}", context, "3");
    check("nested subexpression", "{{loud (concat user.first \" \" user.last)}}", context, "ADA LOVELACE");
    check("subexpression of subexpression", "{{#if (eq (loud title) \"HELLO\")}}y{{/if}}", context, "y");
    check("two subexpressions", "{{loud (concat (loud user.first) (id user.last))}}", context, "ADALOVELACE");
    check("hash argument", "{{concat user.first user.last sep=\"-\"}}", context, "Ada-Lovelace");
    check("hash subexpression", "{{concat \"a\" \"b\" sep=(loud \"x\")}}", context, "aXb");
    check("hash inside subexpression", "{{concat (concat \"a\" \"b\" sep=\"+\") \"c\" sep=\" = \"}}", context, "a+b &#x3D; c");
    check("if zero result", "{{#if (id zero)}}z{{/if}}", context, "");
    check("if zero result includeZero", "{{#if (id zero) includeZero=true}}z{{/if}}", context, "z");
    check("parens in strings", "{{loud (concat \"a)\" \" (b\")}}", context, "A) (B");
    check("helper inside with", "{{#with user}}{{loud first}} {{loud ../title}}{{/with}}", context, "ADA HELLO");
    check("escaped concat", "{{concat \"<b>\" name}}", context, "&lt;b&gt;Paulo &lt;3");
    check("raw concat", "{{{concat \"<b>\" name}}}", context, "<b>Paulo <3");
    check("unknown subexpression", "{{#if (nope)}}y{{/if}}", context, "");

    // A bare {{name}} calls the helper of that name before it looks up the
    // field; ./name and this.name, dotted paths and params are paths.
    check("bare helper wins", "{{#with user}}{{first}}{{/with}}", context, "F&lt;");
    check("bare helper raw", "{{#with user}}{{{first}}}{{/with}}", context, "F<");
    check("scoped paths skip helpers", "{{#with user}}{{./first}}|{{this.first}}|{{this/first}}{{/with}}", context, "Ada|Ada|Ada");
    check("dotted path skips helpers", "{{user.first}}", context, "Ada");
    check("zero-argument helper", "{{count}}", context, "0");
    check("helper result Null wins", "{{zero}}|{{./zero}}", context, "|0");
    check("param is a path", "{{#with user}}{{loud first}}{{/with}}", context, "ADA");
    check("subexpression without arguments", "{{loud (first)}}", context, "F&lt;");
    check("no helper, field", "{{#with user}}{{last}}{{/with}}", context, "Lovelace");
    check("block param beats helper", "{{#with user as |first|}}{{first.last}}{{/with}}", context, "Lovelace");

    // gooseneck's own.
    check("unknown helper", "[{{nope title}}]", context, "[]");
    check("with subexpression", "{{#with (id user)}}{{first}}{{/with}}", context, "");

    let engine = gooseneck::get_engine("{{loud title}}");
    let out, err = gooseneck::render(engine, context);
    if err.len > 0 || out.len != 0 { fail("no helpers", "struct", err, out, ""); }
    print("no helpers");

    // The helpers may be a block, given the context by reference.
    let shouted: u8[>..] = [];
    gooseneck::render_into(engine, context, shouted) { cx => gooseneck::answer(cx, upper(cx.text, gooseneck::param(cx, 0))); };
    if shouted != "HELLO" { fail("block helpers", "struct", "", shouted, "HELLO"); }
    print("block helpers");

    // A block may capture state: here a count of the calls.
    var calls: i64 = 0;
    let counted = gooseneck::get_engine("{{n a}},{{n a}},{{#if (n a)}}{{n a}}{{/if}}");
    let counted_out: u8[>..] = [];
    gooseneck::render_into(counted, context, counted_out) { cx =>
        calls += 1;
        gooseneck::answer(cx, json::Value.Int { v: calls });
    };
    if counted_out != "1,2,4" || calls != 4 { fail("captured state", "struct", "", counted_out, "1,2,4"); }
    print("captured state");

    check_rejected("unclosed subexpression", "{{#if (eq a b}}x{{/if}}", context, "unclosed subexpression: (eq a b");
    check_rejected("unclosed nested subexpression", "{{loud (concat a (id b)}}", context, "unclosed subexpression: (concat a (id b)");
    check_rejected("stray close", "{{loud a)}}", context, "unexpected ): a)");
    check_rejected("empty subexpression", "{{#if ()}}x{{/if}}", context, "missing helper name: ()");
    check_rejected("text after subexpression", "{{loud (id a)b}}", context, "text after subexpression: (id a)b");
    check_rejected("unclosed string in subexpression", "{{loud (id \"a)}}", context, "unclosed string: (id \"a)");
    check_rejected("bad helper name", "{{loud (a! b)}}", context, "Invalid characted in segment");
    check_rejected("bad argument in subexpression", "{{loud (id a!)}}", context, "Invalid characted in segment");
    check_rejected("param after hash", "{{concat sep=\"-\" a}}", context, "positional argument after hash arguments: a");
    check_rejected("includeZero subexpression", "{{#if a includeZero=(eq a b)}}x{{/if}}", context, "#if: includeZero must be true or false");
}
