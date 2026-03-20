# Spec: Issue #{{ISSUE_NUMBER}}

## Objective
{{ISSUE_TITLE}}

## Requirements
{{ISSUE_BODY}}

## Acceptance Criteria
- All existing tests must pass: `{{TEST_COMMAND}}`
- No modifications to test files
- Code must compile/build without errors
- Changes must be minimal and focused on the issue

## Constraints
- Do NOT modify any test files matching: *_test.* *_spec.* test_*.* *.test.*
- Do NOT change CI/CD configuration
- Do NOT add unnecessary dependencies
- Do NOT refactor code unrelated to this issue
- Keep changes minimal and focused

## Context Files
<!-- Ralph will auto-discover relevant files -->

## Verification
Run `{{TEST_COMMAND}}` — all tests must pass.
