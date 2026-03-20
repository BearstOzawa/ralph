# Feishu Integration

A Feishu (Lark) app + a Cloudflare Worker for bidirectional Feishu ↔ Ralph communication.

## Architecture

```
Feishu (Group / Private)   CF Worker (custom domain)         GitHub
┌─────────┐  @bot /ralph  ┌──────────────────┐  create    ┌──────────┐
│  User    │─────────────▶│  POST /          │──issue──▶│  Ralph   │
│          │  👍 received  │  (Feishu callback)│          │ Workflow │
│          │  ✅ created   │                  │          │          │
│          │◀─────────────│  POST /notify     │◀─notify──│          │
└─────────┘  status notify└──────────────────┘          └──────────┘
```

**Single Feishu app** handles both directions:
- **Feishu → Ralph**: User sends command (group @bot or private chat) → Worker creates GitHub Issue
- **Ralph → Feishu**: GitHub Actions calls Worker `/notify` → notifications sent back to the **same chat** where the command originated (group or private). Non-Feishu triggers (Webhook, manual dispatch) fall back to `FEISHU_CHAT_ID`.

The Worker also acts as the routing layer for:
- hidden `ralph-meta` issue metadata
- cross-repo approval resolution
- duplicate task suppression for similar open issues

## Supported Commands

| Command | Description |
|---------|-------------|
| `/ralph <description>` | Create Issue in default repo and trigger Ralph |
| `/ralph owner/repo <task>` | Create Issue in specified repo and trigger |
| `/create owner/repo <task>` | Create new repo and implement task |
| `--approve` | Add to `/ralph` or `/create` to require plan approval |
| `/approve <issue#>` | Approve execution plan for specified Issue |
| `/approve owner/repo <issue#>` | Approve a plan in a specific repo |
| `/reject <issue#>` | Reject execution plan |
| `/reject owner/repo <issue#>` | Reject a plan in a specific repo |
| `/run <issue#>` | Manually dispatch an existing Issue |
| `/continue <issue#>` | Continue an existing Issue |
| `/retry <issue#>` | Retry an existing Issue |
| `/plan <issue#>` | Generate/refresh the plan only, then wait for approval |
| `/review <issue#>` | Re-run PR/formal review without coding iterations |
| `/logs <issue#>` | Get the latest workflow run link from Issue comments |
| `/cancel <issue#>` | Post `/reject` to stop approval waiting |
| `/config` | Show current default dispatch config |
| `/config set <key> <value>` | Persist chat defaults when KV is enabled |
| `/lang` | Show current UI language and supported values |
| `/status` | View in-progress Issues |
| `/chatid` | Get current chat_id |
| `/help` | Show help |

Supported per-command flags for `/ralph`, `/create`, `/run`, `/continue`, `/retry`:
- `--approve`
- `--backend auto|opencode|llm`
- `--max-iterations 5|10|15|20`
- `--plan-mode auto|always|off`
- `--execution-mode single|multi`
- `--lang zh-CN|en-US`

### Examples

```
/ralph Implement a simple calculator in Python

/ralph Refactor user module
Split user.py into model and service
Keep existing tests passing

/ralph
Goal: redesign the homepage
Requirements: modern style, responsive layout, include hero and gallery
Constraints: keep current stack, do not change CI
Acceptance: mobile works, no console errors

/ralph myorg/api Add user registration endpoint

/ralph --approve Refactor the entire auth module

/create myorg/calculator Build a CLI calculator in Go

/approve 42

/approve myorg/api 42

/run 42 --backend opencode --max-iterations 10

/retry myorg/api 42 --plan-mode always --execution-mode multi

/plan myorg/api 42 --lang zh-CN

/review 42

/logs 42

/ralph myorg/api Add rate limiting middleware --approve --lang en-US

/config set backend opencode

/config set lang en-US
```

### Interaction Flow (Standard Task)

