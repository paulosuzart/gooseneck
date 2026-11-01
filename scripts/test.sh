#!/bin/sh
# Runs every program in test/ and compares its stdout with test/expected/<name>.out,
# then every examples/<name>/main.goose that has an expected.out beside it.
# Goose v2026.3 has assert, and no goose test command. A failed assert aborts
# the program. Then scripts/test_cli.sh checks the CLI. GOOSE selects the
# compiler; otherwise the goose on PATH.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
goose=${GOOSE:-$(command -v goose)}
fail=0

for src in "$root"/test/*.goose; do
    name=$(basename "$src" .goose)
    want="$root/test/expected/$name.out"
    out=$(mktemp)
    err=$(mktemp)
    echo "== $name"
    if ! "$goose" run "$src" >"$out" 2>"$err"; then
        echo "FAIL $name: goose run exited $?"
        cat "$err"
        cat "$out"
        fail=1
    elif ! diff -u "$want" "$out"; then
        echo "FAIL $name: stdout differs from test/expected/$name.out"
        fail=1
    else
        echo "ok $name"
    fi
    rm -f "$out" "$err"
done

for want in "$root"/examples/*/expected.out; do
    dir=$(dirname "$want")
    name=examples/$(basename "$dir")
    out=$(mktemp)
    err=$(mktemp)
    echo "== $name"
    if ! "$goose" run "$dir/main.goose" >"$out" 2>"$err"; then
        echo "FAIL $name: goose run exited $?"
        cat "$err"
        fail=1
    elif ! diff -u "$want" "$out"; then
        echo "FAIL $name: stdout differs from $name/expected.out"
        fail=1
    else
        echo "ok $name"
    fi
    rm -f "$out" "$err"
done

echo "== cli"
GOOSE="$goose" "$root/scripts/test_cli.sh" || fail=1

exit "$fail"
