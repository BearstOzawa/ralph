/**
 * Cloudflare Worker: Ralph Central Dispatcher
 *
 * Three entry points, unified dispatcher for the central Ralph workflow:
 *
 * 1. POST /          — Feishu Event Callback (Feishu command → create Issue → dispatch workflow)
 * 2. POST /notify    — Ralph → Feishu notification (GitHub Actions callback)
 * 3. POST /github    — GitHub Webhook (any repo issue labeled ai/ready → dispatch workflow)
 *
 * Environment variables:
 *   FEISHU_APP_ID / FEISHU_APP_SECRET / FEISHU_VERIFICATION_TOKEN
 *   FEISHU_CHAT_ID — default Feishu chat_id (fallback when feishu_chat_id not provided)
 *   GITHUB_TOKEN  — needs read/write access to all target repos
 *   GITHUB_REPO   — default target repo (owner/repo)
 *   NOTIFY_SECRET — protects /notify endpoint
 *   GITHUB_WEBHOOK_SECRET — GitHub Webhook Secret (optional, recommended)
 *   RALPH_API_KEY — LLM API key for title summarization (optional)
 *   RALPH_API_BASE_URL — LLM API base URL (required for title summarization)
 *   RALPH_API_MODEL — LLM model name (required for title summarization)
 *   RALPH_LANG    — UI language: zh-CN / en-US (legacy zh/en also supported)
 */

import { t } from './locales/index.js';

const processedEvents = new Set();
const MAX_PROCESSED = 500;
const RUN_BACKENDS = new Set(['auto', 'opencode', 'llm']);
const RUN_MAX_ITERATIONS = new Set(['5', '10', '15', '20']);
const RUN_PLAN_MODES = new Set(['auto', 'always', 'off']);
const RUN_EXECUTION_MODES = new Set(['single', 'multi']);
const RUN_LANGS = new Set(['zh-CN', 'en-US']);
const CONFIG_KEYS = new Set(['backend', 'maxIterations', 'planMode', 'executionMode', 'lang', 'requireApproval']);

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);

    // ── /notify: Ralph → Feishu notification ──
    if (url.pathname === '/notify') {
      return handleNotify(request, env);
    }

    // ── /github: GitHub Webhook receiver ──
    if (url.pathname === '/github') {
      return handleGitHubWebhook(request, env, ctx);
    }

    // ── GET: Health check ──
    if (request.method !== 'POST') {
      return new Response(
        '🐺 Ralph Central Dispatcher\n\n' +
        'POST /        — Feishu event callback\n' +
        'POST /notify  — Ralph → Feishu notification\n' +
        'POST /github  — GitHub Webhook (issue labeled)',
        { status: 200, headers: { 'Content-Type': 'text/plain; charset=utf-8' } }
      );
    }

    // ── POST /: Feishu event ──
    const body = await request.json();

    if (body.type === 'url_verification') {
      return Response.json({ challenge: body.challenge });
    }

    if (env.FEISHU_VERIFICATION_TOKEN && body.header?.token !== env.FEISHU_VERIFICATION_TOKEN) {
      return Response.json({ error: 'invalid token' }, { status: 403 });
    }

    const eventId = body.header?.event_id;
    if (eventId) {
      if (processedEvents.has(eventId)) {
        return Response.json({ ok: true, dedup: true });
      }
      processedEvents.add(eventId);
      if (processedEvents.size > MAX_PROCESSED) {
        const first = processedEvents.values().next().value;
        processedEvents.delete(first);
      }
    }

    if (body.header?.event_type === 'im.message.receive_v1') {
      ctx.waitUntil(handleMessage(body.event, env).catch(e => console.error('handleMessage error:', e)));
    }

    return Response.json({ ok: true });
  },
};

// ═══════════════════════════════════════════
// Title summarization via LLM
// ═══════════════════════════════════════════
async function summarizeTitle(text, env) {
  const raw = String(text || '').trim();
  if (!raw) return raw;
  if (raw.length <= 12) return raw;

  const apiKey = env.RALPH_API_KEY;
  const apiBase = env.RALPH_API_BASE_URL;
  const model = env.RALPH_API_MODEL;
  if (!apiKey || !apiBase || !model) {
    return raw.length <= 60 ? raw : raw.substring(0, 60).replace(/\s+\S*$/, '') + '...';
  }

  try {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 8000);
    const resp = await fetch(`${apiBase}/v1/chat/completions`, {
      method: 'POST',
      headers: { 'Authorization': `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        model,
        messages: [
          {
            role: 'system',
            content: 'Generate a concise GitHub issue title summarizing the task. Prefer 12-32 characters for Chinese, under 60 characters overall. Output ONLY the title, no quotes, no prefix, no explanation. Keep the same language as input.'
          },
          { role: 'user', content: raw }
        ],
        max_tokens: 100,
        temperature: 0.1
      }),
      signal: controller.signal,
    });
    clearTimeout(timeout);
    const data = await resp.json();
    let title = (data.choices?.[0]?.message?.content || '').replace(/<think>[\s\S]*?<\/think>/g, '').trim();
    if (title && title.length > 0 && title.length <= 80) return title;
  } catch (e) {
    console.error('Title summarization failed:', e.message);
  }
  return raw.length <= 60 ? raw : raw.substring(0, 60).replace(/\s+\S*$/, '') + '...';
}

// ═══════════════════════════════════════════
// Repo auto-creation helper
// ═══════════════════════════════════════════
async function ensureRepoExists(repo, token) {
  const [owner, name] = repo.split('/');

  // Check if repo exists
  const checkResp = await fetch(`https://api.github.com/repos/${repo}`, {
    headers: {
      Authorization: `Bearer ${token}`,
      'User-Agent': 'Ralph-Central-Dispatcher',
    },
  });
  if (checkResp.ok) return { exists: true, created: false };
  if (checkResp.status !== 404) return { exists: false, created: false, error: `check failed: ${checkResp.status}` };

  // Repo doesn't exist — determine if owner is user or org
  const userResp = await fetch('https://api.github.com/user', {
    headers: {
      Authorization: `Bearer ${token}`,
      'User-Agent': 'Ralph-Central-Dispatcher',
    },
  });
  const user = await userResp.json();

  const createUrl = user.login === owner
    ? 'https://api.github.com/user/repos'
    : `https://api.github.com/orgs/${owner}/repos`;

  const createResp = await fetch(createUrl, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
      'User-Agent': 'Ralph-Central-Dispatcher',
    },
    body: JSON.stringify({
      name,
      description: 'Created by Ralph AI',
      auto_init: true,
      private: false,
    }),
  });

  if (createResp.ok) {
    await new Promise(r => setTimeout(r, 2000));
    return { exists: true, created: true };
  }

  const err = await createResp.text();
  return { exists: false, created: false, error: `${createResp.status}: ${err}` };
}

function normalizeIssueText(text) {
  return (text || '')
    .toLowerCase()
    .replace(/\s+/g, ' ')
    .replace(/[^\p{L}\p{N}\s/_-]/gu, '')
    .trim();
}

function normalizeRunLang(input, fallback = 'zh-CN') {
  const raw = String(input || '').trim();
  if (!raw) return fallback;

  const lower = raw.replace('_', '-').toLowerCase();
  if (lower === 'zh' || lower === 'zh-cn' || lower === 'zh-hans') return 'zh-CN';
  if (lower === 'en' || lower === 'en-us') return 'en-US';
  return fallback;
}

function normalizeBooleanString(input) {
  const raw = String(input || '').trim().toLowerCase();
  if (raw === 'true' || raw === '1' || raw === 'yes' || raw === 'on') return true;
  if (raw === 'false' || raw === '0' || raw === 'no' || raw === 'off') return false;
  return null;
}

function normalizeStoredConfig(raw) {
  const config = {};
  if (RUN_BACKENDS.has(String(raw?.backend || '').trim())) config.backend = String(raw.backend).trim();
  if (RUN_MAX_ITERATIONS.has(String(raw?.maxIterations || '').trim())) config.maxIterations = String(raw.maxIterations).trim();
  if (RUN_PLAN_MODES.has(String(raw?.planMode || '').trim())) config.planMode = String(raw.planMode).trim();
  if (RUN_EXECUTION_MODES.has(String(raw?.executionMode || '').trim())) config.executionMode = String(raw.executionMode).trim();
  if (RUN_LANGS.has(normalizeRunLang(raw?.lang || '', ''))) config.lang = normalizeRunLang(raw.lang, '');
  if (typeof raw?.requireApproval === 'boolean') config.requireApproval = raw.requireApproval;
  return config;
}

async function getChatConfig(env, chatId) {
  if (!chatId || !env.RALPH_CONFIG?.get) return {};
  try {
    const raw = await env.RALPH_CONFIG.get(`chat:${chatId}`, 'json');
    return normalizeStoredConfig(raw || {});
  } catch (err) {
    console.error('Load chat config failed:', err);
    return {};
  }
}

async function putChatConfig(env, chatId, config) {
  if (!chatId || !env.RALPH_CONFIG?.put) throw new Error('RALPH_CONFIG not configured');
  await env.RALPH_CONFIG.put(`chat:${chatId}`, JSON.stringify(normalizeStoredConfig(config)));
}

