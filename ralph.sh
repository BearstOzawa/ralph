#!/usr/bin/env bash
set -euo pipefail

#———————————————————————————————————————————————————————
# 🐺 Ralph — Autonomous AI Coding Agent
#  Pipeline: Plan → [Human Checkpoint] → ReAct Loop → Commit → Push
#  Supports Plan-and-Execute + ReAct paradigms for complex tasks
#  PR creation, formal review, and labels are handled by the workflow YAML
#———————————————————————————————————————————————————————

MAX_ITERATIONS=${RALPH_MAX_ITERATIONS:-5}
TEST_COMMAND=${RALPH_TEST_COMMAND:-""}
AGENT_BACKEND=${RALPH_AGENT_BACKEND:-opencode}
BRANCH_PREFIX=${RALPH_BRANCH_PREFIX:-ralph/issue-}
PROTECTED_PATTERNS=${RALPH_PROTECTED_PATTERNS:-"*_test.* *_spec.* test_*.* *.test.*"}

# Unified API configuration: protocol / base_url / model / key
API_PROTOCOL=${RALPH_API_PROTOCOL:-openai}          # openai | anthropic
API_BASE_URL=${RALPH_API_BASE_URL:-}
API_MODEL=${RALPH_API_MODEL:-}
API_KEY=${RALPH_API_KEY:-}
API_MAX_TOKENS=${RALPH_API_MAX_TOKENS:-32768}
OPENCODE_TIMEOUT=${RALPH_OPENCODE_TIMEOUT:-900}
OPENCODE_HEARTBEAT_SECONDS=${RALPH_OPENCODE_HEARTBEAT_SECONDS:-30}


# Plan-and-Execute configuration
PLAN_MODE=${RALPH_PLAN_MODE:-auto}              # auto | always | off
PLAN_EXECUTION_MODE=${RALPH_PLAN_EXECUTION_MODE:-single}  # single | multi
REQUIRE_PLAN_APPROVAL=${RALPH_REQUIRE_PLAN_APPROVAL:-false}  # true = wait for human
PLAN_TIMEOUT=${RALPH_PLAN_TIMEOUT:-30}           # minutes to wait for approval
REACT_MAX_RETRIES=${RALPH_REACT_MAX_RETRIES:-3}  # ReAct retries per subtask
PROGRESS_COMMENT_ID=""                           # updated at runtime

: "${ISSUE_NUMBER:?ISSUE_NUMBER is required}"
: "${REPO_FULL_NAME:?REPO_FULL_NAME is required}"
: "${GITHUB_TOKEN:?GITHUB_TOKEN is required}"

OWNER=$(echo "$REPO_FULL_NAME" | cut -d/ -f1)
REPO=$(echo "$REPO_FULL_NAME" | cut -d/ -f2)
BRANCH="${BRANCH_PREFIX}${ISSUE_NUMBER}"
SPEC_FILE=".ralph/spec-${ISSUE_NUMBER}.md"

# Issue repo: where the issue lives (may differ from code repo for /create flows)
ISSUE_REPO=${RALPH_ISSUE_REPO:-$REPO_FULL_NAME}

# Language for user-facing messages (zh or en)
LANG=${RALPH_LANG:-zh-CN}

log() { echo "🐺 [ralph] $*"; }
fail() { log "FATAL: $*"; exit 1; }

llm_api_available() {
  [ -n "${API_KEY:-}" ]
}

normalize_issue_text() {
  local input="${1:-}"
  printf '%s' "$input" | sed 's/\r//g' | sed 's/[[:space:]]\+$//'
}

issue_body_char_count() {
  local body
  body=$(normalize_issue_text "$1")
  printf '%s' "$body" | tr -d '\n[:space:]' | wc -c | tr -d ' '
}

issue_body_line_count() {
  local body
  body=$(normalize_issue_text "$1")
  [ -z "$body" ] && { echo 0; return 0; }
  printf '%s\n' "$body" | wc -l | tr -d ' '
}

issue_has_structured_markers() {
  local body
  body=$(normalize_issue_text "$1" | tr '[:upper:]' '[:lower:]')
  echo "$body" | grep -Eq '(^|\n)(目标|要求|限制|验收|背景|context|goal|requirements|constraints|acceptance|background)[:：]' 
}

extract_issue_section() {
  local body="$1" pattern="$2"
  printf '%s' "$body" | awk -v pat="$pattern" '
    BEGIN { IGNORECASE=1; found=0 }
    $0 ~ pat {
      found=1
      sub("^[^:：]*[:：][[:space:]]*", "", $0)
      print
      next
    }
    found {
      if ($0 ~ /^[[:space:]]*$/) exit
      if ($0 ~ /^(目标|要求|限制|验收|背景|context|goal|requirements|constraints|acceptance|background)[[:space:]]*[:：]/) exit
      print
    }
  ' | sed '/^[[:space:]]*$/d'
}

build_structured_requirements() {
  local body
  body=$(normalize_issue_text "$1")
  [ -z "$body" ] && return 0

  local objective requirements constraints acceptance background
  objective=$(extract_issue_section "$body" '^(目标|goal)[[:space:]]*[:：]')
  requirements=$(extract_issue_section "$body" '^(要求|requirements?)[[:space:]]*[:：]')
  constraints=$(extract_issue_section "$body" '^(限制|constraints?)[[:space:]]*[:：]')
  acceptance=$(extract_issue_section "$body" '^(验收|acceptance)[[:space:]]*[:：]')
  background=$(extract_issue_section "$body" '^(背景|context|background)[[:space:]]*[:：]')

  if [ -n "$objective$requirements$constraints$acceptance$background" ]; then
    [ -n "$objective" ] && printf '### Parsed Objective\n%s\n\n' "$objective"
    [ -n "$requirements" ] && printf '### Parsed Requirements\n%s\n\n' "$requirements"
    [ -n "$constraints" ] && printf '### Parsed Constraints\n%s\n\n' "$constraints"
    [ -n "$acceptance" ] && printf '### Parsed Acceptance Criteria\n%s\n\n' "$acceptance"
    [ -n "$background" ] && printf '### Parsed Background\n%s\n\n' "$background"
  else
    printf '### Raw Issue Body\n%s\n' "$body"
  fi
}

