// User block helpers: a body on the block's context, twice, on a param,
// on each item of a custom iterator (with @index, @key, @first, @last and
// block parameters), forwards and backwards, the inverse, hash arguments,
// escaping, nesting, else chains, raw blocks, and the compile errors. The block
// helpers below mirror the handlebars.js ones in the comment of each; every
// expected output is what handlebars.js 4.7.10 renders for the same
// template and data, except the errors, which are gooseneck's messages.
// Each case asserts, then prints its name; scripts/test.sh compares that
// list with test/expected/blocks.out.
import handlebars from "../gooseneck";

struct Item { name: const u8[:], price: i64 }

struct Person { first: const u8[:], last: const u8[:] }

struct Shop {
    title: const u8[:],
    tags: const u8[:][:],
    items: const Item[:],
    owner: Person,
    empty: const i64[:],
    flag: bool,
    off: bool,
}

// The same data as Shop, as JSON, plus an object to iterate.
const CONTEXT_JSON: const u8[:] = "{\"title\":\"Shop <1>\",\"tags\":[\"new\",\"sale\"],\"items\":[{\"name\":\"pen\",\"price\":2},{\"name\":\"ink\",\"price\":0}],\"owner\":{\"first\":\"Ada\",\"last\":\"Lovelace\"},\"prices\":{\"pen\":2,\"ink\":0.5},\"empty\":[],\"flag\":true,\"off\":false}";

// No expression helpers.
fn helpers(cx) {}

// Appends a string value, HTML-escaped or as it is.
fn append_string(out: u8[>..]&, value: json::Value, escaped: bool) {
    match value {
        Str t => {
            if escaped { gooseneck::append_escaped(out, t.s); } else { out.append(t.s); }
        },
        _ => {},
    }
}

// Whether a value is the boolean true.
fn is_true(value: json::Value) -> bool {
    match value {
        Bool b => { return b.v; },
        _ => { return false; },
    }
}

