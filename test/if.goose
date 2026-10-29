// {{#if}} and {{#unless}}: truthiness of every value kind, includeZero, nesting with
// {{#with}}, ../ inside an if, whitespace control, and the compile errors of
// block helper calls. Every expected output below is what handlebars.js
// 4.7.10 renders for the same template and data (NaN only through the
// struct, {} and null only through JSON). The errors are gooseneck's own:
// handlebars.js accepts some of those calls (unknown hash keys, #repeat),
// gooseneck checks block calls at compile time. Each case asserts, then
// prints its name; scripts/test.sh compares that list with
// test/expected/if.out.
import handlebars from "../gooseneck";

struct Item { label: const u8[:] }

struct Values {
    name: const u8[:],
    empty: const u8[:],
    zero: i64,
    one: i64,
    fzero: f64,
    half: f64,
    nan: f64,
    yes: bool,
    no: bool,
    list: const i64[:],
    none: const i64[:],
    obj: Item,
}

// The same data as Values, as JSON, plus what a struct cannot hold.
const CONTEXT_JSON: const u8[:] = "{\"name\":\"Jo\",\"empty\":\"\",\"zero\":0,\"one\":1,\"fzero\":0.0,\"half\":0.5,\"yes\":true,\"no\":false,\"list\":[1,2],\"none\":[],\"obj\":{\"label\":\"L\"},\"maybe\":null,\"blank\":{}}";

