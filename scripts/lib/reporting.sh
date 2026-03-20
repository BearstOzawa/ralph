#!/usr/bin/env bash

comment_marker() {
  local kind="$1"
  echo "<!-- ralph-${kind}:${ISSUE_NUMBER} -->"
}

format_elapsed_seconds() {
  local total="$1" minutes seconds hours
  if ! printf '%s' "$total" | grep -Eq '^[0-9]+$'; then
    echo "0s"
    return 0
  fi
  if [ "$total" -lt 60 ]; then
    echo "${total}s"
    return 0
  fi
  if [ "$total" -lt 3600 ]; then
    minutes=$((total / 60))
    seconds=$((total % 60))
    echo "${minutes}m${seconds}s"
    return 0
  fi
  hours=$((total / 3600))
  minutes=$(((total % 3600) / 60))
  seconds=$((total % 60))
  echo "${hours}h${minutes}m${seconds}s"
}

render_execution_status_block() {
  local state_file status stage summary failure_code current next updated elapsed_seconds elapsed_label elapsed_value
  state_file=$(execution_result_file)
  [ -f "$state_file" ] || return 0

  status=$(jq -r '.status // empty' "$state_file" 2>/dev/null)
  stage=$(jq -r '.stage // empty' "$state_file" 2>/dev/null)
  summary=$(jq -r '.summary // empty' "$state_file" 2>/dev/null)
  failure_code=$(jq -r '.failure_code // empty' "$state_file" 2>/dev/null)
  current=$(jq -r '.current_subtask // empty' "$state_file" 2>/dev/null)
  next=$(jq -r '.next_subtask // empty' "$state_file" 2>/dev/null)
  updated=$(jq -r '.updated_at // empty' "$state_file" 2>/dev/null)
  elapsed_seconds=$(jq -r '.elapsed_seconds // 0' "$state_file" 2>/dev/null)
  elapsed_label=$(i18n_text "elapsed_label")
  elapsed_value=$(format_elapsed_seconds "$elapsed_seconds")

  [ -z "$status$stage$summary$current$next" ] && return 0

  printf '**Status**: `%s`\n' "${status:-unknown}"
  [ -n "$stage" ] && printf '**Stage**: `%s`\n' "$stage"
  [ -n "$summary" ] && printf '**Summary**: %s\n' "$summary"
  [ -n "$failure_code" ] && printf '**Failure Code**: `%s`\n' "$failure_code"
  [ -n "$current" ] && printf '**Current**: `%s`\n' "$current"
  [ -n "$next" ] && printf '**Next**: `%s`\n' "$next"
  [ -n "$elapsed_seconds" ] && [ "$elapsed_seconds" -gt 0 ] && printf '**%s**: `%s`\n' "$elapsed_label" "$elapsed_value"
  [ -n "$updated" ] && printf '**Updated**: `%s`\n' "$updated"
}

find_comment_id_by_marker() {
  local marker="$1"
  gh api "/repos/${ISSUE_REPO}/issues/${ISSUE_NUMBER}/comments?per_page=100" 2>/dev/null \
    | jq -r --arg marker "$marker" '.[] | select((.body // "") | contains($marker)) | .id' \
    | head -1
}

render_plan_comment_body() {
  local plan_json="$1"
  local complexity reasoning
  complexity=$(echo "$plan_json" | jq -r '.complexity')
  reasoning=$(echo "$plan_json" | jq -r '.reasoning')

  local PLAN_HEADER COMPLEXITY_LABEL STEP_LABEL CLARIFY_HEADER AWAIT_APPROVAL AUTO_EXEC
  PLAN_HEADER=$(i18n_text "plan_header")
  COMPLEXITY_LABEL=$(i18n_text "complexity_label")
  STEP_LABEL=$(i18n_text "step_label")
  CLARIFY_HEADER=$(i18n_text "clarify_header")
  AWAIT_APPROVAL=$(i18n_text "await_approval")
  AUTO_EXEC=$(i18n_text "auto_exec")

  local body=""
  body+="$(comment_marker "plan")\n"
  body+='> [!NOTE]\n'
  body+="> ${PLAN_HEADER}\n"
  body+='>\n'
  body+="> **${COMPLEXITY_LABEL}**: \`${complexity}\` — ${reasoning}\n"
  body+='>\n'

  local subtask_count
  subtask_count=$(echo "$plan_json" | jq '.subtasks | length')
  for idx in $(seq 0 $((subtask_count - 1))); do
    local title desc
    title=$(echo "$plan_json" | jq -r ".subtasks[$idx].title")
    desc=$(echo "$plan_json" | jq -r ".subtasks[$idx].description" | head -1)
    body+="> - [ ] **${STEP_LABEL} $((idx + 1))**: ${title}\n"
    body+=">   _${desc}_\n"
  done

  local clarification_count
  clarification_count=$(echo "$plan_json" | jq '.clarifications | length')
  if [ "$clarification_count" -gt 0 ]; then
    body+="> \n> ${CLARIFY_HEADER}\n"
    for idx in $(seq 0 $((clarification_count - 1))); do
      local question
      question=$(echo "$plan_json" | jq -r ".clarifications[$idx]")
      body+="> - ${question}\n"
    done
  fi

  if [ "$REQUIRE_PLAN_APPROVAL" = "true" ] || [ "$complexity" = "ambiguous" ]; then
    body+="> \n> ${AWAIT_APPROVAL}\n"
  else
    body+="> \n> ${AUTO_EXEC}\n"
  fi

  printf '%b' "$body"
}