async function deleteChatConfig(env, chatId) {
  if (!chatId || !env.RALPH_CONFIG?.delete) throw new Error('RALPH_CONFIG not configured');
  await env.RALPH_CONFIG.delete(`chat:${chatId}`);
}

async function getChatTaskState(env, chatId) {
  if (!chatId || !env.RALPH_CONFIG?.get) return null;
  try {
    const raw = await env.RALPH_CONFIG.get(`chat-task:${chatId}`, 'json');
    if (!raw || typeof raw !== 'object') return null;
    const issueRepo = String(raw.issueRepo || '').trim();
    const issueNumber = Number(raw.issueNumber);
    const targetRepo = String(raw.targetRepo || issueRepo).trim();
    if (!issueRepo || !Number.isFinite(issueNumber) || issueNumber <= 0) return null;
    return {
      issueRepo,
      issueNumber,
      targetRepo,
      title: String(raw.title || '').trim(),
      updatedAt: String(raw.updatedAt || '').trim(),
    };
  } catch (err) {
    console.error('Load chat task state failed:', err);
    return null;
  }
}

async function putChatTaskState(env, chatId, state) {
  if (!chatId || !env.RALPH_CONFIG?.put || !state?.issueRepo || !state?.issueNumber) return;
  await env.RALPH_CONFIG.put(
    `chat-task:${chatId}`,
    JSON.stringify({
      issueRepo: state.issueRepo,
      issueNumber: Number(state.issueNumber),
      targetRepo: state.targetRepo || state.issueRepo,
      title: state.title || '',
      updatedAt: state.updatedAt || new Date().toISOString(),
    })
  );
}

function buildConfigSource(env, config = {}) {
  return {
    ...env,
    RALPH_LANG: config.lang || env.RALPH_LANG || 'zh-CN',
    RALPH_DEFAULT_BACKEND: config.backend || env.RALPH_DEFAULT_BACKEND || 'auto',
    RALPH_DEFAULT_MAX_ITERATIONS: config.maxIterations || env.RALPH_DEFAULT_MAX_ITERATIONS || '5',
    RALPH_DEFAULT_PLAN_MODE: config.planMode || env.RALPH_DEFAULT_PLAN_MODE || 'auto',
    RALPH_DEFAULT_EXECUTION_MODE: config.executionMode || env.RALPH_DEFAULT_EXECUTION_MODE || 'single',
    RALPH_DEFAULT_REQUIRE_APPROVAL: typeof config.requireApproval === 'boolean'
      ? String(config.requireApproval)
      : String(env.RALPH_DEFAULT_REQUIRE_APPROVAL || 'false'),
  };
}

function buildRunOptions(env, overrides = {}) {
  return {
    backend: RUN_BACKENDS.has(String(overrides.backend || env.RALPH_DEFAULT_BACKEND || '').trim())
      ? String(overrides.backend || env.RALPH_DEFAULT_BACKEND).trim()
      : 'auto',
    maxIterations: RUN_MAX_ITERATIONS.has(String(overrides.maxIterations || env.RALPH_DEFAULT_MAX_ITERATIONS || '').trim())
      ? String(overrides.maxIterations || env.RALPH_DEFAULT_MAX_ITERATIONS).trim()
      : '5',
    planMode: RUN_PLAN_MODES.has(String(overrides.planMode || env.RALPH_DEFAULT_PLAN_MODE || '').trim())
      ? String(overrides.planMode || env.RALPH_DEFAULT_PLAN_MODE).trim()
      : 'auto',
    executionMode: RUN_EXECUTION_MODES.has(String(overrides.executionMode || env.RALPH_DEFAULT_EXECUTION_MODE || '').trim())
      ? String(overrides.executionMode || env.RALPH_DEFAULT_EXECUTION_MODE).trim()
      : 'single',
    lang: normalizeRunLang(overrides.lang || env.RALPH_LANG || 'zh-CN'),
    requireApproval: typeof overrides.requireApproval === 'boolean'
      ? overrides.requireApproval
      : normalizeBooleanString(env.RALPH_DEFAULT_REQUIRE_APPROVAL) === true,
  };
}

function parseCommandOptions(env, rawText) {
  let rest = String(rawText || '').trim();
  const options = buildRunOptions(env);

  rest = rest.replace(/(^|\s)--approve\b/gi, (_, prefix) => {
    options.requireApproval = true;
    return prefix;
  });

  rest = rest.replace(/(^|\s)--backend\s+(auto|opencode|llm)\b/gi, (_, prefix, value) => {
    options.backend = value.toLowerCase();
    return prefix;
  });

  rest = rest.replace(/(^|\s)--max-iterations\s+(5|10|15|20)\b/gi, (_, prefix, value) => {
    options.maxIterations = value;
    return prefix;
  });

  rest = rest.replace(/(^|\s)--plan-mode\s+(auto|always|off)\b/gi, (_, prefix, value) => {
    options.planMode = value.toLowerCase();
    return prefix;
  });

  rest = rest.replace(/(^|\s)--execution-mode\s+(single|multi)\b/gi, (_, prefix, value) => {
    options.executionMode = value.toLowerCase();
    return prefix;
  });

  rest = rest.replace(/(^|\s)--lang\s+([a-zA-Z_-]+)\b/gi, (_, prefix, value) => {
    options.lang = normalizeRunLang(value, options.lang);
    return prefix;
  });

  return {
    raw: rest.replace(/\s+/g, ' ').trim(),
    options,
  };
}

function extractStructuredSection(text, labels) {
  const lines = String(text || '').replace(/\r/g, '').split('\n');
  const normalizedLabels = labels.map(label => label.toLowerCase());
  let collecting = false;
  const buffer = [];

  for (const line of lines) {
    const trimmed = line.trim();
    const lower = trimmed.toLowerCase();
    const matchedLabel = normalizedLabels.find(label => lower.startsWith(`${label}:`) || lower.startsWith(`${label}：`));

    if (matchedLabel) {
      if (collecting && buffer.length > 0) break;
      collecting = true;
      const content = trimmed.slice(matchedLabel.length + 1).trim();
      if (content) buffer.push(content);
      continue;
    }

    if (collecting) {
      const looksLikeNextHeader = /^[\p{L}\p{N}_ -]+[:：]\s*$/u.test(trimmed);
      if (looksLikeNextHeader) break;
      buffer.push(line);
    }
  }

  return buffer.join('\n').trim();
}

function parseStructuredTaskContent(rawText) {
  const raw = String(rawText || '').trim().replace(/\r/g, '');
  const lines = raw.split('\n').map(line => line.trimEnd());
  const nonEmptyLines = lines.filter(line => line.trim().length > 0);

  const objective = extractStructuredSection(raw, ['objective', 'goal', '目标']);
  const requirements = extractStructuredSection(raw, ['requirements', 'requirement', '要求']);
  const constraints = extractStructuredSection(raw, ['constraints', 'constraint', '限制']);
  const acceptance = extractStructuredSection(raw, ['acceptance criteria', 'acceptance', '验收标准', '验收']);
  const context = extractStructuredSection(raw, ['context', 'background', 'additional context', '补充上下文', '背景']);

  const hasStructuredSections = [objective, requirements, constraints, acceptance, context].some(Boolean);
  if (hasStructuredSections) {
    return {
      titleSource: objective || nonEmptyLines[0] || raw,
      objective: objective || nonEmptyLines[0] || raw,
      requirements,
      constraints,
      acceptance,
      context,
      raw,
      hasStructuredSections: true,
    };
  }

  const titleSource = nonEmptyLines[0] || raw;
  const remaining = nonEmptyLines.slice(1).join('\n').trim();
  return {
    titleSource,
    objective: titleSource,
    requirements: remaining || raw,
    constraints: '',
    acceptance: '',
    context: '',
    raw,
    hasStructuredSections: false,
  };
}

function needsTaskClarification(task) {
  const objectiveLen = String(task?.objective || '').replace(/\s+/g, '').length;
  const requirementsLen = String(task?.requirements || '').replace(/\s+/g, '').length;
  const hasAcceptance = String(task?.acceptance || '').replace(/\s+/g, '').length > 0;
  const hasStructuredSections = task?.hasStructuredSections === true;

  if (hasStructuredSections) {
    return objectiveLen < 6 || requirementsLen < 12 || !hasAcceptance;
  }

  return objectiveLen < 10 || requirementsLen < 20;
}

function normalizeTaskFingerprintPart(text) {
  return String(text || '')
    .toLowerCase()
    .replace(/\s+/g, ' ')
    .replace(/[^\p{L}\p{N}\s/_-]/gu, '')
    .trim();
}

function buildTaskFingerprint(task) {
  const objective = normalizeTaskFingerprintPart(task?.objective || task?.titleSource || '');
  const requirements = normalizeTaskFingerprintPart(task?.requirements || '');
  const constraints = normalizeTaskFingerprintPart(task?.constraints || '');
  const acceptance = normalizeTaskFingerprintPart(task?.acceptance || '');
  return [objective, requirements, constraints, acceptance].join('||');
}

function extractIssueSection(body, title) {
  const escaped = title.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const pattern = new RegExp(`^##\\s+${escaped}\\s*\\n([\\s\\S]*?)(?=\\n##\\s+|\\n---\\n|\\n<!--\\s*ralph-meta:|$)`, 'im');
  const match = String(body || '').match(pattern);
  return match ? match[1].trim() : '';
}

