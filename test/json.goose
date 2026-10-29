// Rendering with a context parsed from JSON. The HANDOVER table renders the
// same with the Greeting struct and with test/fixtures/greeting.json, the
// same data as JSON. Then the JSON data model (escapes, Int vs Num, true,
// false, null, arrays) and malformed JSON, which comes back as the error.
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

fn fixture(name: const u8[:]) -> u8[>..] {
    return str(resource_dir(), "fixtures/", name);
}

// Renders template with the struct and with the JSON file; both must give
// want.
fn check_same(label: const u8[:], template: const u8[:], context: const Greeting&, want: const u8[:]) {
    let path = fixture("greeting.json");
    let from_struct: u8[>..] = [];
    let from_json: u8[>..] = [];
    let t = gooseneck::get_engine(template);
    let err = t.error;
    gooseneck::render_into(t, context, from_struct);
    let json_err = gooseneck::render_json_file(t, path, from_json);
    if err.len > 0 || json_err.len > 0 || from_struct != want || from_json != want {
        print(label);
        print("err: ", err, json_err);
        print("struct:\n", from_struct);
        print("json:\n", from_json);
        print("want:\n", want);
        assert(false);
    }
    print(label);
}

// Renders template with json_text as the context.
fn check_json(label: const u8[:], template: const u8[:], json_text: const u8[:], want: const u8[:]) {
    let out: u8[>..] = [];
    let t = gooseneck::get_engine(template);
    let err = t.error;
    let json_err = gooseneck::render_json(t, json_text, out);
    if err.len > 0 || json_err.len > 0 || out != want {
        print(label);
        print("err: ", err, json_err);
        print("got:\n", out);
        print("want:\n", want);
        assert(false);
    }
    print(label);
}

// json_text is malformed: render_json returns its error and writes nothing.
// The label and the message are printed, so test/expected/json.out pins the
// messages.
fn check_json_error(label: const u8[:], json_text: const u8[:]) {
    let out: u8[>..] = [];
    let t = gooseneck::get_engine("{{a}}");
    let err = t.error;
    let json_err = gooseneck::render_json(t, json_text, out);
    if err.len > 0 || json_err.len == 0 || !starts_with(json_err, "json: ") || out.len != 0 {
        print(label);
        print("err: ", err, json_err);
        print("out:\n", out);
        assert(false);
    }
    print(label, ": ", json_err);
}

fn main() {
    let context = Greeting {
        name: "John",
        age: 21,
        address: Address { street: "123 Main St", city: City { name: "Springfield" } },
        special: "& < > \" ' ` =",
    };

    check_same("fields", "hello {{name }}, {{age}}", context, "hello John, 21");
    check_same("nested with", "{{#with address}} street: {{street }}, {{#with city}}{{name}}{{/with}} {{/with}} hello name: {{name }}, idade: {{age}}", context, " street: 123 Main St, Springfield  hello name: John, idade: 21");
    check_same("adjacent tags", "{{#with address}}{{#with city}}{{name}}{{/with}}{{/with}}", context, "Springfield");
    check_same("back to parent", "{{#with address}}{{street}}{{/with}} {{name}}", context, "123 Main St John");
    check_same("dotted path", "{{address.city.name}}", context, "Springfield");
    check_same("dotted with", "{{#with address.city}}{{name}}{{/with}}", context, "Springfield");
    check_same("with result parent", "{{#with address.city}}{{../name}}{{/with}}", context, "John");
    check_same("current dot", "{{#with address}}{{./street}}{{/with}}", context, "123 Main St");
    check_same("parent path", "{{#with address}}{{../name}}{{/with}}", context, "John");
    check_same("parent twice", "{{#with address}}{{#with city}}{{../../name}}{{/with}}{{/with}}", context, "John");
    check_same("parent at root", "a{{../name}}b", context, "ab");
    check_same("html escape", "x {{special}} y", context, "x &amp; &lt; &gt; &quot; &#x27; &#x60; &#x3D; y");
    check_same("raw triple", "x {{{ special }}} y", context, "x & < > \" ' ` = y");
    check_same("missing field", "a{{missing}}b", context, "ab");
    check_same("unknown with", "{{#with gone}}HIDDEN{{/with}}after", context, "after");
    check_same("scalar with", "{{#with age}}HIDDEN{{/with}}{{age}}", context, "21");

    let data = "{\"s\": \"q\\\"b\\\\s\\/n\\nt\\tb\\bf\\fr\\r\\u00e9\\u20ac\\ud83d\\ude00\", \"int\": 21, \"neg\": -7, \"whole\": 2.0, \"half\": 1.5, \"exp\": 1e300, \"t\": true, \"f\": false, \"z\": null, \"list\": [1, \"two\", {\"k\": \"v\"}], \"obj\": {\"k\": \"v\", \"n\": {\"deep\": 3}}}";
    check_json("json string escapes", "{{{s}}}", data, "q\"b\\s/n\nt\tb\x08f\x0cr\r\xc3\xa9\xe2\x82\xac\xf0\x9f\x98\x80");
    check_json("json numbers", "{{int}} {{neg}} {{whole}} {{half}} {{exp}}", data, "21 -7 2 1.5 1e+300");
    check_json("json literals", "[{{t}}] [{{f}}] [{{z}}]", data, "[true] [false] []");
    check_json("json array writes nothing", "a{{list}}b", data, "ab");
    check_json("json with object", "{{#with obj}}{{k}} {{n.deep}} {{../int}}{{/with}}", data, "v 3 21");
    check_json("json with skips", "{{#with list}}A{{/with}}{{#with z}}B{{/with}}{{#with t}}C{{/with}}{{#with half}}D{{/with}}.", data, ".");
    check_json("json root scalar", "a{{.}}b{{x}}", "\"hi\"", "ahib");

    check_json_error("missing value", "{\"a\": }");
    check_json_error("trailing comma", "{\"a\": 1,}");
    check_json_error("unterminated string", "{\"a\": \"x");
    check_json_error("bad escape", "{\"a\": \"\\x\"}");
    check_json_error("text after value", "{\"a\": 1} x");
    check_json_error("empty input", "");

    let out: u8[>..] = [];
    let t = gooseneck::get_engine("{{a}}");
    let err = t.error;
    let file_err = gooseneck::render_json_file(t, fixture("missing.json"), out);
    if err.len > 0 || !starts_with(file_err, "cannot read JSON ") || !ends_with(file_err, "fixtures/missing.json") {
        print("err: ", err, file_err);
        assert(false);
    }
    print("missing json file");
}