is_low_context_issue() {
  local body chars lines
  body=$(normalize_issue_text "$1")
  chars=$(issue_body_char_count "$body")
  lines=$(issue_body_line_count "$body")
  [ "$chars" -lt 24 ] && ! issue_has_structured_markers "$body" && [ "$lines" -le 3 ]
}

truncate_single_line() {
  local text="$1" limit="${2:-120}"
  text=$(printf '%s' "$text" | tr '\r\n' ' ' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')
  if [ "${#text}" -gt "$limit" ]; then
    printf '%s…' "${text:0:$((limit - 1))}"
  else
    printf '%s' "$text"
  fi
}

latest_opencode_log_hint() {
  local log_file="$1"
  [ -f "$log_file" ] || return 0

  local hint
  hint=$(grep -v '^[[:space:]]*$' "$log_file" | tail -1 2>/dev/null || true)
  [ -z "$hint" ] && return 0
  truncate_single_line "$hint" 100
}

refresh_live_progress_comment() {
  local plan_file=".ralph/plan-${ISSUE_NUMBER}.json"
  [ -n "${PROGRESS_COMMENT_ID:-}" ] || return 0
  [ -f "$plan_file" ] || return 0
  update_progress "$(cat "$plan_file")" >/dev/null 2>&1 || true
}

run_opencode_with_timeout() {
  local prompt="$1"
  local timeout_cmd=""
  local log_file=".ralph/opencode-run.log"
  local start_ts elapsed command_string command_pid heartbeat_pid status interval hint

  mkdir -p .ralph
  : > "$log_file"
  interval="$OPENCODE_HEARTBEAT_SECONDS"
  if ! printf '%s' "$interval" | grep -Eq '^[0-9]+$' || [ "$interval" -le 0 ]; then
    interval=30
  fi

  if command -v timeout >/dev/null 2>&1; then
    timeout_cmd="timeout ${OPENCODE_TIMEOUT}s"
  elif command -v gtimeout >/dev/null 2>&1; then
    timeout_cmd="gtimeout ${OPENCODE_TIMEOUT}s"
  fi

  printf -v command_string '%q ' opencode --print-logs run "$prompt"
  command_string="${command_string% }"
  if [ -n "$timeout_cmd" ]; then
    command_string="${timeout_cmd} ${command_string}"
  fi

  log "🤖 Phase: OpenCode — starting (timeout ${OPENCODE_TIMEOUT}s)"
  log "📝 OpenCode live log: ${log_file}"
  start_ts=$(date +%s)

  bash -o pipefail -c "${command_string} 2>&1 | tee $(printf '%q' "$log_file")" &
  command_pid=$!

  (
    while kill -0 "$command_pid" 2>/dev/null; do
      sleep "$interval"
      kill -0 "$command_pid" 2>/dev/null || exit 0
      elapsed=$(( $(date +%s) - start_ts ))
      hint=$(latest_opencode_log_hint "$log_file")
      if [ -n "$hint" ]; then
        log "⏳ OpenCode still running... ${elapsed}s elapsed | latest: ${hint}"
      else
        log "⏳ OpenCode still running... ${elapsed}s elapsed"
      fi
      refresh_live_progress_comment
    done
  ) &
  heartbeat_pid=$!

  wait "$command_pid"
  status=$?
  kill "$heartbeat_pid" 2>/dev/null || true
  wait "$heartbeat_pid" 2>/dev/null || true

  elapsed=$(( $(date +%s) - start_ts ))
  if [ "$status" -eq 0 ]; then
    log "✅ OpenCode finished in ${elapsed}s"
  else
    log "❌ OpenCode exited with status ${status} after ${elapsed}s"
  fi

  return "$status"
}

# Post comment on the issue
post_comment() {
  local body="$1"
  local body_json
  body_json=$(printf '%s' "$body" | jq -Rs .)
  curl -sS --max-time 10 -X POST \
    "https://api.github.com/repos/${ISSUE_REPO}/issues/${ISSUE_NUMBER}/comments" \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"body\": ${body_json}}" >/dev/null 2>&1 || true
}

source "$(dirname "$0")/scripts/lib/planning.sh"
source "$(dirname "$0")/scripts/lib/i18n.sh"
source "$(dirname "$0")/scripts/lib/reporting.sh"
source "$(dirname "$0")/scripts/lib/execution.sh"

# —— Setup OpenCode config ——————————————————————————————————————————————————————————
setup_opencode_config() {
  local config_file="opencode.json"
  local api_protocol="${API_PROTOCOL:-openai}"
  local provider_api="openai"
  local base_url="${API_BASE_URL:-}"
  local model_id="${API_MODEL:-}"

  # Determine provider API type
  if [ "$api_protocol" = "anthropic" ]; then
    provider_api="anthropic"
  fi

  # Build provider name from base URL
  local provider_name="ralph-provider"

  cat > "$config_file" <<OCEOF
{
  "\$schema": "https://opencode.ai/config.json",
  "provider": {
    "${provider_name}": {
      "api": "${provider_api}",
      "name": "Ralph AI Provider",
      "env": ["OPENAI_API_KEY"],
      "options": {
        "baseURL": "${base_url}/v1"
      },
      "models": {
        "${model_id}": {
          "name": "${model_id}"
        }
      }
    }
  },
  "model": "${provider_name}/${model_id}",
  "agent": {
    "build": {
      "tools": {
        "edit": true,
        "write": true,
        "bash": true,
        "glob": true,
        "grep": true,
        "read": true,
        "webfetch": true
      },
      "system": "You are Ralph, an autonomous AI coding agent. Implement the given requirements precisely. Read existing code before modifying. Do NOT modify test files, .github/, feishu/, or ralph.sh."
    }
  },
  "mcp": {
    "github": {
      "type": "local",
      "command": ["npx", "-y", "@modelcontextprotocol/server-github"],
      "enabled": true,
      "environment": {
        "GITHUB_PERSONAL_ACCESS_TOKEN": "${GITHUB_TOKEN}"
      }
    }
  }
}
OCEOF
  log "Generated opencode.json (provider=${provider_name}, model=${model_id})"

  # Ensure opencode.json (contains secrets) is never committed
  if ! grep -qx 'opencode.json' .gitignore 2>/dev/null; then
    echo 'opencode.json' >> .gitignore
  fi
}

# —— Validate backend ———————————————————————————————————————————————————————————————
log "Backend: ${AGENT_BACKEND}"
case "$AGENT_BACKEND" in
  llm)
    [ -z "$API_KEY" ] && fail "API key is not set (RALPH_API_KEY)"
    log "LLM: ${API_MODEL} via ${API_BASE_URL} (${API_PROTOCOL})"
    ;;
  opencode)
    command -v opencode &>/dev/null || fail "'opencode' CLI not found"
    [ -z "$API_KEY" ] && fail "API key is not set (RALPH_API_KEY, needed for opencode)"
    export OPENAI_API_KEY="$API_KEY"
    log "OpenCode: model=${API_MODEL:-auto} base=${API_BASE_URL:-default}"

    # Generate opencode.json for this run
    setup_opencode_config
    ;;
  *) fail "Unknown backend: ${AGENT_BACKEND}" ;;
