#!/usr/bin/env bash
set -euo pipefail

RESULT_DIR="${RALPH_RESULT_DIR:-.ralph}"
RESULT_FILE="${RESULT_DIR}/validation-result.json"

mkdir -p "$RESULT_DIR"

json_escape() {
  jq -Rs . <<<"${1:-}"
}

run_check() {
  local name="$1"
  local cmd="$2"
  local log_file="${RESULT_DIR}/${name}.log"

  if [ -z "$cmd" ]; then
    CHECK_RESULTS["$name"]="skip"
    CHECK_DETAILS["$name"]="No command configured"
    return 0
  fi

  echo "==> ${name}: ${cmd}"
  if bash -lc "$cmd" >"$log_file" 2>&1; then
    CHECK_RESULTS["$name"]="pass"
    CHECK_DETAILS["$name"]="$(tail -20 "$log_file" 2>/dev/null || true)"
    return 0
  fi

  CHECK_RESULTS["$name"]="fail"
  CHECK_DETAILS["$name"]="$(tail -40 "$log_file" 2>/dev/null || true)"
  return 1
}

has_npm_script() {
  local script_name="$1"
  [ -f package.json ] || return 1
  jq -e --arg name "$script_name" '.scripts[$name] != null and .scripts[$name] != ""' package.json >/dev/null 2>&1
}

declare -A CHECK_RESULTS=()
declare -A CHECK_DETAILS=()

BUILD_CMD=""
TEST_CMD=""
LINT_CMD=""
ACCEPTANCE_CMD=""

if [ -f package.json ]; then
  if has_npm_script build; then
    BUILD_CMD="npm run build"
  fi
  if has_npm_script test; then
    TEST_CMD="npm test -- --runInBand"
  fi
  if has_npm_script lint; then
    LINT_CMD="npm run lint"
  fi
elif [ -f go.mod ]; then
  BUILD_CMD="go build ./..."
  TEST_CMD="go test ./..."
elif [ -f Cargo.toml ]; then
  BUILD_CMD="cargo build"
  TEST_CMD="cargo test"
elif [ -f pyproject.toml ] || [ -f setup.py ]; then
  BUILD_CMD="python -m compileall ."
  if command -v pytest >/dev/null 2>&1; then
    TEST_CMD="pytest"
  fi
fi

if [ -x scripts/acceptance.sh ]; then
  ACCEPTANCE_CMD="./scripts/acceptance.sh"
fi

FAILED=0

run_check build "$BUILD_CMD" || FAILED=1
run_check test "$TEST_CMD" || FAILED=1
run_check lint "$LINT_CMD" || FAILED=1
run_check acceptance "$ACCEPTANCE_CMD" || FAILED=1

RESULT="pass"
if [ "$FAILED" -ne 0 ]; then
  RESULT="fail"
elif [ "${CHECK_RESULTS[build]}" = "skip" ] && \
     [ "${CHECK_RESULTS[test]}" = "skip" ] && \
     [ "${CHECK_RESULTS[lint]}" = "skip" ] && \
     [ "${CHECK_RESULTS[acceptance]}" = "skip" ]; then
  RESULT="partial"
fi

cat >"$RESULT_FILE" <<EOF
{
  "result": "$RESULT",
  "checks": {
    "build": {
      "status": "${CHECK_RESULTS[build]}",
      "detail": $(json_escape "${CHECK_DETAILS[build]}")
    },
    "test": {
      "status": "${CHECK_RESULTS[test]}",
      "detail": $(json_escape "${CHECK_DETAILS[test]}")
    },
    "lint": {
      "status": "${CHECK_RESULTS[lint]}",
      "detail": $(json_escape "${CHECK_DETAILS[lint]}")
    },
    "acceptance": {
      "status": "${CHECK_RESULTS[acceptance]}",
      "detail": $(json_escape "${CHECK_DETAILS[acceptance]}")
    }
  }
}
EOF

cat "$RESULT_FILE"

if [ "$RESULT" = "fail" ]; then
  exit 1
fi
