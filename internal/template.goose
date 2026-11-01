import std;

namespace gooseneck;

// ---------------------------------------------------------------------------
// Compiled templates.

// The index of no node: a link that leads nowhere, and the opener of the
// top level.
const NONE: i64 = -1;

// A range of Engine.text.
struct Span { start: i64, len: i64 }

// A run of Engine.args: the count arguments from index first on.
struct Range { first: i64, count: i64 }

// Expression is a {{path}}; Call is a {{helper args...}}, a mustache with
// arguments, whose helper is the user's (see Helpers in gooseneck.goose).
enum NodeKind { Text, Expression, Call, Block }

// One node of a compiled template. value is the text of a Text node, the
// path of an Expression, or the helper name of a Call or a Block ("with",
// "if"). The arguments of a Call or a Block are parsed once, at compile
// time, into Engine.args: params are its positional arguments, hash its
// key=value ones; both are empty for the other kinds. next, body and
// inverse are indices into Engine.nodes, NONE for none; only a Block has a
// body, and an inverse, the chain after its {{else}}.
// escaped is the {{...}} / {{{...}}} flag of an Expression or a Call.
// block_params is how many block parameters a Block declares, 2 for
// {{#each items as |item i|}}, and param_ref says whether an Expression's
// path starts with one (see ParamRef). helper_first marks an Expression
// that is a bare name, {{name}}: a helper of that name, if the helpers
// have one, wins over the field (see may_be_helper).
struct Node {
    kind: NodeKind,
    value: Span,
    escaped: bool,
    params: Range,
    hash: Range,
    next: i64,
    body: i64,
    inverse: i64,
    block_params: i64,
    param_ref: ParamRef,
    helper_first: bool,
}

// Where the block parameter a path starts with comes from, found at
// compile time from where the path is written: up counts the blocks with
// block parameters between the path and the one that declares it (0 for
// the innermost), and slot is its position in as |...|. A path that does
// not start with one has up NONE. {{#each groups as |g|}}{{#each g.items
// as |it|}}{{g.name}} gives g.name up 1 and slot 0.
struct ParamRef { up: i64, slot: i64 }

// A path that is looked up in the context, not a block parameter.
fn no_param_ref() -> ParamRef {
    return ParamRef { up: NONE, slot: NONE };
}

// What a helper argument is. A path is looked up when rendering. A Call is
// a subexpression, (helper args...): its helper name and its own params and
// hash, Ranges of Engine.args, so subexpressions nest. The other kinds are
// literals: an Int is a number with neither fraction nor exponent, any other
// number is a Number, and a string's text is between its quotes, unescaped.
// A path's param_ref is that of an Expression node.
enum ArgValue {
    Path { path: Span, param_ref: ParamRef },
    Call { name: Span, params: Range, hash: Range },
    Int { v: i64 },
    Number { v: f64 },
    Bool { v: bool },
    String { text: Span },
    Null,
}

// One helper argument: positional when key is empty, otherwise the hash
// argument key=value.
struct Arg { key: Span, value: ArgValue }

// The argument at position i of range, counting from 0.
fn arg_at(args: const Arg[:], range: Range, i: i64) -> Arg {
    return args[range.first + i];
}

// The text a span views.
fn span_text(text: const u8[:], span: Span) -> const u8[:] {
    return text[span.start..span.start + span.len];
}
