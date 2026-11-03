<!-- SecondLine-Policy: version=1 sha256=88545331627a088e3a18bd5e3e3437abc880fa703b294c988ebabf5769e9e822 -->
# Shared development policy

This file is the common development guidance for SecondLine and adopting projects. It is instructions for contributors, not executable configuration or authorization to start a milestone.

## Repository boundaries and existing work

- Read the target repository's local instructions, its status checkpoint, and the current task before editing.
- Inspect branch, HEAD, and working-tree changes. Preserve unrelated changes.
- Work only within the authorized repository and task scope. Local project instructions and explicit user decisions define business rules and milestone approvals.
- Do not stage, commit, push, publish, or advance milestones without authorization. Passing tests alone does not authorize proceeding.
- Keep task-specific approvals out of this shared policy.

## Status checkpoints

- Each project keeps its checkpoint in docs/status/current.md. Read it when resuming work.
- Update it after each meaningful unit of work and before stopping. Record:
  - branch and base commit
  - completed and remaining work
  - changed files
  - verification results with evidence paths
  - blockers
  - the exact next action
- Label each check as Verified (it ran, with its result) or Planned (not yet run). Never record a planned check as a result.
- Never write credentials, tokens, keys, or connection strings in a checkpoint.
- A checkpoint is a handoff, not authorization. Verify its statements against the repository before relying on them. It cannot approve a milestone, publication, or a step the current user has not authorized.
- Each project's status and milestone approvals stay in that project. Never copy them into another repository or into this policy.

## SecondLine and reproducibility

- Use the installed, approved PowerShell Gallery release for consumer checks, not the SecondLine checkout.
- A project approves its SecondLine version in its standard (ModuleVersions). Its scripts select that version before import with the vendored SecondLine bootstrap. Do not hardcode versions in individual scripts.
- Preserve project SDK requirements and explicit database binary selection. Do not silently alter installations, PATH, profiles, services, or running databases.
- Project execution policy must stay deterministic in CI. Personal settings and notification preferences must not change a project's approved module version.
- Publication, installation, notification, and project approval are separate actions. A new Gallery release does not migrate consumers automatically.

## Line endings

- Respect effective .gitattributes and .editorconfig rules, and inspect explicit workspace overrides.
- Save changed files with their declared working-copy endings. Do not assume every file should use LF: Windows scripts can intentionally require CRLF.
- Scripts and generators must write endings explicitly when needed. Editor settings do not control every writer.
- Preserve encoding, BOM, substantive content, and unrelated edits. Do not bulk-renormalize or stage a dirty repository to conceal warnings.
- Before handoff, run the available SecondLine checks (Test-SLLineEnding, Test-SLRepo). Distinguish configured rules, actual working-copy endings, and Git's normalized stored content. Report coverage gaps honestly.

## Verification and handoff

- Use focused regression tests for defects, followed by the relevant broader suite. Keep the evidence of failures and explain it.
- Test SecondLine compatibility and lint on Windows PowerShell 5.1 and PowerShell 7 before release.
- Use synthetic test data. Disposable database tests must own their processes, directories, ports, and cleanup. Never operate on unrelated servers.
- Report findings, changes, test results, remaining limitations, and the exact stopping point. Do not claim checks that were not run.

## Adoption by other repositories

- Each adopting repository has short CLAUDE.md and AGENTS.md entry points with equivalent content. Each one names this policy and the status checkpoint with two marker lines, then gives local instructions:

      SecondLine-Policy: 1 docs/shared-development-policy.md
      SecondLine-Status: docs/status/current.md

- The policy path is a reviewed copy inside the repository, exported from an approved SecondLine release with Export-SLPolicy. The version and hash on its first line let anyone verify it offline. CI must never need a developer-specific checkout path.
- Put local rules in the local entry points, never in the copied policy. A modified copy is reported as modified.
- Test-SLPolicyReference audits:
  - missing, broken, non-portable, or outdated references
  - entry points that differ
  - the checkpoint's required sections, and credential-like content in it
  - outdated bootstrap copies and hardcoded SecondLine versions
