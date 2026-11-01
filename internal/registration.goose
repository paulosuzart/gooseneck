// What a render checks of the user's helpers and block helpers before it
// writes anything: duplicate names, and blocks nobody registered.

import std;

namespace gooseneck;

// The resolved argument at position i of range.
fn resolved_at(cx: const HelperContext&, range: Range, i: i64) -> Resolved {
    return cx.resolved[range.first + i];
}

// While listing, appends name to reg.call.text, one per line.
fn list_name(reg: Registry&, name: const u8[:]) {
    reg.call.text.append(name);
    reg.call.text.push('\n');
}

// Appends the names that the helpers F register to names, one per line: F
// runs once on a listing Registry, where no registration runs its block.
fn helper_names<F>(names: u8[>..]&) {
    let resolved: Resolved[>..<] = [];
    let none = Range { first: 0, count: 0 };
    let out: u8[>..] = [];
    let call = HelperContext { resolved: resolved, params: none, hash: none, text: names, out: out };
    var reg = Registry { call: call, listing: true };
    F(reg);
}

// The first name that names, one per line, holds twice, or "".
fn first_duplicate(names: const u8[:]) -> const u8[:] {
    let list = words(names);
    for i in list.len {
        for j in i {
            if list[j] == list[i] { return list[i]; }
        }
    }
    return "";
}

// The error for a kind of helper ("helper" or "block helper") whose names,
// one per line, hold one twice, such as duplicate helper "now"; empty when
// each is there once.
fn duplicate_error(kind: const u8[:], names: const u8[:]) -> u8[>..] {
    let twice = first_duplicate(names);
    guard twice.len > 0 else { return []; }
    return str("duplicate ", kind, " \"", twice, "\"");
}

// What a render checks before it writes anything: that helpers F and
// block helpers G register each name once, and that every block of engine
// that is not built in has a block helper in G. Returns the error, empty
// when both hold.
fn registration_error<F, G>(engine: const Engine&) -> u8[>..] {
    let names: u8[>..] = [];
    helper_names(names, F);
    let duplicate = duplicate_error("helper", names);
    guard duplicate.len == 0 else { return duplicate; }
    let block_names: u8[>..] = [];
    block_helper_names(block_names, G);
    let block_duplicate = duplicate_error("block helper", block_names);
    guard block_duplicate.len == 0 else { return block_duplicate; }
    return unknown_block_error(engine, block_names);
}

// The error for the first block of engine whose helper is neither built in
// nor among block_names, one per line, such as unknown block helper
// "nope"; empty when there is none.
fn unknown_block_error(engine: const Engine&, block_names: const u8[:]) -> u8[>..] {
    let known = words(block_names);
    for node in engine.nodes {
        guard node.kind == NodeKind.Block else { continue; }
        let helper = span_text(engine.text, node.value);
        guard !is_built_in_block(helper) && !_is_listed(known, helper) else { continue; }
        return str("unknown block helper \"", helper, "\"");
    }
    return [];
}

// Whether names holds name.
fn _is_listed(names: const u8[:][>..]&, name: const u8[:]) -> bool {
    for listed in names {
        if listed == name { return true; }
    }
    return false;
}

// Appends the names of the block helpers that G registers to names, one
// per line, as _helper_names does, with a B that walks nothing.
fn block_helper_names<G>(names: u8[>..]&) {
    fn no_body(part: Body) -> bool { return false; }
    fn blocks(reg) { G(reg, no_body); }
    helper_names(names, blocks);
}
