#!/usr/bin/env bash
# Minimal bash test helpers: sandboxed HOME, stubbed binaries, assertions.

TESTS_RUN=0
TESTS_FAILED=0

# setup_sandbox — fresh temp HOME + stub bin dir on PATH. Call before each test.
setup_sandbox() {
    _SAVED_PATH="$PATH"
    SANDBOX=$(mktemp -d)
    STUBS="$SANDBOX/bin"
    STUB_LOG="$SANDBOX/log"
    mkdir -p "$STUBS" "$STUB_LOG" "$SANDBOX/home"
    export HOME="$SANDBOX/home"
    export PATH="$STUBS:$PATH"
}

# teardown_sandbox — remove the temp tree and restore PATH.
teardown_sandbox() {
    [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX"
    [ -n "${_SAVED_PATH:-}" ] && export PATH="$_SAVED_PATH"
    return 0
}

# stub <name> — install an executable stub on PATH. Stub body is read from
# stdin; argv is logged (one space-joined line per call) to $STUB_LOG/<name>.calls
# before the body runs.
stub() {
    local name="$1"
    : > "$STUB_LOG/$name.calls"
    {
        echo '#!/usr/bin/env bash'
        echo "printf '%s\\n' \"\$*\" >> \"$STUB_LOG/$name.calls\""
        cat
    } > "$STUBS/$name"
    chmod +x "$STUBS/$name"
}

# calls_of <name> — print the logged calls for a stub (empty if never called).
calls_of() {
    cat "$STUB_LOG/$1.calls" 2>/dev/null || true
}

# assert_eq <expected> <actual> <message>
assert_eq() {
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$1" = "$2" ]; then
        echo "  ok: $3"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo "  FAIL: $3"
        echo "    expected: [$1]"
        echo "    actual:   [$2]"
    fi
}

assert_contains() {
    TESTS_RUN=$((TESTS_RUN + 1))
    if printf '%s' "$1" | grep -qF -- "$2"; then
        echo "  ok: $3"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo "  FAIL: $3"
        echo "    haystack: [$1]"
        echo "    needle:   [$2]"
    fi
}

assert_not_contains() {
    TESTS_RUN=$((TESTS_RUN + 1))
    if printf '%s' "$1" | grep -qF -- "$2"; then
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo "  FAIL: $3"
        echo "    unexpectedly found: [$2]"
    else
        echo "  ok: $3"
    fi
}

assert_file_missing() {
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ -e "$1" ]; then
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo "  FAIL: $2 (file exists: $1)"
    else
        echo "  ok: $2"
    fi
}

# finish — print summary and set exit status. Call at end of each test file.
finish() {
    echo "--- $TESTS_RUN run, $TESTS_FAILED failed ---"
    [ "$TESTS_FAILED" -eq 0 ]
}
