// Helpers for the hello page. {{ordinal requests}} is "1st", "2nd", "3rd",
// "4th", with 11th, 12th and 13th staying "th". {{now}} is the time of the
// render, in whole seconds since the Unix epoch.
namespace helpers;

fn _suffix(n: i64) -> const u8[:] {
    let mod100 = n % 100;
    if mod100 >= 11 && mod100 <= 13 { return "th"; }
    let mod10 = n % 10;
    if mod10 == 1 { return "st"; }
    if mod10 == 2 { return "nd"; }
    if mod10 == 3 { return "rd"; }
    return "th";
}

fn _ordinal(args: const gooseneck::Args&) -> json::Value {
    match gooseneck::param(args, 0) {
        Int n => {
            let start = args.text.len;
            format(args.text, n.v);
            args.text.append(_suffix(n.v));
            return json::Value.Str { s: args.text[start..] };
        },
        _ => { return json::Value.Null; },
    }
}

// The current time in whole seconds since the Unix epoch.
fn _now() -> json::Value {
    return json::Value.Int { v: time_ns() / 1000000000 };
}

// The helpers the template may call, one registration each.
fn all(name: const u8[:], args: const gooseneck::Args&) -> gooseneck::Result {
    return gooseneck::helpers(args) { call =>
        gooseneck::helper(call, "ordinal") { return gooseneck::known(_ordinal(args)); };
        gooseneck::helper(call, "now") { return gooseneck::known(_now()); };
    };
}