function buildIssueFingerprint(issue) {
  const body = issue?.body || '';
  return buildTaskFingerprint({
    objective: extractIssueSection(body, 'Objective') || extractIssueSection(body, '目标'),
    requirements: extractIssueSection(body, 'Requirements') || extractIssueSection(body, '要求'),
    constraints: extractIssueSection(body, 'Constraints') || extractIssueSection(body, '限制'),
    acceptance: extractIssueSection(body, 'Acceptance Criteria') || extractIssueSection(body, '验收标准'),
  });
}

function buildStructuredIssueBody(task, sender, metadataBlock, source, sourceLabelKey = 'issue_source_label') {
  const sections = [
    `## ${t(source, 'issue_section_objective')}`,
    task.objective || '(not provided)',
    '',
    `## ${t(source, 'issue_section_requirements')}`,
    task.requirements || t(source, 'issue_default_requirements'),
    '',
    `## ${t(source, 'issue_section_constraints')}`,
    task.constraints || t(source, 'issue_default_constraints'),
    '',
    `## ${t(source, 'issue_section_acceptance')}`,
    task.acceptance || t(source, 'issue_default_acceptance'),
  ];

  if (task.context) {
    sections.push('', `## ${t(source, 'issue_section_context')}`, task.context);
  }

  sections.push('', '---', `> ${t(source, sourceLabelKey)} (sender: ${sender})`, '', metadataBlock);
  return sections.join('\n');
}

