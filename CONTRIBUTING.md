# Contributing to Ralph

Thanks for contributing to Ralph.

## Before You Start

- Open an Issue first for large changes, architecture changes, or behavior changes.
- Keep changes scoped. Small, reviewable pull requests are preferred.
- Preserve Ralph's core contract: issue-driven execution, plan-first orchestration, validator-gated completion, and GitHub as the source of truth.

## Development Setup

1. Fork the repository and create a branch from `main`.
2. Read [README.md](./README.md) and [README_CN.md](./README_CN.md) for project context.
3. Copy examples as needed:
   - `config.example.yml`
   - `feishu/wrangler.example.toml`
4. Provide your own secrets and local environment values. Do not commit credentials or personal deployment settings.

## Pull Request Guidelines

- Make one logical change per pull request.
- Explain the problem, the approach, and any tradeoffs.
- Update docs when behavior, commands, or configuration changes.
- Keep user-facing language consistent across English and Chinese where applicable.
- Do not introduce hardcoded personal identifiers, private domains, or user-specific defaults.

## Code Style

- Prefer simple shell and workflow logic over clever indirection.
- Keep state transitions explicit.
- Fail clearly and report actionable status.
- Preserve backward compatibility only when it improves operator experience and does not complicate the core flow excessively.

## Validation

Before opening a pull request, verify at least the following when relevant:

- Workflow syntax is valid.
- Shell scripts remain executable where required.
- Localization keys stay in sync.
- Documentation matches runtime behavior.

## Security

If you find a security issue, do not open a public issue first. Follow the instructions in [SECURITY.md](./SECURITY.md).
