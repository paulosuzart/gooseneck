// Rendered templates. Goose has no test runner in this release: each case
// asserts, then prints its name. scripts/test.sh compares that list with
// test/expected/render.out.
import gooseneck from "..";

struct City { name: const u8[:] }

struct Address {
    street: const u8[:],
    city: City,
}

struct Greeting {
    name: const u8[:],
    age: i64,
    address: Address,
    special: const u8[:],
}

fn check(label: const u8[:], template: const u8[:], context: const Greeting&, want: const u8[:]) {
    let engine = gooseneck::get_engine(template);
    let out, err = gooseneck::render(engine, context);
    if err.len > 0 || out != want {
        print(label);
        print("err: ", err);
        print("got:\n", out);
        print("want:\n", want);
        assert(false);
    }
    print(label);
}

fn check_rejected(label: const u8[:], template: const u8[:], context: const Greeting&, want: const u8[:]) {
    let engine = gooseneck::get_engine(template);
    let out, err = gooseneck::render(engine, context);
    if err != want || out.len != 0 {
        print(label);
        print("err:\n", err);
        print("want:\n", want);
        print("out:\n", out);
        assert(false);
    }
    print(label);
}

fn main() {
    let context = Greeting {
        name: "John",
        age: 21,
        address: Address { street: "123 Main St", city: City { name: "Springfield" } },
        special: "& < > \" ' ` =",
    };

    check("fields", "hello {{name }}, {{age}}", context, "hello John, 21");
    check("nested with", "{{#with address}} street: {{street }}, {{#with city}}{{name}}{{/with}} {{/with}} hello name: {{name }}, idade: {{age}}", context, " street: 123 Main St, Springfield  hello name: John, idade: 21");
    check("adjacent tags", "{{#with address}}{{#with city}}{{name}}{{/with}}{{/with}}", context, "Springfield");
    check("back to parent", "{{#with address}}{{street}}{{/with}} {{name}}", context, "123 Main St John");
    check("dotted path", "{{address.city.name}}", context, "Springfield");
    check("dotted with", "{{#with address.city}}{{name}}{{/with}}", context, "Springfield");
    check("with result parent", "{{#with address.city}}{{../name}}{{/with}}", context, "John");
    check("current dot", "{{#with address}}{{./street}}{{/with}}", context, "123 Main St");
    check("parent path", "{{#with address}}{{../name}}{{/with}}", context, "John");
    check("parent twice", "{{#with address}}{{#with city}}{{../../name}}{{/with}}{{/with}}", context, "John");
    check("parent at root", "a{{../name}}b", context, "ab");
    check("html escape", "x {{special}} y", context, "x &amp; &lt; &gt; &quot; &#x27; &#x60; &#x3D; y");
    check("raw triple", "x {{{ special }}} y", context, "x & < > \" ' ` = y");
    check("missing field", "a{{missing}}b", context, "ab");
    check("unknown with", "{{#with gone}}HIDDEN{{/with}}after", context, "after");
    check("scalar with", "{{#with age}}HIDDEN{{/with}}{{age}}", context, "21");
    check("trailing text", "{{name}}!", context, "John!");

    // Escaped mustaches, as handlebars.js 4.7.10 renders them: \{{ writes
    // the text up to the next mustache as it is, \\{{ one backslash.
    check("escaped mustache", "\\{{name}}", context, "{{name}}");
    check("escaped inside text", "a\\{{name}}b", context, "a{{name}}b");
    check("escaped then mustache", "\\{{name}} {{name}}", context, "{{name}} John");
    check("two escaped", "\\{{name}} \\{{age}} {{age}}", context, "{{name}} {{age}} 21");
    check("escaped backslash", "\\\\{{name}}", context, "\\John");
    check("escaped then escaped backslash", "\\{{name}}\\\\{{age}}", context, "{{name}}\\21");
    check("three backslashes", "x\\\\\\{{name}}", context, "x\\\\John");
    check("escaped triple", "\\{{{name}}}", context, "{{{name}}}");
    check("escaped unclosed", "a\\{{name", context, "a{{name");
    check("escaped comment", "\\{{!c}}{{name}}", context, "{{!c}}John");
    check("escaped block", "\\{{#with address}}x", context, "{{#with address}}x");
    check("trailing backslash", "{{name}}\\", context, "John\\");
    check_rejected("empty template", "", context, "Must not be empty");
    check_rejected("extra with", "{{#with address}}{{street}}{{/with}}{{/with}}", context, "unexpected /with");
    check_rejected("bad path", "{{name!}}", context, "Invalid characted in segment");
    check_rejected("bad with path", "{{#with name!}}x{{/with}}", context, "Invalid characted in segment");
    check_rejected("keyword in path", "{{foo.true}}", context, "true, false, null, or undefined allowed only at the beginning of the path");
    check_rejected("empty expression", "{{}}", context, "Has 0 length");
}
