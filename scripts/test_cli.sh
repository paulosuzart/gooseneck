#!/bin/sh
# Builds the CLI (main.goose) into a temporary directory and checks
# `gooseneck render`: one JSON file to stdout, a folder of JSON files into
# -o <dir> or beside them, a file that fails while the others render, the
# .out extension of a template named only *.hbs, a template error and the
# usage. scripts/test.sh runs it after the suites. GOOSE selects the
# compiler; otherwise the goose on PATH.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
goose=${GOOSE:-$(command -v goose)}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0

if ! "$goose" build "$root/main.goose" -o "$tmp/gooseneck" >"$tmp/build.log" 2>&1; then
    cat "$tmp/build.log"
    echo "FAIL cli: goose build"
    exit 1
fi
cli="$tmp/gooseneck"
cd "$root"

# Compares what a case got with what it wants.
check() { # label got want
    if [ "$2" = "$3" ]; then
        echo "ok cli $1"
    else
        echo "FAIL cli $1"
        printf 'got:\n%s\nwant:\n%s\n' "$2" "$3"
        fail=1
    fi
}

# Runs the CLI, keeping stdout, stderr and the exit code.
run() {
    code=0
    "$cli" "$@" >"$tmp/stdout" 2>"$tmp/stderr" || code=$?
}

run render test/fixtures/greeting.hbs test/fixtures/greeting.json
check "one file" "$(cat "$tmp/stdout")|$code" "hello John, 21! Springfield (John)|0"

run render test/fixtures/cli/card.html.hbs test/fixtures/cli/people -o "$tmp/out"
check "folder with -o, exit code" "$code" "1"
check "folder with -o, files" "$(ls "$tmp/out")" "$(printf 'ana.html\nbo.html')"
check "folder with -o, ana" "$(cat "$tmp/out/ana.html")" "<p>Ana, 30</p>"
check "folder with -o, bo" "$(cat "$tmp/out/bo.html")" "<p>Bo, 4</p>"
check "folder with -o, stderr" "$(cat "$tmp/stderr")" "$(printf 'wrote %s\nwrote %s\n%s' "$tmp/out/ana.html" "$tmp/out/bo.html" \
    "gooseneck: test/fixtures/cli/people/broken.json: json: expected a key at byte 15")"

mkdir "$tmp/beside"
cp test/fixtures/cli/people/ana.json test/fixtures/cli/people/bo.json "$tmp/beside"
run render test/fixtures/cli/card.html.hbs "$tmp/beside"
check "folder, files beside the JSON" "$(ls "$tmp/beside")|$code" "$(printf 'ana.html\nana.json\nbo.html\nbo.json')|0"

mkdir "$tmp/plain"
cp test/fixtures/greeting.json "$tmp/plain"
run render test/fixtures/greeting.hbs "$tmp/plain"
check "template without an extension" "$(cat "$tmp/plain/greeting.out")|$code" "hello John, 21! Springfield (John)|0"

run render test/fixtures/bad.hbs test/fixtures/greeting.json
check "template error" "$(cat "$tmp/stderr")|$code" "gooseneck: test/fixtures/bad.hbs: unexpected /with|1"

run render test/fixtures/greeting.hbs test/fixtures/greeting.json -o "$tmp/nowhere"
check "-o with one file" "$(cat "$tmp/stderr")|$code" "gooseneck: -o needs a folder of JSON files; one file renders to stdout|2"

run test/fixtures/greeting.hbs test/fixtures/greeting.json
check "no subcommand" "$(head -1 "$tmp/stderr")|$code" "usage: gooseneck render <template> <context.json>|2"

exit "$fail"
