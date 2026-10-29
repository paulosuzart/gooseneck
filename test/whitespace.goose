// Whitespace control: ~ in tags, and standalone lines, as in
// https://handlebarsjs.com/guide/expressions.html#whitespace-control. Every
// expected output below is what handlebars.js 4.7.10 renders for the same
// template and data. Each case asserts, then prints its name;
// scripts/test.sh compares that list with test/expected/whitespace.out.
import gooseneck from "..";

struct City { name: const u8[:] }

struct Address {
    street: const u8[:],
    city: City,
}

struct Person {
    name: const u8[:],
    age: i64,
    address: Address,
}

fn show(s: const u8[:]) -> u8[>..] {
    let out: u8[>..] = [];
    for c in s {
        if c == '\n' { out.append("\\n"); } else if c == '\r' { out.append("\\r"); } else if c == '\t' { out.append("\\t"); } else { out.push(c); }
    }
    return out;
}

fn check(label: const u8[:], template: const u8[:], context: const Person&, want: const u8[:]) {
    let engine = gooseneck::get_engine(template);
    let out, err = gooseneck::render(engine, context);
    if err.len > 0 || out != want {
        print(label);
        print("err:  ", err);
        print("got:  ", show(out));
        print("want: ", show(want));
        assert(false);
    }
    print(label);
}

fn main() {
    let context = Person {
        name: "John",
        age: 21,
        address: Address { street: "123 Main St", city: City { name: "Springfield" } },
    };

    check("tilde both sides",
          "a  {{~name~}}  b",
          context, "aJohnb");
    check("tilde left",
          "a \n {{~name}} b",
          context, "aJohn b");
    check("tilde right",
          "a {{name~}} \n b",
          context, "a Johnb");
    check("tilde eats blank lines",
          "x\n\n  {{~name~}}\n\n  y",
          context, "xJohny");
    check("tilde raw triple",
          "a {{~{name}~}} b",
          context, "aJohnb");
    check("tilde with spaces in tag",
          "a {{~ name ~}} b",
          context, "aJohnb");
    check("tilde block open and close",
          "<p>\n  {{~#with address~}}\n  {{street}}\n  {{~/with~}}\n</p>",
          context, "<p>123 Main St</p>");
    check("tilde inside block",
          "{{#with address~}}   {{street}}   {{~/with}}",
          context, "123 Main St");
    check("tilde only outside block",
          "[ {{~#with address}} {{street}} {{/with~}} ]",
          context, "[ 123 Main St ]");
    check("tilde next to tag",
          "{{name~}}{{age}}",
          context, "John21");
    check("standalone block lines",
          "<ul>\n{{#with address}}\n  <li>{{street}}</li>\n{{/with}}\n</ul>\n",
          context, "<ul>\n  <li>123 Main St</li>\n</ul>\n");
    check("standalone indented nested",
          "<div>\n    {{#with address}}\n      {{#with city}}\n      <b>{{name}}</b>\n      {{/with}}\n    {{/with}}\n</div>",
          context, "<div>\n      <b>Springfield</b>\n</div>");
    check("standalone tabs and trailing spaces",
          "a\n\t{{#with address}}  \n{{street}}\n\t {{/with}}\t\nb",
          context, "a\n123 Main St\nb");
    check("standalone crlf",
          "a\r\n  {{#with address}}\r\n{{street}}\r\n  {{/with}}\r\nb",
          context, "a\r\n123 Main St\r\nb");
    check("standalone at start and end",
          "{{#with address}}\n{{street}}\n{{/with}}",
          context, "123 Main St\n");
    check("standalone at end with newline",
          "{{#with address}}\n{{street}}\n{{/with}}\n",
          context, "123 Main St\n");
    check("standalone indented at start",
          "  {{#with address}}  \n{{street}}\n  {{/with}}  ",
          context, "123 Main St\n");
    check("standalone empty body",
          "a\n{{#with address}}\n{{/with}}\nb",
          context, "a\nb");
    check("standalone comments",
          "a\n  {{! note }}\nb\n{{!-- long }} note --}}\nc",
          context, "a\nb\nc");
    check("comment alone",
          "{{! only a comment }}",
          context, "");
    check("inline comment",
          "a {{! x }} b",
          context, "a  b");
    check("tilde comment",
          "a {{~! c ~}} b",
          context, "ab");
    check("inline block untouched",
          "a {{#with address}}{{street}}{{/with}} b\n",
          context, "a 123 Main St b\n");
    check("block with text on its line",
          "x {{#with address}}\n{{street}}\n{{/with}} y",
          context, "x \n123 Main St\n y");
    check("two block tags on one line",
          "{{#with address}}{{#with city}}\n{{name}}\n{{/with}}{{/with}}\n",
          context, "\nSpringfield\n\n");
    check("mustache alone on a line",
          "a\n  {{name}}\nb",
          context, "a\n  John\nb");
    check("blank lines kept",
          "a\n\n{{#with address}}\n\n{{street}}\n\n{{/with}}\n\nb",
          context, "a\n\n\n123 Main St\n\n\nb");
    check("standalone and tilde together",
          "a\n  {{#with address~}}\n  {{street}}\n  {{~/with}}\nb",
          context, "a\n123 Main Stb");

    let unclosed = gooseneck::get_engine("a {{name");
    assert(unclosed.error == "unclosed tag");
    print("unclosed tag");
    let unclosed_comment = gooseneck::get_engine("a {{!-- note }");
    assert(unclosed_comment.error == "unclosed tag");
    print("unclosed comment");
}
