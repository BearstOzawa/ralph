#!/usr/bin/env bash
set -euo pipefail

# 🐺 Ralph Setup Script
# Run this in your project directory to set up Ralph.

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
RALPH_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
PROJECT_DIR=$(pwd)

echo "🐺 Setting up Ralph in ${PROJECT_DIR}..."
echo ""

# 1. Copy workflow
mkdir -p "${PROJECT_DIR}/.github/workflows"
if [ ! -f "${PROJECT_DIR}/.github/workflows/ralph.yml" ]; then
  cp "${RALPH_DIR}/.github/workflows/ralph.yml" "${PROJECT_DIR}/.github/workflows/"
  echo "  ✅ Copied .github/workflows/ralph.yml"
else
  echo "  ⏭️  .github/workflows/ralph.yml already exists"
fi

# 1b. Copy cron workflow
if [ ! -f "${PROJECT_DIR}/.github/workflows/ralph-cron.yml" ]; then
  cp "${RALPH_DIR}/.github/workflows/ralph-cron.yml" "${PROJECT_DIR}/.github/workflows/"
  echo "  ✅ Copied .github/workflows/ralph-cron.yml"
else
  echo "  ⏭️  .github/workflows/ralph-cron.yml already exists"
fi

# 2. Copy ralph.sh
if [ ! -f "${PROJECT_DIR}/ralph.sh" ]; then
  cp "${RALPH_DIR}/ralph.sh" "${PROJECT_DIR}/ralph.sh"
  chmod +x "${PROJECT_DIR}/ralph.sh"
  echo "  ✅ Copied ralph.sh"
else
  echo "  ⏭️  ralph.sh already exists"
fi

# 3. Copy spec template
if [ ! -f "${PROJECT_DIR}/SPEC.tmpl.md" ]; then
  cp "${RALPH_DIR}/SPEC.tmpl.md" "${PROJECT_DIR}/SPEC.tmpl.md"
  echo "  ✅ Copied SPEC.tmpl.md"
else
  echo "  ⏭️  SPEC.tmpl.md already exists"
fi

# 3b. Copy validator
mkdir -p "${PROJECT_DIR}/scripts" "${PROJECT_DIR}/scripts/lib" "${PROJECT_DIR}/locales/core"
if [ ! -f "${PROJECT_DIR}/scripts/validator.sh" ]; then
  cp "${RALPH_DIR}/scripts/validator.sh" "${PROJECT_DIR}/scripts/validator.sh"
  chmod +x "${PROJECT_DIR}/scripts/validator.sh"
  echo "  ✅ Copied scripts/validator.sh"
else
  echo "  ⏭️  scripts/validator.sh already exists"
fi

if [ ! -f "${PROJECT_DIR}/scripts/lib/planning.sh" ]; then
  cp "${RALPH_DIR}/scripts/lib/planning.sh" "${PROJECT_DIR}/scripts/lib/planning.sh"
  chmod +x "${PROJECT_DIR}/scripts/lib/planning.sh"
  echo "  ✅ Copied scripts/lib/planning.sh"
else
  echo "  ⏭️  scripts/lib/planning.sh already exists"
fi

if [ ! -f "${PROJECT_DIR}/scripts/lib/reporting.sh" ]; then
  cp "${RALPH_DIR}/scripts/lib/reporting.sh" "${PROJECT_DIR}/scripts/lib/reporting.sh"
  chmod +x "${PROJECT_DIR}/scripts/lib/reporting.sh"
  echo "  ✅ Copied scripts/lib/reporting.sh"
else
  echo "  ⏭️  scripts/lib/reporting.sh already exists"
fi

if [ ! -f "${PROJECT_DIR}/scripts/lib/execution.sh" ]; then
  cp "${RALPH_DIR}/scripts/lib/execution.sh" "${PROJECT_DIR}/scripts/lib/execution.sh"
  chmod +x "${PROJECT_DIR}/scripts/lib/execution.sh"
  echo "  ✅ Copied scripts/lib/execution.sh"
