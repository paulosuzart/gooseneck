// {{#each}}: arrays of scalars and of objects, objects, nested each, each
// inside with and if, this and ., ../, the data variables @index, @key,
// @first and @last, @root, empty and missing values, {{else}} on each, with and
// if, whitespace control, and the compile errors of blocks. Every expected
// output below is what handlebars.js 4.7.10 renders for the same template
// and data, except the cases under "gooseneck's own". Object iteration and
// nested arrays run on the JSON context only: a typed struct converts only
// the fields the template names, which a template that only iterates an
// object never does. Each case asserts, then prints its name;
// scripts/test.sh compares that list with test/expected/each.out.
import handlebars from "../gooseneck";

struct Item { name: const u8[:], price: i64 }

struct Named { name: const u8[:] }

struct Group { name: const u8[:], items: const Named[:] }

struct Person { first: const u8[:], last: const u8[:] }

struct Shop {
    title: const u8[:],
    tags: const u8[:][:],
    numbers: const i64[:],
    empty: const i64[:],
    items: const Item[:],
    groups: const Group[:],
    owner: Person,
}

// The same data as Shop, as JSON, plus what the struct leaves out.
const CONTEXT_JSON: const u8[:] = "{\"title\":\"Shop\",\"tags\":[\"new\",\"sale\"],\"numbers\":[0,1,2],\"empty\":[],\"items\":[{\"name\":\"pen\",\"price\":2},{\"name\":\"ink\",\"price\":0}],\"groups\":[{\"name\":\"a\",\"items\":[{\"name\":\"x\"},{\"name\":\"y\"}]},{\"name\":\"b\",\"items\":[{\"name\":\"z\"}]}],\"owner\":{\"first\":\"Ada\",\"last\":\"Lovelace\"},\"prices\":{\"pen\":2,\"ink\":0.5},\"matrix\":[[1,2],[3]],\"none\":{}}";

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