async function dispatchRalphWorkflow(env, inputs) {
  return fetch(
    `https://api.github.com/repos/${env.GITHUB_REPO}/actions/workflows/ralph.yml/dispatches`,
    {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${env.GITHUB_TOKEN}`,
        'Content-Type': 'application/json',
        'User-Agent': 'Ralph-Feishu-Bridge',
      },
      body: JSON.stringify({
        ref: 'main',
        inputs,
      }),
    }
  );
}

function buildDispatchInputs(base, runOptions, extra = {}) {
  return {
    ...base,
    backend: runOptions.backend,
    lang: runOptions.lang,
    max_iterations: runOptions.maxIterations,
    plan_mode: runOptions.planMode,
    plan_execution_mode: runOptions.executionMode,
    require_approval: runOptions.requireApproval ? 'true' : 'false',
    ...extra,
  };
}

async function findSimilarOpenIssue(repo, token, task) {
  const fingerprint = buildTaskFingerprint(task);
  const normalizedTitle = normalizeIssueText(task?.titleSource || '');
  if (!fingerprint && !normalizedTitle) return null;

  const resp = await fetch(
    `https://api.github.com/repos/${repo}/issues?state=open&per_page=30&sort=updated&direction=desc`,
    {
      headers: {
        Authorization: `Bearer ${token}`,
        'User-Agent': 'Ralph-Feishu-Bridge',
      },
    }
  );

  if (!resp.ok) return null;
  const issues = await resp.json();
  return issues.find(issue => {
    if (issue.pull_request) return false;
    const issueFingerprint = buildIssueFingerprint(issue);
    if (fingerprint && issueFingerprint) {
      return issueFingerprint === fingerprint;
    }
    return normalizedTitle && normalizeIssueText(issue.title) === normalizedTitle;
  }) || null;
}

function buildRalphMetadata(metadata) {
  return `<!-- ralph-meta: ${JSON.stringify(metadata)} -->`;
}

function parseRalphMetadata(issue) {
  const body = issue?.body || '';
  const match = body.match(/<!--\s*ralph-meta:\s*([\s\S]*?)\s*-->/i);
  if (!match) return null;

  try {
    return JSON.parse(match[1]);
  } catch (_) {
    return null;
  }
}

async function fetchIssue(repo, token, issueNumber) {
  const resp = await fetch(
    `https://api.github.com/repos/${repo}/issues/${issueNumber}`,
    {
      headers: {
        Authorization: `Bearer ${token}`,
        'User-Agent': 'Ralph-Feishu-Bridge',
      },
    }
  );

  if (resp.status === 404) return null;
  if (!resp.ok) throw new Error(`fetch issue failed: ${resp.status}`);
  return await resp.json();
}

async function fetchIssueComments(repo, token, issueNumber) {
  const resp = await fetch(
    `https://api.github.com/repos/${repo}/issues/${issueNumber}/comments?per_page=100&sort=created&direction=desc`,
    {
      headers: {
        Authorization: `Bearer ${token}`,
        'User-Agent': 'Ralph-Feishu-Bridge',
      },
    }
  );

  if (!resp.ok) throw new Error(`fetch comments failed: ${resp.status}`);
  return await resp.json();
}

async function searchIssues(token, query, perPage = 20) {
  const url = new URL('https://api.github.com/search/issues');
  url.searchParams.set('q', query);
  url.searchParams.set('per_page', String(perPage));

  const resp = await fetch(url.toString(), {
    headers: {
      Authorization: `Bearer ${token}`,
      'User-Agent': 'Ralph-Feishu-Bridge',
    },
  });

  if (!resp.ok) throw new Error(`search issues failed: ${resp.status}`);
  const data = await resp.json();
  return Array.isArray(data?.items) ? data.items : [];
}

function extractRepoFromApiUrl(repositoryUrl = '') {
  const match = String(repositoryUrl || '').match(/\/repos\/([^/]+\/[^/]+)$/);
  return match ? match[1] : null;
}

function getRepoOwner(repo = '') {
  return String(repo || '').split('/')[0] || '';
}

async function findRecentRalphIssues(env, { includeClosed = false, limit = 20 } = {}) {
  const owner = getRepoOwner(env.GITHUB_REPO);
  if (!owner) return [];

  const issueScope = includeClosed ? 'is:issue' : 'is:issue is:open';
  const queries = [
    `user:${owner} ${issueScope} "Ralph 已接收任务" in:comments sort:updated-desc`,
    `user:${owner} ${issueScope} "Ralph is on it" in:comments sort:updated-desc`,
  ];
  const merged = new Map();

  for (const query of queries) {
    const items = await searchIssues(env.GITHUB_TOKEN, query, limit);
    for (const item of items) {
      const repo = extractRepoFromApiUrl(item.repository_url);
      if (!repo) continue;

      const key = `${repo}#${item.number}`;
      const nextValue = {
        repo,
        number: item.number,
        title: item.title,
        html_url: item.html_url,
        state: item.state,
        updated_at: item.updated_at,
      };
      const prevValue = merged.get(key);
      if (!prevValue || new Date(nextValue.updated_at || 0).getTime() > new Date(prevValue.updated_at || 0).getTime()) {
        merged.set(key, nextValue);
      }
    }
  }

  return Array.from(merged.values()).sort((a, b) => {
    return new Date(b.updated_at || 0).getTime() - new Date(a.updated_at || 0).getTime();
  });
}

async function findLatestTaskForSender(env, senderOpenId) {
  if (!senderOpenId) return null;
  const owner = getRepoOwner(env.GITHUB_REPO);
  if (!owner) return null;

  const items = await searchIssues(
    env.GITHUB_TOKEN,
    `user:${owner} is:issue "${senderOpenId}" in:body sort:updated-desc`,
    10
  ).catch(() => []);

  for (const item of items) {
    const repo = extractRepoFromApiUrl(item.repository_url);
    if (!repo) continue;
    return {
      issueRepo: repo,
      issueNumber: Number(item.number),
      targetRepo: repo,
      title: item.title || '',
      updatedAt: item.updated_at || '',
    };
  }

  return null;
}

async function resolveCurrentTaskContext(env, chatId, senderOpenId = '') {
  const stored = await getChatTaskState(env, chatId);
  if (stored) return stored;
  return await findLatestTaskForSender(env, senderOpenId);
}

function extractLatestExecutionSnapshot(comments) {
  const progressMarker = /<!--\s*ralph-progress:\d+\s*-->/i;
  for (const comment of comments || []) {
    const body = comment?.body || '';
    if (!progressMarker.test(body)) continue;

    const status = body.match(/\*\*Status\*\*:\s*`([^`]+)`/i)?.[1] || '';
    const stage = body.match(/\*\*Stage\*\*:\s*`([^`]+)`/i)?.[1] || '';
    const summary = body.match(/\*\*Summary\*\*:\s*([^\n]+)/i)?.[1]?.trim() || '';
    const failureCode = body.match(/\*\*Failure Code\*\*:\s*`([^`]+)`/i)?.[1] || '';
    if (status || stage || summary || failureCode) {
      return { status, stage, summary, failureCode };
    }
  }
  return null;
}

function extractTargetRepoFromIssue(issue) {
  const body = issue?.body || '';
  const match = body.match(/Target repo:\s+`([^`]+)`/i);
  return match ? match[1] : null;
}

function findLatestRunUrlFromComments(comments) {
  const runUrlPattern = /https:\/\/github\.com\/[^/\s]+\/[^/\s]+\/actions\/runs\/\d+/g;
  for (const comment of comments || []) {
    const body = comment?.body || '';
    const matches = body.match(runUrlPattern);
    if (matches && matches.length) {
      return matches[matches.length - 1];
    }
  }
  return null;
}

async function resolveApprovalRepo(env, issueNumber, repoHint = null) {
  if (repoHint) {
    const hintedIssue = await fetchIssue(repoHint, env.GITHUB_TOKEN, issueNumber);
    if (hintedIssue) {
      const metadata = parseRalphMetadata(hintedIssue);
      return {
        repo: repoHint,
        issue: hintedIssue,
        targetRepo: metadata?.target_repo || extractTargetRepoFromIssue(hintedIssue),
      };
    }
  }

  const defaultRepo = env.GITHUB_REPO;
  const centralIssue = await fetchIssue(defaultRepo, env.GITHUB_TOKEN, issueNumber);
  if (!centralIssue) return null;

  const metadata = parseRalphMetadata(centralIssue);
  const targetRepo = metadata?.target_repo || extractTargetRepoFromIssue(centralIssue);
  if (!targetRepo) {
    return {
      repo: defaultRepo,
      issue: centralIssue,
    };
  }

  return {
    repo: defaultRepo,
    issue: centralIssue,
    targetRepo,
  };
}

async function resolveIssueForLogs(env, issueNumber, repoHint = null) {
  const direct = await resolveApprovalRepo(env, issueNumber, repoHint);
  if (direct) {
    const comments = await fetchIssueComments(direct.repo, env.GITHUB_TOKEN, issueNumber).catch(() => []);
    const runUrl = findLatestRunUrlFromComments(comments);
    if (runUrl) {
      return { repo: direct.repo, issueNumber: Number(issueNumber), runUrl };
    }
  }

  const candidates = await findRecentRalphIssues(env, { includeClosed: true, limit: 30 });
  for (const item of candidates) {
    if (item.number !== Number(issueNumber)) continue;
    if (repoHint && item.repo !== repoHint) continue;

    const comments = await fetchIssueComments(item.repo, env.GITHUB_TOKEN, item.number).catch(() => []);
    const runUrl = findLatestRunUrlFromComments(comments);
    if (runUrl) {
      return { repo: item.repo, issueNumber: item.number, runUrl };
    }
  }

  return null;
}

// ═══════════════════════════════════════════
// GitHub Webhook receiver
// ═══════════════════════════════════════════
async function handleGitHubWebhook(request, env, ctx) {
  if (request.method !== 'POST') {
    return Response.json({ error: 'POST only' }, { status: 405 });
  }

  // Verify GitHub Webhook signature (optional but recommended)
  if (env.GITHUB_WEBHOOK_SECRET) {
    const signature = request.headers.get('x-hub-signature-256') || '';
    const bodyText = await request.text();
    const isValid = await verifyGitHubSignature(bodyText, signature, env.GITHUB_WEBHOOK_SECRET);
    if (!isValid) {
      return Response.json({ error: 'invalid signature' }, { status: 401 });
    }
    const body = JSON.parse(bodyText);
    ctx.waitUntil(processGitHubEvent(request, body, env));
  } else {
    const body = await request.json();
    ctx.waitUntil(processGitHubEvent(request, body, env));
  }

  return Response.json({ ok: true });
}

async function processGitHubEvent(request, body, env) {
  const event = request.headers.get('x-github-event');

  // Only handle issues.labeled events
  if (event !== 'issues' || body.action !== 'labeled') return;

  const label = body.label?.name;
  if (label !== 'ai/ready') return;

  const repo = body.repository?.full_name;
  const issueNumber = body.issue?.number;
  if (!repo || !issueNumber) return;

  const centralRepo = env.GITHUB_REPO;

  console.log(`🐺 Webhook: ${repo}#${issueNumber} labeled ai/ready → dispatching ${centralRepo}`);

  // Dispatch central workflow
  const resp = await fetch(
    `https://api.github.com/repos/${centralRepo}/actions/workflows/ralph.yml/dispatches`,
    {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${env.GITHUB_TOKEN}`,
        'Content-Type': 'application/json',
        'User-Agent': 'Ralph-Central-Dispatcher',
      },
      body: JSON.stringify({
        ref: 'main',
        inputs: {
          issue_number: String(issueNumber),
          target_repo: repo,
          backend: 'auto',
          max_iterations: '5',
        },
      }),
    }
  );

  if (!resp.ok) {
    const err = await resp.text();
    console.error(`Dispatch failed for ${repo}#${issueNumber}:`, resp.status, err);
  }
}

async function verifyGitHubSignature(payload, signature, secret) {
  if (!signature) return false;
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    'raw',
    encoder.encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign']
  );
  const sig = await crypto.subtle.sign('HMAC', key, encoder.encode(payload));
  const digest = 'sha256=' + Array.from(new Uint8Array(sig)).map(b => b.toString(16).padStart(2, '0')).join('');
  return signature === digest;
}

// ═══════════════════════════════════════════
// Feishu → Ralph: message handling
// ═══════════════════════════════════════════
async function handleMessage(event, env) {
  const msg = event?.message;
  if (!msg || msg.message_type !== 'text') return;

  // Source chat_id — used to route notifications back to the same chat (private or group)
  const chatId = msg.chat_id;
  const senderOpenId = event?.sender?.sender_id?.open_id || '';
  const chatConfig = await getChatConfig(env, chatId);
  const source = buildConfigSource(env, chatConfig);

  try {
  const content = JSON.parse(msg.content || '{}');
  let text = (content.text || '').replace(/@_user_\d+/g, '').trim();

  const defaultRepo = env.GITHUB_REPO;

  // ── /chatid ──
  if (text === '/chatid') {
    await replyFeishuCard(
      env,
      msg.message_id,
      buildInfoCard({
        title: t(source, 'chatid_title'),
        template: 'wathet',
        sections: [t(source, 'chatid_reply', chatId || 'unknown')],
      }),
      t(source, 'chatid_reply', chatId || 'unknown')
    );
    return;
  }

  // ── /lang [locale] ──
  const langMatch = text.match(/^\/lang(?:\s+([a-zA-Z_-]+))?$/i);
  if (langMatch) {
    await handleLang(env, source, msg.message_id, chatId, langMatch[1] || '');
    return;
  }

  // ── /config ──
  if (text === '/config') {
    await handleConfig(env, source, msg.message_id, chatId, 'show');
    return;
  }
  const configSetMatch = text.match(/^\/config\s+set\s+(backend|maxIterations|planMode|executionMode|lang|requireApproval)\s+(.+)$/i);
  if (configSetMatch) {
    await handleConfig(env, source, msg.message_id, chatId, 'set', configSetMatch[1], configSetMatch[2]);
    return;
  }
  const configUnsetMatch = text.match(/^\/config\s+unset\s+(backend|maxIterations|planMode|executionMode|lang|requireApproval)$/i);
  if (configUnsetMatch) {
    await handleConfig(env, source, msg.message_id, chatId, 'unset', configUnsetMatch[1]);
    return;
  }
  if (/^\/config\s+reset$/i.test(text)) {
    await handleConfig(env, source, msg.message_id, chatId, 'reset');
    return;
  }

  // ── /help ──
  if (text === '/help' || text === 'help') {
    await replyFeishuCard(
      env,
      msg.message_id,
      buildInfoCard({
        title: t(source, 'help_title'),
        template: 'blue',
        sections: [
          t(source, 'help_create'),
          t(source, 'help_multiline'),
          t(source, 'help_recommended'),
          t(source, 'help_execution'),
          t(source, 'help_plan'),
          t(source, 'help_manual'),
          t(source, 'help_other'),
        ],
        note: t(source, 'help_note'),
      }),
      [t(source, 'help_create'), t(source, 'help_multiline'), t(source, 'help_recommended'), t(source, 'help_execution'), t(source, 'help_plan'), t(source, 'help_manual'), t(source, 'help_other'), t(source, 'help_note')].join('\n\n')
    );
    return;
  }

  // ── /status ──
  const statusMatch = text.match(/^\/status(?:\s+(?:(?<repo>[a-zA-Z0-9_.-]+\/[a-zA-Z0-9_.-]+)\s+)?(?<num>\d+))?$/i);
  if (statusMatch) {
    await handleStatus(env, source, msg.message_id, chatId, senderOpenId, statusMatch.groups?.num || null, statusMatch.groups?.repo || null);
    return;
  }

  // ── /run|/continue|/retry|/plan|/review <issue#> ──
  const runMatch = text.match(/^\/(?<command>run|continue|retry|plan|review)\s+(?:(?<repo>[a-zA-Z0-9_.-]+\/[a-zA-Z0-9_.-]+)\s+)?(?<num>\d+)(?<raw>[\s\S]*)$/i);
  if (runMatch) {
    await handleRunCommand(
      env,
      source,
      msg.message_id,
      runMatch.groups.command.toLowerCase(),
      runMatch.groups.num,
      runMatch.groups.repo || null,
      runMatch.groups.raw || '',
      chatId
    );
    return;
  }

  // ── /logs <issue#> ──
  const logsMatch = text.match(/^\/logs(?:\s+(?:(?<repo>[a-zA-Z0-9_.-]+\/[a-zA-Z0-9_.-]+)\s+)?(?<num>\d+))?$/i);
  if (logsMatch) {
    await handleLogs(env, source, msg.message_id, chatId, senderOpenId, logsMatch.groups?.num || null, logsMatch.groups?.repo || null);
    return;
  }

  // ── /approve <issue#> ──
  const approveMatch = text.match(/\/approve\s+(?:(?<repo>[a-zA-Z0-9_.-]+\/[a-zA-Z0-9_.-]+)\s+)?(?<num>\d+)/);
  if (approveMatch) {
    await handleApproveReject(
      env,
      source,
      msg.message_id,
      approveMatch.groups.num,
      'approve',
      approveMatch.groups.repo || null
    );
    return;
  }

  // ── /reject <issue#> ──
  const rejectMatch = text.match(/\/reject\s+(?:(?<repo>[a-zA-Z0-9_.-]+\/[a-zA-Z0-9_.-]+)\s+)?(?<num>\d+)/);
  if (rejectMatch) {
    await handleApproveReject(
      env,
      source,
      msg.message_id,
      rejectMatch.groups.num,
      'reject',
      rejectMatch.groups.repo || null
    );
    return;
  }

  // ── /cancel <issue#> ──
  const cancelMatch = text.match(/\/cancel\s+(?:(?<repo>[a-zA-Z0-9_.-]+\/[a-zA-Z0-9_.-]+)\s+)?(?<num>\d+)/i);
  if (cancelMatch) {
    await handleCancel(env, source, msg.message_id, cancelMatch.groups.num, cancelMatch.groups.repo || null);
    return;
  }

  // ── /create owner/repo <task> ──
  const createMatch = text.match(/\/create\s+([a-zA-Z0-9_.-]+\/[a-zA-Z0-9_.-]+)(?:\s+(.+))?/s);
  if (createMatch) {
    let createTask = createMatch[2] || createMatch[1].split('/')[1];
    const parsedCreate = parseCommandOptions(source, createTask);
    await handleCreateRepo(env, source, msg, event, createMatch[1], parsedCreate.raw, chatId, parsedCreate.options);
    return;
  }

  // ── /ralph <task> or /ralph owner/repo <task> ──
  const match = text.match(/\/ralph\s+(.+)/s);
  if (!match) return;

  await addReaction(env, msg.message_id, 'THUMBSUP');

  const parsedTask = parseCommandOptions(source, match[1].trim());
  let rawContent = parsedTask.raw;
  const runOptions = parsedTask.options;

  // Parse repo: /ralph owner/repo task
  let targetRepo = defaultRepo;
  let taskContent = rawContent;
  const repoMatch = rawContent.match(/^([a-zA-Z0-9_.-]+\/[a-zA-Z0-9_.-]+)\s+(.+)/s);
  if (repoMatch) {
    targetRepo = repoMatch[1];
    taskContent = repoMatch[2].trim();
  }

  const isCrossRepo = targetRepo !== defaultRepo;
  const structuredTask = parseStructuredTaskContent(taskContent.trim());
  if (needsTaskClarification(structuredTask)) {
    await replyFeishu(env, msg.message_id, t(source, 'task_clarification_needed'));
    return;
  }
  const sender = event?.sender?.sender_id?.open_id || 'unknown';
  const title = await summarizeTitle(structuredTask.titleSource, env);
  const metadataBlock = buildRalphMetadata({
    source: 'feishu',
    issue_repo: targetRepo,
    target_repo: targetRepo,
    chat_id: chatId || '',
    lang: runOptions.lang,
    require_approval: runOptions.requireApproval,
    sender,
    created_at: new Date().toISOString(),
  });
  const issueBody = buildStructuredIssueBody(structuredTask, sender, metadataBlock, source, 'issue_source_label');

  try {
    // 0. Ensure target repo exists (auto-create if missing for cross-repo)
    if (isCrossRepo) {
      const repoStatus = await ensureRepoExists(targetRepo, env.GITHUB_TOKEN);
      if (!repoStatus.exists) {
        await replyFeishu(env, msg.message_id, t(source, 'repo_not_exist', targetRepo, repoStatus.error || 'unknown'));
        return;
      }
      if (repoStatus.created) {
        console.log(`Auto-created repo: ${targetRepo}`);
      }
    }

    const existingIssue = await findSimilarOpenIssue(targetRepo, env.GITHUB_TOKEN, structuredTask);
    if (existingIssue) {
      await putChatTaskState(env, chatId, {
        issueRepo: targetRepo,
        issueNumber: Number(existingIssue.number),
        targetRepo,
        title: existingIssue.title || '',
      });
      await addReaction(env, msg.message_id, 'OK');
      await replyFeishu(env, msg.message_id, t(source, 'duplicate_issue_reply', existingIssue.number, targetRepo));
      return;
    }

    // 1. Create Issue in target repo (no ai/ready label to avoid webhook duplicate trigger)
    const issueResp = await fetch(
      `https://api.github.com/repos/${targetRepo}/issues`,
      {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${env.GITHUB_TOKEN}`,
          'Content-Type': 'application/json',
          'User-Agent': 'Ralph-Feishu-Bridge',
        },
        body: JSON.stringify({
          title,
          body: issueBody,
          labels: [],
        }),
      }
    );

    if (!issueResp.ok) {
      const err = await issueResp.text();
      console.error('GitHub API error:', issueResp.status, err);
      await replyFeishu(env, msg.message_id, t(source, 'issue_create_error', issueResp.status));
      return;
    }

    const issue = await issueResp.json();
    await putChatTaskState(env, chatId, {
      issueRepo: targetRepo,
      issueNumber: Number(issue.number),
      targetRepo,
      title: issue.title || '',
    });

    // 2. Dispatch central workflow directly (bypass webhook to avoid race)
    const dispatchResp = await dispatchRalphWorkflow(env, buildDispatchInputs(
      {
        issue_number: String(issue.number),
        target_repo: targetRepo,
        feishu_chat_id: chatId || '',
      },
      runOptions
    ));

    if (!dispatchResp.ok) {
      const err = await dispatchResp.text();
      console.error('Dispatch error:', dispatchResp.status, err);
      await replyFeishu(env, msg.message_id, t(source, 'dispatch_error', issue.number, dispatchResp.status));
      return;
    }

    await addReaction(env, msg.message_id, 'OK');

    const card = {
      config: { wide_screen_mode: true },
      header: {
        title: { tag: 'plain_text', content: t(source, 'ralph_card_title') },
        template: 'blue',
      },
      elements: [
        {
          tag: 'div',
          text: { tag: 'lark_md', content: t(source, 'ralph_card_summary', issue.title) },
        },
        buildFactFields([
          { label: t(source, 'card_issue_label'), value: `[#${issue.number}](${issue.html_url})` },
          { label: t(source, 'card_repo_label'), value: `\`${targetRepo}\`` },
          { label: t(source, 'card_backend_label'), value: `\`${runOptions.backend}\`` },
          { label: t(source, 'card_mode_label'), value: `\`${runOptions.planMode}/${runOptions.executionMode}\`` },
        ]),
        buildActionRow([
          { tag: 'button', text: { tag: 'plain_text', content: t(source, 'view_issue') }, url: issue.html_url, type: 'primary' },
        ]),
        {
          tag: 'note',
          elements: [{ tag: 'plain_text', content: t(source, 'dispatch_note', env.GITHUB_REPO) }],
        },
      ],
    };
    await replyFeishuCard(env, msg.message_id, card);
  } catch (err) {
    console.error('Create issue failed:', err);
    await replyFeishu(env, msg.message_id, t(source, 'issue_error', err.message));
  }
  } catch (topErr) {
    console.error('handleMessage uncaught error:', topErr);
    try { await replyFeishu(env, msg.message_id, t(source, 'internal_error', topErr.message)); } catch (_) {}
  }
}

// ── /approve & /reject ──
async function handleApproveReject(env, source, messageId, issueNumber, action, repoHint = null) {
  const commentBody = action === 'approve' ? '/approve' : '/reject';

  try {
    const approvalTarget = await resolveApprovalRepo(env, issueNumber, repoHint);
    if (!approvalTarget) {
      await replyFeishu(env, messageId, t(source, 'issue_not_found', issueNumber));
      return;
    }

    const repo = approvalTarget.repo;

    // Post comment on the issue
    const resp = await fetch(
      `https://api.github.com/repos/${repo}/issues/${issueNumber}/comments`,
      {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${env.GITHUB_TOKEN}`,
          'Content-Type': 'application/json',
          'User-Agent': 'Ralph-Feishu-Bridge',
        },
        body: JSON.stringify({ body: `${commentBody}\n\n> ${t(source, 'comment_source_feishu')}` }),
      }
    );

    if (!resp.ok) {
      await replyFeishu(env, messageId, t(source, 'approve_error', resp.status));
      return;
    }

    // If approving, also add label as backup
    if (action === 'approve') {
      await fetch(
        `https://api.github.com/repos/${repo}/issues/${issueNumber}/labels`,
        {
          method: 'POST',
          headers: {
            Authorization: `Bearer ${env.GITHUB_TOKEN}`,
            'Content-Type': 'application/json',
            'User-Agent': 'Ralph-Feishu-Bridge',
          },
          body: JSON.stringify({ labels: ['ai/plan-approved'] }),
        }
      );
    }

    const emoji = action === 'approve' ? '✅' : '❌';
    const verb = t(source, action === 'approve' ? 'approve_verb' : 'reject_verb');
    await replyFeishu(env, messageId, t(source, 'approve_reply', emoji, verb, issueNumber));
  } catch (err) {
    await replyFeishu(env, messageId, t(source, 'approve_error', err.message));
  }
}

async function handleCancel(env, source, messageId, issueNumber, repoHint = null) {
  try {
    const approvalTarget = await resolveApprovalRepo(env, issueNumber, repoHint);
    if (!approvalTarget) {
      await replyFeishu(env, messageId, t(source, 'issue_not_found', issueNumber));
      return;
    }

    const repo = approvalTarget.repo;
    const resp = await fetch(
      `https://api.github.com/repos/${repo}/issues/${issueNumber}/comments`,
      {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${env.GITHUB_TOKEN}`,
          'Content-Type': 'application/json',
          'User-Agent': 'Ralph-Feishu-Bridge',
        },
        body: JSON.stringify({ body: `/reject\n\n> ${t(source, 'comment_source_cancel')}` }),
      }
    );

    if (!resp.ok) {
      await replyFeishu(env, messageId, t(source, 'approve_error', resp.status));
      return;
    }

    await replyFeishu(env, messageId, t(source, 'cancel_note', issueNumber));
  } catch (err) {
    await replyFeishu(env, messageId, t(source, 'approve_error', err.message));
  }
}

async function handleRunCommand(env, source, messageId, command, issueNumber, repoHint, rawOptions, feishuChatId) {
  try {
    const runOptions = parseCommandOptions(source, rawOptions).options;
    const approvalTarget = await resolveApprovalRepo(env, issueNumber, repoHint);
    if (!approvalTarget) {
      await replyFeishu(env, messageId, t(source, 'issue_not_found', issueNumber));
      return;
    }

    const issueRepo = approvalTarget.repo;
    const targetRepo = approvalTarget.targetRepo || approvalTarget.repo;
    await putChatTaskState(env, feishuChatId, {
      issueRepo,
      issueNumber: Number(issueNumber),
      targetRepo,
      title: approvalTarget.issue?.title || '',
    });
    const effectiveOptions = command === 'plan'
      ? {
          ...runOptions,
          planMode: 'always',
          requireApproval: true,
        }
      : runOptions;
    const dispatchResp = await dispatchRalphWorkflow(env, buildDispatchInputs(
      {
        issue_number: String(issueNumber),
        target_repo: targetRepo,
        issue_repo: issueRepo,
        feishu_chat_id: feishuChatId || '',
        review_only: command === 'review' ? 'true' : 'false',
      },
      effectiveOptions
    ));

    if (!dispatchResp.ok) {
      const err = await dispatchResp.text();
      console.error('Run dispatch error:', dispatchResp.status, err);
      await replyFeishu(env, messageId, t(source, 'run_dispatch_error', issueNumber, dispatchResp.status));
      return;
    }

    await replyFeishu(
      env,
      messageId,
      t(
        source,
        command === 'plan' ? 'plan_dispatch_ok' : command === 'review' ? 'review_dispatch_ok' : 'run_dispatch_ok',
        command,
        issueNumber,
        targetRepo,
        effectiveOptions.backend,
        effectiveOptions.maxIterations,
        effectiveOptions.lang
      )
    );
  } catch (err) {
    await replyFeishu(env, messageId, t(source, 'run_dispatch_fail', err.message));
  }
}

async function handleLogs(env, source, messageId, chatId, senderOpenId, issueNumber = null, repoHint = null) {
  try {
    let effectiveRepoHint = repoHint;
    let effectiveIssueNumber = issueNumber ? Number(issueNumber) : null;

    if (!effectiveRepoHint || !effectiveIssueNumber) {
      const currentTask = await resolveCurrentTaskContext(env, chatId, senderOpenId);
      if (currentTask) {
        effectiveRepoHint = effectiveRepoHint || currentTask.issueRepo;
        effectiveIssueNumber = effectiveIssueNumber || currentTask.issueNumber;
      }
    }

    if (!effectiveIssueNumber) {
      await replyFeishu(env, messageId, t(source, 'current_task_missing'));
      return;
    }

    const resolved = await resolveIssueForLogs(env, effectiveIssueNumber, effectiveRepoHint);
    if (!resolved?.runUrl) {
      await replyFeishu(env, messageId, t(source, 'logs_not_found', effectiveIssueNumber));
      return;
    }

    await replyFeishu(env, messageId, t(source, 'logs_found', effectiveIssueNumber, resolved.runUrl));
  } catch (err) {
    await replyFeishu(env, messageId, t(source, 'logs_error', err.message));
  }
}

// ── /create owner/repo <task> ──
async function handleCreateRepo(env, source, msg, event, targetRepo, taskContent, feishuChatId, runOptions) {
  await addReaction(env, msg.message_id, 'THUMBSUP');

  const centralRepo = env.GITHUB_REPO;
  const structuredTask = parseStructuredTaskContent(taskContent.trim());
  if (needsTaskClarification(structuredTask)) {
    await replyFeishu(env, msg.message_id, t(source, 'task_clarification_needed'));
    return;
  }
  const sender = event?.sender?.sender_id?.open_id || 'unknown';
  const title = await summarizeTitle(structuredTask.titleSource, env);
  const metadataBlock = buildRalphMetadata({
    source: 'feishu_create',
    issue_repo: centralRepo,
    target_repo: targetRepo,
    chat_id: feishuChatId || '',
    lang: runOptions.lang,
    require_approval: runOptions.requireApproval,
    sender,
    created_at: new Date().toISOString(),
  });
  const issueBody = buildStructuredIssueBody(structuredTask, sender, metadataBlock, source, 'issue_source_label_create');

  try {
    const centralIssueTitle = `[${targetRepo}] ${title}`;
    const existingIssue = await findSimilarOpenIssue(centralRepo, env.GITHUB_TOKEN, {
      ...structuredTask,
      titleSource: centralIssueTitle,
      objective: structuredTask.objective || centralIssueTitle,
    });
    if (existingIssue) {
      await putChatTaskState(env, feishuChatId, {
        issueRepo: centralRepo,
        issueNumber: Number(existingIssue.number),
        targetRepo,
        title: existingIssue.title || '',
      });
      await addReaction(env, msg.message_id, 'OK');
      await replyFeishu(env, msg.message_id, t(source, 'duplicate_issue_reply', existingIssue.number, centralRepo));
      return;
    }

    // Create issue in central repo (target repo doesn't exist yet)
    const issueResp = await fetch(
      `https://api.github.com/repos/${centralRepo}/issues`,
      {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${env.GITHUB_TOKEN}`,
          'Content-Type': 'application/json',
          'User-Agent': 'Ralph-Feishu-Bridge',
        },
        body: JSON.stringify({
          title: centralIssueTitle,
          body: `Target repo: \`${targetRepo}\` (to be created)\n\n${issueBody}`,
          labels: [],
        }),
      }
    );

    if (!issueResp.ok) {
      await replyFeishu(env, msg.message_id, t(source, 'issue_create_error', issueResp.status));
      return;
    }

    const issue = await issueResp.json();
    await putChatTaskState(env, feishuChatId, {
      issueRepo: centralRepo,
      issueNumber: Number(issue.number),
      targetRepo,
      title: issue.title || '',
    });

    // Dispatch workflow with create_repo=true
    const createOptions = {
      ...runOptions,
      maxIterations: runOptions.maxIterations === '5' ? '10' : runOptions.maxIterations,
    };
    const dispatchResp = await dispatchRalphWorkflow(env, buildDispatchInputs(
      {
        issue_number: String(issue.number),
        target_repo: targetRepo,
        issue_repo: centralRepo,
        create_repo: 'true',
        repo_visibility: 'public',
        feishu_chat_id: feishuChatId || '',
      },
      createOptions
    ));

    if (!dispatchResp.ok) {
      await replyFeishu(env, msg.message_id, t(source, 'create_dispatch_error', issue.number, dispatchResp.status));
      return;
    }

    await addReaction(env, msg.message_id, 'OK');

    const card = {
      config: { wide_screen_mode: true },
      header: {
        title: { tag: 'plain_text', content: t(source, 'create_card_title') },
        template: 'green',
      },
      elements: [
        {
          tag: 'div',
          text: { tag: 'lark_md', content: t(source, 'create_card_summary', title) },
        },
        buildFactFields([
          { label: t(source, 'card_issue_label'), value: `[#${issue.number}](${issue.html_url})` },
          { label: t(source, 'card_repo_label'), value: `\`${targetRepo}\`` },
          { label: t(source, 'card_backend_label'), value: `\`${createOptions.backend}\`` },
          { label: t(source, 'card_iterations_label'), value: `\`${createOptions.maxIterations}\`` },
        ]),
        buildActionRow([
          { tag: 'button', text: { tag: 'plain_text', content: t(source, 'view_issue') }, url: issue.html_url, type: 'primary' },
        ]),
      ],
    };
    await replyFeishuCard(env, msg.message_id, card);
  } catch (err) {
    await replyFeishu(env, msg.message_id, t(source, 'create_error', err.message));
  }
}

