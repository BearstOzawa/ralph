#!/usr/bin/env bash

plan_task_legacy() {
  local spec_content
  spec_content=$(cat "$SPEC_FILE" 2>/dev/null || echo "")

  local file_tree
  file_tree=$(find . -type f \
    -not -path './.git/*' -not -path './node_modules/*' -not -path './vendor/*' \
    -not -path './.ralph/*' -not -path './.github/*' -not -path './feishu/*' \
    -not -name '*.lock' -not -name 'go.sum' -not -name 'ralph.sh' \
    2>/dev/null | sort | head -80 || echo "(empty project)")

  local system_msg='你是 Ralph 的任务规划模块。分析以下需求，判断复杂度并拆分子任务。

判断标准：
- SIMPLE: 单文件改动、简单功能、bug修复、配置变更、1-2个文件
- COMPLEX: 多文件改动、新功能模块、架构变更、需要3+个文件

严格输出格式：
COMPLEXITY: SIMPLE 或 COMPLEX

如果 COMPLEX，继续输出：
SUBTASK_COUNT: 数字
PHASE 1: 标题 - 描述
PHASE 2: 标题 - 描述
PHASE 3: 标题 - 描述
...

规则：
- 子任务不超过 5 个
- 每个子任务要足够小，可独立编码
- 按执行顺序排列，后面的可以依赖前面的
- 不要输出 <think> 标签'

  local user_msg="--- SPEC ---
${spec_content}
--- END SPEC ---

--- PROJECT FILES ---
${file_tree}
--- END ---"

  local sys_json usr_json
  sys_json=$(printf '%s' "$system_msg" | jq -Rs .)
  usr_json=$(printf '%s' "$user_msg" | jq -Rs .)

  log "Calling LLM for task planning..."
  local response
  response=$(curl -sS --max-time 60 -X POST "${API_BASE_URL}/v1/chat/completions" \
    -H "Authorization: Bearer ${API_KEY}" \
    -H "Content-Type: application/json" \
    -d "{
      \"model\": \"${API_MODEL}\",
      \"messages\": [
        {\"role\": \"system\", \"content\": ${sys_json}},
        {\"role\": \"user\", \"content\": ${usr_json}}
      ],
      \"max_tokens\": 2048,
      \"temperature\": 0.1
    }") || return 1

  local content
  content=$(echo "$response" | jq -r '.choices[0].message.content // empty')
  [ -z "$content" ] && return 1
  content=$(echo "$content" | sed '/<think>/,/<\/think>/d' | sed 's/<think>.*<\/think>//g')
  echo "$content"
}

plan_task() {
  local issue_title="$1" issue_body="$2"
  local issue_body_chars file_count

  local system_msg='你是 Ralph 的任务规划模块。分析 GitHub Issue，输出结构化执行计划。

严格输出 JSON，不要任何其他内容，不要 markdown 代码块，不要 <think> 标签。

JSON 结构：
{
  "complexity": "simple|complex|ambiguous",
  "reasoning": "一句话说明判定理由",
  "clarifications": ["仅 ambiguous 时填写需要确认的问题"],
  "subtasks": [
    {
      "id": 1,
      "title": "简短描述",
      "description": "详细执行步骤",
      "files_to_read": ["需要先读取理解的文件"],
      "files_to_modify": ["需要修改或创建的文件"],
      "depends_on": [],
      "verification": "如何验证此步骤完成"
    }
  ]
}

判定规则：
- simple: 单文件或少量文件改动，需求明确，1-2 个 subtask
- complex: 多文件联动，需要分步骤，3+ 个 subtask
- ambiguous: 需求不清晰，缺少关键信息，需要人工确认

注意：
- subtask 之间用 depends_on 表达依赖
- files_to_read / files_to_modify 基于你对项目结构的理解推测
- 每个 subtask 必须是可独立验证的最小单元
- 必须优先吸收 Issue body / Structured Interpretation 中的具体要求、限制条件、风格要求、验收标准
- 如果标题与正文存在冲突，以正文和 Structured Interpretation 为准
- 不允许只根据标题泛化任务，必须在 reasoning 或 subtasks 中体现正文约束
- 不要创建超过 7 个 subtask'

  local user_msg="## Issue: ${issue_title}

${issue_body}

## Project file structure
$(find . -type f -not -path './.git/*' -not -path './node_modules/*' -not -path './vendor/*' -not -path './.next/*' -not -path './dist/*' -not -path './build/*' -not -name '*.lock' -not -name 'go.sum' 2>/dev/null | head -100)"

  local sys_json usr_json
  sys_json=$(printf '%s' "$system_msg" | jq -Rs .)
  usr_json=$(printf '%s' "$user_msg" | jq -Rs .)

  issue_body_chars=$(printf '%s' "$issue_body" | wc -m | tr -d ' ')
  file_count=$(find . -type f -not -path './.git/*' -not -path './node_modules/*' -not -path './vendor/*' -not -path './.next/*' -not -path './dist/*' -not -path './build/*' -not -name '*.lock' -not -name 'go.sum' 2>/dev/null | head -100 | wc -l | tr -d ' ')
  log "📋 Planning task..."
  log "📋 Planning context: body=${issue_body_chars} chars, files=${file_count}"
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
    }") || { log "Plan LLM call failed"; return 1; }

  local content
  content=$(echo "$response" | jq -r '.choices[0].message.content // empty')
  [ -z "$content" ] && { log "Plan returned empty"; return 1; }
  log "📋 Plan response received (${#content} chars)"

  content=$(echo "$content" | sed '/<think>/,/<\/think>/d' | sed 's/<think>.*<\/think>//g')
  content=$(echo "$content" | sed '/^```/d')

  if ! echo "$content" | jq . >/dev/null 2>&1; then
    log "Plan returned invalid JSON, extracting..."
    content=$(echo "$content" | grep -oP '\{[\s\S]*\}' | head -1)
    echo "$content" | jq . >/dev/null 2>&1 || { log "Cannot parse plan JSON"; return 1; }
  fi

  log "📋 Plan parsed: complexity=$(echo "$content" | jq -r '.complexity // \"unknown\"') subtasks=$(echo "$content" | jq '.subtasks | length')"

  echo "$content"
}
