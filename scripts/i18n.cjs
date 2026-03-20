const fs = require('fs');
const path = require('path');

function normalizeLang(input = 'zh-CN') {
  const raw = String(input || 'zh-CN').trim().replace(/_/g, '-').toLowerCase();
  if (raw === 'zh' || raw === 'zh-cn' || raw === 'zh-hans') return 'zh-CN';
  if (raw === 'en' || raw === 'en-us') return 'en-US';
  return 'zh-CN';
}

function loadLocale(lang) {
  const normalized = normalizeLang(lang);
  const localeDir = path.join(__dirname, '..', 'locales', 'core');
  const localePath = path.join(localeDir, `${normalized}.json`);
  const fallbackPath = path.join(localeDir, 'zh-CN.json');
  const fallback = JSON.parse(fs.readFileSync(fallbackPath, 'utf8'));
  let primary = fallback;
  if (fs.existsSync(localePath)) {
    primary = JSON.parse(fs.readFileSync(localePath, 'utf8'));
  }
  return { ...fallback, ...primary };
}

function format(template, ...args) {
  let index = 0;
  return String(template).replace(/%s/g, () => String(args[index++] ?? ''));
}

function t(lang, key, ...args) {
  const locale = loadLocale(lang);
  const value = locale[key] ?? key;
  return format(value, ...args);
}

function buildFormalReviewSystemPrompt(lang) {
  const normalized = normalizeLang(lang);
  if (normalized === 'en-US') {
    return `You are Ralph's formal code review module. Review the PR comprehensively.

Review dimensions:
1. Correctness — whether the code implements the requirement correctly
2. Security — whether there are security risks
3. Architecture — whether the structure is sound
4. Code Quality — naming, readability, DRY
5. Performance — whether there are obvious performance issues

Output format (Markdown):

## 🐺 Ralph Code Review

### 🎯 Summary
[One-sentence overall assessment with grade A/B/C/D]

### 📋 Findings

| Severity | File | Finding |
|:---------|:-----|:--------|
| Critical / Warning / Suggestion | filename | description |

### 💡 Suggestions
[List improvements if any, otherwise write "Code quality is acceptable, no further changes required"]

Do not output <think> tags. Output Markdown directly.`;
  }

  return `你是 Ralph 的正式代码审查模块。请对以下 PR 进行全面代码审查。

审查维度：
1. ✅ 正确性 — 代码是否正确实现了需求
2. 🛡️ 安全性 — 是否存在安全风险
3. 🏗️ 架构 — 代码结构是否合理
4. 🧹 代码质量 — 命名、可读性、DRY
5. ⚡ 性能 — 是否有明显性能问题

输出格式（中文，Markdown）：

## 🐺 Ralph Code Review

### 🎯 总评
[一句话总结，包含综合评分 A/B/C/D]

### 📋 详细发现

| 级别 | 文件 | 发现 |
|:-----|:-----|:-----|
| 🔴 严重 / 🟡 警告 / 🟢 建议 | filename | description |

### 💡 改进建议
[如有列出，无则写“代码质量良好，无需额外修改”]

注意：不要输出 <think> 标签，直接输出 Markdown`;
}

function buildFormalReviewUserPrompt(lang, issueTitle, issueBody, diffText) {
  const normalized = normalizeLang(lang);
  if (normalized === 'en-US') {
    return `Requirement: ${issueTitle}\n${issueBody || '(no additional details)'}\n\n--- PR DIFF ---\n${String(diffText).substring(0, 30000)}\n--- END DIFF ---`;
  }
  return `需求：${issueTitle}\n${issueBody || '(无详细描述)'}\n\n--- PR DIFF ---\n${String(diffText).substring(0, 30000)}\n--- END DIFF ---`;
}

module.exports = { normalizeLang, loadLocale, t, buildFormalReviewSystemPrompt, buildFormalReviewUserPrompt };