// ── /status ──
async function handleStatus(env, source, messageId, chatId, senderOpenId, issueNumber = null, repoHint = null) {
  try {
    let effectiveRepoHint = repoHint;
    let effectiveIssueNumber = issueNumber ? Number(issueNumber) : null;

    if (!effectiveRepoHint || !effectiveIssueNumber) {
      const currentTask = await resolveCurrentTaskContext(env, chatId, senderOpenId);
      if (currentTask) {
        effectiveRepoHint = effectiveRepoHint || currentTask.issueRepo;
        effectiveIssueNumber = effectiveIssueNumber || currentTask.issueNumber;
      }
    }

    if (!effectiveIssueNumber) {
      await replyFeishu(env, messageId, t(source, 'current_task_missing'));
      return;
    }

    const issueRepo = effectiveRepoHint || env.GITHUB_REPO;
    const issue = await fetchIssue(issueRepo, env.GITHUB_TOKEN, effectiveIssueNumber);
    if (!issue) {
      await replyFeishu(env, messageId, t(source, 'issue_not_found', effectiveIssueNumber));
      return;
    }

    const comments = await fetchIssueComments(issueRepo, env.GITHUB_TOKEN, effectiveIssueNumber).catch(() => []);
    const snapshot = extractLatestExecutionSnapshot(comments);
    const status = snapshot?.status || 'open';
    const targetRepo = parseRalphMetadata(issue)?.target_repo || extractTargetRepoFromIssue(issue) || issueRepo;
    const emoji =
      status === 'completed' || status === 'ai/done' ? '🟢' :
      status === 'failed' || status === 'blocked' || status === 'ai/failed' ? '🔴' :
      status === 'clarification_needed' ? '🟠' :
      '🟡';
    const extra = [snapshot?.stage, snapshot?.failureCode].filter(Boolean).join(' / ');
    const elements = [];
    elements.push({
      tag: 'div',
      text: {
        tag: 'lark_md',
        content: `${emoji} **${issueRepo}#${effectiveIssueNumber}** [${issue.title}](${issue.html_url})\n${t(source, 'card_repo_label')}: \`${targetRepo}\`\n${t(source, 'card_status_label')}: \`${status}\`${extra ? `\n${t(source, 'card_stage_label')}: \`${extra}\`` : ''}`,
      },
    });
    const card = {
      config: { wide_screen_mode: true },
      header: {
        title: { tag: 'plain_text', content: t(source, 'status_title') },
        template: 'purple',
      },
      elements: [
        ...elements,
        {
          tag: 'note',
          elements: [{ tag: 'plain_text', content: t(source, 'status_legend') }],
        },
      ],
    };
    await replyFeishuCard(env, messageId, card);
  } catch (err) {
    await replyFeishu(env, messageId, t(source, 'status_error', err.message));
  }
}

async function handleConfig(env, source, messageId, chatId, action = 'show', key = '', value = '') {
  if (action === 'show') {
    const defaults = buildRunOptions(source);
    const lines = [
      `**${t(source, 'config_label_repo')}** \`${env.GITHUB_REPO || '(not set)'}\``,
      `**${t(source, 'config_label_backend')}** \`${defaults.backend}\``,
      `**${t(source, 'config_label_iterations')}** \`${defaults.maxIterations}\``,
      `**${t(source, 'config_label_plan_mode')}** \`${defaults.planMode}\``,
      `**${t(source, 'config_label_execution_mode')}** \`${defaults.executionMode}\``,
      `**${t(source, 'config_label_language')}** \`${defaults.lang}\``,
      `**${t(source, 'config_label_approval')}** \`${defaults.requireApproval ? 'true' : 'false'}\``,
      `**${t(source, 'config_label_persistent')}** \`${env.RALPH_CONFIG?.get ? t(source, 'config_value_enabled') : t(source, 'config_value_disabled')}\``,
      '',
      t(source, 'config_usage'),
    ];
    await replyFeishuCard(
      env,
      messageId,
      buildInfoCard({
        title: t(source, 'config_title'),
        template: 'indigo',
        sections: [lines.join('\n')],
      }),
      lines.join('\n')
    );
    return;
  }

  if (!env.RALPH_CONFIG?.get) {
    await replyFeishu(env, messageId, t(source, 'config_store_missing'));
    return;
  }

  try {
    if (action === 'reset') {
      await deleteChatConfig(env, chatId);
      await replyFeishu(env, messageId, t(source, 'config_reset_ok'));
      return;
    }

    const existing = await getChatConfig(env, chatId);
    const normalizedKey = String(key || '').trim();
    if (!CONFIG_KEYS.has(normalizedKey)) {
      await replyFeishu(env, messageId, t(source, 'config_invalid_key', normalizedKey));
      return;
    }

    if (action === 'unset') {
      delete existing[normalizedKey];
      if (Object.keys(existing).length === 0) {
        await deleteChatConfig(env, chatId);
      } else {
        await putChatConfig(env, chatId, existing);
      }
      await replyFeishu(env, messageId, t(source, 'config_unset_ok', normalizedKey));
      return;
    }

    let normalizedValue;
    switch (normalizedKey) {
      case 'backend':
        normalizedValue = RUN_BACKENDS.has(String(value || '').trim()) ? String(value).trim() : null;
        break;
      case 'maxIterations':
        normalizedValue = RUN_MAX_ITERATIONS.has(String(value || '').trim()) ? String(value).trim() : null;
        break;
      case 'planMode':
        normalizedValue = RUN_PLAN_MODES.has(String(value || '').trim()) ? String(value).trim() : null;
        break;
      case 'executionMode':
        normalizedValue = RUN_EXECUTION_MODES.has(String(value || '').trim()) ? String(value).trim() : null;
        break;
      case 'lang':
        normalizedValue = RUN_LANGS.has(normalizeRunLang(value, '')) ? normalizeRunLang(value, '') : null;
        break;
      case 'requireApproval':
        normalizedValue = normalizeBooleanString(value);
        break;
      default:
        normalizedValue = null;
    }

    if (normalizedValue === null) {
      await replyFeishu(env, messageId, t(source, 'config_invalid_value', normalizedKey, value));
      return;
    }

    existing[normalizedKey] = normalizedValue;
    await putChatConfig(env, chatId, existing);
    await replyFeishu(env, messageId, t(source, 'config_set_ok', normalizedKey, String(normalizedValue)));
  } catch (err) {
    await replyFeishu(env, messageId, t(source, 'config_error', err.message));
  }
}

async function handleLang(env, source, messageId, chatId, requested) {
  const current = normalizeRunLang(source.RALPH_LANG || 'zh-CN');
  if (!requested) {
    const text = t(source, 'lang_status', current);
    await replyFeishuCard(
      env,
      messageId,
      buildInfoCard({
        title: t(source, 'lang_title'),
        template: 'turquoise',
        sections: [text],
      }),
      text
    );
    return;
  }

  const normalized = normalizeRunLang(requested, '');
  if (!RUN_LANGS.has(normalized)) {
    await replyFeishu(env, messageId, t(source, 'lang_invalid', requested));
    return;
  }

  if (env.RALPH_CONFIG?.get && chatId) {
    try {
      const existing = await getChatConfig(env, chatId);
      existing.lang = normalized;
      await putChatConfig(env, chatId, existing);
      await replyFeishu(env, messageId, t(source, 'lang_set_saved', normalized));
      return;
    } catch (err) {
      await replyFeishu(env, messageId, t(source, 'config_error', err.message));
      return;
    }
  }

  await replyFeishu(env, messageId, t(source, 'lang_set_hint', normalized));
}

// ═══════════════════════════════════════════
// Ralph → Feishu: /notify
// ═══════════════════════════════════════════
async function handleNotify(request, env) {
  if (request.method !== 'POST') {
    return Response.json({ error: 'POST only' }, { status: 405 });
  }

  const auth = request.headers.get('Authorization') || '';
  const token = auth.replace('Bearer ', '');
  if (!env.NOTIFY_SECRET || token !== env.NOTIFY_SECRET) {
    return Response.json({ error: 'unauthorized' }, { status: 401 });
  }

  const body = await request.json();
  const { event, issue_number, run_url, pr_url, backend, error_msg, plan_mode, review_posted } = body;
  const repo = body.repo || env.GITHUB_REPO;
  const issueUrl = `https://github.com/${repo}/issues/${issue_number}`;

  const card = buildNotifyCard(env, event, { issue_number, repo, issueUrl, run_url, pr_url, backend, error_msg, plan_mode, review_posted });

  // Use feishu_chat_id from request (forwarded from dispatch) or fall back to env default
  const chatId = body.feishu_chat_id || env.FEISHU_CHAT_ID;
  if (!chatId) {
    return Response.json({ error: 'FEISHU_CHAT_ID not configured' }, { status: 500 });
  }

  try {
    const tenantToken = await getTenantToken(env);
    if (card) {
      await sendFeishuCard(tenantToken, chatId, card);
    } else {
      await sendFeishuMessage(tenantToken, chatId, t(env, 'notify_fallback', issue_number, event));
    }
    return Response.json({ ok: true });
  } catch (e) {
    console.error('Notify failed:', e);
    return Response.json({ error: e.message }, { status: 500 });
  }
}

function buildNotifyCard(env, event, data) {
  const { issue_number, repo, issueUrl, run_url, pr_url, backend, error_msg, plan_mode, review_posted } = data;
  const defaultRepo = env.GITHUB_REPO;
  const repoValue = `\`${repo || defaultRepo}\``;

  switch (event) {
    case 'starting': {
      const modeText = plan_mode && plan_mode !== 'off'
        ? t(env, 'notify_mode_plan_short')
        : t(env, 'notify_mode_legacy_short');
      return {
        config: { wide_screen_mode: true },
        header: {
          title: { tag: 'plain_text', content: t(env, 'notify_start_title') },
          template: 'blue',
        },
        elements: [
          {
            tag: 'div',
            text: { tag: 'lark_md', content: t(env, 'notify_start_summary') },
          },
          buildFactFields([
            { label: t(env, 'card_issue_label'), value: `[#${issue_number}](${issueUrl})` },
            { label: t(env, 'card_repo_label'), value: repoValue },
            { label: t(env, 'card_backend_label'), value: backend || 'auto' },
            { label: t(env, 'card_mode_label'), value: modeText },
          ]),
          ...(run_url ? [buildActionRow([{ tag: 'button', text: { tag: 'plain_text', content: t(env, 'view_run') }, url: run_url, type: 'primary' }])] : []),
        ],
      };
    }

    case 'plan_posted':
      return {
        config: { wide_screen_mode: true },
        header: {
          title: { tag: 'plain_text', content: t(env, 'notify_plan_title') },
          template: 'orange',
        },
        elements: [
          {
            tag: 'div',
            text: { tag: 'lark_md', content: t(env, 'notify_plan_body', issue_number) },
          },
          buildFactFields([
            { label: t(env, 'card_issue_label'), value: `[#${issue_number}](${issueUrl})` },
            { label: t(env, 'card_repo_label'), value: repoValue },
          ]),
          buildActionRow([
            { tag: 'button', text: { tag: 'plain_text', content: t(env, 'approve_plan_btn') }, url: issueUrl, type: 'primary' },
            { tag: 'button', text: { tag: 'plain_text', content: t(env, 'view_issue') }, url: issueUrl, type: 'default' },
          ]),
          {
            tag: 'note',
            elements: [{ tag: 'plain_text', content: t(env, 'approve_note', issue_number) }],
          },
        ],
      };

    case 'success': {
      const reviewNote = review_posted === 'true' ? t(env, 'review_completed') : '';
      return {
        config: { wide_screen_mode: true },
        header: {
          title: { tag: 'plain_text', content: t(env, 'notify_success_title') },
          template: 'green',
        },
        elements: [
          {
            tag: 'div',
            text: { tag: 'lark_md', content: t(env, 'notify_success_summary') },
          },
          buildFactFields([
            { label: t(env, 'card_issue_label'), value: `[#${issue_number}](${issueUrl})` },
            { label: t(env, 'card_repo_label'), value: repoValue },
            { label: t(env, 'card_pr_label'), value: pr_url ? `[${t(env, 'review_pr')}](${pr_url})` : t(env, 'pr_not_created') },
            { label: t(env, 'card_review_label'), value: review_posted === 'true' ? t(env, 'review_completed_short') : t(env, 'review_pending_short') },
          ]),
          buildActionRow([
            ...(pr_url ? [{ tag: 'button', text: { tag: 'plain_text', content: t(env, 'review_pr') }, url: pr_url, type: 'primary' }] : []),
            ...(run_url ? [{ tag: 'button', text: { tag: 'plain_text', content: t(env, 'view_run') }, url: run_url, type: 'default' }] : []),
          ]),
          ...(reviewNote ? [{
            tag: 'note',
            elements: [{ tag: 'plain_text', content: reviewNote.replace('\n', '').trim() }],
          }] : []),
        ],
      };
    }

    case 'clarification_needed':
      return {
        config: { wide_screen_mode: true },
        header: {
          title: { tag: 'plain_text', content: t(env, 'notify_clarification_title') },
          template: 'orange',
        },
        elements: [
          {
            tag: 'div',
            text: { tag: 'lark_md', content: t(env, 'notify_clarification_body', issue_number) },
          },
          buildFactFields([
            { label: t(env, 'card_issue_label'), value: `[#${issue_number}](${issueUrl})` },
            { label: t(env, 'card_repo_label'), value: repoValue },
          ]),
          buildActionRow([
            { tag: 'button', text: { tag: 'plain_text', content: t(env, 'view_issue') }, url: issueUrl, type: 'primary' },
            ...(run_url ? [{ tag: 'button', text: { tag: 'plain_text', content: t(env, 'view_run') }, url: run_url, type: 'default' }] : []),
          ]),
        ],
      };

    case 'failed':
      return {
        config: { wide_screen_mode: true },
        header: {
          title: { tag: 'plain_text', content: t(env, 'notify_fail_title') },
          template: 'red',
        },
        elements: [
          {
            tag: 'div',
            text: { tag: 'lark_md', content: t(env, 'notify_fail_summary') },
          },
          buildFactFields([
            { label: t(env, 'card_issue_label'), value: `[#${issue_number}](${issueUrl})` },
            { label: t(env, 'card_repo_label'), value: repoValue },
            ...(error_msg ? [{ label: t(env, 'card_reason_label'), value: error_msg, isShort: false }] : []),
          ]),
          {
            tag: 'note',
            elements: [{ tag: 'plain_text', content: t(env, 'fail_tip') }],
          },
          ...(run_url ? [buildActionRow([{ tag: 'button', text: { tag: 'plain_text', content: t(env, 'view_logs') }, url: run_url, type: 'danger' }])] : []),
        ],
      };

    default:
      return null;
  }
}

function buildInfoCard({ title, template = 'blue', sections = [], note = '' }) {
  const elements = [];
  const visibleSections = sections.filter(Boolean);
  visibleSections.forEach((section, index) => {
    elements.push({
      tag: 'div',
      text: { tag: 'lark_md', content: section },
    });
    if (index < visibleSections.length - 1) {
      elements.push({ tag: 'hr' });
    }
  });
  if (note) {
    if (visibleSections.length) {
      elements.push({ tag: 'hr' });
    }
    elements.push({
      tag: 'note',
      elements: [{ tag: 'plain_text', content: note }],
    });
  }
  return {
    config: { wide_screen_mode: true },
    header: {
      title: { tag: 'plain_text', content: title },
      template,
    },
    elements,
  };
}

function buildFactFields(facts = []) {
  return {
    tag: 'div',
    fields: facts
      .filter((fact) => fact?.label && fact?.value)
      .map((fact) => ({
        is_short: fact.isShort !== false,
        text: { tag: 'lark_md', content: `**${fact.label}**\n${fact.value}` },
      })),
  };
}

function buildActionRow(actions = []) {
  return {
    tag: 'action',
    actions,
  };
}

// ═══════════════════════════════════════════
// Feishu API
// ═══════════════════════════════════════════
async function getTenantToken(env) {
  const resp = await fetch(
    'https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal',
    {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        app_id: env.FEISHU_APP_ID,
        app_secret: env.FEISHU_APP_SECRET,
      }),
    }
  );
  const data = await resp.json();
  if (data.code !== 0) throw new Error(`Feishu auth failed: ${data.msg}`);
  return data.tenant_access_token;
}

