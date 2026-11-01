import std;
import json;

namespace gooseneck;

// ---------------------------------------------------------------------------
// Compiling: a page and the partials it uses, into one Engine.
//
// The page is parsed first. Then every {{> name}} is resolved to the
// template of that name, which is read and parsed the first time it is
// called, so only the partials in use are loaded, and the partials they
// call in turn. All the templates' text goes into Engine.text, one after
// the other, and every Span views it. A name that gives no template is a
// compile error, as is any error in a partial, given with the partial's
// file or name.

// Where a page's partials come from: the files next to it, dir/name.hbs
// for {{> name}}, or the list a caller gave.
struct PartialSource { from_files: bool, dir: const u8[:], list: const Partial[:] }

// An Engine that only carries error.
fn failed(error: const u8[:]) -> Engine {
    return Engine { nodes: [], roots: [], templates: [], args: [], names: [], text: [], error: error };
}

// Compiles the page template and the partials it uses from partials, and
// returns the Engine for them. prefix starts the error text of an error in
// the page, if any: "page.hbs:" or nothing.
fn compile(template: const u8[:], prefix: const u8[:], partials: const PartialSource&) -> Engine {
    let text: u8[>..] = [];
    text.append(template);
    let nodes: Node[>..] = [];
    let roots: i64[>..] = [];
    let args: Arg[>..] = [];
    let templates: Template[>..] = [];
    let at, why = parse_template(text, 0, nodes, roots, args);
    guard why.len == 0 else { return failed(str(prefix, line_column(text, 0, at), why)); }
    templates.push(Template { name: Span { start: 0, len: 0 }, start: 0, roots: Range { first: 0, count: roots.len } });

    // nodes grows as partials are parsed, so their calls are resolved too.
    var i: i64 = 0;
    while i < nodes.len {
        if nodes[i].kind == NodeKind.Partial {
            let name = span_text(text, nodes[i].value);
            var found = template_named(text, templates, name);
            if found == NONE {
                let content: u8[>..] = [];
                guard read_partial(partials, name, content) else {
                    let caller = template_at(templates, nodes[i].value.start);
                    let label = template_label(text, templates[caller], prefix, partials);
                    return failed(str(label, line_column(text, templates[caller].start, nodes[i].value.start), "unknown partial \"", name, "\""));
                }
                let start = text.len;
                text.append(content);
                let first_root = roots.len;
                // An empty partial renders nothing, as in handlebars.js.
                var partial_at = NONE;
                var partial_why: u8[>..] = [];
                if content.len > 0 { partial_at, partial_why = parse_template(text, start, nodes, roots, args); }
                found = templates.len;
                templates.push(Template { name: nodes[i].value, start: start, roots: Range { first: first_root, count: roots.len - first_root } });
                guard partial_why.len == 0 else {
                    let label = template_label(text, templates[found], prefix, partials);
                    return failed(str(label, line_column(text, start, partial_at), partial_why));
                }
            }
            nodes[i].partial = found;
        }
        i += 1;
    }
    let names = field_names(text, nodes, args);
    return Engine { nodes: nodes, roots: roots, templates: templates, args: args, names: names, text: text, error: "" };
}

// The field names the paths of nodes and args use: those of the
// expressions and those among the arguments, which hold every call's,
// subexpressions included. A lookup's literal key names a field too.
fn field_names(text: const u8[:], nodes: const Node[>..]&, args: const Arg[>..]&) -> Span[>..] {
    let names: Span[>..] = [];
    for node in nodes {
        match node.kind {
            Expression => { add_path_names(names, text, node.value); },
            Call => { add_lookup_key_name(names, text, args, node.value, node.params); },
            _ => {},
        }
    }
    for arg in args {
        match arg.value {
            Path p => { add_path_names(names, text, p.path); },
            Call c => { add_lookup_key_name(names, text, args, c.name, c.params); },
            _ => {},
        }
    }
    return names;
}

// The index of the partial named name among templates, or NONE.
fn template_named(text: const u8[:], templates: const Template[>..]&, name: const u8[:]) -> i64 {
    var i: i64 = 1;
    while i < templates.len {
        if span_text(text, templates[i].name) == name { return i; }
        i += 1;
    }
    return NONE;
}

// The index of the template whose text holds byte at of text.
fn template_at(templates: const Template[>..]&, at: i64) -> i64 {
    var i = templates.len - 1;
    while i > 0 && templates[i].start > at { i -= 1; }
    return i;
}

// What starts the error text of an error in template: prefix for the page,
// the partial's file, "dir/name.hbs:", or its name, "name:", for a partial.
fn template_label(text: const u8[:], template: Template, prefix: const u8[:], partials: const PartialSource&) -> u8[>..] {
    guard template.name.len > 0 else { return str(prefix); }
    let name = span_text(text, template.name);
    guard partials.from_files else { return str(name, ":"); }
    return str(partials.dir, name, ".hbs:");
}

// Appends the text of the partial name to content: the file dir/name.hbs,
// or the list's entry of that name. False when there is none.
fn read_partial(partials: const PartialSource&, name: const u8[:], content: u8[>..]&) -> bool {
    if partials.from_files { return read_file(str(partials.dir, name, ".hbs"), content); }
    for partial in partials.list {
        if partial.name == name {
            content.append(partial.text);
            return true;
        }
    }
    return false;
}

// The directory part of path, up to and with its last '/'; empty when it
// has none.
fn dir_of(path: const u8[:]) -> const u8[:] {
    var end = path.len;
    while end > 0 && path[end - 1] != '/' { end -= 1; }
    return path[..end];
}

// Tokenizes and parses the template text[from..] into nodes, roots and
// args. Returns where the compile error is and what it says, or NONE and
// nothing when the template compiles. The tokenizer and the parser stop at
// their first error with error_at, which returns it here from however deep
// they found it.
fn parse_template(text: const u8[:], from: i64, nodes: Node[>..]&, roots: i64[>..]&, args: Arg[>..]&) -> i64, u8[>..] {
    parse(text, tokenize(text, from), nodes, roots, args);
    return NONE, [];
}

// Ends the compile with the error why, found at byte at of source.
fn error_at(source: const u8[:], at: i64, why: const u8[:]) {
    return at, str(why) from parse_template;
}

// Where byte at of text is in the template that starts at byte from, as
// "line:column: ", both counted from 1: "3:5: ". The column counts bytes.
fn line_column(text: const u8[:], from: i64, at: i64) -> u8[>..] {
    var line: i64 = 1;
    var column: i64 = 1;
    for i in from..at {
        if text[i] == '\n' { line += 1; column = 1; } else { column += 1; }
    }
    return str(line, ":", column, ": ");
}
