#!/usr/bin/env bash

PLAN_EXECUTION_MODE=${RALPH_PLAN_EXECUTION_MODE:-single}

refresh_progress_comment_if_ready() {
  local plan_json="$1"
  [ -n "${PROGRESS_COMMENT_ID:-}" ] || return 0
  update_progress "$plan_json" >/dev/null 2>&1 || true
}

execution_result_file() {
  echo ".ralph/execution-result.json"
}

mark_execution_result() {
  local status="$1" stage="${2:-}" summary="${3:-}" current_subtask="${4:-}" next_subtask="${5:-}" failure_code="${6:-}"
  local state_file started_at started_ts elapsed_seconds now_ts
  state_file=$(execution_result_file)
  mkdir -p .ralph
  now_ts=$(date +%s)
  started_at=""
  started_ts=""
  if [ -f "$state_file" ]; then
    started_at=$(jq -r '.started_at // empty' "$state_file" 2>/dev/null || true)
    started_ts=$(jq -r '.started_ts // empty' "$state_file" 2>/dev/null || true)
  fi
  if [ -z "$started_at" ]; then
    started_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  fi
  if ! printf '%s' "$started_ts" | grep -Eq '^[0-9]+$'; then
    started_ts=$now_ts
  fi
  if [ -n "$started_ts" ]; then
    elapsed_seconds=$((now_ts - started_ts))
  else
    elapsed_seconds=0
  fi
  cat > "$state_file" <<EOF
{
  "status": $(printf '%s' "$status" | jq -Rs .),
  "stage": $(printf '%s' "$stage" | jq -Rs .),
  "summary": $(printf '%s' "$summary" | jq -Rs .),
  "failure_code": $(printf '%s' "$failure_code" | jq -Rs .),
  "current_subtask": $(printf '%s' "$current_subtask" | jq -Rs .),
  "next_subtask": $(printf '%s' "$next_subtask" | jq -Rs .),
  "mode": $(printf '%s' "$PLAN_EXECUTION_MODE" | jq -Rs .),
  "started_at": $(printf '%s' "$started_at" | jq -Rs .),
  "started_ts": $started_ts,
  "elapsed_seconds": $elapsed_seconds,
  "updated_at": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}
EOF
}

subtask_state_file() {
  local subtask_idx="$1"
  echo ".ralph/subtasks/subtask-$((subtask_idx + 1)).json"
}

subtask_state_value() {
  local subtask_idx="$1" key="$2"
  local state_file
  state_file=$(subtask_state_file "$subtask_idx")
  [ -f "$state_file" ] || return 1
  jq -r --arg key "$key" '.[$key] // empty' "$state_file" 2>/dev/null
}

subtask_is_terminal() {
  local subtask_idx="$1"
  local result
  result=$(subtask_state_value "$subtask_idx" "result" || true)
  [ "$result" = "passed" ] || [ "$result" = "partial" ]
}

subtask_dependencies_satisfied() {
  local plan_json="$1" subtask_idx="$2"
  local deps dep dep_idx

  deps=$(echo "$plan_json" | jq -r ".subtasks[$subtask_idx].depends_on[]? // empty")
  [ -z "$deps" ] && return 0

  for dep in $deps; do
    dep_idx=$((dep - 1))
    if ! subtask_is_terminal "$dep_idx"; then
      return 1
    fi
  done

  return 0
}

next_runnable_subtask_idx() {
  local plan_json="$1"
  local subtask_count idx
  subtask_count=$(echo "$plan_json" | jq '.subtasks | length')

  for idx in $(seq 0 $((subtask_count - 1))); do
    if subtask_is_terminal "$idx"; then
      continue
    fi
    if subtask_dependencies_satisfied "$plan_json" "$idx"; then
      echo "$idx"
      return 0
    fi
  done

  return 1
}

has_incomplete_subtasks() {
  local plan_json="$1"
  local subtask_count idx
  subtask_count=$(echo "$plan_json" | jq '.subtasks | length')

  for idx in $(seq 0 $((subtask_count - 1))); do
    if ! subtask_is_terminal "$idx"; then
      return 0
    fi
  done

  return 1
}

mark_subtask_state() {
  local plan_json="$1" subtask_idx="$2" phase="$3" result="${4:-}"
  local state_dir=".ralph/subtasks"
  mkdir -p "$state_dir"
  local title
  title=$(echo "$plan_json" | jq -r ".subtasks[$subtask_idx].title")
  cat > "${state_dir}/subtask-$((subtask_idx+1)).json" <<EOF
{
  "index": $((subtask_idx + 1)),
  "title": $(printf '%s' "$title" | jq -Rs .),
  "phase": $(printf '%s' "$phase" | jq -Rs .),
  "result": $(printf '%s' "$result" | jq -Rs .),
  "updated_at": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}
EOF
}

