# Pi CodeCompanion and MiniDiff Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace pi.nvim's terminal and two-pane review UI with CodeCompanion, codecompanion-ui, pi-acp, and mini.diff while preserving private Git-tree acceptance semantics.

**Architecture:** Pi chats run through CodeCompanion ACP and pi-acp. pi.nvim supplies a Pi adapter, synchronous checkpoint callbacks, project association, and a MiniDiff source backed by `accepted_tree`.

**Tech Stack:** Lua, Neovim 0.10+, CodeCompanion.nvim, codecompanion-ui.nvim, pi-acp, mini.diff, Git.

**Spec:** `docs/superpowers/specs/2026-09-03-pi-codecompanion-minidiff-design.md`

## Global Constraints

- Do not implement or vendor RPC, ACP, chat, composer, model-picker, or diff UI replacements.
- Keep all pi.nvim source in Lua and never touch the user's real Git index.
- Use documented dependency APIs except for isolated, feature-detected
  CodeCompanion picker and codecompanion-ui draft compatibility shims, covered
  by contract tests until public callable exports exist.
- Run `make test` after every task and `make smoke` at every milestone.
- Stop for review after each of the three milestones.

---

### Task 1: Protect and project-scope checkpoints

**Files:** Modify `lua/pi/checkpoint.lua`, `tests/checkpoint_spec.lua`, `tests/git_spec.lua`; create `LICENSE`, `THIRD_PARTY.md`.

**Interfaces:** Preserve existing calls; add optional cwd to `state`, `view`, acceptance, rejection, status, and cleanup operations.

- [ ] Add failing regressions for two independent roots, repeated turns, new/deleted files, all acceptance directions, and byte-identical real-index state.
- [ ] Run `make test` and confirm the new cases fail.
- [ ] Replace singleton checkpoint state with normalized root-keyed state while retaining active-root compatibility.
- [ ] Add MIT and third-party notices, then run `make test`.
- [ ] Commit as `test: protect project checkpoint semantics`.

### Task 2: Add the Pi ACP bridge and lifecycle

**Files:** Create `lua/pi/codecompanion.lua`, `lua/pi/lifecycle.lua`, `tests/codecompanion_spec.lua`, `tests/lifecycle_spec.lua`; modify `tests/run.lua`.

**Interfaces:** Produce `codecompanion.adapter()`, project-chat create/restore/prompt/abort/model/thinking operations, plus `lifecycle.setup()` and idempotent `lifecycle.attach(chat, cwd)`.

- [ ] Add failing tests for the ACP adapter, Pi-only callback filtering, chat reuse, save-before-checkpoint ordering, cancellation, cwd restoration, completion reload, and draft recovery.
- [ ] Run `make test` and confirm failures.
- [ ] Implement the minimal adapter/facade and synchronous `on_before_submit` lifecycle, delegating all ACP and agent behavior to CodeCompanion.
- [ ] Run `make test && make smoke`.
- [ ] Commit as `feat: bridge Pi through CodeCompanion ACP` and stop for milestone 1 review.

### Task 3: Route the public frontend through CodeCompanion UI

**Files:** Modify `lua/pi/init.lua`, `lua/pi/config.lua`, `plugin/pi.lua`, `tests/init_spec.lua`, `tests/config_spec.lua`, `tests/commands_spec.lua`; create `tests/codecompanion_ui_spec.lua`.

**Interfaces:** Preserve `toggle`, `ask`, `prompt`, `select`, `abort`, and keymaps; add `focus`, `model`, `thinking`, and `stop`.

- [ ] Add failing tests for toggle/focus reuse, source-context capture, legacy-token translation, direct prompts, delegated controls, fallback opt-in, and command completion.
- [ ] Run `make test` and confirm failures.
- [ ] Rewire the facade to CodeCompanion/codecompanion-ui and add one-release terminal/context compatibility options and warnings.
- [ ] Run `make test && make smoke`.
- [ ] Commit as `refactor: use CodeCompanion native chat UI` and stop for milestone 2 review.

### Task 4: Implement the accepted-tree MiniDiff source

**Files:** Create `lua/pi/review/patch.lua`, `lua/pi/review/minidiff.lua`, `tests/review_patch_spec.lua`, `tests/review_minidiff_spec.lua`; modify `tests/run.lua`.

**Interfaces:** Produce pure hunk splicing/serialization helpers and MiniDiff `attach`, `detach`, `refresh`, `accept_hunk`, `reject_hunk`, and navigation operations.

- [ ] Add failing tests for every MiniDiff hunk shape, empty files, final-newline handling, repeated/multiple acceptance, source configuration restoration, and accept-all refresh.
- [ ] Run `make test` and confirm failures.
- [ ] Implement line splicing from MiniDiff hunk coordinates and a per-buffer source using checkpoint reference text.
- [ ] Run `make test`.
- [ ] Commit as `feat: add accepted-tree MiniDiff source`.

### Task 5: Replace the two-pane reviewer

**Files:** Rewrite `lua/pi/review.lua`, `tests/review_spec.lua`; modify `lua/pi/init.lua`, `lua/pi/config.lua`, `plugin/pi.lua`, `tests/commands_spec.lua`.

**Interfaces:** Preserve `review.open`, `close`, `accept`, `reject`, and `current`; pending scope is mutable and turn/session scopes are audits.

- [ ] Add failing tests for real-buffer opening, picker cancellation, buffer-local mappings, hunk/file/all actions, read-only scopes, reject confirmation, and unsupported files.
- [ ] Run `make test` and confirm failures.
- [ ] Replace tab diffs with the MiniDiff integration and file-level fallbacks.
- [ ] Run `make test`.
- [ ] Commit as `refactor: review Pi changes with mini.diff`.

### Task 6: Verify the stack and remove legacy code

**Files:** Delete `lua/pi/terminal.lua`, `lua/pi/context.lua`, `tests/terminal_spec.lua`; modify `lua/pi/health.lua`, `lua/pi/config.lua`, `lua/pi/init.lua`, `plugin/pi.lua`, `README.md`, `doc/pi.txt`, `Makefile`, `tests/run.lua`, `tests/smoke.lua`; create `tests/integration_spec.lua` and a guarded real-stack integration target.

**Interfaces:** Finalize the command/configuration surface in the design spec; terminal fallback and legacy context parsing no longer exist.

- [ ] Add controlled dependency integration tests and guarded pi-acp/Pi checks covering cwd, prompt, abort, model configuration, and process reuse.
- [ ] Run the integration checks before deleting legacy modules.
- [ ] Remove terminal/context code, finish health checks and migration documentation, and update smoke coverage.
- [ ] Run `make test && make smoke` from a clean worktree and verify the real Git index is unchanged.
- [ ] Commit as `refactor: complete CodeCompanion and MiniDiff migration` and stop for milestone 3 review.