async function sendFeishuMessage(token, chatId, text) {
  const resp = await fetch(
    'https://open.feishu.cn/open-apis/im/v1/messages?receive_id_type=chat_id',
    {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${token}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        receive_id: chatId,
        content: JSON.stringify({ text }),
        msg_type: 'text',
      }),
    }
  );
  const data = await resp.json();
  if (!resp.ok || data.code !== 0) throw new Error(`Send message failed: ${resp.status} ${data.msg || 'unknown error'}`);
  return data;
}

async function sendFeishuCard(token, chatId, card) {
  const resp = await fetch(
    'https://open.feishu.cn/open-apis/im/v1/messages?receive_id_type=chat_id',
    {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${token}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        receive_id: chatId,
        content: JSON.stringify(card),
        msg_type: 'interactive',
      }),
    }
  );
  const data = await resp.json();
  if (!resp.ok || data.code !== 0) throw new Error(`Send card failed: ${resp.status} ${data.msg || 'unknown error'}`);
  return data;
}

async function replyFeishu(env, messageId, text) {
  try {
    const token = await getTenantToken(env);
    const resp = await fetch(
      `https://open.feishu.cn/open-apis/im/v1/messages/${messageId}/reply`,
      {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${token}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          content: JSON.stringify({ text }),
          msg_type: 'text',
        }),
      }
    );
    const data = await resp.json();
    if (!resp.ok || data.code !== 0) {
      throw new Error(`Reply failed: ${resp.status} ${data.msg || 'unknown error'}`);
    }
  } catch (e) {
    console.error('Reply failed:', e);
  }
}

async function replyFeishuCard(env, messageId, card, fallbackText = '') {
  try {
    const token = await getTenantToken(env);
    const resp = await fetch(
      `https://open.feishu.cn/open-apis/im/v1/messages/${messageId}/reply`,
      {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${token}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          content: JSON.stringify(card),
          msg_type: 'interactive',
        }),
      }
    );
    const data = await resp.json();
    if (!resp.ok || data.code !== 0) {
      throw new Error(`Reply card failed: ${resp.status} ${data.msg || 'unknown error'}`);
    }
  } catch (e) {
    console.error('Reply card failed:', e);
    if (fallbackText) {
      await replyFeishu(env, messageId, fallbackText);
    }
  }
}

async function addReaction(env, messageId, emojiType) {
  try {
    const token = await getTenantToken(env);
    await fetch(
      `https://open.feishu.cn/open-apis/im/v1/messages/${messageId}/reactions`,
      {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${token}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          reaction_type: { emoji_type: emojiType },
        }),
      }
    );
  } catch (e) {
    console.error('Add reaction failed:', e);
  }
}
