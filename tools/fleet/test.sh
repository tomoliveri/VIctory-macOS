#!/bin/bash
# Tests for the fleet's parsing, validation and moderation (no network).
# Run: tools/fleet/test.sh
# shellcheck disable=SC2016,SC2001 # literal backticks, jq and GraphQL in single quotes
set -euo pipefail
# shellcheck source=tools/fleet/lib.sh
. "$(dirname "$0")/lib.sh"

pass=0
fail=0
ok() { # NAME COMMAND... : the command must succeed
    local name=$1
    shift
    if "$@" > /dev/null 2>&1; then pass=$((pass + 1)); else
        fail=$((fail + 1))
        echo "FAIL: $name"
    fi
}
no() { # NAME COMMAND... : the command must fail
    local name=$1
    shift
    if "$@" > /dev/null 2>&1; then
        fail=$((fail + 1))
        echo "FAIL: $name"
    else pass=$((pass + 1)); fi
}
eq() { # NAME EXPECTED ACTUAL
    if [ "$2" = "$3" ]; then pass=$((pass + 1)); else
        fail=$((fail + 1))
        printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"
    fi
}

SHA=0123456789abcdef0123456789abcdef01234567
REPO=example/VIctory-macOS
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# --- tasks
body=$(task_body "$SHA" m3 "$REPO")
eq "task body round-trips" "$SHA m3" "$(parse_task "$body")"
eq "task body passes moderation" "" "$(moderate "$body")"
eq "task body with CRLF" "$SHA m3" "$(parse_task "$(sed 's/$/\r/' <<< "$body")")"
no "task with unknown chip" parse_task "$(task_body "$SHA" m9 "$REPO")"
no "task with short commit" parse_task "$(task_body 0123abc m3 "$REPO")"
no "task without a block" parse_task "commit: $SHA"
no "task with another kind" parse_task "$(sed 's/^kind: test-matrix/kind: shader/' <<< "$body")"

# --- commands
eq "claim" claim "$(parse_command "/claim")"
eq "claim with spaces" claim "$(parse_command "  /claim  ")"
eq "beat" beat "$(parse_command "/beat")"
eq "release" "release no_time" "$(parse_command "/release no_time")"
eq "release with a bad reason" "" "$(parse_command "/release because")"
eq "claim with extra text" "" "$(parse_command "/claim
please")"
eq "command not on the first line" "" "$(parse_command "hi
/claim")"
eq "plain comment" "" "$(parse_command "Works on my M2 Air")"
eq "result" result "$(parse_command "/result")"

# --- results
good=$(jq -cn --arg c "$SHA" '{schema: 1, kind: "test-matrix", upstream_commit: $c, hw_model: "Mac15,12",
    chip: "Apple M3 Pro", macos: "15.4.1", gptk: "3.0", setup: "ok",
    native: {passed: 300, failed: 0, ignored: 2}, wine: {passed: 340, failed: 3, ignored: 0},
    failures: [{test: "wine/victory_gpu::tests::depth16", sig: "0123456789ab", topic: "gpu"}],
    timings: {setup: 61, native: 42, wine: 130},
    binaries: [{suite: "native", name: "victory_gpu", seconds: 1.25}, {suite: "wine", name: "victory_gpu", seconds: 20.5}]}')
comment=$(printf '/result\n```json\n%s\n```\n' "$good")
eq "result block extracts" "$good" "$(result_json "$comment")"
no "result with text before the block" result_json "$(printf '/result\nhello\n```json\n{}\n```')"
no "result with text after the block" result_json "$(printf '/result\n```json\n{}\n```\nmore')"
no "result without a block" result_json "/result"
ok "valid result" validate_result "$good" "$SHA" m3
no "wrong commit" validate_result "$good" "${SHA%7}8" m3
no "wrong chip family" validate_result "$good" "$SHA" m2
bad() { validate_result "$(jq -c "$1" <<< "$good")" "$SHA" m3; }
no "extra field" bad '.notes = "see https://example.com"'
no "missing field" bad 'del(.gptk)'
no "free text in hw_model" bad '.hw_model = "Mac15,12 see my link"'
no "free text in chip" bad '.chip = "Apple M3 Pro https://x"'
no "free text in macos" bad '.macos = "15.4 beta (lol)"'
no "free text in a test name" bad '.failures[0].test = "wine/victory_gpu::a b"'
no "test name without a suite" bad '.failures[0].test = "victory_gpu::x"'
no "test name without a binary" bad '.failures[0].test = "wine/x"'
no "too many failures" bad '.failures = [range(101) | {test: "wine/b::t\(.)", sig: "0123456789ab", topic: "gpu"}]'
no "signature with text" bad '.failures[0].sig = "see my link"'
no "unknown topic" bad '.failures[0].topic = "rumours"'
no "extra failure field" bad '.failures[0].message = "boom"'
no "timings with text" bad '.timings.native = "slow"'
no "timings with an extra field" bad '.timings.note = 1'
no "seconds with too many decimals" bad '.binaries[0].seconds = 1.234'
no "binary name with text" bad '.binaries[0].name = "see https://x"'
no "unknown suite" bad '.binaries[0].suite = "game"'
ok "null timings" bad '.timings = {setup: 5, native: null, wine: null}'
no "negative count" bad '.native.failed = -1'
no "fractional count" bad '.native.failed = 1.5'
no "extra count field" bad '.native.note = 1'
no "bad setup value" bad '.setup = "maybe"'
no "array instead of object" validate_result '[1]' "$SHA" m3
no "not JSON" validate_result 'nope' "$SHA" m3
no "too large" validate_result "$(printf '%9000s' x)" "$SHA" m3
ok "null suites when setup failed" bad '.setup = "failed" | .native = null | .wine = null | .failures = [] | .binaries = []'
ok "unknown toolkit version" bad '.gptk = "unknown"'
ok "MacBook model id" bad '.hw_model = "MacBookAir10,1"'
ok "failing result" result_failing "$good"
no "passing result" result_failing "$(jq -c '.wine.failed = 0' <<< "$good")"
ok "setup failure is failing" result_failing "$(jq -c '.setup = "failed" | .native = null | .wine = null' <<< "$good")"
eq "validation error text" "upstream_commit is not the task commit" "$(validate_result "$good" "${SHA%7}8" m3 || true)"