react_reason() {
  local subtask_json="$1" observation="$2" codebase_context="$3"

  local title desc verification
  title=$(echo "$subtask_json" | jq -r '.title')
  desc=$(echo "$subtask_json" | jq -r '.description')
  verification=$(echo "$subtask_json" | jq -r '.verification')

  local system_msg='你是 Ralph 的推理模块（ReAct Reason 阶段）。
分析当前子任务，输出你的推理过程和行动计划。

严格输出 JSON：
{
  "reasoning": "你对当前状态的分析，包括：要解决什么、可能的实现方式、需要注意的边界条件",
  "action_plan": "具体的编码步骤，按顺序列出",
  "files_to_create": ["需要新建的文件路径"],
  "files_to_modify": ["需要修改的文件路径"],
  "risk_assessment": "可能出错的地方和应对策略"
}

不要输出代码，只输出分析和计划。不要 markdown 代码块。不要 <think> 标签。'

  local user_msg="## 子任务: ${title}
${desc}

## 验证方式
${verification}

## 上下文
${codebase_context}"

  if [ -n "$observation" ]; then
    user_msg+="

## 上一轮观测（失败原因）
${observation}

请根据失败原因调整你的推理和行动计划。"
  fi

  local sys_json usr_json
  sys_json=$(printf '%s' "$system_msg" | jq -Rs .)
  usr_json=$(printf '%s' "$user_msg" | jq -Rs .)

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
  content=$(echo "$content" | sed '/<think>/,/<\/think>/d' | sed 's/<think>.*<\/think>//g' | sed '/^```/d')
  echo "$content"
}

react_act() {
  local subtask_json="$1" reasoning_json="$2" codebase_context="$3"

  local title desc
  title=$(echo "$subtask_json" | jq -r '.title')
  desc=$(echo "$subtask_json" | jq -r '.description')

  local action_plan
  action_plan=$(echo "$reasoning_json" | jq -r '.action_plan // empty' 2>/dev/null || echo "$reasoning_json")

  local prompt="基于以下推理分析，实现代码改动。

## 子任务: ${title}
${desc}

## 推理分析与行动计划
${action_plan}

## 约束
- Do NOT modify test files
- Do NOT modify .github/ or feishu/ or ralph.sh
- Keep changes minimal and focused"

  case "$AGENT_BACKEND" in
    opencode)
      run_opencode_with_timeout "$prompt" || true
      ;;
    llm)
      local llm_output
      llm_output=$(call_llm "$prompt" "$codebase_context") || { mark_execution_result "executing" "acting" "LLM act call failed" "" "" "llm_act_failed"; log "LLM Act call failed"; return 1; }
      apply_llm_output "$llm_output" || { mark_execution_result "executing" "acting" "Applying LLM output failed in act phase" "" "" "apply_failed"; log "Apply failed in Act phase"; return 1; }
      ;;
  esac
}

react_observe() {
  local observation=""

  git checkout -- .github/ 2>/dev/null || true
  git checkout -- feishu/ 2>/dev/null || true
  git checkout -- ralph.sh 2>/dev/null || true

  local changed_files
  changed_files=$( {
    git diff --name-only -- ':!ralph.sh' ':!opencode.json' ':!.ralph/*' ':!.ralph-central/*' ':!.github/*' ':!feishu/*';
    git ls-files --others --exclude-standard -- ':!opencode.json' ':!.ralph/*' ':!.ralph-central/*' ':!.github/*' ':!feishu/*' ':!ralph.sh';
  } | sort -u )

  if [ -z "$changed_files" ]; then
    echo "NO_CHANGES: No code changes produced"
    return 1
  fi

  observation="CHANGED_FILES:\n${changed_files}\n"

  if [ -n "$TEST_COMMAND" ]; then
    local test_output
    if test_output=$(eval "$TEST_COMMAND" 2>&1); then
      observation+="TESTS: PASSED"
      echo "$observation"
      return 0
    else
      observation+="TESTS: FAILED\n$(echo "$test_output" | tail -30)"
      echo "$observation"
      return 1
    fi
  fi

  echo "$observation"
  return 0
}