fn blocks<B>(cx) {
    // bold: "<b>" + options.fn(this) + "</b>"
    gooseneck::block_helper(cx, "bold") {
        cx.out.append("<b>");
        B(gooseneck::this());
        cx.out.append("</b>");
    };
    // raw: options.fn(this)
    gooseneck::block_helper(cx, "raw") {
        B(gooseneck::this());
    };
    // twice: options.fn(this) + options.fn(this)
    gooseneck::block_helper(cx, "twice") {
        B(gooseneck::this());
        B(gooseneck::this());
    };
    // list: "<ul>" + each item as "<li>" + options.fn(item, { data, blockParams: [item, key] }) + "</li>" + "</ul>"
    gooseneck::block_helper(cx, "list") {
        cx.out.append("<ul>");
        for k in gooseneck::length(gooseneck::param(cx, 0)) {
            cx.out.append("<li>");
            B(gooseneck::element(0, k));
            cx.out.append("</li>");
        }
        cx.out.append("</ul>");
    };
    // backwards: options.fn(item, { data, blockParams: [item, key] }) for each item, last first
    gooseneck::block_helper(cx, "backwards") {
        var k = gooseneck::length(gooseneck::param(cx, 0));
        while k > 0 {
            k -= 1;
            B(gooseneck::element(0, k));
        }
    };
    // when: v === true ? options.fn(this) : options.inverse(this)
    gooseneck::block_helper(cx, "when") {
        if is_true(gooseneck::param(cx, 0)) {
            B(gooseneck::this());
        } else {
            B(gooseneck::inverse(gooseneck::this()));
        }
    };
    // scope: options.fn(v, { blockParams: [v] })
    gooseneck::block_helper(cx, "scope") {
        B(gooseneck::param(0));
    };
    // tag: "<" + name + " class=\"" + escape(class) + "\">" + options.fn(this) + "</" + name + ">"
    gooseneck::block_helper(cx, "tag") {
        cx.out.append("<");
        append_string(cx.out, gooseneck::hash_arg(cx, "name"), false);
        cx.out.append(" class=\"");
        append_string(cx.out, gooseneck::hash_arg(cx, "class"), true);
        cx.out.append("\">");
        B(gooseneck::this());
        cx.out.append("</");
        append_string(cx.out, gooseneck::hash_arg(cx, "name"), false);
        cx.out.append(">");
    };
    // label: escape(v) + ": " + options.fn(this)
    gooseneck::block_helper(cx, "label") {
        append_string(cx.out, gooseneck::param(cx, 0), true);
        cx.out.append(": ");
        B(gooseneck::this());
    };
    // try: v is an object ? options.fn(v, { blockParams: [v] }) : "missing"
    gooseneck::block_helper(cx, "try") {
        if !B(gooseneck::param(0)) { cx.out.append("missing"); }
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

// Renders template with the struct, the JSON, or both; each must give want.
fn check(label: const u8[:], template: const u8[:], context: const Shop&, use_struct: bool, use_json: bool, want: const u8[:]) {
    let engine = gooseneck::get_engine(template, blocks);
    if use_struct {
        let out, err = gooseneck::render(engine, context, helpers, blocks);
        if err.len > 0 || out != want { fail(label, "struct", err, out, want); }
    }
    if use_json {
        let out: u8[>..] = [];
        let err = gooseneck::render_json(engine, CONTEXT_JSON, out, helpers, blocks);
        if err.len > 0 || out != want { fail(label, "json", err, out, want); }
    }
    print(label);
}

// Compiles template with the block helpers, or without them, and renders
// it; the render must fail with want.
fn check_rejected(label: const u8[:], template: const u8[:], with_blocks: bool, context: const Shop&, want: const u8[:]) {
    let engine = if with_blocks { gooseneck::get_engine(template, blocks) } else { gooseneck::get_engine(template) };
    let out, err = gooseneck::render(engine, context, helpers, blocks);
    if err != want || out.len != 0 { fail(label, "error", err, out, want); }
    print(label);
}

fn main() {
    let tags: const u8[:][>..] = ["new", "sale"];
    let items: Item[>..] = [Item { name: "pen", price: 2 }, Item { name: "ink", price: 0 }];
    let nothing: i64[>..] = [];
    let context = Shop {
        title: "Shop <1>",
        tags: tags,
        items: items,
        owner: Person { first: "Ada", last: "Lovelace" },
        empty: nothing,
        flag: true,
        off: false,
    };

    check("bold", "{{#bold}}{{title}}{{/bold}}", context, true, true, "<b>Shop &lt;1&gt;</b>");
    check("twice", "{{#twice}}x{{/twice}}", context, true, true, "xx");
    check("list", "{{#list tags}}{{this}}{{/list}}", context, true, true, "<ul><li>new</li><li>sale</li></ul>");
    check("list data", "{{#list items}}{{name}}={{price}} {{@index}}{{#if @first}}F{{/if}}{{#if @last}}L{{/if}}{{/list}}", context, true, true, "<ul><li>pen=2 0F</li><li>ink=0 1L</li></ul>");
    check("list object", "{{#list prices}}{{@key}}:{{this}}{{/list}}", context, false, true, "<ul><li>pen:2</li><li>ink:0.5</li></ul>");
    check("list block params", "{{#list items as |item i|}}{{i}}.{{item.name}}{{/list}}", context, true, true, "<ul><li>0.pen</li><li>1.ink</li></ul>");
    check("list parent data", "{{#each tags}}{{#list ../items}}{{@../index}}{{name}}{{/list}}{{/each}}", context, true, true, "<ul><li>0pen</li><li>0ink</li></ul><ul><li>1pen</li><li>1ink</li></ul>");
    check("list empty", "{{#list empty}}x{{/list}}", context, true, true, "<ul></ul>");
    check("when true", "{{#when flag}}yes{{else}}no{{/when}}", context, true, true, "yes");
    check("when inverse", "{{#when off}}yes{{else}}no{{/when}}", context, true, true, "no");
    check("scope", "{{#scope owner}}{{first}} {{../title}}{{/scope}}", context, true, true, "Ada Shop &lt;1&gt;");
    check("scope block param", "{{#scope owner as |o|}}{{o.last}}{{/scope}}", context, true, true, "Lovelace");
    check("hash", "{{#tag name=\"em\" class=\"a<b\"}}{{title}}{{/tag}}", context, true, true, "<em class=\"a&lt;b\">Shop &lt;1&gt;</em>");
    check("backwards", "{{#backwards tags}}{{@index}}{{this}}{{#if @last}}!{{/if}} {{/backwards}}", context, true, true, "1sale! 0new ");
    check("missing context", "{{#try missing}}x{{/try}}", context, true, true, "missing");
    check("found context", "{{#try owner}}{{first}}{{/try}}", context, true, true, "Ada");
    check("nested", "{{#bold}}{{#list tags}}{{#bold}}{{this}}{{/bold}}{{/list}}{{/bold}}", context, true, true, "<b><ul><li><b>new</b></li><li><b>sale</b></li></ul></b>");
    check("else block helper", "{{#if off}}A{{else bold}}B{{/if}}", context, true, true, "<b>B</b>");
    check("else chain of helpers", "{{#when off}}A{{else when flag}}B{{/when}}", context, true, true, "B");
    check("lookup param", "{{#list (lookup . \"tags\")}}{{this}}{{/list}}", context, true, true, "<ul><li>new</li><li>sale</li></ul>");
    check("this path", "{{#bold}}{{this.title}}{{/bold}}", context, true, true, "<b>Shop &lt;1&gt;</b>");
    check("standalone", "{{#bold}}\n  x\n{{/bold}}\n", context, true, true, "<b>  x\n</b>");
    check("escaped param", "{{#label title}}!{{/label}}", context, true, true, "Shop &lt;1&gt;: !");
    check("this keeps the frame", "{{#with owner}}{{#bold}}{{first}}{{../title}}{{/bold}}{{/with}}", context, true, true, "<b>AdaShop &lt;1&gt;</b>");
    check("params across helpers", "{{#list items as |item|}}{{#scope ../owner as |o|}}{{item.name}}{{o.first}}{{/scope}}{{/list}}", context, true, true, "<ul><li>penAda</li><li>inkAda</li></ul>");
    check("each param in helper", "{{#each items as |item|}}{{#bold}}{{item.name}}{{/bold}}{{/each}}", context, true, true, "<b>pen</b><b>ink</b>");

    // Raw blocks: {{{{helper}}}}...{{{{/helper}}}} hands the helper its
    // content as text.
    check("raw block", "{{{{raw}}}} {{title}} {{{{/raw}}}}", context, true, true, " {{title}} ");
    check("raw block of tags", "{{{{raw}}}}{{#if x}}{{/if}}{{{{/raw}}}}{{title}}", context, true, true, "{{#if x}}{{/if}}Shop &lt;1&gt;");
    check("raw block helper", "a{{{{bold}}}}{{title}}{{{{/bold}}}}b", context, true, true, "a<b>{{title}}</b>b");
    check("nested raw block", "{{{{raw}}}}{{{{raw}}}}x{{{{/raw}}}}{{{{/raw}}}}", context, true, true, "{{{{raw}}}}x{{{{/raw}}}}");
    check("other raw block inside", "{{{{raw}}}}{{{{bold}}}}x{{{{/bold}}}}{{{{/raw}}}}", context, true, true, "{{{{bold}}}}x{{{{/bold}}}}");
    check("standalone raw block", "{{{{raw}}}}\n{{x}}\n{{{{/raw}}}}\n", context, true, true, "{{x}}\n");
    check("standalone raw lines", "a\n{{{{raw}}}}\nb\n{{{{/raw}}}}\nc", context, true, true, "a\nb\nc");
    check("empty raw block", "{{{{raw}}}}{{{{/raw}}}}", context, true, true, "");
    check("spaced raw tag", "{{{{ raw }}}}x{{{{/raw}}}}", context, true, true, "x");
    check("backslash in raw block", "{{{{raw}}}}\\{{x}}{{{{/raw}}}}", context, true, true, "\\{{x}}");
    check("raw if", "{{{{if title}}}}{{x}}{{{{/if}}}}", context, true, true, "{{x}}");
    check("raw else", "{{{{raw}}}}{{x}}{{else}}y{{{{/raw}}}}", context, true, true, "{{x}}{{else}}y");
    check("raw braces", "{{{{raw}}}}}}}}{{{{/raw}}}}", context, true, true, "}}}}");
    check_rejected("unclosed raw block", "{{{{raw}}}}x", true, context, "unclosed #raw");
    check_rejected("raw block closed by another", "{{{{raw}}}}x{{{{/bold}}}}", true, context, "unexpected /bold");
    check_rejected("unknown raw block", "{{{{nope}}}}x{{{{/nope}}}}", true, context, "unknown block helper #nope");
    check_rejected("unclosed raw tag", "{{{{raw}}x", true, context, "unclosed tag");

    check_rejected("unknown block helper", "{{#nope}}x{{/nope}}", true, context, "unknown block helper #nope");
    check_rejected("unclosed block helper", "{{#bold}}x", true, context, "unclosed #bold");
    check_rejected("compiled without the block helpers", "{{#bold}}x{{/bold}}", false, context, "unknown block helper #bold");
    check_rejected("params on if still rejected", "{{#if flag as |f|}}x{{/if}}", true, context, "#if takes no block parameters");
}