post_plan_comment() {
  local plan_json="$1"
  local marker existing_id comment_body
  marker=$(comment_marker "plan")
  existing_id=$(find_comment_id_by_marker "$marker" || true)

  if [ -n "$existing_id" ]; then
    echo "$existing_id"
    return 0
  fi

  comment_body=$(render_plan_comment_body "$plan_json")
  local result
  result=$(gh api "/repos/${ISSUE_REPO}/issues/${ISSUE_NUMBER}/comments" \
    -f body="$comment_body" 2>/dev/null) || {
      log "Failed to post plan comment"
      return 1
    }

  echo "$result" | jq -r '.id'
}

wait_for_approval() {
  local timeout_minutes="$1"
  local deadline
  deadline=$(($(date +%s) + timeout_minutes * 60))

  log "$(i18n_text "approval_wait_log" "$timeout_minutes")"

  while [ "$(date +%s)" -lt "$deadline" ]; do
    local labels
    labels=$(gh api "/repos/${ISSUE_REPO}/issues/${ISSUE_NUMBER}/labels" 2>/dev/null \
      | jq -r '.[].name' 2>/dev/null || echo "")
    if echo "$labels" | grep -q "ai/plan-approved"; then
      log "$(i18n_text "approval_label_log")"
      gh api -X DELETE "/repos/${ISSUE_REPO}/issues/${ISSUE_NUMBER}/labels/ai%2Fplan-approved" 2>/dev/null || true
      return 0
    fi

    local comments
    comments=$(gh api "/repos/${ISSUE_REPO}/issues/${ISSUE_NUMBER}/comments?per_page=20&sort=created&direction=desc" 2>/dev/null || echo "[]")
    if echo "$comments" | jq -r '.[].body' 2>/dev/null | grep -qi '/approve'; then
      log "$(i18n_text "approval_comment_log")"
      return 0
    fi

    if echo "$comments" | jq -r '.[].body' 2>/dev/null | grep -qi '/reject'; then
      log "$(i18n_text "approval_reject_log")"
      return 2
    fi

    sleep 30
  done

  log "$(i18n_text "approval_timeout_log" "$timeout_minutes")"
  return 1
}

progress_entry_for_subtask() {
  local plan_json="$1" idx="$2"
  local title result phase marker
  title=$(echo "$plan_json" | jq -r ".subtasks[$idx].title")
  result=$(subtask_state_value "$idx" "result" || true)
  phase=$(subtask_state_value "$idx" "phase" || true)

  case "$result" in
    passed)
      marker="- [x]"
      printf '%s %s %d: %s %s\n' "$marker" "${STEP_LABEL}" "$((idx + 1))" "$title" "✅"
      ;;
    partial)
      marker="- [x]"
      printf '%s %s %d: %s %s\n' "$marker" "${STEP_LABEL}" "$((idx + 1))" "$title" "⚠️ partial"
      ;;
    *)
      if [ -n "$phase" ]; then
        marker="- [ ]"
        printf '%s %s %d: %s %s\n' "$marker" "${STEP_LABEL}" "$((idx + 1))" "$title" "🔄 ${phase}"
      else
        marker="- [ ]"
        printf '%s %s %d: %s\n' "$marker" "${STEP_LABEL}" "$((idx + 1))" "$title"
      fi
      ;;
  esac
}

render_progress_comment_body() {
  local plan_json="$1"
  local progress_header status_block
  progress_header=$(i18n_text "progress_header" "$ISSUE_NUMBER")
  STEP_LABEL=$(i18n_text "step_label")
  status_block=$(render_execution_status_block)

  local body=""
  body+="$(comment_marker "progress")\n"
  body+="${progress_header}\n\n"
  if [ -n "$status_block" ]; then
    body+="${status_block}\n"
  fi

  local subtask_count idx
  subtask_count=$(echo "$plan_json" | jq '.subtasks | length')
  for idx in $(seq 0 $((subtask_count - 1))); do
    body+="$(progress_entry_for_subtask "$plan_json" "$idx")"
  done

  body+="\n_Updated: $(date -u '+%Y-%m-%d %H:%M UTC')_"
  printf '%b' "$body"
}

create_progress_comment() {
  local plan_json="$1"
  local marker existing_id comment_body result
  marker=$(comment_marker "progress")
  existing_id=$(find_comment_id_by_marker "$marker" || true)

  if [ -n "$existing_id" ]; then
    PROGRESS_COMMENT_ID="$existing_id"
    update_progress "$plan_json" "0" ""
    return 0
  fi

  comment_body=$(render_progress_comment_body "$plan_json")
  result=$(gh api "/repos/${ISSUE_REPO}/issues/${ISSUE_NUMBER}/comments" \
    -f body="$comment_body" 2>/dev/null) || return 1

  PROGRESS_COMMENT_ID=$(echo "$result" | jq -r '.id')
  log "Progress comment: #${PROGRESS_COMMENT_ID}"
}

update_progress() {
  local plan_json="$1"
  [ -z "$PROGRESS_COMMENT_ID" ] && return 0

  local comment_body
  comment_body=$(render_progress_comment_body "$plan_json")

  gh api -X PATCH "/repos/${ISSUE_REPO}/issues/comments/${PROGRESS_COMMENT_ID}" \
    -f body="$comment_body" 2>/dev/null || true
}