execute_subtask_react() {
  local subtask_json="$1" subtask_idx="$2" plan_json="$3"

  local title
  title=$(echo "$subtask_json" | jq -r '.title')
  log "━━━ Subtask $((subtask_idx+1)): ${title} ━━━"
  mark_execution_result "executing" "subtask" "Running subtask" "$((subtask_idx + 1)):${title}"
  refresh_progress_comment_if_ready "$plan_json"

  local context=""
  if [ "$AGENT_BACKEND" = "llm" ]; then
    context=$(gather_context) || context=""
  fi

  local observation="" react_success=false

  for attempt in $(seq 1 "$REACT_MAX_RETRIES"); do
    mark_subtask_state "$plan_json" "$subtask_idx" "reasoning" "attempt-${attempt}"
    mark_execution_result "executing" "reasoning" "Reasoning" "$((subtask_idx + 1)):${title}" "attempt ${attempt}/${REACT_MAX_RETRIES}"
    refresh_progress_comment_if_ready "$plan_json"
    log "🧠 ReAct [${attempt}/${REACT_MAX_RETRIES}] — Reason..."

    local reasoning
    reasoning=$(react_reason "$subtask_json" "$observation" "$context" 2>/dev/null) || reasoning=""
    if [ -n "$reasoning" ]; then
      local action_plan
      action_plan=$(echo "$reasoning" | jq -r '.action_plan // empty' 2>/dev/null || echo "")
      [ -n "$action_plan" ] && log "📝 Plan: $(echo "$action_plan" | head -1)"
    fi

    log "⚡ ReAct [${attempt}/${REACT_MAX_RETRIES}] — Act..."
    mark_subtask_state "$plan_json" "$subtask_idx" "acting" "attempt-${attempt}"
    mark_execution_result "executing" "acting" "Acting" "$((subtask_idx + 1)):${title}" "attempt ${attempt}/${REACT_MAX_RETRIES}"
    refresh_progress_comment_if_ready "$plan_json"
    react_act "$subtask_json" "$reasoning" "$context"

    log "👁️ ReAct [${attempt}/${REACT_MAX_RETRIES}] — Observe..."
    mark_subtask_state "$plan_json" "$subtask_idx" "observing" "attempt-${attempt}"
    mark_execution_result "executing" "observing" "Observing" "$((subtask_idx + 1)):${title}" "attempt ${attempt}/${REACT_MAX_RETRIES}"
    refresh_progress_comment_if_ready "$plan_json"
    observation=$(react_observe 2>&1)
    local observe_exit=$?

    if [ "$observe_exit" -eq 0 ]; then
      react_success=true
      mark_subtask_state "$plan_json" "$subtask_idx" "completed" "passed"
      mark_execution_result "executing" "subtask" "Subtask passed" "$((subtask_idx + 1)):passed"
      log "✅ Subtask $((subtask_idx+1)) passed"
      break
    else
      mark_subtask_state "$plan_json" "$subtask_idx" "retrying" "$(echo "$observation" | head -3 | tr '\n' ' ')"
      mark_execution_result "executing" "observing" "Retrying after observation" "$((subtask_idx + 1)):${title}" "attempt ${attempt}/${REACT_MAX_RETRIES}" "observation_retry"
      log "⚠️ Subtask $((subtask_idx+1)) observation: $(echo "$observation" | head -3)"
      refresh_progress_comment_if_ready "$plan_json"
    fi
  done

  git add -A
  git reset HEAD -- .github/ 2>/dev/null || true
  git reset HEAD -- .ralph/ 2>/dev/null || true
  git reset HEAD -- .ralph-central/ 2>/dev/null || true
  git reset HEAD -- opencode.json 2>/dev/null || true
  git reset HEAD -- ralph.sh 2>/dev/null || true
  git reset HEAD -- feishu/ 2>/dev/null || true

  if ! git diff --cached --quiet; then
    if [ "$react_success" = true ]; then
      git commit -m "feat(#${ISSUE_NUMBER}): step $((subtask_idx+1)) — ${title} [ralph]" || true
    else
      git commit --no-verify -m "wip(#${ISSUE_NUMBER}): step $((subtask_idx+1)) — ${title} (incomplete) [ralph]" 2>/dev/null || true
    fi
  fi

  if [ "$react_success" = true ]; then
    update_progress "$plan_json" "$subtask_idx" "✅"
  else
    mark_subtask_state "$plan_json" "$subtask_idx" "completed" "partial"
    mark_execution_result "executing" "subtask" "Subtask partial" "$((subtask_idx + 1)):partial" "" "subtask_partial"
    update_progress "$plan_json" "$subtask_idx" "⚠️ partial"
  fi

  $react_success
}

run_single_subtask_cycle() {
  local plan_json="$1" subtask_idx="$2"
  local subtask
  subtask=$(echo "$plan_json" | jq ".subtasks[$subtask_idx]")

  if ! execute_subtask_react "$subtask" "$subtask_idx" "$plan_json"; then
    log "⚠️ Subtask $((subtask_idx+1)) did not fully pass"
    return 1
  fi

  return 0
}

