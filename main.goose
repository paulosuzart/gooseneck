// gooseneck CLI: renders a Handlebars template file with contexts read from
// JSON, so the engine can be tried without writing or recompiling Goose
// code.
//
//   gooseneck render <template> <context.json>
//   gooseneck render <template> <folder> [-o <dir>]
//
// With one JSON file, the result goes to stdout, followed by a newline.
// With a folder, the template is rendered with each *.json file in it (not
// in its subfolders), in name order, and each result is written, as it
// is, to a file of its own: the JSON file's name without .json, plus the
// template's extension once a trailing .hbs is dropped. page.html.hbs and
// ana.json give ana.html; a template named x.hbs gives ana.out. The files
// go into <dir> with -o, created if missing, or else beside the JSON
// files. Each written file is reported on stderr as "wrote <path>".
//
// The template is compiled once. A template error stops everything. In a
// folder, a file that fails is reported on stderr with its name and the
// rest still render. Exit codes: 0 when everything rendered, 1 when
// anything failed, 2 for wrong arguments (with the usage).
//
// Build it, and run it from the repository root, for example:
//
//   goose build main.goose -o build/gooseneck
//   build/gooseneck render test/fixtures/greeting.hbs test/fixtures/greeting.json
//
// prints "hello John, 21! Springfield (John)". Relative paths resolve
// against the working directory. goose run main.goose -- render ... works
// too, and prints its own compile progress on stderr as well.
//
// The library is gooseneck.goose beside this file, which this program
// imports as a module of its own directory. An example of gooseneck inside
// an HTTP service is in examples/http/.
import gooseneck;

fn usage() {
    write_stderr("usage: gooseneck render <template> <context.json>\n");
    write_stderr("       gooseneck render <template> <folder> [-o <dir>]\n");
    write_stderr("  Renders the Handlebars template with a JSON file as its context, to stdout,\n");
    write_stderr("  or with each *.json file in folder, to <name><ext> files in <dir>\n");
    write_stderr("  (default: the folder). <ext> is the template's extension without .hbs,\n");
    write_stderr("  or .out: page.html.hbs and ana.json give ana.html.\n");
}

fn fail_usage() {
    usage();
    exit(2);
}

fn report(message: const u8[:]) {
    write_stderr(str("gooseneck: ", message, "\n"));
}

// The last segment of path: "page.html.hbs" for "views/page.html.hbs".
fn base_name(path: const u8[:]) -> const u8[:] {
    let slash = rfind(path, "/");
    guard slash >= 0 else { return path; }
    return path[slash + 1..];
}

// dir and name joined with one '/'.
fn join(dir: const u8[:], name: const u8[:]) -> u8[>..] {
    guard !ends_with(dir, "/") else { return str(dir, name); }
    return str(dir, "/", name);
}

// The extension of the files a folder render writes: the template's own,
// after a trailing .hbs is dropped, or .out when there is none left.
// page.html.hbs gives .html, x.hbs gives .out.
fn output_extension(template_path: const u8[:]) -> const u8[:] {
    var name = base_name(template_path);
    if ends_with(name, ".hbs") { name = name[..name.len - 4]; }
    let dot = rfind(name, ".");
    guard dot > 0 else { return ".out"; }
    return name[dot..];
}

// Renders engine with the JSON file at path to stdout. Returns whether it
// rendered.
fn render_file(engine: const gooseneck::Engine&, path: const u8[:]) -> bool {
    let out: u8[>..] = [];
    let err = gooseneck::render_json_file(engine, path, out);
    if err.len > 0 {
        report(err);
        return false;
    }
    write_stdout(out);
    write_stdout("\n");
    return true;
}

// Renders engine with each *.json file in folder, in name order, into
// out_dir, as the header describes. Returns whether every file rendered
// and was written.
fn render_folder(engine: const gooseneck::Engine&, folder: const u8[:], out_dir: const u8[:], extension: const u8[:]) -> bool {
    guard make_dir(out_dir) else {
        report(str("cannot create ", out_dir));
        return false;
    }
    let listing: u8[>..] = [];
    guard list_dir(folder, listing) else {
        report(str("cannot list ", folder));
        return false;
    }
    var all_ok = true;
    var rendered: i64 = 0;
    for name in split(listing, '\n') {
        let path = join(folder, name);
        guard ends_with(name, ".json") && file_exists(path) else { continue; }
        rendered += 1;
        let out: u8[>..] = [];
        let err = gooseneck::render_json_file(engine, path, out);
        if err.len > 0 {
            report(err);
            all_ok = false;
            continue;
        }
        let target = join(out_dir, str(name[..name.len - 5], extension));
        if write_file(target, out) {
            write_stderr(str("wrote ", target, "\n"));
        } else {
            report(str("cannot write ", target));
            all_ok = false;
        }
    }
    guard rendered > 0 else {
        report(str("no .json files in ", folder));
        return false;
    }
    return all_ok;
}

fn main() {
    let argv = args();
    if argv.len == 2 && (argv[1] == "-h" || argv[1] == "--help") {
        usage();
        exit(0);
    }
    guard argv.len >= 4 && argv[1] == "render" else { fail_usage(); }
    let template = argv[2];
    let data = argv[3];
    var out_dir = data;
    if argv.len == 6 && argv[4] == "-o" {
        out_dir = argv[5];
    } else if argv.len != 4 {
        fail_usage();
    }
    let folder = is_dir(data);
    if !folder && argv.len == 6 {
        report("-o needs a folder of JSON files; one file renders to stdout");
        exit(2);
    }
    let engine = gooseneck::load_engine(template);
    if engine.error.len > 0 {
        report(engine.error);
        exit(1);
    }
    let ok = if folder { render_folder(engine, data, out_dir, output_extension(template)) } else { render_file(engine, data) };
    if !ok { exit(1); }
}
