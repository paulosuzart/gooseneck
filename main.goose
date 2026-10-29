// gooseneck CLI: renders a Handlebars template file with a context read from
// a JSON file, so the engine can be tried without writing or recompiling
// Goose code.
//
//   goose run main.goose -- <template.hbs> <context.json>
//   goose build main.goose -o build/gooseneck && build/gooseneck <template.hbs> <context.json>
//
// For example, from the repository root:
//
//   goose run main.goose -- test/fixtures/greeting.hbs test/fixtures/greeting.json
//
// prints "hello John, 21! Springfield (John)". Relative paths resolve
// against the working directory. A template or JSON error goes to stderr
// with exit code 1; wrong arguments print the usage and exit with 2.
// goose run prints its own compile progress on stderr as well.
//
// An example of gooseneck inside an HTTP service is in examples/http/.
import gooseneck.handlebars;

fn usage() {
    write_stderr("usage: gooseneck <template.hbs> <context.json>\n");
    write_stderr("  Renders the Handlebars template with the JSON file as its context.\n");
}

fn main() {
    let argv = args();
    if argv.len == 2 && (argv[1] == "-h" || argv[1] == "--help") {
        usage();
        exit(0);
    }
    if argv.len != 3 {
        usage();
        exit(2);
    }
    let engine = gooseneck::load_engine(argv[1]);
    if engine.error.len > 0 {
        write_stderr(str("gooseneck: ", engine.error, "\n"));
        exit(1);
    }
    let out: u8[>..] = [];
    let err = gooseneck::render_json_file(engine, argv[2], out);
    if err.len > 0 {
        write_stderr(str("gooseneck: ", err, "\n"));
        exit(1);
    }
    write_stdout(out);
    write_stdout("\n");
}