fn show(s: const u8[:]) -> u8[>..] {
    let out: u8[>..] = [];
    for c in s {
        if c == '\n' { out.append("\\n"); } else if c == '\r' { out.append("\\r"); } else { out.push(c); }
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

// Renders template with the struct, the JSON, or both; each must give want.
fn check(label: const u8[:], template: const u8[:], context: const Values&, use_struct: bool, use_json: bool, want: const u8[:]) {
    let engine = gooseneck::get_engine(template);
    if use_struct { check_struct(label, engine, context, want); }
    if use_json { check_json(label, engine, want); }
    print(label);
}

fn check_rejected(label: const u8[:], template: const u8[:], context: const Values&, want: const u8[:]) {
    let engine = gooseneck::get_engine(template);
    let out, err = gooseneck::render(engine, context);
    if err != want || out.len != 0 { fail(label, "error", err, out, want); }
    print(label);
}

fn main() {
    let numbers: i64[>..] = [1, 2];
    let nothing: i64[>..] = [];
    let context = Values {
        name: "Jo",
        empty: "",
        zero: 0,
        one: 1,
        fzero: 0.0,
        half: 0.5,
        nan: 0.0 / 0.0,
        yes: true,
        no: false,
        list: numbers,
        none: nothing,
        obj: Item { label: "L" },
    };

    check("non-empty string", "{{#if name}}yes{{/if}}", context, true, true, "yes");
    check("empty string", "{{#if empty}}yes{{/if}}", context, true, true, "");
    check("int zero", "{{#if zero}}yes{{/if}}", context, true, true, "");
    check("int one", "{{#if one}}yes{{/if}}", context, true, true, "yes");
    check("float zero", "{{#if fzero}}yes{{/if}}", context, true, true, "");
    check("float half", "{{#if half}}yes{{/if}}", context, true, true, "yes");
    check("NaN", "{{#if nan}}yes{{/if}}", context, true, false, "");
    check("NaN includeZero", "{{#if nan includeZero=true}}yes{{/if}}", context, true, false, "");
    check("true", "{{#if yes}}yes{{/if}}", context, true, true, "yes");
    check("false", "{{#if no}}yes{{/if}}", context, true, true, "");
    check("non-empty array", "{{#if list}}yes{{/if}}", context, true, true, "yes");
    check("empty array", "{{#if none}}yes{{/if}}", context, true, true, "");
    check("object", "{{#if obj}}yes{{/if}}", context, true, true, "yes");
    check("empty object", "{{#if blank}}yes{{/if}}", context, false, true, "yes");
    check("null", "{{#if maybe}}yes{{/if}}", context, false, true, "");
    check("missing", "{{#if nope}}yes{{/if}}", context, true, true, "");
    check("missing dotted", "{{#if obj.nope}}yes{{/if}}", context, true, true, "");
    check("dotted path", "{{#if obj.label}}{{obj.label}}{{/if}}", context, true, true, "L");
    check("includeZero int", "{{#if zero includeZero=true}}yes{{/if}}", context, true, true, "yes");
    check("includeZero float", "{{#if fzero includeZero=true}}yes{{/if}}", context, true, true, "yes");
    check("includeZero false", "{{#if zero includeZero=false}}yes{{/if}}", context, true, true, "");
    check("includeZero empty string", "{{#if empty includeZero=true}}yes{{/if}}", context, true, true, "");
    check("includeZero empty array", "{{#if none includeZero=true}}yes{{/if}}", context, true, true, "");
    check("literal true", "{{#if true}}yes{{/if}}", context, true, true, "yes");
    check("literal false", "{{#if false}}yes{{/if}}", context, true, true, "");
    check("literal string", "{{#if \"x y\"}}yes{{/if}}", context, true, true, "yes");
    check("literal empty string", "{{#if ''}}yes{{/if}}", context, true, true, "");
    check("literal null", "{{#if null}}yes{{/if}}", context, true, true, "");
    check("literal undefined", "{{#if undefined}}yes{{/if}}", context, true, true, "");
    check("literal zero", "{{#if 0}}yes{{/if}}", context, true, true, "");
    check("literal zero includeZero", "{{#if 0 includeZero=true}}yes{{/if}}", context, true, true, "yes");
    check("literal int", "{{#if 7}}yes{{/if}}", context, true, true, "yes");
    check("literal number", "{{#if -1.5}}yes{{/if}}", context, true, true, "yes");
    check("same frame", "{{#if obj}}[{{name}}|{{label}}]{{/if}}", context, true, true, "[Jo|]");
    check("text around", "a {{#if yes}}b {{name}}{{/if}} c {{#if no}}d{{/if}}e", context, true, true, "a b Jo c e");
    check("nested if", "{{#if yes}}1{{#if one}}2{{#if no}}3{{/if}}{{/if}}{{/if}}", context, true, true, "12");
    check("if inside with", "{{#with obj}}{{#if label}}[{{label}}]{{/if}}{{/with}}", context, true, true, "[L]");
    check("with inside if", "{{#if yes}}{{#with obj}}{{label}}{{/with}}{{/if}}", context, true, true, "L");
    check("parent inside if inside with", "{{#with obj}}{{#if ../yes}}{{../name}}{{/if}}{{/with}}", context, true, true, "Jo");
    check("parent from if at root", "{{#if yes}}[{{../name}}]{{/if}}", context, true, true, "[]");
    check("parent arg", "{{#with obj}}{{#if ../no}}x{{/if}}{{#if ../one}}y{{/if}}{{/with}}", context, true, true, "y");
    check("spaces in tags", "{{#if  yes  }}yes{{/if }}", context, true, true, "yes");
    check("standalone if lines", "<ul>\n{{#if yes}}\n  <li>{{name}}</li>\n{{/if}}\n</ul>\n", context, true, true, "<ul>\n  <li>Jo</li>\n</ul>\n");
    check("standalone falsy if", "a\n{{#if no}}\nhidden\n{{/if}}\nb\n", context, true, true, "a\nb\n");
    check("indented standalone if", "<div>\n  {{#if obj}}\n    {{#with obj}}\n    <p>{{label}}</p>\n    {{/with}}\n  {{/if}}\n</div>", context, true, true, "<div>\n    <p>L</p>\n</div>");
    check("standalone if CRLF", "a\r\n{{#if yes}}\r\nb\r\n{{/if}}\r\nc", context, true, true, "a\r\nb\r\nc");
    check("inline if untouched", "a {{#if yes}} b {{/if}} c\n", context, true, true, "a  b  c\n");
    check("tilde if", "a  {{~#if yes~}}  b  {{~/if~}}  c", context, true, true, "abc");

    // {{#unless}}: the same truthiness, inverted.
    check("unless false", "{{#unless no}}yes{{/unless}}", context, true, true, "yes");
    check("unless true", "{{#unless yes}}yes{{/unless}}", context, true, true, "");
    check("unless zero", "{{#unless zero}}zero{{/unless}}", context, true, true, "zero");
    check("unless zero includeZero", "{{#unless zero includeZero=true}}zero{{/unless}}", context, true, true, "");
    check("unless empty string", "{{#unless empty}}empty{{/unless}}", context, true, true, "empty");
    check("unless empty array", "{{#unless none}}none{{/unless}}", context, true, true, "none");
    check("unless array", "{{#unless list}}list{{/unless}}", context, true, true, "");
    check("unless missing", "{{#unless nope}}missing{{/unless}}", context, true, true, "missing");
    check("unless null", "{{#unless maybe}}null{{/unless}}", context, false, true, "null");
    check("unless empty object", "{{#unless blank}}blank{{/unless}}", context, false, true, "");
    check("unless else taken", "{{#unless yes}}a{{else}}b{{/unless}}", context, true, true, "b");
    check("unless else skipped", "{{#unless no}}a{{else}}b{{/unless}}", context, true, true, "a");
    check("unless lookup missing", "{{#unless (lookup obj \"nope\")}}no label{{/unless}}", context, true, true, "no label");
    check("unless lookup found", "{{#unless (lookup obj \"label\")}}x{{else}}{{obj.label}}{{/unless}}", context, true, true, "L");
    check("unless inside with", "{{#with obj}}{{#unless ../no}}{{label}} {{../name}}{{/unless}}{{/with}}", context, true, true, "L Jo");
    check("if inside unless", "{{#unless no}}{{#if yes}}both{{/if}}{{/unless}}", context, true, true, "both");
    check("standalone unless else", "a\n{{#unless no}}\n  b\n{{else}}\n  c\n{{/unless}}\nd\n", context, true, true, "a\n  b\nd\n");
    check("tilde unless", "a  {{~#unless no~}}  b  {{~/unless~}}  c", context, true, true, "abc");

    // {{else helper ...}} chains: the inverse is one more block, which the
    // first block's closing tag closes too.
    check("else if taken", "{{#if no}}A{{else if yes}}B{{/if}}", context, true, true, "B");
    check("else if after true", "{{#if yes}}A{{else if yes}}B{{/if}}", context, true, true, "A");
    check("else if none true", "{{#if no}}A{{else if no}}B{{/if}}", context, true, true, "");
    check("else if then else", "{{#if no}}A{{else if no}}B{{else}}C{{/if}}", context, true, true, "C");
    check("else if three", "{{#if no}}A{{else if no}}B{{else if one}}C{{else}}D{{/if}}", context, true, true, "C");
    check("else unless", "{{#if no}}A{{else unless no}}B{{/if}}", context, true, true, "B");
    check("unless else if", "{{#unless yes}}A{{else if one}}B{{/unless}}", context, true, true, "B");
    check("else with", "{{#if no}}A{{else with obj}}{{label}}{{/if}}", context, true, true, "L");
    check("else each", "{{#if no}}A{{else each list}}{{this}},{{/if}}", context, true, true, "1,2,");
    check("else each empty", "{{#if no}}A{{else each none}}{{this}}{{else}}E{{/if}}", context, true, true, "E");
    check("each else if", "{{#each none}}x{{else if yes}}Y{{/each}}", context, true, true, "Y");
    check("each else if skipped", "{{#each list}}{{this}}{{else if yes}}Y{{/each}}", context, true, true, "12");
    check("with else if", "{{#with blank}}x{{else if one}}O{{/with}}", context, false, true, "x");
    check("with null else if", "{{#with maybe}}x{{else if one}}O{{/with}}", context, false, true, "O");
    check("else if includeZero", "{{#if no}}A{{else if zero includeZero=true}}Z{{/if}}", context, true, true, "Z");
    check("nested else if", "{{#if no}}A{{else if yes}}{{#if no}}a{{else if yes}}b{{/if}}{{/if}}", context, true, true, "b");
    check("else if parent path", "{{#with obj}}{{#if ../no}}A{{else if label}}{{label}}{{/if}}{{/with}}", context, true, true, "L");
    check("standalone else if", "a\n{{#if no}}\n  A\n{{else if yes}}\n  B\n{{else}}\n  C\n{{/if}}\nd\n", context, true, true, "a\n  B\nd\n");
    check("else if tilde", "{{#if no}}A{{~else if yes~}} B {{/if}}", context, true, true, "B ");
    check_rejected("else if closed by its own name", "{{#if no}}A{{else unless yes}}B{{/unless}}", context, "unexpected /unless");
    check_rejected("else if wrong close", "{{#if no}}A{{else if yes}}B{{/unless}}", context, "unexpected /unless");
    check_rejected("else if at top level", "{{else if yes}}x", context, "unexpected else");
    check_rejected("else if after else", "{{#if no}}A{{else}}B{{else if yes}}C{{/if}}", context, "unexpected else");
    check_rejected("else if unclosed", "{{#if no}}A{{else if yes}}B", context, "unclosed #if");
    check_rejected("else if without param", "{{#if no}}A{{else if}}B{{/if}}", context, "#if takes exactly one argument");
    check_rejected("else unknown helper", "{{#if no}}A{{else repeat yes}}B{{/if}}", context, "unknown block helper #repeat");
    check_rejected("two else after else if", "{{#if no}}A{{else if yes}}B{{else}}C{{else}}D{{/if}}", context, "unexpected else");
    check_rejected("mismatched close", "{{#if yes}}x{{/with}}", context, "unexpected /with");
    check_rejected("mismatched close with", "{{#with obj}}x{{/if}}", context, "unexpected /if");
    check_rejected("stray close", "x{{/if}}", context, "unexpected /if");
    check_rejected("if without param", "{{#if}}x{{/if}}", context, "#if takes exactly one argument");
    check_rejected("if two params", "{{#if yes no}}x{{/if}}", context, "#if takes exactly one argument");
    check_rejected("if unknown hash key", "{{#if yes foo=true}}x{{/if}}", context, "#if: unknown hash argument foo");
    check_rejected("includeZero not bool", "{{#if yes includeZero=1}}x{{/if}}", context, "#if: includeZero must be true or false");
    check_rejected("with two params", "{{#with obj yes}}x{{/with}}", context, "#with takes exactly one argument");
    check_rejected("with hash", "{{#with obj as=1}}x{{/with}}", context, "#with takes no hash arguments");
    check_rejected("unknown helper", "{{#repeat yes}}x{{/repeat}}", context, "unknown block helper #repeat");
    check_rejected("unless without param", "{{#unless}}x{{/unless}}", context, "#unless takes exactly one argument");
    check_rejected("unless unknown hash key", "{{#unless yes foo=true}}x{{/unless}}", context, "#unless: unknown hash argument foo");
    check_rejected("unless includeZero not bool", "{{#unless yes includeZero=1}}x{{/unless}}", context, "#unless: includeZero must be true or false");
    check_rejected("unless closed by if", "{{#unless yes}}x{{/if}}", context, "unexpected /if");
    check_rejected("if closed by unless", "{{#if yes}}x{{/unless}}", context, "unexpected /unless");
    check_rejected("unclosed unless", "{{#unless yes}}x", context, "unclosed #unless");
    check_rejected("unclosed subexpression", "{{#if (eq yes no}}x{{/if}}", context, "unclosed subexpression: (eq yes no");
    check_rejected("includeZero subexpression", "{{#if yes includeZero=(no)}}x{{/if}}", context, "#if: includeZero must be true or false");
    check_rejected("unclosed string", "{{#if \"abc}}x{{/if}}", context, "unclosed string: \"abc");
    check_rejected("param after hash", "{{#if includeZero=true yes}}x{{/if}}", context, "positional argument after hash arguments: yes");
    check_rejected("bad arg path", "{{#if a!}}x{{/if}}", context, "Invalid characted in segment");
}