1. User sends `@Ralph /ralph Implement a calculator` in Feishu group (or private chat)
2. Bot adds 👍 reaction (received)
3. Worker creates GitHub Issue + triggers Ralph workflow
4. Bot adds ✅ reaction (Issue created)
5. Bot replies with Issue link
6. Ralph analyzes task, posts execution plan on Issue
7. [Optional] User sends `@Ralph /approve 10` or `@Ralph /approve owner/repo 10`
8. Ralph executes one runnable subtask per workflow run and keeps updating the same draft PR
9. Ralph completes or blocks, notification sent back to the same chat

### Interaction Flow (Create New Repo)

1. User sends `@Ralph /create myorg/new-app Build a TODO app with React`
2. Ralph creates repo `myorg/new-app`
3. Implements code in the repo, creates PR
4. Notification sent back to the same chat

### Task Routing and Deduplication

- Feishu-created issues include hidden `ralph-meta` JSON in the issue body.
- Approval resolution prefers hidden metadata over free-text issue parsing.
- The Worker checks for a similar open issue with the same normalized title before creating a new one.
- `/create` tasks route approval through the central tracking issue even when code runs in another repo.

### Notification Types

Ralph pushes notifications back to the originating chat (group or private). For non-Feishu triggers, notifications go to `FEISHU_CHAT_ID`:

| Event | Content |
|-------|---------|
| `starting` | Ralph started working, shows backend and repo info |
| `plan_posted` | Execution plan posted, awaiting approval |
| `success` | Current orchestration finished, with PR link |
| `failed` | Failed, with log link |

Notes:
- A `success` notification may still point to a **draft PR** if validation is only `partial`.
- In orchestrated mode, Ralph may auto-dispatch follow-up workflow runs before the final completion state.

---

## Deployment Steps (~15 minutes)

### Step 1: Create Feishu App

