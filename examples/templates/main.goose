// A tour of the template language on a JSON file: paths, escaping,
// bracketed segments, #with, #each over arrays and objects, the data
// variables, #if with else chains and includeZero, #unless, block
// parameters, lookup, comments and whitespace control. The template is
// tour.hbs and the context tour.json, beside this file. Run it from the
// repository root:
//
//   goose run examples/templates/main.goose
//
// scripts/test.sh runs it and compares its output with expected.out, which
// is what handlebars.js 4.7.10 renders for the same files.
import gooseneck from "../..";

fn main() {
    let engine = gooseneck::load_engine(str(resource_dir(), "tour.hbs"));
    let out: u8[>..] = [];
    let err = gooseneck::render_json_file(engine, str(resource_dir(), "tour.json"), out);
    if err.len > 0 { print(err); return; }
    write_stdout(out);
}
