// A usage example of gooseneck inside an HTTP service, built on goose-http
// and plod. GET /hello/:name answers a small HTML page rendered from
// hello.html.hbs (beside this file) with a typed context, HelloPage. Each
// worker loads the template into a gooseneck::Engine once, at startup, and
// keeps it in its AppState for the server's life.
//
//   goose build examples/http/main.goose -o examples/http/hello
//   examples/http/hello [port]      # default port 9997
//   curl http://localhost:9997/hello/Paulo
//
// goose run cannot run it: its JIT has no threads. See README.md here.
import http from "github.com/kaitk/goose-http@v0.5.12";
import plod from "github.com/kaitk/plod@v0.5.9";
import handlebars from "../../gooseneck";
import .helpers;

const HTML: u8[24] = "text/html; charset=utf-8";

// The template's context: {{name}} at the top, {{#if first}} for a line
// that only the worker's first request shows, and {{#with server}} for the
// nested fields, where {{../name}} reaches back to the visitor's name and
// {{ordinal requests}} calls the helper in helpers.goose, as {{now}} does.
// {{#each links}} lists the links.
struct ServerInfo {
    name: const u8[:],
    requests: i64,
}

struct Link {
    label: const u8[:],
    url: const u8[:],
}

struct HelloPage {
    name: const u8[:],
    first: bool,
    server: ServerInfo,
    links: const Link[:],
}

// A worker's state. page is compiled once, when the worker starts.
struct AppState {
    requests: u64,
    page: gooseneck::Engine,
}

fn handle(cx) {
    plod::routes(cx) { cx =>
        plod::get(cx, "/hello/:name") {
            cx.app.requests += 1;
            hello(cx, plod::param(cx, "name"), cx.app.requests, cx.app.page);
        };
    };
}


// Renders the page for name. Values in {{...}} are HTML-escaped, so the name
// from the URL cannot inject markup.
fn hello(cx, name: const u8[:], requests: u64, page: const gooseneck::Engine&) {
    guard name.len <= 20 else { plod::fail(cx, 400, "name_too_long"); }
    let links: Link[>..] = [
        Link { label: "Handlebars guide", url: "https://handlebarsjs.com/guide/" },
        Link { label: "goose-http", url: "https://github.com/kaitk/goose-http" },
        Link { label: "plod", url: "https://github.com/kaitk/plod" },
    ];
    let context = HelloPage {
        name: name,
        first: requests == 1,
        server: ServerInfo { name: "gooseneck on goose-http + plod", requests: requests as i64 },
        links: links,
    };
    let out: u8[>..] = [];
    gooseneck::render_into(page, context, out) { cx => {
        gooseneck::helper(cx, "ordinal") { gooseneck::answer(cx, helpers::ordinal(cx)); };
        gooseneck::helper(cx, "now") { gooseneck::answer(cx, helpers::now()); };
    }};
    plod::bytes(cx, 200, HTML, out);
}

// The page template. resource_dir() is this file's directory under goose
// run, and the executable's after goose build, which puts the executable
// beside this file.
fn page_template() -> u8[>..] {
    return str(resource_dir(), "hello.html.hbs");
}

thread_fn worker(cfg: http::Config) {
    // Globals are copied into each worker (spec §11.2), so each worker
    // compiles its own Engine, once, and keeps it for the server's life.
    var app = AppState { requests: 0, page: gooseneck::load_engine(page_template()) };
    if app.page.error.len > 0 {
        print("cannot start: ", app.page.error);
        return;
    }
    print("Serving http://localhost:", cfg.port, "/hello/:name");
    let e = plod::serve(cfg, app) { cx => handle(cx) };
    if e.code != 0 { http::report(e); }
}

fn main() {
    let a = args();
    var port: i64 = 9997;
    if a.len > 1 {
        let p, ok = parse_int(a[1]);
        if ok { port = p; }
    }
    http::exit_on_error(http::stop_on_signals());
    let cfg = http::Config { port: port as i32, workers: 2, .. };
    http::run(cfg, worker);
}