1. Go to [Feishu Open Platform](https://open.feishu.cn/app) → Create enterprise app
2. App capabilities → Enable "Bot"
3. Permissions → Add:
   - `im:message` — Read messages
   - `im:message:send_as_bot` — Send messages as bot
   - `im:message.receive_v1` — Receive message events
   - `im:message.reaction:write` — Add emoji reactions (for read status)
4. Note down **App ID**, **App Secret**, **Verification Token**
5. Skip event subscription config for now (wait for Worker deployment)

### Step 2: Deploy Cloudflare Worker

`feishu/worker.js` now imports locale modules from `feishu/locales/`, so it is a **multi-file module Worker**.
Do not paste only `worker.js` into the Cloudflare dashboard editor, or deployment will fail with module resolution errors.

Recommended deployment:

1. Install Wrangler locally:

```bash
npm install -g wrangler
```

2. From the `feishu/` directory, log in and deploy:

```bash
cd feishu
wrangler login
wrangler deploy
```

3. In Cloudflare Dashboard or via `wrangler secret put`, add:

| Variable | Value | Description |
|----------|-------|-------------|
| `FEISHU_APP_ID` | `cli_xxx` | Feishu app App ID |
| `FEISHU_APP_SECRET` | `xxx` | Feishu app App Secret |
| `FEISHU_VERIFICATION_TOKEN` | `xxx` | Feishu event subscription Verification Token |
| `FEISHU_CHAT_ID` | Leave empty, get in step 5 | Default Feishu chat_id (fallback for non-Feishu triggers) |
| `GITHUB_TOKEN` | `ghp_xxx` | GitHub PAT (needs repo scope, including repo creation) |
| `GITHUB_REPO` | (required) | Default target repo (owner/repo) |
| `NOTIFY_SECRET` | Random string | Protects /notify endpoint |
| `RALPH_API_KEY` | (optional) | LLM API key for title summarization |
| `RALPH_API_BASE_URL` | (optional) | LLM API base URL |
| `RALPH_API_MODEL` | (optional) | LLM model name |

Worker note:
- These `RALPH_API_*` values are the only model runtime config used by the GitHub workflow.
- Set Worker `RALPH_LANG` and GitHub Actions Variable `RALPH_LANG` to the same value if you want consistent defaults for both Feishu and non-Feishu triggers.

4. Copy the template and keep your real deployment config local only:

```bash
cp wrangler.example.toml wrangler.toml
```

Do not commit your real `wrangler.toml`. It usually contains environment-specific worker names, routes, repos, and language defaults.

Optional persistent chat defaults:

- Create a Cloudflare KV namespace, for example `ralph-config`
- Bind it to the Worker as `RALPH_CONFIG`
- Then `/config set ...` and `/lang <locale>` will persist per chat

5. Workers → Settings → Triggers → Custom Domains → Bind custom domain
   - Domain must be added to Cloudflare first (NS pointing to Cloudflare)
   - Example: `ralph.yourdomain.com`

> ⚠️ `.workers.dev` domains are blocked in China. **Must use a custom domain**.

If you insist on using the Cloudflare dashboard UI, import the whole `feishu/` folder as a Worker project instead of pasting a single file.

### Step 3: Configure Feishu Event Subscription

1. Feishu Open Platform → Your app → Events & Callbacks → Event config
2. Request URL: `https://ralph.yourdomain.com/`
3. Save (Feishu sends verification request, Worker auto-passes)
4. Add event: `im.message.receive_v1`
5. Version management → Create version → Publish → **Admin approval**

### Step 4: Configure GitHub Secrets

Repo Settings → Secrets and variables → Actions:

| Secret | Value |
|--------|-------|
| `FEISHU_NOTIFY_URL` | `https://ralph.yourdomain.com/notify` |
| `FEISHU_NOTIFY_SECRET` | Same as Worker's `NOTIFY_SECRET` |

### Step 5: Get chat_id

1. Add bot to target Feishu group (Group settings → Group bots → Add)
2. Send in group or private chat: `/chatid`
3. Bot replies with `oc_xxx`
4. Set `oc_xxx` as Worker env variable `FEISHU_CHAT_ID`

### Done!

Send `@Ralph /help` in the group to verify everything works.

## Runtime Notes

- Long OpenCode runs now emit heartbeat lines in GitHub Actions logs roughly every 30 seconds.
- Those heartbeat lines now include the latest OpenCode log hint when available.
- Live OpenCode output is written to `.ralph/opencode-run.log` during execution.
- In `plan_mode=auto`, simple or low-context issues skip the heavier plan-and-execute path and clamp retries more aggressively.
- Extremely low-context issues now stop before coding and ask for clarification instead of guessing from a short prompt.
- When someone says the job is stuck, the fastest check is `/logs [issue#]` in Feishu, then inspect the current Actions run.
- Language priority is: workflow input `lang` → issue metadata `ralph-meta.lang` → GitHub variable `RALPH_LANG`.

---

## Security Notes

- GitHub PAT: use Fine-grained Token with only target repo Issues write access
  - For repo creation feature, use Classic Token with `repo` scope
- `/notify` endpoint protected by Bearer Token, only GitHub Actions with the secret can call it
- Feishu App Secret stored in Worker env vars (Cloudflare encrypted storage)
- Event callbacks verified with Verification Token to prevent forgery
- Event dedup mechanism prevents duplicate message processing

---

## Alternatives

<details>
<summary>Bitable Automation (no CF Worker needed)</summary>

Use Feishu Bitable automation instead of deploying a Worker:
- Add a row in Bitable → Automation triggers → HTTP POST GitHub API to create Issue
- Only supports Feishu→Ralph direction; Ralph→Feishu notifications need separate webhook bot
- See earlier versions of this project for documentation

</details>

<details>
<summary>WebSocket Long Connection (requires persistent process)</summary>

If you have a server or want to run locally on Mac, use `bridge.py`:
- Uses Feishu WebSocket SDK for outbound connection, no public URL needed
- Process must stay alive
- See `bridge.py` and `requirements.txt`

</details>
