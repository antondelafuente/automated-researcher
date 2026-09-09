#!/usr/bin/env bash
# Smoke for stream_tar_census.sh — the streaming checkpoint census (automated-researcher#857).
# The property the incident turns on is behavioral, so it cannot be read off the source:
#   - the member list is produced from the STREAM and the archive is never written to disk (asserted by
#     giving the run its own TMPDIR and showing nothing archive-sized is left in it, and by showing the
#     helper never hands curl an output path)
#   - `--max-members N` caps the listing AND tears the transfer down (the reader closes the pipe), so the
#     teardown statuses curl/tar exit with are success there and NOT a failed census
#   - an UNCAPPED census whose stream fails prints NO member lines and exits non-zero — a truncated stream
#     must never read as a complete census
#   - a non-http(s) URL is refused: a local path is already on the box, which is the hop this removes
#   - labels: derived per URL by default, `--label` for a single archive, refused for many
# Plus the two caller-data invariants from PR #858's round-1 review, which are exactly the kind of property
# that reads fine in the source and fails in practice:
#   - a label is DATA, never program text: a label crafted to close a `sed s###` command and use GNU sed's
#     `e` flag executes NOTHING (asserted by the file that command would have created not existing)
#   - no diagnostic emits a live URL: a presigned URL's query string appears NOWHERE in stdout or stderr —
#     not in a refusal, not in the failure line, not in the `CENSUS:` summary, not in a derived label, and
#     not in curl's own replayed error text
# curl is stubbed on PATH — nothing is fetched and no network is touched.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
S="$HERE/stream_tar_census.sh"
[ -f "$S" ] || { echo "FAIL: missing $S"; exit 1; }

TMP=$(mktemp -d) || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT

fails=0
ok(){ echo "ok   $1"; }
no(){ echo "FAIL $1"; fails=1; }

# --- a real tar to serve ---------------------------------------------------------------------------
SRC="$TMP/src"; mkdir -p "$SRC/layers"
for i in 1 2 3 4 5 6 7 8; do head -c 4096 /dev/zero > "$SRC/layers/tensor$i.bin"; done
tar -cf "$TMP/adapter.tar" -C "$SRC" .

# --- stubbed curl ----------------------------------------------------------------------------------
# Streams the fixture to stdout, exactly like the real thing. It also RECORDS its argv, so the assertion
# "the helper never asks curl to write a file" is made against what was actually invoked.
BIN="$TMP/bin"; mkdir -p "$BIN"
cat > "$BIN/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CURL_LOG"
url=""
for a in "$@"; do case "$a" in http://*|https://*) url=$a ;; esac; done
# Curl words its own diagnostics, and some of them name a URL this script never passed it (a redirect
# target). STUB_CURL_ECHO_URL is that case, so the redaction of curl's replayed stderr is asserted.
[ -n "${STUB_CURL_ECHO_URL:-}" ] && echo "curl: (0) note: following redirect to $STUB_CURL_ECHO_URL" >&2
[ "${STUB_CURL_FAIL:-0}" = 1 ] && { echo "curl: (22) stub failure for $url" >&2; exit 22; }
url=${url%%\?*}   # a presigned store URL carries a query string; the object is the path
case "$url" in
  *adapter.tar) cat "$STUB_ARCHIVE" ;;
  *)            echo "curl: (22) stub: no such url" >&2; exit 22 ;;
esac
EOF
chmod +x "$BIN/curl"
PATH="$BIN:$PATH"; export PATH
export CURL_LOG="$TMP/curl.log"
export STUB_ARCHIVE="$TMP/adapter.tar"

# Its own TMPDIR, so "did the archive land on disk?" is answerable by looking at one directory.
SANDBOX="$TMP/scratch-tmp"; mkdir -p "$SANDBOX"
run(){ TMPDIR="$SANDBOX" bash "$S" "$@"; }

URL="https://store.example/adapters/adapter.tar"

# --- the member list comes from the stream, labelled, with nothing written to disk -------------------
: > "$CURL_LOG"
out=$(run "$URL" 2>"$TMP/err"); rc=$?
[ "$rc" = 0 ] && ok census-exit0 || no "census-exit0 (rc=$rc, stderr: $(cat "$TMP/err"))"
printf '%s\n' "$out" | grep -q "^adapter\.tar	\./layers/tensor1\.bin$" && ok census-members-labelled \
  || no "census-members-labelled (out: $out)"