fn check_struct(label: const u8[:], engine: const gooseneck::Engine&, context: const Shop&, want: const u8[:]) {
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
fn check(label: const u8[:], template: const u8[:], context: const Shop&, use_struct: bool, use_json: bool, want: const u8[:]) {
    let engine = gooseneck::get_engine(template);
    if use_struct { check_struct(label, engine, context, want); }
    if use_json { check_json(label, engine, want); }
    print(label);
}

fn check_rejected(label: const u8[:], template: const u8[:], context: const Shop&, want: const u8[:]) {
    let engine = gooseneck::get_engine(template);
    let out, err = gooseneck::render(engine, context);
    if err != want || out.len != 0 { fail(label, "error", err, out, want); }
    print(label);
}

fn main() {
    let tags: const u8[:][>..] = ["new", "sale"];
    let numbers: i64[>..] = [0, 1, 2];
    let nothing: i64[>..] = [];
    let items: Item[>..] = [Item { name: "pen", price: 2 }, Item { name: "ink", price: 0 }];
    let a_items: Named[>..] = [Named { name: "x" }, Named { name: "y" }];
    let b_items: Named[>..] = [Named { name: "z" }];
    let groups: Group[>..] = [Group { name: "a", items: a_items }, Group { name: "b", items: b_items }];
    let context = Shop {
        title: "Shop",
        tags: tags,
        numbers: numbers,
        empty: nothing,
        items: items,
        groups: groups,
        owner: Person { first: "Ada", last: "Lovelace" },
    };

    // Arrays of scalars.
    check("this", "{{#each tags}}[{{this}}]{{/each}}", context, true, true, "[new][sale]");
    check("dot", "{{#each tags}}{{.}},{{/each}}", context, true, true, "new,sale,");
    check("index", "{{#each tags}}{{@index}}:{{this}} {{/each}}", context, true, true, "0:new 1:sale ");
    check("array key", "{{#each tags}}{{@key}}{{/each}}", context, true, true, "01");
    check("first and last in if", "{{#each numbers}}{{#if @first}}<{{/if}}{{this}}{{#if @last}}>{{else}},{{/if}}{{/each}}", context, true, true, "<0,1,2>");
    check("first and last written", "{{#each tags}}{{@first}}/{{@last}} {{/each}}", context, true, true, "true/false false/true ");

    // Arrays of objects.
    check("item fields", "{{#each items}}{{name}}={{price}};{{/each}}", context, true, true, "pen=2;ink=0;");
    check("this.field", "{{#each items}}{{this.name}} {{/each}}", context, true, true, "pen ink ");
    check("parent", "{{#each items}}{{name}} in {{../title}};{{/each}}", context, true, true, "pen in Shop;ink in Shop;");
    check("nested each", "{{#each groups}}{{name}}:{{#each items}}{{name}}@{{../name}}/{{@index}} {{/each}}|{{/each}}", context, true, true, "a:x@a/0 y@a/1 |b:z@b/0 |");
    check("each inside with", "{{#with owner}}{{#each ../tags}}{{../first}}-{{this}} {{/each}}{{/with}}", context, true, true, "Ada-new Ada-sale ");
    check("each inside if", "{{#if tags}}{{#each tags}}{{this}}{{/each}}{{/if}}", context, true, true, "newsale");
    check("if inside each", "{{#each numbers}}{{#if this}}y{{else}}n{{/if}}{{/each}}", context, true, true, "nyy");
    check("includeZero inside each", "{{#each numbers}}{{#if this includeZero=true}}y{{/if}}{{/each}}", context, true, true, "yyy");
    check("with this", "{{#each items}}{{#with this}}{{name}}{{/with}}{{/each}}", context, true, true, "penink");

    // Nothing to walk.
    check("empty list", "[{{#each empty}}x{{/each}}]", context, true, true, "[]");
    check("missing", "[{{#each nope}}x{{/each}}]", context, true, true, "[]");
    check("string", "[{{#each title}}x{{/each}}]", context, true, true, "[]");
    check("literal", "[{{#each 3}}x{{/each}}]", context, true, true, "[]");
    check("data outside each", "[{{@index}}{{@first}}]", context, true, true, "[]");
    check("data after each", "{{#each tags}}{{@index}}{{/each}}{{@index}}", context, true, true, "01");
    check("parent index", "{{#each groups}}{{#each items}}{{@../index}}{{@index}} {{/each}}{{/each}}", context, true, true, "00 01 10 ");
    check("parent index through with", "{{#each groups}}{{#with this}}{{#each items}}{{@../index}}{{/each}}{{/with}}{{/each}}", context, true, true, "001");
    check("parent key first last", "{{#each groups}}{{#each items}}{{@../key}}{{@../first}}{{@../last}} {{/each}}{{/each}}", context, true, true, "0truefalse 0truefalse 1falsetrue ");
    check("past the outermost each", "{{#each groups}}{{#each items}}[{{@../../index}}]{{/each}}{{/each}}", context, true, true, "[][][]");
    check("parent data outside each", "[{{@../index}}]", context, true, true, "[]");

    // {{else}}.
    check("each else", "{{#each empty}}x{{else}}none{{/each}}", context, true, true, "none");
    check("each else skipped", "{{#each tags}}{{this}}{{else}}none{{/each}}", context, true, true, "newsale");
    check("with else", "{{#with nope}}x{{else}}no {{title}}{{/with}}", context, true, true, "no Shop");
    check("if else", "{{#if empty}}y{{else}}n{{/if}}", context, true, true, "n");

    // Whitespace.
    check("standalone each", "<ul>\n  {{#each tags}}\n  <li>{{this}}</li>\n  {{/each}}\n</ul>\n", context, true, true, "<ul>\n  <li>new</li>\n  <li>sale</li>\n</ul>\n");
    check("tilde each", "{{#each tags ~}} {{this}} {{~/each}}", context, true, true, "newsale");
    check("standalone else", "{{#each empty}}\nx\n{{else}}\nnone\n{{/each}}\n", context, true, true, "none\n");
    check("indented standalone else", "<p>\n  {{#if empty}}\n  y\n  {{else}}\n  n\n  {{/if}}\n</p>", context, true, true, "<p>\n  n\n</p>");

    // Objects and nested arrays, JSON only.
    check("object", "{{#each prices}}{{@key}}={{this}}{{#if @last}}.{{else}}, {{/if}}{{/each}}", context, false, true, "pen=2, ink=0.5.");
    check("object data", "{{#each prices}}{{@index}}{{@first}}{{@last}} {{/each}}", context, false, true, "0truefalse 1falsetrue ");
    check("nested arrays", "{{#each matrix}}{{#each this}}{{this}}{{/each}};{{/each}}", context, false, true, "12;3;");
    check("parent first in if", "{{#each matrix}}{{#each this}}{{#if @../first}}F{{/if}}{{this}}{{/each}};{{/each}}", context, false, true, "F1F2;3;");
    check("nested index", "{{#each matrix}}{{@index}}:{{#each this}}{{@index}}{{/each}} {{/each}}", context, false, true, "0:01 1:0 ");
    check("empty object", "[{{#each none}}x{{else}}empty{{/each}}]", context, false, true, "[empty]");
    check("object members", "{{#each owner}}{{@key}}={{this}};{{/each}}", context, false, true, "first=Ada;last=Lovelace;");

    // Block parameters, as |item key|, tied to their block at compile time.
    check("param item", "{{#each tags as |tag|}}{{tag}},{{/each}}", context, true, true, "new,sale,");
    check("param index", "{{#each tags as |tag i|}}{{i}}={{tag}} {{/each}}", context, true, true, "0=new 1=sale ");
    check("param key of object", "{{#each prices as |price name|}}{{name}}:{{price}} {{/each}}", context, false, true, "pen:2 ink:0.5 ");
    check("param field and context", "{{#each items as |item|}}{{item.name}}/{{name}} {{/each}}", context, true, true, "pen/pen ink/ink ");
    check("nested params", "{{#each groups as |g gi|}}{{#each g.items as |it ii|}}{{gi}}.{{ii}}={{g.name}}{{it.name}} {{/each}}{{/each}}", context, true, true, "0.0=ax 0.1=ay 1.0=bz ");
    check("inner param shadows", "{{#each groups as |g|}}{{#each items as |g|}}{{g.name}}{{/each}}{{/each}}", context, true, true, "xyz");
    check("outer param in plain each", "{{#each groups as |g|}}{{#each items}}{{g.name}}{{name}} {{/each}}{{/each}}", context, true, true, "ax ay bz ");
    check("with param", "{{#with owner as |o|}}{{o.first}} {{last}}{{/with}}", context, true, true, "Ada Lovelace");
    check("with second param", "{{#with owner as |o x|}}[{{x}}]{{/with}}", context, true, true, "[]");
    check("scoped path is no param", "{{#each tags as |tag|}}{{./tag}}{{this.tag}}{{tag}}{{/each}}", context, true, true, "newsale");
    check("param inside with", "{{#each tags as |tag|}}{{#with ../owner}}{{tag}}{{first}}{{/with}}{{/each}}", context, true, true, "newAdasaleAda");
    check("parent path is no param", "{{#each tags as |tag|}}{{../tag}}{{/each}}", context, true, true, "");
    check("param in if", "{{#each tags as |tag i|}}{{#if i}}, {{/if}}{{tag}}{{/each}}", context, true, true, "new, sale");
    check("param as lookup key", "{{#each tags as |tag i|}}{{lookup ../tags i}}{{/each}}", context, true, true, "newsale");
    check("with on param", "{{#each items as |item|}}{{#with item}}{{name}}{{/with}}{{/each}}", context, true, true, "penink");
    check("each on param", "{{#each matrix as |row|}}{{#each row as |cell|}}{{cell}}{{/each}};{{/each}}", context, false, true, "12;3;");
    check("no params in inverse", "{{#each empty as |e|}}x{{else}}{{e}}none{{/each}}", context, true, true, "none");
    check("field of key", "{{#each tags as |tag i|}}{{i.x}}{{/each}}", context, true, true, "");
    check("spaced params", "{{#each tags as | tag  i |}}{{i}}{{tag}}{{/each}}", context, true, true, "0new1sale");
    check("params and data", "{{#each tags as |tag|}}{{@index}}{{tag}}{{/each}}", context, true, true, "0new1sale");
    check("param out of scope", "{{#each tags as |tag|}}{{/each}}{{tag}}", context, true, true, "");
    check("third param", "{{#each tags as |a b c|}}[{{c}}]{{/each}}", context, true, true, "[][]");
    check("params on lookup", "{{#each (lookup groups 0) as |v k|}}{{k}} {{/each}}", context, false, true, "name items ");
    check("param under parent each", "{{#each tags as |tag|}}{{#each ../matrix as |row|}}{{tag}}{{/each}}{{/each}}", context, false, true, "newnewsalesale");
    check("params on else each", "{{#if title}}{{else each tags as |t|}}{{t}}{{/if}}{{#if empty}}{{else each tags as |t|}}{{t}}{{/if}}", context, true, true, "newsale");
    check("standalone params", "{{#each tags as |tag|}}\n{{tag}}\n{{/each}}\n", context, true, true, "new\nsale\n");
    check_rejected("no param names", "{{#each tags as ||}}x{{/each}}", context, "missing block parameter names: as ||");
    check_rejected("dotted param name", "{{#each tags as |a.b|}}x{{/each}}", context, "invalid block parameter name: a.b");
    check_rejected("unclosed params", "{{#each tags as |tag}}x{{/each}}", context, "Invalid characted in segment");
    check_rejected("params without as", "{{#each tags |tag|}}x{{/each}}", context, "Invalid characted in segment");
    check_rejected("params on if", "{{#if title as |t|}}{{t}}{{/if}}", context, "#if takes no block parameters");

    // @root: the context the render began with, from anywhere. On the
    // struct, a field only @root names (owner.last) is still converted.
    check("root at the top", "{{@root.title}}", context, true, true, "Shop");
    check("root in each", "{{#each tags}}{{@root.title}}{{/each}}", context, true, true, "ShopShop");
    check("root in with", "{{#with owner}}{{@root.title}}{{/with}}", context, true, true, "Shop");
    check("with root", "{{#with @root}}{{title}}{{/with}}", context, true, true, "Shop");
    check("each on a root path", "{{#with owner}}{{#each @root.tags}}{{this}}{{/each}}{{/with}}", context, true, true, "newsale");
    check("root in nested each", "{{#each groups}}{{#each items}}{{@root.owner.first}}{{name}} {{/each}}{{/each}}", context, true, true, "Adax Aday Adaz ");
    check("root as lookup target", "{{#each groups}}{{lookup @root.owner \"first\"}}{{/each}}", context, true, true, "AdaAda");
    check("root field named only there", "{{#each tags}}{{@root.owner.last}}{{/each}}", context, true, true, "LovelaceLovelace");
    check("root with data key", "{{#each prices}}{{@key}}={{lookup @root.prices @key}} {{/each}}", context, false, true, "pen=2 ink=0.5 ");
    check("root in if", "{{#if @root.title}}y{{/if}}", context, true, true, "y");
    check("root path finds nothing", "[{{@root.nope}}]", context, false, true, "[]");

    // gooseneck's own: the struct converts only the fields the template
    // names, and this one names none of owner's.
    check("struct object members", "[{{#each owner}}{{@key}}={{this}};{{/each}}]", context, true, false, "[]");
    // An object writes nothing (handlebars.js writes [object Object]).
    check("root alone", "[{{@root}}]", context, true, true, "[]");

    check_rejected("unclosed each", "{{#each tags}}x", context, "unclosed #each");
    check_rejected("unclosed inner", "{{#each tags}}{{#if this}}x{{/each}}", context, "unexpected /each");
    check_rejected("stray close", "x{{/each}}", context, "unexpected /each");
    check_rejected("mismatched close", "{{#each tags}}x{{/if}}", context, "unexpected /if");
    check_rejected("each without param", "{{#each}}x{{/each}}", context, "#each takes exactly one argument");
    check_rejected("each two params", "{{#each tags items}}x{{/each}}", context, "#each takes exactly one argument");
    check_rejected("each hash", "{{#each tags key=1}}x{{/each}}", context, "#each takes no hash arguments");
    check_rejected("else at top", "a{{else}}b", context, "unexpected else");
    check_rejected("second else", "{{#if tags}}x{{else}}y{{else}}z{{/if}}", context, "unexpected else");
    check("else if", "{{#if empty}}x{{else if items}}y{{/if}}", context, true, true, "y");
    check_rejected("unknown data variable", "{{#each tags}}{{@level}}{{/each}}", context, "Unknown data variable: only @root, and @index, @key, @first and @last after any ../");
    check_rejected("root after ../", "{{#each tags}}{{@../root.title}}{{/each}}", context, "Unknown data variable: only @root, and @index, @key, @first and @last after any ../");
    check_rejected("root path ends in a dot", "{{@root.}}", context, "Invalid characted in segment");
}