# --- moderation
verdict() { moderate "$1" | cut -d ' ' -f 1; }
eq "clean comment" "" "$(verdict "Setup failed at the Wine build on my M1, log attached locally")"
eq "torrent link" delete "$(verdict "grab it here magnet:?xt=urn:btih:abc")"
eq "file host link" delete "$(verdict "https://MEGA.nz/file/abc")"
eq "game dump talk" hide "$(verdict "where do I get a game dump")"
eq "dumped my game" hide "$(verdict "I dumped my game yesterday")"
eq "decryption" hide "$(verdict "how do I decrypt the package")"
eq "container names" hide "$(verdict "it is an XVD file")"
eq "image attachment" hide "$(verdict "![x](https://github.com/user-attachments/assets/1)")"
eq "long encoded run" hide "$(verdict "$(printf 'A%.0s' $(seq 1 220))")"
eq "words containing short tokens" "" "$(verdict "the dumpster fire of the rpfoo tickets")"

# --- cargo output
cat > "$tmp/native.log" << 'EOF'
     Running unittests src/lib.rs (target/debug/deps/victory_gpu-0f1e2d3c4b5a6978)

running 3 tests
test tests::one ... ok
test tests::two ... FAILED
test tests::three ... ignored

failures:

---- tests::two stdout ----

thread 'tests::two' panicked at /Users/someone/src/VIctory-macOS/crates/victory-gpu/src/x.rs:12:5:
assertion `left == right` failed: texture at 0x7ff3a0 not uploaded
  left: 3
 right: 4
note: run with `RUST_BACKTRACE=1` environment variable to display a backtrace


failures:
    tests::two

test result: FAILED. 1 passed; 1 failed; 1 ignored; 0 measured; 0 filtered out; finished in 0.52s

     Running tests/load_probe.rs (target/x86_64-pc-windows-gnullvm/debug/deps/load_probe-99aa.exe)

running 2 tests
test probe_loads ... ok
test probe timeout ... FAILED

failures:

---- probe timeout stdout ----
timed out

failures:
    probe timeout

test result: FAILED. 1 passed; 1 failed; 0 ignored; 0 measured; 0 filtered out; finished in 12.00s

   Doc-tests victory_core

running 0 tests

test result: ok. 0 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s
EOF
eq "counts are summed" "2 2 1" "$(parse_counts "$tmp/native.log")"
eq "counts json" '{"passed":2,"failed":2,"ignored":1}' "$(counts_json "$tmp/native.log")"
parsed=$(parse_cargo "$tmp/native.log")
eq "binaries and times" "victory_gpu 0.52|load_probe 12.00|doc_victory_core 0.00" "$(grep '^B' <<< "$parsed" | cut -f 2,3 | tr '\t' ' ' | paste -sd '|' -)"
eq "failure text is normalised" 'victory_gpu::tests::two' "$(grep '^F' <<< "$parsed" | head -n 1 | cut -f 2)"
ok "paths, numbers and addresses are removed" grep -q "panicked at crates/victory-gpu/src/x.rs:#:#: assertion \`left == right\` failed: texture at 0x# not uploaded left: # right: #" <<< "$parsed"
no "notes are dropped" grep -q 'RUST_BACKTRACE' <<< "$parsed"
failures=$(failures_json "$parsed" native)
eq "test names with spaces are skipped" 1 "$(jq length <<< "$failures")"
eq "failure entry" "native/victory_gpu::tests::two gpu" "$(jq -r '.[0] | "\(.test) \(.topic)"' <<< "$failures")"
ok "signature is 12 hex" grep -Eq '^[0-9a-f]{12}$' <<< "$(jq -r '.[0].sig' <<< "$failures")"
sed 's/0x7ff3a0/0x1234/; s/left: 3/left: 9/; s|/Users/someone/src|/home/runner/work|' "$tmp/native.log" > "$tmp/other-mac.log"
eq "same failure on another Mac gives the same signature" "$(jq -r '.[0].sig' <<< "$failures")" \
    "$(failures_json "$(parse_cargo "$tmp/other-mac.log")" native | jq -r '.[0].sig')"
eq "binaries json" '[{"suite":"wine","name":"victory_gpu","seconds":0.52},{"suite":"wine","name":"load_probe","seconds":12},{"suite":"wine","name":"doc_victory_core","seconds":0}]' "$(binaries_json "$parsed" wine)"
eq "signature lines keep the text locally" "native/victory_gpu::tests::two" "$(signature_lines "$parsed" native | head -n 1 | cut -f 2)"
eq "topic: timeout wins" timeout "$(failure_topic "victory_gpu::x" "timed out after #s")"
eq "topic: crate" shader "$(failure_topic "victory_shader::t" "assertion failed")"
eq "topic: metal" d3dmetal "$(failure_topic "victory_gpu::t" "Metal returned #")"
eq "topic: unknown" other "$(failure_topic "fidelityfx::t" "assertion failed")"
full=$(jq -c --argjson f "$failures" --argjson b "$(binaries_json "$parsed" native)" '.failures = $f | .binaries = $b' <<< "$good")
ok "a parsed run makes a valid result" validate_result "$full" "$SHA" m3

# --- findings
fbody=$(finding_body 0123456789ab native/victory_gpu::tests::two gpu "$REPO")
eq "finding round-trips" "0123456789ab native/victory_gpu::tests::two gpu" "$(parse_finding "$fbody")"
eq "performance finding round-trips" "0123456789ab wine/victory_gpu performance" "$(parse_finding "$(finding_body 0123456789ab wine/victory_gpu performance "$REPO")")"
eq "finding body passes moderation" "" "$(moderate "$fbody")"
no "finding with unknown topic" parse_finding "$(finding_body 0123456789ab native/a::b rumours "$REPO")"
no "a task is not a finding" parse_finding "$body"
ok "bots are trusted authors" is_trusted_author "github-actions[bot]"
no "strangers are not trusted" is_trusted_author "mallory"
slower=$(jq -c '.binaries[1].seconds = 40' <<< "$good")
eq "slowdown found" "wine/victory_gpu	20.5	40" "$(slowdowns "$good" "$slower")"
eq "small slowdowns ignored" "" "$(slowdowns "$good" "$(jq -c '.binaries[0].seconds = 3' <<< "$good")")"

eq "chip family" m3 "$(chip_family_of "Apple M3 Pro")"
eq "chip family of an Intel Mac" "" "$(chip_family_of "Intel(R) Core(TM) i7")"

# --- report
r1=$(jq -c '. + {n: 1, closed: "2026-11-20T10:00:00Z"}' <<< "$good")
r2=$(jq -c '. + {n: 2, closed: "2026-11-21T10:00:00Z", chip: "Apple M1", hw_model: "MacBookAir10,1", failures: [], wine: {passed: 343, failed: 0, ignored: 0}}' <<< "$good")
r3=$(jq -c '. + {n: 3, closed: "2026-11-22T10:00:00Z", chip: "Apple M2", setup: "failed", native: null, wine: null, failures: [], binaries: []}' <<< "$good")
report=$(printf '%s\n%s\n%s\n' "$r1" "$r2" "$r3" | report_markdown)
ok "report counts results" grep -q '^3 accepted results across 1 commits' <<< "$report"
ok "report coverage" grep -q '3 of 5: m1, m2, m3 | 2 of 3' <<< "$report"
ok "report chip-specific failure" grep -q 'victory_gpu::tests::depth16` (gpu, sig `0123456789ab`): fails on m3; passes on m1' <<< "$report"
ok "report lists every result" grep -q '^| #3 |' <<< "$report"
ok "report slowest binaries" grep -q 'm3 (`0123456789ab`): wine/victory_gpu 20.5 s' <<< "$report"
r4=$(jq -c '. + {n: 4, closed: "2026-11-23T10:00:00Z", upstream_commit: "fedcba9876543210fedcba9876543210fedcba98", binaries: [{suite: "wine", name: "victory_gpu", seconds: 40}]}' <<< "$good")
ok "report slowdowns" grep -q 'm3: wine/victory_gpu 20.5 s at `0123456789ab` -> 40 s at `fedcba987654`' <<< "$(printf '%s\n%s\n' "$r1" "$r4" | report_markdown)"
eq "empty report" "None found." "$(: | report_markdown | sed -n '/^## Tests/{n;n;p;}')"

echo "fleet tests: $pass passed, $fail failed"
[ "$fail" = 0 ]