[ "$(printf '%s\n' "$out" | wc -l | tr -d '[:space:]')" -ge 9 ] && ok census-lists-whole-archive \
  || no "census-lists-whole-archive ($(printf '%s\n' "$out" | wc -l) lines)"
grep -q "CENSUS: label=adapter.tar members=" "$TMP/err" && ok census-summary-on-stderr \
  || no "census-summary-on-stderr ($(cat "$TMP/err"))"
grep -q "archive_written_to_disk=no" "$TMP/err" && ok census-summary-states-no-disk || no census-summary-states-no-disk

# THE POINT OF THE HELPER: the 41.5 GB never lands. Nothing archive-sized is left behind, and curl was
# never handed an output path (`-o`/`--output`/`-O`) — the two ways this could regress into a download.
leftover=$(find "$SANDBOX" -type f -size +1k 2>/dev/null | head -n1)
[ -z "$leftover" ] && ok census-nothing-archive-sized-left || no "census-nothing-archive-sized-left ($leftover)"
grep -Eq -- '(^| )(-o|-O|--output|--remote-name)( |$)' "$CURL_LOG" && no census-curl-never-writes-a-file \
  || ok census-curl-never-writes-a-file

# --- --max-members caps the listing and the teardown statuses are not a failure ----------------------
: > "$CURL_LOG"
out=$(run --max-members 2 "$URL" 2>"$TMP/err"); rc=$?
[ "$rc" = 0 ] && ok capped-exit0 || no "capped-exit0 (rc=$rc, stderr: $(cat "$TMP/err"))"
[ "$(printf '%s\n' "$out" | wc -l | tr -d '[:space:]')" = 2 ] && ok capped-two-members \
  || no "capped-two-members (out: $out)"
grep -q "capped_at=2" "$TMP/err" && ok capped-on-the-record || no "capped-on-the-record ($(cat "$TMP/err"))"

# --- an UNCAPPED census whose stream fails prints nothing and exits non-zero -------------------------
: > "$CURL_LOG"
out=$(STUB_CURL_FAIL=1 run "$URL" 2>"$TMP/err"); rc=$?
[ "$rc" != 0 ] && ok fetchfail-nonzero || no "fetchfail-nonzero (rc=$rc)"
[ -z "$out" ] && ok fetchfail-no-members-printed || no "fetchfail-no-members-printed (out: $out)"
grep -q "CENSUS FAILED" "$TMP/err" && ok fetchfail-said-so || no "fetchfail-said-so ($(cat "$TMP/err"))"

# ...and an unknown URL is the same shape (the stub 404s it), so a typo can't read as an empty archive.
out=$(run "https://store.example/nope.tar" 2>/dev/null); rc=$?
[ "$rc" != 0 ] && [ -z "$out" ] && ok unknown-url-nonzero-and-silent || no "unknown-url-nonzero-and-silent (rc=$rc out: $out)"

# --- a local path is refused: it is already on the box, which is the hop this removes ----------------
: > "$CURL_LOG"
out=$(run "$TMP/adapter.tar" 2>"$TMP/err"); rc=$?
[ "$rc" != 0 ] && ok localpath-refused || no "localpath-refused (rc=$rc)"
[ -z "$out" ] && ok localpath-no-members || no "localpath-no-members (out: $out)"
[ ! -s "$CURL_LOG" ] && ok localpath-no-fetch || no "localpath-no-fetch ($(cat "$CURL_LOG"))"

# --- label handling ---------------------------------------------------------------------------------
out=$(run --label run7 "$URL" 2>/dev/null)
printf '%s\n' "$out" | grep -q "^run7	" && ok label-applied || no "label-applied (out: $out)"
if run --label run7 "$URL" "$URL" >/dev/null 2>&1; then no label-many-urls-refused; else ok label-many-urls-refused; fi

# a query string is not part of the derived label (a presigned store URL carries a long one)
out=$(run "$URL?X-Amz-Signature=deadbeef" 2>/dev/null)
printf '%s\n' "$out" | grep -q "^adapter\.tar	" && ok label-strips-query || no "label-strips-query (out: $out)"

