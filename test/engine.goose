// Engines as values: load_engine reads and compiles a template file once,
// and the Engine it returns is kept in a struct, passed around, copied, and
// rendered with many contexts, struct and JSON alike. A missing, empty or
// malformed file comes back as the engine's error. Fixtures sit in
// test/fixtures/, found through resource_dir(), which is the directory of
// this source in a goose run.
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

// What an HTTP handler's state might look like: the engines are compiled
// once at startup and live as long as the state.
struct Service {
    renders: i64,
    page: gooseneck::Engine,
    banner: gooseneck::Engine,
}

fn fixture(name: const u8[:]) -> u8[>..] {
    return str(resource_dir(), "fixtures/", name);
}

fn fail(label: const u8[:], got: const u8[:]) {
    print(label);
    print("got: ", got);
    assert(false);
}

fn expect(label: const u8[:], got: const u8[:], want: const u8[:]) {
    if got != want { print("want: ", want); fail(label, got); }
    print(label);
}

// Builds the state, as a server's startup would.
fn start() -> Service {
    return Service {
        renders: 0,
        page: gooseneck::load_engine(fixture("greeting.hbs")),
        banner: gooseneck::get_engine("[{{name}}]"),
    };
}

// Renders a page from the engine kept in service.
fn handle(service: Service&, who: const Greeting&) -> u8[>..] {
    service.renders += 1;
    let out: u8[>..] = [];
    gooseneck::render_into(service.page, who, out);
    gooseneck::render_into(service.banner, who, out);
    return out;
}

// An engine taken by reference renders as the original does.
fn render_with(engine: const gooseneck::Engine&, who: const Greeting&) -> u8[>..] {
    let out: u8[>..] = [];
    gooseneck::render_into(engine, who, out);
    return out;
}

// load_engine must return an engine whose error has want_prefix and
// want_suffix, and which renders nothing.
fn check_load_error(label: const u8[:], file: const u8[:], want_prefix: const u8[:], want_suffix: const u8[:]) {
    let engine = gooseneck::load_engine(fixture(file));
    let john = Greeting { name: "John", age: 21, address: Address { street: "", city: City { name: "" } }, special: "" };
    let out, err = gooseneck::render(engine, john);
    if !starts_with(engine.error, want_prefix) || !ends_with(engine.error, want_suffix) || err != engine.error || out.len != 0 {
        fail(label, engine.error);
    }
    print(label);
}

fn main() {
    let john = Greeting {
        name: "John",
        age: 21,
        address: Address { street: "123 Main St", city: City { name: "Springfield" } },
        special: "&",
    };
    let mary = Greeting {
        name: "Mary",
        age: 34,
        address: Address { street: "742 Evergreen Terrace", city: City { name: "Shelbyville" } },
        special: "<",
    };

    let engine = gooseneck::load_engine(fixture("greeting.hbs"));
    if engine.error.len > 0 { fail("load_engine", engine.error); }
    expect("file template", render_with(engine, john), "hello John, 21! Springfield (John)");
    expect("same engine, second context", render_with(engine, mary), "hello Mary, 34! Shelbyville (Mary)");
    expect("same engine, render again", render_with(engine, john), "hello John, 21! Springfield (John)");

    let json_out: u8[>..] = [];
    let json_err = gooseneck::render_json_file(engine, fixture("greeting.json"), json_out);
    if json_err.len > 0 { fail("same engine, JSON context", json_err); }
    expect("same engine, JSON context", json_out, "hello John, 21! Springfield (John)");
    let inline_out: u8[>..] = [];
    let inline_err = gooseneck::render_json(engine, "{\"name\": \"Ana\", \"age\": 7.5, \"address\": {\"city\": {\"name\": \"Lima\"}}}", inline_out);
    if inline_err.len > 0 { fail("same engine, inline JSON", inline_err); }
    expect("same engine, inline JSON", inline_out, "hello Ana, 7.5! Lima (Ana)");

    var service = start();
    if service.page.error.len > 0 || service.banner.error.len > 0 { fail("engines in a struct", service.page.error); }
    expect("engines in a struct", handle(service, john), "hello John, 21! Springfield (John)[John]");
    expect("engines in a struct, again", handle(service, mary), "hello Mary, 34! Shelbyville (Mary)[Mary]");
    if service.renders != 2 { fail("engines in a struct, count", ""); }

    // An engine owns its text: the template it was compiled from can go.
    var template: u8[>..] = [];
    template.append("<{{name}}>");
    let owned = gooseneck::get_engine(template);
    template.clear();
    template.append("XXXXXXXXXX");
    expect("engine owns its text", render_with(owned, mary), "<Mary>");

    let copied = copy(service.banner);
    expect("copied engine", render_with(copied, mary), "[Mary]");

    check_load_error("missing file", "missing.hbs", "cannot read template ", "fixtures/missing.hbs");
    check_load_error("empty file", "empty.hbs", "", "fixtures/empty.hbs: Must not be empty");
    check_load_error("parse error in file", "bad.hbs", "", "fixtures/bad.hbs: unexpected /with");

    let bad = gooseneck::get_engine("{{name!}}");
    let bad_out: u8[>..] = [];
    let bad_json_err = gooseneck::render_json(bad, "{}", bad_out);
    if bad.error != "Invalid characted in segment" || bad_json_err != bad.error || bad_out.len != 0 { fail("template error", bad.error); }
    print("template error");
}
