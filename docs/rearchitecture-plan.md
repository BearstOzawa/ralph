# Ralph Re-architecture Plan

## Problem Statement

Current Ralph behavior is biased toward producing any code artifact and treating it as completion. The workflow can mark an issue as done even when the generated change is only a placeholder, lacks build validation, or does not close the issue lifecycle cleanly.

Observed failure modes:

- Success is inferred from branch commits rather than a strong validator result.
- Issues can remain open after `ai/done`, so state is not trustworthy.
- Similar Feishu requests can create duplicate active issues.
- Cross-repo execution depends on central orchestration, but approval and runtime assets are not consistently routed.
- PR creation is not coupled to an explicit validation report.

## Target Operating Model

Ralph should behave as an orchestrated engineering system, not a single long-running prompt loop.

### State Machine

Each task should move through the following states:

1. `queued`
2. `planning`
3. `awaiting_approval`
4. `executing`
5. `validating`
6. `draft_pr_open`
7. `awaiting_review`
8. `done`
9. `blocked`
10. `failed`

Rules:

- `done` is only reachable after validator pass.
- `draft_pr_open` is not completion.
- `failed` must preserve logs and branch context when available.
- Only one active task may exist per issue.

### Source of Truth

- GitHub Issue / PR is the source of truth for task state.
- Feishu is an ingress and notification surface only.
- Validation artifacts must be written to `.ralph/validation-result.json`.
- Feishu-created issues should persist hidden `ralph-meta` JSON in the issue body for routing and task metadata.

## Immediate Phase 1 Changes

### 1. Validation Gate

Introduce a standalone validator script that:

- detects project type
- runs build/test/lint/acceptance checks when available
- emits a JSON report
- fails the workflow on hard validation failure

This is implemented by `scripts/validator.sh`.

### 2. Success Criteria

Workflow success must require:

- `ralph.sh` exits successfully
- `scripts/validator.sh` returns pass or partial
- PR body includes a validation summary

Issue closure must only happen when validation result is `pass`.

If validation result is `partial`:

- create a Draft PR
- keep the issue open
- do not mark the issue as completed

### 3. Runtime Asset Consistency

Cross-repo runs must copy both:

- `ralph.sh`
- `scripts/validator.sh`

Setup installation must copy the validator into downstream repositories.

### 4. Deduplication at Ingress

Feishu-triggered tasks must check for an existing similar open issue before creating a new one.

Current minimal rule:

- same repository
- same normalized title
- open issue only

If a similar issue exists, Ralph should reuse it instead of creating another task.

## Next Phase 2 Changes

### Planner / Executor Split

Refactor `ralph.sh` so that:

- planner only creates subtasks and acceptance criteria
- executor runs one subtask per fresh loop
- partial success no longer upgrades to workflow success automatically

Current progress:

- planning functions have been extracted into `scripts/lib/planning.sh`
- issue reporting / progress functions have been extracted into `scripts/lib/reporting.sh`
- ReAct execution functions have been extracted into `scripts/lib/execution.sh`
- the duplicated legacy planning / reporting / execution bodies have been removed from `ralph.sh`
- the module split is now the active runtime path rather than a transitional copy
- subtask runtime state is now persisted under `.ralph/subtasks/*.json`
- execution now selects the next runnable subtask from persisted state instead of blindly restarting from the first subtask
- execution status is emitted to `.ralph/execution-result.json`
- default plan execution mode is now one runnable subtask per workflow run, followed by automatic workflow redispatch when more subtasks remain
- progress comments are now idempotent and rendered from persisted `.ralph/subtasks/*.json` state
- `ralph.sh` now acts more clearly as the orchestrator shell

### Draft PR First

Change PR behavior to:

- create or update a draft PR as soon as executable work starts
- push incremental commits to that draft PR across multiple workflow runs
- move to ready-for-review only after validator pass on the final execution state

## Next Phase 3 Changes

### Idempotency and Deduplication

Add task locking and duplication prevention:

- detect existing active issue before creating a new one from Feishu
- detect active branch / PR before dispatching another run
- attach a `task_id` to issue comments or labels for run ownership

Current minimal lock:

- GitHub Actions `concurrency` by `repo + issue_number`

### Approval Routing

Cross-repo approval must resolve against the real issue repository, not the target code repo by assumption.

Immediate compatibility rules:

- `/approve <issue#>` targets the central issue repo by default
- `/approve owner/repo <issue#>` explicitly targets another repository
- `/create` tasks remain approved through their central tracking issue
- approval and notification routing should prefer hidden issue metadata over free-text body parsing

## Implementation Order

1. Keep validator as the only merge-quality gate.
2. Remove commit-count based success fallback in `ralph.sh`.
3. Introduce draft PR state.
4. Add issue deduplication and active task locks.
5. Split `ralph.sh` into planner, executor, and reporter modules.

## Exit Criteria

Phase 1 is complete when:

- invalid code can no longer reach `ai/done`
- successful runs close the issue
- PR body contains validation results
- cross-repo runs can access the validator