# --- invariant 1: a label is DATA, never program text (#858 round-1 review) --------------------------
# The prefix used to be applied with `sed "s#^#$label\t#"`. A `#` in the label closes that `s###` command,
# and GNU sed's `e` flag then EXECUTES the pattern space — which is the replacement text followed by the
# member path — as a shell command. The payload therefore ends its own command with `;` so the appended
# member path becomes a second (failing) command and the canary lands whatever the member is called; the
# canary is the file that command would create, and its absence is the assertion. Verified against the old
# `sed` form while writing this: the canary DID appear, so this is a real regression test, not a decoration.
CANARY="$TMP/pwned"
PAYLOAD="touch $CANARY;#e;#"
rm -f "$CANARY"
out=$(run --label "$PAYLOAD" "$URL" 2>/dev/null); rc=$?
[ ! -e "$CANARY" ] && ok label-not-program-text || no "label-not-program-text (the label EXECUTED: $CANARY exists)"
[ "$rc" = 0 ] && ok label-injection-attempt-still-censuses || no "label-injection-attempt-still-censuses (rc=$rc)"
# ...and the hostile label is emitted VERBATIM as the first field — treated as the text it is.
printf '%s\n' "$out" | grep -qF "$PAYLOAD	./layers/tensor1.bin" && ok label-emitted-verbatim \
  || no "label-emitted-verbatim (out: $out)"
# A control character in a label would break the TAB-separated output contract, so it is refused outright.
if run --label "$(printf 'a\tb')" "$URL" >/dev/null 2>&1; then no label-control-char-refused; else ok label-control-char-refused; fi

# --- invariant 2: no diagnostic emits a live URL (#858 round-1 review) ------------------------------
# The presigned query string IS the credential. It must appear in neither stream, on any path: a successful
# census, a failed one, a refusal, and curl's own error text (which the helper replays redacted).
SIG="X-Amz-Signature=deadbeefcafe&X-Amz-Credential=AKIAsecret"
PRESIGNED="$URL?$SIG"
leaks(){ # leaks <tag> <stdout-file> <stderr-file>
  if grep -qF "deadbeefcafe" "$2" "$3" || grep -qF "AKIAsecret" "$2" "$3"; then
    no "$1 (credential leaked: $(grep -hoF -m1 deadbeefcafe "$2" "$3"; grep -hoF -m1 AKIAsecret "$2" "$3"))"
  else ok "$1"; fi
}
run "$PRESIGNED" >"$TMP/o" 2>"$TMP/e"
leaks presigned-not-leaked-on-success "$TMP/o" "$TMP/e"
grep -q "url=https://store.example/adapters/adapter.tar?REDACTED" "$TMP/e" && ok presigned-summary-shows-redacted \
  || no "presigned-summary-shows-redacted ($(cat "$TMP/e"))"
STUB_CURL_FAIL=1 run "$PRESIGNED" >"$TMP/o" 2>"$TMP/e"
leaks presigned-not-leaked-on-failure "$TMP/o" "$TMP/e"
grep -q "CENSUS FAILED for 'https://store.example/adapters/adapter.tar?REDACTED'" "$TMP/e" \
  && ok presigned-failure-line-redacted || no "presigned-failure-line-redacted ($(cat "$TMP/e"))"
run "ftp://store.example/adapters/adapter.tar?$SIG" >"$TMP/o" 2>"$TMP/e"
leaks presigned-not-leaked-on-refusal "$TMP/o" "$TMP/e"
# curl's OWN error text is not ours to word, so any URL-shaped token in it is redacted generically — here
# the stub prints a redirect target the helper never passed it.
STUB_CURL_ECHO_URL="https://store.example/redirected.tar?$SIG" run "$URL" >"$TMP/o" 2>"$TMP/e"
leaks presigned-not-leaked-from-curl-stderr "$TMP/o" "$TMP/e"
grep -q "store.example/redirected.tar?REDACTED" "$TMP/e" && ok curl-stderr-replayed-redacted \
  || no "curl-stderr-replayed-redacted ($(cat "$TMP/e"))"
# userinfo credentials live before the '@', not in the query — same rule.
run "https://user:s3cretpw@store.example/adapters/adapter.tar" >"$TMP/o" 2>"$TMP/e"
grep -qF "s3cretpw" "$TMP/o" "$TMP/e" && no userinfo-not-leaked || ok userinfo-not-leaked

# --- argument validation ----------------------------------------------------------------------------
if run >/dev/null 2>&1; then no noargs-refused; else ok noargs-refused; fi
if run --max-members 0 "$URL" >/dev/null 2>&1; then no maxzero-refused; else ok maxzero-refused; fi
if run --max-members x "$URL" >/dev/null 2>&1; then no maxnan-refused; else ok maxnan-refused; fi

[ "$fails" = 0 ] && { echo "stream_tar_census smoke PASS"; exit 0; } || { echo "stream_tar_census smoke FAIL"; exit 1; }