else
  echo "  ⏭️  scripts/lib/execution.sh already exists"
fi

if [ ! -f "${PROJECT_DIR}/scripts/lib/i18n.sh" ]; then
  cp "${RALPH_DIR}/scripts/lib/i18n.sh" "${PROJECT_DIR}/scripts/lib/i18n.sh"
  chmod +x "${PROJECT_DIR}/scripts/lib/i18n.sh"
  echo "  ✅ Copied scripts/lib/i18n.sh"
else
  echo "  ⏭️  scripts/lib/i18n.sh already exists"
fi

if [ ! -f "${PROJECT_DIR}/scripts/i18n.cjs" ]; then
  cp "${RALPH_DIR}/scripts/i18n.cjs" "${PROJECT_DIR}/scripts/i18n.cjs"
  echo "  ✅ Copied scripts/i18n.cjs"
else
  echo "  ⏭️  scripts/i18n.cjs already exists"
fi

if [ ! -f "${PROJECT_DIR}/locales/core/zh-CN.json" ]; then
  cp "${RALPH_DIR}/locales/core/zh-CN.json" "${PROJECT_DIR}/locales/core/zh-CN.json"
  echo "  ✅ Copied locales/core/zh-CN.json"
else
  echo "  ⏭️  locales/core/zh-CN.json already exists"
fi

if [ ! -f "${PROJECT_DIR}/locales/core/en-US.json" ]; then
  cp "${RALPH_DIR}/locales/core/en-US.json" "${PROJECT_DIR}/locales/core/en-US.json"
  echo "  ✅ Copied locales/core/en-US.json"
else
  echo "  ⏭️  locales/core/en-US.json already exists"
fi

# 4. Copy config
if [ ! -f "${PROJECT_DIR}/config.example.yml" ]; then
  cp "${RALPH_DIR}/config.example.yml" "${PROJECT_DIR}/config.example.yml"
  echo "  ✅ Copied config.example.yml"
else
  echo "  ⏭️  config.example.yml already exists"
fi

# 5. Install git hook
if [ -d "${PROJECT_DIR}/.git" ]; then
  mkdir -p "${PROJECT_DIR}/.git/hooks"
  cp "${RALPH_DIR}/hooks/pre-commit" "${PROJECT_DIR}/.git/hooks/pre-commit"
  chmod +x "${PROJECT_DIR}/.git/hooks/pre-commit"
  echo "  ✅ Installed anti-cheat pre-commit hook"
else
  echo "  ⚠️  Not a git repo — skipping hook installation"
fi

echo ""
echo "🐺 Ralph is ready! Next steps:"
echo ""
echo "  1. Add secrets in GitHub:"
echo "     - RALPH_API_KEY (LLM API key for opencode/llm backend)"
echo "     - RALPH_GITHUB_TOKEN (PAT with repo scope — needed for cross-repo and repo creation)"
echo ""
echo "  2. Create labels:"
echo "     - ai/ready (#7057ff)        — triggers Ralph"
echo "     - ai/done (#0e8a16)         — Ralph succeeded"
echo "     - ai/failed (#d93f0b)       — Ralph failed"
echo "     - ai/plan-approved (#1d76db) — approve execution plan"
echo "     - ralph (#6f42c1)           — marks Ralph PRs"
echo ""
echo "  3. Enable workflow PR permissions:"
echo "     Settings → Actions → General → Allow GitHub Actions to create and approve pull requests"
echo ""
echo "  4. Create an issue, label it ai/ready, and go to sleep 💤"
echo ""
echo "  New features:"
echo "     - Plan-and-Execute + ReAct for complex tasks (auto by default)"
echo "     - Human-in-the-loop: /approve or /reject on issues"
echo "     - Repo creation: set create_repo=true when dispatching"
echo "     - Feishu commands: /create, /approve, /reject"
echo ""