run_plan_and_execute() {
  local plan_json="$1"
  local complexity
  complexity=$(echo "$plan_json" | jq -r '.complexity')

  echo "$plan_json" | jq . > ".ralph/plan-${ISSUE_NUMBER}.json"
  log "Plan saved | complexity=${complexity}"
  mark_execution_result "planning" "planning" "Plan saved"

  local plan_comment_id
  plan_comment_id=$(post_plan_comment "$plan_json") || plan_comment_id=""

  if [ "$REQUIRE_PLAN_APPROVAL" = "true" ] || [ "$complexity" = "ambiguous" ]; then
    local approval_result=0
    wait_for_approval "$PLAN_TIMEOUT" || approval_result=$?

    if [ "$approval_result" -eq 2 ]; then
      log "Plan rejected, aborting"
      mark_execution_result "failed" "approval" "Plan rejected by human" "" "" "plan_rejected"
      local reject_body
      reject_body=$(printf '> [!WARNING]\n> %s\n>\n> %s' \
        "$(i18n_text "cancel_title")" \
        "$(i18n_text "cancel_body")")
      gh api "/repos/${ISSUE_REPO}/issues/${ISSUE_NUMBER}/comments" \
        -f body="$reject_body" 2>/dev/null || true
      exit 1
    elif [ "$approval_result" -eq 1 ]; then
      log "Approval timeout, proceeding anyway..."
      mark_execution_result "awaiting_approval" "approval" "Approval timeout, continuing automatically"
    fi
  fi

  create_progress_comment "$plan_json"
  mark_execution_result "executing" "execution" "Progress tracker ready"
  refresh_progress_comment_if_ready "$plan_json"

  local next_idx=""
  if ! next_idx=$(next_runnable_subtask_idx "$plan_json"); then
    if has_incomplete_subtasks "$plan_json"; then
      log "⚠️ Plan execution is blocked: no runnable subtask"
      mark_execution_result "blocked" "execution" "Incomplete subtasks remain but none is runnable" "" "" "dependency_blocked"
      return 1
    fi

    mark_execution_result "completed" "execution" "All subtasks already finished"
    update_progress "$plan_json"
    return 0
  fi

  if [ "$PLAN_EXECUTION_MODE" != "single" ]; then
    local all_success=true
    while [ -n "$next_idx" ]; do
      log "▶️ Next runnable subtask: $((next_idx + 1))"
      mark_execution_result "executing" "execution" "Queued next runnable subtask" "$((next_idx + 1))"
      refresh_progress_comment_if_ready "$plan_json"
      if ! run_single_subtask_cycle "$plan_json" "$next_idx"; then
        all_success=false
      fi

      if ! next_idx=$(next_runnable_subtask_idx "$plan_json"); then
        next_idx=""
      fi
    done

    if has_incomplete_subtasks "$plan_json"; then
      log "⚠️ Plan execution stopped with incomplete subtasks"
      mark_execution_result "blocked" "execution" "Incomplete subtasks remain but none is runnable" "" "" "dependency_blocked"
      return 1
    fi

    mark_execution_result "completed" "execution" "All subtasks finished in multi mode"
    $all_success
    return $?
  fi

  log "▶️ Next runnable subtask: $((next_idx + 1))"
  mark_execution_result "executing" "execution" "Queued next runnable subtask" "$((next_idx + 1))"
  refresh_progress_comment_if_ready "$plan_json"
  local current_result="passed"
  if ! run_single_subtask_cycle "$plan_json" "$next_idx"; then
    current_result="partial"
  fi

  local upcoming_idx=""
  if upcoming_idx=$(next_runnable_subtask_idx "$plan_json"); then
    mark_execution_result \
      "needs_continue" \
      "execution" \
      "Executed one subtask and queued the next run" \
      "$((next_idx + 1)):${current_result}" \
      "$((upcoming_idx + 1))"
    update_progress "$plan_json"
    return 0
  fi

  if has_incomplete_subtasks "$plan_json"; then
    log "⚠️ Plan execution is blocked after current subtask"
    mark_execution_result \
      "blocked" \
      "execution" \
      "Incomplete subtasks remain after current run" \
      "$((next_idx + 1)):${current_result}" \
      "" \
      "dependency_blocked"
    update_progress "$plan_json"
    return 1
  fi

  mark_execution_result \
    "completed" \
    "execution" \
    "Final runnable subtask executed" \
    "$((next_idx + 1)):${current_result}"
  update_progress "$plan_json"
  return 0
}