esac

#———————————————————————————————————————————————————————
# LLM Backend functions
#———————————————————————————————————————————————————————
call_llm() {
  local prompt="$1"
  local codebase_context="$2"

  local system_msg='You are Ralph, an autonomous coding agent. You receive a spec and codebase context, then output ONLY the file changes needed.

Output format - for each file, output exactly:
--- FILE: path/to/file ---
<entire file content>
--- END FILE ---

Rules:
- Output complete file contents (not diffs)
- Do NOT modify any test files (*_test.*, *_spec.*, test_*.*, *.test.*)
- Do NOT create or modify files under .github/ directory
- Do NOT create or modify files under feishu/ directory
- Do NOT modify ralph.sh
- Only output files that need changes or need to be created
- No explanations, no markdown fences, no commentary, just the file blocks
- If creating new files, include the full file path
- Do NOT wrap output in <think> tags or any other tags
- Start your response directly with --- FILE: ...'

  local user_msg="${prompt}

--- CODEBASE CONTEXT ---
${codebase_context}
--- END CODEBASE CONTEXT ---"

  local sys_json usr_json
  sys_json=$(printf '%s' "$system_msg" | jq -Rs .)
  usr_json=$(printf '%s' "$user_msg" | jq -Rs .)

  log "Calling LLM API: ${API_MODEL} via ${API_BASE_URL} (${API_PROTOCOL})..."
  local response
  if [ "$API_PROTOCOL" = "anthropic" ]; then
    # Anthropic Messages API
    response=$(curl -sS --max-time 300 -X POST "${API_BASE_URL}/v1/messages" \
      -H "x-api-key: ${API_KEY}" \
      -H "anthropic-version: 2023-06-01" \
      -H "Content-Type: application/json" \
      -d "{
        \"model\": \"${API_MODEL}\",
        \"max_tokens\": ${API_MAX_TOKENS},
        \"system\": ${sys_json},
        \"messages\": [
          {\"role\": \"user\", \"content\": ${usr_json}}
        ]
      }")
  else
    # OpenAI Chat Completions API (default)
    response=$(curl -sS --max-time 300 -X POST "${API_BASE_URL}/v1/chat/completions" \
      -H "Authorization: Bearer ${API_KEY}" \
      -H "Content-Type: application/json" \
      -d "{
        \"model\": \"${API_MODEL}\",
        \"messages\": [
          {\"role\": \"system\", \"content\": ${sys_json}},
          {\"role\": \"user\", \"content\": ${usr_json}}
        ],
        \"max_tokens\": ${API_MAX_TOKENS},
        \"temperature\": 0.1
      }")
  fi

  local error
  error=$(echo "$response" | jq -r '.error.message // .error.type // empty' 2>/dev/null || true)
  if [ -n "$error" ]; then
    log "LLM API error: $error"
    return 1
  fi

  local content
  if [ "$API_PROTOCOL" = "anthropic" ]; then
    # Anthropic: .content[0].text
    content=$(echo "$response" | jq -r '.content[0].text // empty')
  else
    # OpenAI: .choices[0].message.content
    content=$(echo "$response" | jq -r '.choices[0].message.content // empty')
  fi
  if [ -z "$content" ]; then
    log "LLM returned empty content"
    return 1
  fi

  content=$(echo "$content" | sed '/<think>/,/<\/think>/d' | sed 's/<think>.*<\/think>//g')
  content=$(echo "$content" | sed '/^```$/d' | sed '/^```\w*$/d')

  local byte_count
  byte_count=$(echo "$content" | wc -c | tr -d ' ')
  log "LLM response: ${byte_count} bytes"

  if [ "$byte_count" -lt 20 ]; then
    log "LLM response too short"
    return 1
  fi

  echo "$content"
}

apply_llm_output() {
  local output="$1"
  local files_written=0
  local current_file="" current_content="" in_file=false

  while IFS= read -r line; do
    if [[ "$line" =~ ^---\ FILE:\ (.+)\ ---$ ]]; then
      if [ "$in_file" = true ] && [ -n "$current_file" ]; then
        write_file "$current_file" "$current_content" && ((files_written++)) || true
      fi
      current_file="${BASH_REMATCH[1]}"
      current_content=""
      in_file=true
    elif [[ "$line" =~ ^---\ END\ FILE\ ---$ ]]; then
      if [ -n "$current_file" ]; then
        write_file "$current_file" "$current_content" && ((files_written++)) || true
      fi
      current_file="" current_content="" in_file=false
    elif [ "$in_file" = true ]; then
      [ -n "$current_content" ] && current_content="${current_content}
${line}" || current_content="$line"
    fi
  done <<< "$output"

  if [ "$in_file" = true ] && [ -n "$current_file" ]; then
    log "WARNING: Truncated output — writing last unclosed file: $current_file"
    write_file "$current_file" "$current_content" && ((files_written++)) || true
  fi

  log "Wrote ${files_written} file(s)"
  if [ "$files_written" -eq 0 ]; then
    log "ERROR: No files written!"
    echo "$output" | head -50
    return 1
  fi
}

write_file() {
  local filepath="$1" content="$2"
  filepath="${filepath#./}"

  case "$filepath" in
    .github/*|feishu/*|ralph.sh|.ralph/*)
      log "SKIPPED (infrastructure): $filepath"
      return 1
      ;;
  esac

  for pattern in _test\\. _spec\\. test_\\. \\.test\\. \\.spec\\.; do
    if echo "$filepath" | grep -qE "$pattern"; then
      log "SKIPPED (protected): $filepath"
      return 1
    fi
  done

  mkdir -p "$(dirname "$filepath")"
  printf '%s\n' "$content" > "$filepath"
  log "WROTE: $filepath"
}

gather_context() {
  local ctx=""
  local -a priority_files=() other_files=()

  local keywords
  keywords=$(echo "$ISSUE_TITLE $ISSUE_BODY" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]_' '\n' | sort -u | grep -E '^[a-z_]{3,}$' | grep -vE '^(the|and|for|not|with|this|that|from|have|but|are|was|will|would|could|should|can|may|into|than|then|also|just|only|some|more|all|any|our|you|your|who|which|when|how|what|where|why|each|use|set|get|run|let|try|new|old|one|two)$' | head -15)

  local -a all_files=()
  while IFS= read -r -d '' f; do
    all_files+=("$f")
  done < <(find . -type f \
    -not -path './.git/*' \
    -not -path './.ralph/*' \
    -not -path './.github/*' \
    -not -path './feishu/*' \
    -not -path './hooks/*' \
    -not -path './scripts/*' \
    -not -path './node_modules/*' \
    -not -path './vendor/*' \
    -not -path './.next/*' \
    -not -path './dist/*' \
    -not -path './build/*' \
    -not -path './__pycache__/*' \
    -not -name 'ralph.sh' \
    -not -name '*.lock' \
    -not -name 'go.sum' \
    -not -name '*.min.js' \
    -not -name '*.min.css' \
    -not -name '*.png' -not -name '*.jpg' -not -name '*.gif' \
    -not -name '*.ico' -not -name '*.svg' -not -name '*.pdf' \
    -not -name '*.woff*' -not -name '*.ttf' -not -name '*.eot' \
    -not -name '*.zip' -not -name '*.tar*' -not -name '*.gz' \
    -print0 2>/dev/null || true)

  for f in "${all_files[@]}"; do
    local fname
    fname=$(echo "$f" | tr '[:upper:]' '[:lower:]')
    local is_priority=false
    for kw in $keywords; do
      if echo "$fname" | grep -q "$kw"; then
        is_priority=true
        break
      fi
    done
    if [ "$is_priority" = true ]; then
      priority_files+=("$f")
    else
      other_files+=("$f")
    fi
  done

  log "Context: ${#priority_files[@]} priority, ${#other_files[@]} other"

  local count=0 max_files=50
  for f in "${priority_files[@]}" "${other_files[@]}"; do
    [ "$count" -ge "$max_files" ] && break
    if file -b --mime-type "$f" 2>/dev/null | grep -qv '^text/'; then
      continue
    fi
    local lines
    lines=$(wc -l < "$f" 2>/dev/null || echo "999999")
    if [ "$lines" -lt 300 ]; then
      local file_content
      file_content=$(cat "$f" 2>/dev/null) || continue
      ctx="${ctx}
--- FILE: ${f} ---
${file_content}
--- END FILE ---"
      ((count++)) || true
    fi
  done

  log "Context: ${count} file(s) included"
  echo "$ctx"
}

#———————————————————————————————————————————————————————
# Self-Review: LLM-powered code review
#———————————————————————————————————————————————————————
self_review() {
  local diff="$1"
  local spec_content
  spec_content=$(cat "$SPEC_FILE" 2>/dev/null || echo "No spec available")

  local system_msg='你是 Ralph 的代码审查模块，一位严格的高级代码审查员。
审查以下代码改动，对照需求规格进行评估。

评估维度：
1. 正确性 — 代码逻辑是否正确实现了需求
2. 安全性 — 是否存在注入、XSS、敏感信息泄露等风险
3. 健壮性 — 边界条件、错误处理
4. 可维护性 — 代码清晰度、命名

严格输出格式：
第一行必须是 VERDICT: PASS 或 VERDICT: NEEDS_FIX
第二行必须是 CRITICAL_COUNT: 数字

然后列出发现：
[CRITICAL] 文件名: 描述
[WARNING] 文件名: 描述
[INFO] 文件名: 描述

规则：
- 只有真正的 bug、安全漏洞、逻辑错误标记为 CRITICAL
- CRITICAL_COUNT 为 0 时 VERDICT 必须为 PASS
- 不要输出 <think> 标签'

  local user_msg="--- SPEC ---
${spec_content}
--- END SPEC ---

--- CODE CHANGES ---
${diff}
--- END CODE CHANGES ---"

  local sys_json usr_json
  sys_json=$(printf '%s' "$system_msg" | jq -Rs .)
  usr_json=$(printf '%s' "$user_msg" | jq -Rs .)

  log "Running LLM Self-Review..."
  local response
  response=$(curl -sS --max-time 120 -X POST "${API_BASE_URL}/v1/chat/completions" \
    -H "Authorization: Bearer ${API_KEY}" \
    -H "Content-Type: application/json" \
    -d "{
      \"model\": \"${API_MODEL}\",
      \"messages\": [
        {\"role\": \"system\", \"content\": ${sys_json}},
        {\"role\": \"user\", \"content\": ${usr_json}}
      ],
      \"max_tokens\": 4096,
      \"temperature\": 0.1
    }") || return 1

  local content
  content=$(echo "$response" | jq -r '.choices[0].message.content // empty')
  [ -z "$content" ] && return 1
  content=$(echo "$content" | sed '/<think>/,/<\/think>/d' | sed 's/<think>.*<\/think>//g')
  echo "$content"
}

#———————————————————————————————————————————————————————
#———————————————————————————————————————————————————————
# Step 1: Fetch Issue
#———————————————————————————————————————————————————————
log "Fetching issue #${ISSUE_NUMBER}..."

ISSUE_JSON=$(gh api "/repos/${ISSUE_REPO}/issues/${ISSUE_NUMBER}" 2>/dev/null) \
  || fail "Could not fetch issue #${ISSUE_NUMBER}"

ISSUE_TITLE=$(echo "$ISSUE_JSON" | jq -r '.title')
ISSUE_BODY=$(echo "$ISSUE_JSON" | jq -r '.body // ""')

log "Issue: ${ISSUE_TITLE}"

LOW_CONTEXT_ISSUE=false
CLARIFICATION_REQUIRED=false
if is_low_context_issue "$ISSUE_BODY"; then
  LOW_CONTEXT_ISSUE=true
  log "⚠️ Issue body is low-context (${ISSUE_BODY:-empty})"
fi
ISSUE_BODY_CHARS=$(issue_body_char_count "$ISSUE_BODY")
ISSUE_BODY_LINES=$(issue_body_line_count "$ISSUE_BODY")
log "Issue context: ${ISSUE_BODY_CHARS} chars across ${ISSUE_BODY_LINES} line(s)"
if [ "$LOW_CONTEXT_ISSUE" = true ] && [ "${RALPH_AUTO_REQUIRE_CONTEXT:-true}" = "true" ]; then
  CLARIFICATION_REQUIRED=true
fi

#———————————————————————————————————————————————————————
# Step 2: Auto-detect test command
#———————————————————————————————————————————————————————
if [ -z "$TEST_COMMAND" ]; then
  if [ -f "Makefile" ] && grep -q "^test:" Makefile; then
    TEST_COMMAND="make test"
  elif [ -f "package.json" ]; then
    TEST_COMMAND="npm test"
  elif [ -f "go.mod" ]; then
    TEST_COMMAND="go test ./..."
  elif [ -f "Cargo.toml" ]; then
    TEST_COMMAND="cargo test"
  elif [ -f "pyproject.toml" ] || [ -f "setup.py" ]; then
    TEST_COMMAND="pytest"
  fi
  [ -n "$TEST_COMMAND" ] && log "Test command: ${TEST_COMMAND}" || log "No test framework detected."
fi

#———————————————————————————————————————————————————————
# Step 3: Generate Spec
#———————————————————————————————————————————————————————
log "Generating spec..."
mkdir -p .ralph

cat > "$SPEC_FILE" <<SPEC
# Spec: Issue #${ISSUE_NUMBER}

## Objective
${ISSUE_TITLE}

## Requirements
${ISSUE_BODY}

## Structured Interpretation
$(build_structured_requirements "$ISSUE_BODY")

## Context Quality
$([ "$LOW_CONTEXT_ISSUE" = true ] && echo "- Low-context issue: body is very short or underspecified. Prefer conservative changes and infer as little as possible." || echo "- Issue body contains enough detail to guide planning and implementation.")

## Constraints
- Do NOT modify test files: ${PROTECTED_PATTERNS}
- Do NOT create or modify files under .github/ directory
- Do NOT change CI/CD configuration or workflow files
- Do NOT modify ralph.sh or infrastructure files
- Keep changes minimal and focused
$([ -n "$TEST_COMMAND" ] && echo "- All tests must pass: \`${TEST_COMMAND}\`")
SPEC

log "Spec written"

if [ "$CLARIFICATION_REQUIRED" = true ]; then
  log "🛑 Auto strategy: clarification required before coding"
  if [ "$(normalize_lang "$LANG")" = "zh-CN" ]; then
    post_comment "> [!IMPORTANT]
> ### ❓ Ralph 需要补充信息
>
> 当前 Issue 信息过少，已停止自动编码，避免在低上下文下误改代码。
>
> 请至少补充以下任意两项后，再重新触发：
> - 目标
> - 具体要求
> - 限制条件
> - 验收标准
>
> 建议直接使用结构化格式：
> \`目标:\`
> \`要求:\`
> \`限制:\`
> \`验收:\`"
    mark_execution_result "clarification_needed" "intake" "Issue body is too short; add goal, requirements, constraints, or acceptance criteria before coding" "context:${ISSUE_BODY_CHARS} chars" "" "low_context"
  else
    post_comment "> [!IMPORTANT]
> ### ❓ Ralph needs clarification
>
> This issue does not contain enough context, so coding has been stopped to avoid low-confidence changes.
>
> Please add at least two of the following, then trigger Ralph again:
> - Goal
> - Specific requirements
> - Constraints
> - Acceptance criteria
>
> Recommended structure:
> \`Goal:\`
> \`Requirements:\`
> \`Constraints:\`
> \`Acceptance:\`"
    mark_execution_result "clarification_needed" "intake" "Issue body is too short; add goal, requirements, constraints, or acceptance criteria before coding" "context:${ISSUE_BODY_CHARS} chars" "" "low_context"
  fi
  exit 0
fi

#———————————————————————————————————————————————————————
# Step 3.5: Task Planning (assess complexity, generate phased plan)
#———————————————————————————————————————————————————————
TASK_COMPLEXITY="SIMPLE"

if [ -n "${API_KEY:-}" ]; then
  log "🧠 Phase: Planning..."
  PLAN_OUTPUT=$(plan_task_legacy 2>/dev/null) || PLAN_OUTPUT=""

  if [ -n "$PLAN_OUTPUT" ]; then
    TASK_COMPLEXITY=$(echo "$PLAN_OUTPUT" | grep -o '^COMPLEXITY: [A-Z]*' | awk '{print $2}' || echo "SIMPLE")
    TASK_COMPLEXITY=${TASK_COMPLEXITY:-SIMPLE}

    if [ "$TASK_COMPLEXITY" = "COMPLEX" ]; then
      SUBTASK_COUNT=$(echo "$PLAN_OUTPUT" | grep -o '^SUBTASK_COUNT: [0-9]*' | awk '{print $2}' || echo "1")
      SUBTASK_COUNT=${SUBTASK_COUNT:-1}
      PHASES=$(echo "$PLAN_OUTPUT" | grep '^PHASE ' || echo "")

      log "📋 Complex task: ${SUBTASK_COUNT} phases"

      # Enhance spec with phased plan
      if [ "$(normalize_lang "$LANG")" = "zh-CN" ]; then
        cat >> "$SPEC_FILE" <<PLAN

## 执行计划 (${SUBTASK_COUNT} 个阶段，按顺序实现)
${PHASES}

## 执行指示
- 按顺序实现各阶段：完成阶段 1，再进行阶段 2，以此类推
- 每个阶段必须能独立编译/运行
- 一次输出所有需要修改的文件（包括前面阶段的内容）
- 如果收到之前的反馈，先修复那些问题，然后继续下一个阶段
PLAN
      else
        cat >> "$SPEC_FILE" <<PLAN

## Execution Plan (${SUBTASK_COUNT} phases, implement in order)
${PHASES}

## Execution Instructions
- Implement phases in order: complete phase 1, then phase 2, and so on
- Each phase must compile/run independently
- Output all files that need modification at once (including content from previous phases)
- If you receive PREVIOUS FEEDBACK, fix those issues first, then continue with the next phase
PLAN
      fi

      # Post plan as issue comment
      PHASE_LIST=$(echo "$PHASES" | sed 's/^PHASE \([0-9]*\): \(.*\)/> \1. **\2**/' || echo "> (plan parsing failed)")
      if [ "$(normalize_lang "$LANG")" = "zh-CN" ]; then
        post_comment "> [!NOTE]
> ### 🧠 Ralph 任务分析
>
> 此任务已拆分为 **${SUBTASK_COUNT} 个执行阶段**：
>
${PHASE_LIST}
>
> 开始按计划执行..."
      else
        post_comment "> [!NOTE]
> ### 🧠 Ralph Task Analysis
>
> This task has been decomposed into **${SUBTASK_COUNT} execution phases**:
>
${PHASE_LIST}
>
> Starting execution..."
      fi
    else
      log "✅ Simple task, proceeding directly"
    fi
  fi
fi

if [ "$PLAN_MODE" = "auto" ] && [ "$TASK_COMPLEXITY" = "SIMPLE" ]; then
  log "⚙️ Auto strategy: simple task detected, prefer legacy loop over plan-and-execute"
fi

if [ "$LOW_CONTEXT_ISSUE" = true ] && [ "$MAX_ITERATIONS" -gt 2 ]; then
  log "⚙️ Auto strategy: low-context issue detected, clamp legacy iterations ${MAX_ITERATIONS} -> 2"
  MAX_ITERATIONS=2
elif [ "$TASK_COMPLEXITY" = "SIMPLE" ] && [ "$MAX_ITERATIONS" -gt 3 ]; then
  log "⚙️ Auto strategy: simple task detected, clamp legacy iterations ${MAX_ITERATIONS} -> 3"
  MAX_ITERATIONS=3
fi

#———————————————————————————————————————————————————————
# Step 4: Create branch
#———————————————————————————————————————————————————————
log "Creating branch ${BRANCH}..."
git config user.name "ralph[bot]"
git config user.email "ralph[bot]@users.noreply.github.com"

# Handle empty/new repos: ensure we have at least one commit
if ! git rev-parse HEAD >/dev/null 2>&1; then
  log "Empty repo detected, initializing..."
  echo "# $(echo "$REPO_FULL_NAME" | cut -d/ -f2)" > README.md
  git add README.md
  git commit -m "chore: initialize repository [ralph]"
  git branch -M main
  git push -u origin main 2>/dev/null || true
fi

IS_NEW_REPO="${RALPH_NEW_REPO:-false}"
git push origin --delete "$BRANCH" 2>/dev/null || true
git checkout -B "$BRANCH"

#———————————————————————————————————————————————————————
# Step 5: Anti-cheat hook
#———————————————————————————————————————————————————————
mkdir -p .git/hooks
cat > .git/hooks/pre-commit <<'HOOK'
#!/usr/bin/env bash
for file in $(git diff --cached --name-only); do
  case "$file" in
    .ralph/*|ralph.sh)
      echo "🐺 BLOCKED (infrastructure): $file"; exit 1
      ;;
  esac
  for p in '_test\.' '_spec\.' 'test_\.' '\.test\.' '\.spec\.' '__tests__/' '__snapshots__/'; do
    if echo "$file" | grep -qE "$p"; then
      echo "🐺 BLOCKED (test): $file"; exit 1
    fi
  done
  case "$file" in
    .github/*)
      echo "🐺 BLOCKED (workflow): $file"; exit 1
      ;;
  esac
done
HOOK
chmod +x .git/hooks/pre-commit

#———————————————————————————————————————————————————————
# Step 6: Execution — Plan-and-Execute or Legacy Loop
#———————————————————————————————————————————————————————

SUCCESS=false
LAST_ITERATION=0

# Determine execution mode
USE_PLAN_EXECUTE=false
if [ "$PLAN_MODE" = "always" ]; then
  USE_PLAN_EXECUTE=true
elif [ "$PLAN_MODE" = "auto" ] && llm_api_available; then
  # Auto-detect: use Plan-and-Execute when LLM API is available
  if [ "$TASK_COMPLEXITY" = "COMPLEX" ] && [ "$LOW_CONTEXT_ISSUE" = false ]; then
    USE_PLAN_EXECUTE=true
  fi
fi

if [ "$USE_PLAN_EXECUTE" = true ] && llm_api_available; then
  #═══════════════════════════════════════════════════════
  # Path A: Plan-and-Execute + ReAct (new paradigm)
  #═══════════════════════════════════════════════════════
  log "Mode: Plan-and-Execute + ReAct (${PLAN_EXECUTION_MODE})"

  PLAN_JSON=$(plan_task "$ISSUE_TITLE" "$ISSUE_BODY") || PLAN_JSON=""

  if [ -n "$PLAN_JSON" ] && echo "$PLAN_JSON" | jq -e '.subtasks | length > 0' >/dev/null 2>&1; then
    COMPLEXITY=$(echo "$PLAN_JSON" | jq -r '.complexity')
    SUBTASK_COUNT=$(echo "$PLAN_JSON" | jq '.subtasks | length')
    log "Plan: ${COMPLEXITY} complexity, ${SUBTASK_COUNT} subtask(s)"

    if run_plan_and_execute "$PLAN_JSON"; then
      SUCCESS=true
    else
      mark_execution_result "failed" "planning" "Plan-and-Execute did not complete successfully" "" "" "plan_execute_incomplete"
      log "Plan-and-Execute did not complete successfully"
    fi
  else
    mark_execution_result "executing" "planning" "Planning failed or empty, falling back to legacy loop" "" "" "plan_fallback"
    log "Planning failed or empty, falling back to legacy loop"
    USE_PLAN_EXECUTE=false
  fi
fi

if [ "$USE_PLAN_EXECUTE" = false ] || [ "$PLAN_MODE" = "off" ]; then
  #═══════════════════════════════════════════════════════
  # Path B: Legacy Loop (backward compatible)
  #═══════════════════════════════════════════════════════
  log "Mode: Legacy loop (max ${MAX_ITERATIONS})"

  REVIEW_DONE=false

  for i in $(seq 1 "$MAX_ITERATIONS"); do
    LAST_ITERATION=$i
    log "━━━ Iteration ${i}/${MAX_ITERATIONS} ━━━"

    PROMPT="Implement the requirements in the spec below. Create or modify files as needed.

--- SPEC ---
$(cat "$SPEC_FILE")
--- END SPEC ---"

    # Append previous feedback (test failures or review findings)
    if [ "$i" -gt 1 ] && [ -f ".ralph/last-feedback.txt" ]; then
      PROMPT="${PROMPT}

--- PREVIOUS FEEDBACK ---
$(tail -80 .ralph/last-feedback.txt)
--- END FEEDBACK ---

Fix the issues described above. If it's test failures, make the tests pass. If it's code review findings, fix all CRITICAL issues."
    fi

    AGENT_EXIT=0
    case "$AGENT_BACKEND" in
      opencode)
        run_opencode_with_timeout "$PROMPT" || AGENT_EXIT=$?
        ;;
      llm)
        CONTEXT=$(gather_context) || { log "Context gathering failed"; CONTEXT=""; }
        LLM_OUTPUT=$(call_llm "$PROMPT" "$CONTEXT") || { mark_execution_result "executing" "legacy_loop" "LLM call failed in legacy iteration" "iteration ${i}/${MAX_ITERATIONS}" "" "llm_call_failed"; log "LLM call failed on iteration $i"; continue; }
        apply_llm_output "$LLM_OUTPUT" || { mark_execution_result "executing" "legacy_loop" "Applying LLM output failed in legacy iteration" "iteration ${i}/${MAX_ITERATIONS}" "" "apply_failed"; log "Apply failed on iteration $i"; continue; }
        ;;
    esac

    # Force-revert any changes to protected directories (safety net)
    git checkout -- .github/ 2>/dev/null || true
    git checkout -- feishu/ 2>/dev/null || true
    git checkout -- ralph.sh 2>/dev/null || true

    # Check for real code changes (exclude infrastructure files and mode-only changes)
    CHANGED_FILES=$( {
      git diff --name-only -- ':!ralph.sh' ':!opencode.json' ':!.ralph/*' ':!.ralph-central/*' ':!.github/*' ':!feishu/*';
      git ls-files --others --exclude-standard -- ':!opencode.json' ':!.ralph/*' ':!.ralph-central/*' ':!.github/*' ':!feishu/*' ':!ralph.sh';
    } | sort -u )
    if [ -z "$CHANGED_FILES" ]; then
      log "WARNING: No real code changes after iteration $i (only infrastructure files changed)"
      mark_execution_result "executing" "legacy_loop" "No real code changes produced in legacy iteration" "iteration ${i}/${MAX_ITERATIONS}" "" "no_changes"
      continue
    fi
    log "Changed files:"
    echo "$CHANGED_FILES"

    # ── Phase: Test ────────────────────────────────────────────
    TESTS_PASSED=false
    if [ -n "$TEST_COMMAND" ]; then
      log "🧪 Phase: Test — ${TEST_COMMAND}"
      if TEST_OUTPUT=$(eval "$TEST_COMMAND" 2>&1); then
        log "✅ Tests passed!"
        TESTS_PASSED=true
      else
        echo "$TEST_OUTPUT" | tail -50
        echo "$TEST_OUTPUT" > .ralph/last-feedback.txt
        log "❌ Tests failed (iteration ${i}/${MAX_ITERATIONS})"
        mark_execution_result "executing" "testing" "Tests failed in legacy iteration" "iteration ${i}/${MAX_ITERATIONS}" "" "tests_failed"
      fi
    else
      TESTS_PASSED=true
    fi

    # Stage only real code changes, exclude infrastructure
    git add -A
    git reset HEAD -- .github/ 2>/dev/null || true
    git reset HEAD -- .ralph/ 2>/dev/null || true
    git reset HEAD -- .ralph-central/ 2>/dev/null || true
    git reset HEAD -- opencode.json 2>/dev/null || true
    git reset HEAD -- ralph.sh 2>/dev/null || true
    git reset HEAD -- feishu/ 2>/dev/null || true

    if [ "$TESTS_PASSED" = true ]; then
      # ── Phase: Self-Review ─────────────────────────────────────
      REVIEW_VERDICT="PASS"
      if [ -n "${API_KEY:-}" ] && [ "$REVIEW_DONE" = false ] && [ "$i" -lt "$MAX_ITERATIONS" ]; then
        # Build diff for review (tracked changes + new files)
        DIFF_FOR_REVIEW=$( {
          git diff HEAD -- ':!ralph.sh' ':!opencode.json' ':!.ralph/*' ':!.ralph-central/*' ':!.github/*' ':!feishu/*' 2>/dev/null || true
          git diff --cached -- ':!ralph.sh' ':!opencode.json' ':!.ralph/*' ':!.ralph-central/*' ':!.github/*' ':!feishu/*' 2>/dev/null || true
          for nf in $(git ls-files --others --exclude-standard -- ':!opencode.json' ':!.ralph/*' ':!.ralph-central/*' ':!.github/*' ':!feishu/*' ':!ralph.sh' 2>/dev/null); do
            echo "+++ NEW FILE: ${nf} +++"
            cat "$nf" 2>/dev/null || true
            echo "+++ END NEW FILE +++"
          done
        } )

        if [ -n "$DIFF_FOR_REVIEW" ]; then
          log "🔍 Phase: Self-Review..."
          REVIEW_OUTPUT=$(self_review "$DIFF_FOR_REVIEW" 2>/dev/null) || REVIEW_OUTPUT=""

          if [ -n "$REVIEW_OUTPUT" ]; then
            echo "$REVIEW_OUTPUT" > ".ralph/review-${ISSUE_NUMBER}.md"
            CRITICAL_COUNT=$(echo "$REVIEW_OUTPUT" | grep -c '^\[CRITICAL\]' 2>/dev/null || echo "0")
            CRITICAL_COUNT=${CRITICAL_COUNT:-0}

            if [ "$CRITICAL_COUNT" -gt 0 ]; then
              log "⚠️ Self-Review found ${CRITICAL_COUNT} critical issue(s), entering fix iteration"
              mark_execution_result "executing" "self_review" "Self-review requested fixes" "iteration ${i}/${MAX_ITERATIONS}" "${CRITICAL_COUNT} critical" "review_requested_changes"
              REVIEW_VERDICT="NEEDS_FIX"
              {
                echo "=== CODE REVIEW FINDINGS (${CRITICAL_COUNT} CRITICAL) ==="
                echo "$REVIEW_OUTPUT"
                echo "=== FIX ALL [CRITICAL] ISSUES ABOVE ==="
              } > .ralph/last-feedback.txt
            else
              log "✅ Self-Review passed"
              REVIEW_DONE=true
            fi
          else
            log "Self-review returned empty, skipping"
            REVIEW_DONE=true
          fi
        fi
      fi

      if [ "$REVIEW_VERDICT" = "NEEDS_FIX" ]; then
        # WIP commit, then re-enter loop to fix review issues
        git diff --cached --quiet || \
          git commit --no-verify -m "wip(#${ISSUE_NUMBER}): iteration ${i} — review fixes needed [ralph]" 2>/dev/null || true
        continue
      fi

      # Final commit
      git diff --cached --quiet && { log "Nothing to commit"; break; }
      git commit -m "feat(#${ISSUE_NUMBER}): ${ISSUE_TITLE} [ralph]" || {
        log "Commit blocked, unstaging protected files..."
        for p in $PROTECTED_PATTERNS; do git reset HEAD -- "$p" 2>/dev/null || true; done
        git commit -m "feat(#${ISSUE_NUMBER}): ${ISSUE_TITLE} [ralph]"
      }
      mark_execution_result "completed" "legacy_loop" "Legacy loop completed with commit" "iteration ${i}/${MAX_ITERATIONS}"
      SUCCESS=true
      break
    else
      # WIP commit — preserve incremental progress
      git diff --cached --quiet || \
        git commit --no-verify -m "wip(#${ISSUE_NUMBER}): iteration ${i}/${MAX_ITERATIONS} — tests failing [ralph]" 2>/dev/null || true
    fi
  done
fi

#———————————————————————————————————————————————————————
# Step 7: Push
#———————————————————————————————————————————————————————
if [ "$SUCCESS" = true ]; then
  log "Pushing ${BRANCH}..."
  git push -u origin "$BRANCH"
  log "🎉 Code pushed. PR will be created by the workflow."
else
  COMMIT_COUNT=$(git rev-list --count main..HEAD 2>/dev/null || echo "0")
  if [ "$COMMIT_COUNT" -gt 0 ]; then
    log "📦 Pushing partial progress (${COMMIT_COUNT} WIP commit(s) from ${LAST_ITERATION} iteration(s))..."
    git push -u origin "$BRANCH" || true
  fi
  mark_execution_result "failed" "legacy_loop" "Legacy loop exhausted without converging" "iterations:${LAST_ITERATION}/${MAX_ITERATIONS}" "${COMMIT_COUNT} commit(s)" "legacy_exhausted"
  log "💀 Failed after ${MAX_ITERATIONS} iterations."
  exit 1
fi
