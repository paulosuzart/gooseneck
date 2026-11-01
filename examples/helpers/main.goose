// Helpers and block helpers: registered in a trailing block or a named
// function, with arguments, hash arguments, subexpressions, state kept in
// your locals, a helper that shadows a field, lookup, block parameters,
// the inverse of a block, a raw block, and the errors a render gives
// before it writes. See README.md beside this file for the walkthrough.
// Run it from the repository root:
//
//   goose run examples/helpers/main.goose
//
// scripts/test.sh runs it and compares its output with expected.out.
import gooseneck from "../..";

struct Book { title: const u8[:], year: i64, cents: i64 }

struct Shelf {
    owner: const u8[:],
    title: const u8[:],
    books: const Book[:],
    ages: const i64[:],
    empty: const Book[:],
}

// The first param in upper case, made in cx.text, which lives until the
// render ends; anything but a string is Null.
fn shout(cx: gooseneck::HelperContext&) -> json::Value {
    match gooseneck::param(cx, 0) {
        Str s => {
            let start = cx.text.len;
            for c in s.s {
                if c >= 'a' && c <= 'z' { cx.text.push(c - 32); } else { cx.text.push(c); }
            }
            return json::Value.Str { s: cx.text[start..] };
        },
        _ => { return json::Value.Null; },
    }
}

// Whether the year in param 0 is before 1900.
fn older(cx: gooseneck::HelperContext&) -> json::Value {
    match gooseneck::param(cx, 0) {
        Int year => { return json::Value.Bool { v: year.v < 1900 }; },
        _ => { return json::Value.Bool { v: false }; },
    }
}

// Cents as "12.50 EUR", with the currency from the hash argument.
fn price(cx: gooseneck::HelperContext&) -> json::Value {
    let start = cx.text.len;
    match gooseneck::param(cx, 0) {
        Int c => {
            cx.text.append(str(c.v / 100, "."));
            if c.v % 100 < 10 { cx.text.push('0'); }
            cx.text.append(str(c.v % 100));
        },
        _ => {},
    }
    match gooseneck::hash_arg(cx, "currency") {
        Str s => { cx.text.append(str(" ", s.s)); },
        _ => {},
    }
    return json::Value.Str { s: cx.text[start..] };
}

// Helpers shared by several renders: a named function, its reg untyped.
fn book_helpers(reg) {
    gooseneck::helper(reg, "shout") { cx => gooseneck::answer(cx, shout(cx)); };
    gooseneck::helper(reg, "older") { cx => gooseneck::answer(cx, older(cx)); };
}

// Block helpers: generic over the body B, so always a named function.
fn blocks<B>(reg) {
    // A raw block's body is its text, as it is: {{{{verbatim}}}}...{{{{/verbatim}}}}.
    gooseneck::block_helper(reg, "verbatim") { cx =>
        B(gooseneck::this());
    };
    // The body on the block's own context, inside <b>.
    gooseneck::block_helper(reg, "bold") { cx =>
        cx.out.append("<b>");
        B(gooseneck::this());
        cx.out.append("</b>");
    };
    // The body on each item of param 0, with @index, @key, @first, @last
    // and block parameters; the inverse, after {{else}}, when there is none.
    gooseneck::block_helper(reg, "list") { cx =>
        let count = gooseneck::length(gooseneck::param(cx, 0));
        if count == 0 {
            B(gooseneck::inverse(gooseneck::this()));
            return;
        }
        cx.out.append("<ul>");
        for k in count {
            cx.out.append("<li>");
            B(gooseneck::element(0, k));
            cx.out.append("</li>");
        }
        cx.out.append("</ul>");
    };
}

fn section(title: const u8[:]) {
    print("== ", title);
}

fn main() {
    let books: Book[>..] = [
        Book { title: "Frankenstein", year: 1818, cents: 1250 },
        Book { title: "Dune", year: 1965, cents: 999 },
    ];
    let ages: i64[>..] = [205, 59];
    let none: Book[>..] = [];
    let shelf = Shelf { owner: "Ada", title: "field", books: books, ages: ages, empty: none };

    section("helpers in a trailing block, state in a local");
    let page = gooseneck::get_engine(embed_file("shelf.hbs"));
    if page.error.len > 0 { print(page.error); return; }
    let out: u8[>..] = [];
    var calls: i64 = 0;
    let nodes, err = gooseneck::render_into(page, shelf, out) { reg =>
        gooseneck::helper(reg, "shout") { cx => gooseneck::answer(cx, shout(cx)); };
        gooseneck::helper(reg, "older") { cx => gooseneck::answer(cx, older(cx)); };
        gooseneck::helper(reg, "price") { cx => gooseneck::answer(cx, price(cx)); };
        gooseneck::helper(reg, "next") { cx =>
            calls += 1;
            gooseneck::answer(cx, json::Value.Int { v: calls });
        };
    };
    if err.len > 0 { print(err); return; }
    print(out);

    section("the same helpers in a named function");
    let short = gooseneck::get_engine("{{#each books}}{{shout title}}{{#if (older year)}} (classic){{/if}}; {{/each}}");
    let short_out, short_err = gooseneck::render(short, shelf, book_helpers);
    print(short_out, short_err);

    section("a helper wins over a field of its name; ./ forces the field");
    let shadow = gooseneck::get_engine("{{title}} / {{./title}}");
    let shadow_out, shadow_err = gooseneck::render(shadow, shelf) { reg =>
        gooseneck::helper(reg, "title") { cx => gooseneck::answer(cx, json::Value.Str { s: "helper" }); };
    };
    print(shadow_out, shadow_err);

    section("lookup, by index from another list, and stepping into what it finds");
    let looked = gooseneck::get_engine("{{#each books}}{{title}} is {{lookup ../ages @index}}; {{/each}}{{#with (lookup books 1)}}second: {{title}}{{/with}}");
    let looked_out, looked_err = gooseneck::render(looked, shelf);
    print(looked_out, looked_err);

    section("block helpers, block parameters and the inverse");
    let listed = gooseneck::get_engine("{{#list books as |book i|}}{{#bold}}{{book.title}}{{/bold}} #{{i}}{{/list}} {{#list empty}}x{{else}}nothing{{/list}}");
    let listed_out, listed_err = gooseneck::render(listed, shelf, book_helpers, blocks);
    print(listed_out, listed_err);

    section("a raw block hands its helper the text unparsed");
    let raw = gooseneck::get_engine("{{{{verbatim}}}}{{owner}} is not parsed{{{{/verbatim}}}}, {{owner}} is");
    let raw_out, raw_err = gooseneck::render(raw, shelf, book_helpers, blocks);
    print(raw_out, raw_err);

    section("errors, found before anything is written");
    let twice_out, twice_err = gooseneck::render(short, shelf) { reg =>
        gooseneck::helper(reg, "shout") { cx => gooseneck::answer(cx, shout(cx)); };
        gooseneck::helper(reg, "shout") { cx => gooseneck::answer(cx, shout(cx)); };
    };
    print(twice_err, " (wrote ", twice_out.len, " bytes)");
    let typo = gooseneck::get_engine("{{#typo}}x{{/typo}}");
    let typo_out, typo_err = gooseneck::render(typo, shelf, book_helpers, blocks);
    print(typo_err, " (wrote ", typo_out.len, " bytes)");
}
