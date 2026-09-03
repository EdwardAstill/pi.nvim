# Pi CodeCompanion and MiniDiff Integration Design

Date: 2026-09-03

## Goal

Refactor `EdwardAstill/pi.nvim` into a small Pi-specific integration layer built
on the following runtime stack:

```text
CodeCompanion UI
  -> Agent Client Protocol (ACP)
  -> pi-acp
  -> pi --mode rpc

pi.nvim
  -> project and chat association
  -> checkpoint lifecycle
  -> accepted-tree review source
  -> mini.diff
```

CodeCompanion owns chat buffers, streaming, tool-call display, sessions, model
and thinking controls, and editor context. `codecompanion-ui.nvim` owns the
separate native composer. `pi-acp` owns ACP-to-Pi-RPC translation. `mini.diff`
owns diff calculation, hunk metadata and navigation, and inline/overlay
rendering.

`pi.nvim` retains only Pi-specific integration and the private Git-tree
checkpoint semantics that distinguish pending, turn, and session changes.

## Success criteria

- Pi runs through `CodeCompanion -> ACP -> pi-acp -> pi --mode rpc`.
- `:Pi` provides a small facade over the project-associated Pi chat and review.
- Hiding the CodeCompanion UI does not stop its Pi ACP session.
- Before every user prompt reaches Pi, modified project buffers are saved and
  `turn_base_tree` is captured synchronously.
- A save or checkpoint failure cancels the CodeCompanion submission.
- CodeCompanion editor context is canonical; the old `pi.context` resolver is
  removed after a temporary compatibility period.
- Pending review uses `accepted_tree`; turn and session reviews use
  `turn_base_tree` and `session_start_tree` and cannot mutate `accepted_tree`.
- MiniDiff renders and calculates all text hunks. `pi.nvim` only applies the
  hunk coordinates supplied by MiniDiff to its accepted baseline.
- File and all-file acceptance preserve the working tree. Rejection preserves
  `accepted_tree`.
- The user's real Git index is never read or written by checkpoint operations.
- The terminal frontend remains an explicit migration fallback until the new
  stack passes integration tests, then is deleted.
- Neovim 0.10 remains the minimum supported version.

## Non-goals

This refactor will not implement:

- a Lua Pi RPC client or JSONL decoder;
- a custom ACP implementation;
- a custom chat renderer or composer;
- a custom model or thinking-level picker;
- a custom diff algorithm or diff UI;
- CodeCompanion, codecompanion-ui, pi-acp, or mini.diff vendoring;
- `@file` completion or a second context system;
- Git commits, branches, or writes to the user's real index as part of review.

## Dependencies and compatibility boundary

The supported integration targets the public APIs present in:

- `olimorris/codecompanion.nvim`, including ACP adapters, per-chat callbacks,
  `on_before_submit`, public chat lookup/restore functions, and ACP session
  configuration controls;
- `mrjones2014/codecompanion-ui.nvim`, including the `ui` extension and its
  separate `codecompanion_input` buffer;
- `svkozak/pi-acp` 0.0.33 or newer, launched as a configurable executable and
  responsible for starting `pi --mode rpc`;
- a current `nvim-mini/mini.diff` with empty-reference support in
  `MiniDiff.set_ref_text()`.

The README will recommend Node.js 22 or newer and Pi 0.80.4 or newer, matching
the current pi-acp documentation. Runtime health checks use capability
detection where projects do not expose a stable Lua version API.

Users install and configure the dependencies explicitly. `pi.nvim` supplies an
ACP adapter factory and a documented CodeCompanion configuration snippet. It
does not mutate a previously initialized CodeCompanion configuration.

## Project and session model

Each Pi CodeCompanion chat is associated with one immutable normalized project
root when the chat is created. `pi.nvim` tracks one preferred Pi chat buffer per
project root. A hidden valid buffer is restored; an invalid or closed buffer is
replaced. Other CodeCompanion chats and adapters are not affected.

Checkpoint state changes from a single `current` value into a map keyed by
normalized project root. Existing no-cwd calls continue to target the active
project for one compatibility release. Lifecycle and review code pass the cwd
explicitly so simultaneous project chats cannot change one another's trees.

The checkpoint state for each root remains:

```lua
{
  cwd = string,
  git_root = string,
  git = Git,
  available = boolean,
  session_start_tree = string,
  accepted_tree = string,
  turn_base_tree = string | nil,
  turn_number = integer,
}
```

Cleanup accepts an optional root and can clean all roots during `VimLeavePre`.
Every `Git` instance continues to use its own temporary index.

## Components

### `lua/pi/codecompanion.lua`

This module is the facade over CodeCompanion. It:

- exposes the `pi-acp` ACP adapter factory;
- creates, remembers, restores, hides, focuses, and closes Pi chats by root;
- captures CodeCompanion buffer context before changing windows;
- sends direct prompts through the project chat;
- delegates stop, model, thinking, and session actions to CodeCompanion;
- accesses codecompanion-ui only for its published extension exports where
  possible;
- isolates any required codecompanion-ui draft compatibility code behind small
  feature-detected functions.

The adapter command defaults to `{ "pi-acp" }` and is configurable. It uses
CodeCompanion's ACP helper to form messages and otherwise follows the standard
custom ACP adapter contract.

### `lua/pi/lifecycle.lua`

This module installs and removes integration hooks. It attaches only to chats
whose resolved adapter name is `pi`. Attachment is idempotent.

It stores the chat's project root, installs the synchronous pre-submit callback,
and handles request completion, cancellation, closure, and UI restoration.
Callbacks created through `:Pi` are passed directly when the chat is created.
A `CodeCompanionChatCreated` hook also attaches to Pi chats created through
CodeCompanion itself.

### `lua/pi/checkpoint.lua`

The checkpoint module retains its tree semantics and gains root-keyed state.
The following calls accept an optional explicit cwd while remaining compatible
with their current forms:

- `state(cwd)`
- `ensure(cwd)`
- `start_turn(cwd)`
- `view(scope, cwd)`
- `accept_file(path, cwd)`
- `accept_text(path, data, cwd)`
- `accept_all(cwd)`
- `reject_file(path, cwd)`
- `status(cwd)`
- `cleanup(cwd)`

### `lua/pi/review.lua`

The public review facade keeps:

```lua
review.open(scope)
review.close()
review.accept(target)
review.reject(target)
review.current()
```

It obtains a checkpoint view, shows a changed-file picker, opens supported real
files in the normal editing area, and delegates attachment and actions to the
MiniDiff integration. It keeps enough current-file state for file-level actions
on deleted, binary, symlink, and unsupported paths.

### `lua/pi/review/minidiff.lua`

This module owns the temporary Pi MiniDiff source. For each attached buffer it:

- records the project root, relative path, review scope, and base tree;
- reads reference data through `checkpoint.state(root).git:read_file()`;
- treats a path absent from the base tree as an empty reference;
- supplies reference text with `MiniDiff.set_ref_text()`;
- obtains hunks through `MiniDiff.get_buf_data()` and invokes documented
  navigation/reset APIs;
- advances `accepted_tree` from its source `apply_hunks` callback in mutable
  pending review;
- leaves turn and session sources without Pi accept/reject mappings;
- tracks attached buffers so accept-all can refresh each one.

Before attachment it records the exact buffer-local `vim.b.minidiff_config`
value and whether MiniDiff was enabled. It disables MiniDiff only for that
buffer, installs the Pi source, and re-enables it. Closing review reverses those
steps and restores the previous source when it was active. Global MiniDiff
configuration is never replaced.

### `lua/pi/review/patch.lua`

This is not a diff implementation. It contains pure line-splicing and
serialization helpers that consume MiniDiff's hunk fields:

```lua
patch.apply_hunks(reference_lines, buffer_lines, hunks)
patch.lines_to_data(lines, endofline)
patch.data_to_lines(data)
```

Multiple hunks are applied from bottom to top so earlier coordinates remain
valid. MiniDiff remains the only component that decides where hunks are.

## Submission lifecycle

The user-prompt path is:

```text
codecompanion-ui submit
  -> CodeCompanion on_before_submit
  -> resolve the root stored on this Pi chat
  -> save modified normal buffers inside that root
  -> checkpoint.start_turn(root)
  -> cancel on failure, otherwise continue
  -> CodeCompanion ACP client
  -> pi-acp
  -> pi --mode rpc
```

The pre-submit callback is synchronous. It returns `false` if saving or
checkpointing fails. No notification callback, deferred autocmd, or
post-submit event is used to establish the baseline.

CodeCompanion currently derives ACP process and `session/new` cwd from the
effective Neovim cwd. The integration therefore uses a narrow cwd guard around
the first submission/session establishment: it records whether the current
scope is window-local, tab-local, or global, changes that same scope to the Pi
root, and restores it immediately after the synchronous submit call. This code
is isolated and covered by tests so it can be removed if CodeCompanion exposes
a per-chat ACP cwd option.

On successful completion, lifecycle code runs `checktime` for loaded normal
buffers inside the root and refreshes status for attached pending reviews. A
reload or refresh failure is reported but does not corrupt checkpoint state.

## Context and composer compatibility

CodeCompanion buffer context is captured in the source window before a Pi chat
is opened or restored. The chat's buffer context is updated when the user
invokes `:Pi ask`, `:Pi prompt`, or the corresponding keymaps from another
source buffer.

CodeCompanion's `#{...}` editor context syntax is canonical. For one migration
release, prompt text is translated as follows before it enters the composer:

| Legacy token | CodeCompanion token |
| --- | --- |
| `@this` | `#{selection}` when visual, otherwise `#{buffer}` |
| `@buffer` | `#{buffer}` |
| `@buffers` | `#{buffers}` |
| `@visible` | `#{viewport}` |
| `@diagnostics` | `#{diagnostics}` |
| `@quickfix` | `#{quickfix}` |
| `@diff` | `#{diff}` |

The translation is textual only. `pi.context` does not capture or render any
context for the new backend and is deleted with the terminal after migration.

Current codecompanion-ui clears its input buffer immediately before calling
`chat:submit()`, while CodeCompanion restores the editable chat buffer when an
`on_before_submit` callback cancels. A feature-detected compatibility handler
preserves the submitted draft and moves it back to the composer after
`CodeCompanionChatRestored`. This handler is isolated, tested, and does not
replace the composer implementation.

## Review behavior

### Opening

`review.open(scope)` obtains `checkpoint.view(scope, root)`, asks the user to
select a changed file, and opens supported files in the existing normal editing
area. It never creates a review tab or side-by-side baseline buffer.

Pending review uses `accepted_tree` and installs mutable mappings. Turn and
session review use their audit trees and install navigation and close mappings
only. Audit review cannot change `accepted_tree`.

### Accept hunk

1. Ask MiniDiff for current buffer data.
2. Select the hunk under the cursor through its published coordinates.
3. Invoke MiniDiff's apply path so the Pi source receives those hunks.
4. Splice current buffer lines into accepted reference lines.
5. Serialize while preserving the appropriate final-newline state.
6. Call `checkpoint.accept_text(path, data, root)`.
7. Refresh MiniDiff reference text without modifying the working buffer.

### Reject hunk

1. Select the current hunk from MiniDiff data.
2. Invoke MiniDiff's documented reset operation for that hunk range.
3. Preserve the buffer's `endofline` setting and write the real buffer.
4. Leave `accepted_tree` unchanged and allow MiniDiff to recalculate.

### File and all-file actions

- Accept file calls `checkpoint.accept_file(path, root)` and refreshes its
  reference.
- Reject file confirms if the loaded buffer has unsaved modifications, calls
  `checkpoint.reject_file(path, root)`, then reloads the buffer.
- Accept all calls `checkpoint.accept_all(root)` and refreshes every Pi review
  attachment for that root. It does not modify any working-tree file.
- Deleted, binary, symlink, and unsupported files expose file-level operations
  only.

Default mappings are buffer-local and exist only while a buffer is attached to
Pi review:

```text
[h  previous hunk
]h  next hunk
a   accept hunk
r   reject hunk
A   accept file
R   reject file
q   close Pi review mode
```

## Public facade

The final command surface is:

```text
:Pi
:Pi toggle
:Pi focus
:Pi ask [text]
:Pi prompt <text-or-name>
:Pi select
:Pi abort
:Pi model
:Pi thinking
:Pi checkpoint
:Pi review [turn|session]
:Pi accept hunk|file|all
:Pi reject hunk|file
:Pi status
:Pi stop
```

Chat-related commands call CodeCompanion or codecompanion-ui. `model` and
`thinking` open CodeCompanion's ACP controls; pi.nvim supplies no picker.
`stop` closes the project Pi chat and therefore its ACP process. Toggle only
hides or restores the UI.

## Configuration and migration

New Pi configuration contains integration and review options only:

```lua
{
  codecompanion = {
    adapter = "pi",
    command = { "pi-acp" },
  },
  project = {
    cwd = nil,
  },
  review = {
    enabled = true,
    save_before_prompt = true,
    overlay = true,
    keymaps = {
      previous_hunk = "[h",
      next_hunk = "]h",
      accept_hunk = "a",
      reject_hunk = "r",
      accept_file = "A",
      reject_file = "R",
      close = "q",
    },
  },
  compatibility = {
    terminal_fallback = false,
    legacy_context_tokens = true,
  },
}
```

During the first two milestones, recognized terminal fields translate into the
fallback configuration and emit one deprecation warning per Neovim session.
Unknown terminal timing and paste fields are ignored with one warning. After
the real-stack integration test passes in milestone three, terminal fallback,
terminal configuration, `terminal.lua`, `terminal_spec.lua`, `pi.context`, and
its duplicate configuration are removed. The migration is then documented as
a breaking release.

## Error handling

- Missing CodeCompanion, codecompanion-ui, pi-acp, Pi, Git, or MiniDiff is
  reported by health checks and by the affected command with a direct remedy.
- Lifecycle callbacks are gated by adapter name and chat metadata, preventing
  side effects in non-Pi CodeCompanion chats.
- Save and checkpoint errors notify once and cancel submission.
- ACP startup errors are owned and displayed by CodeCompanion. A turn baseline
  already captured for an attempted submission remains valid; `accepted_tree`
  is unchanged.
- Missing or closed buffers and windows are treated as stale UI state and
  recreated rather than causing hard failures.
- Review refuses hunk operations when scope is read-only, reference data is
  unavailable, or the path is not supported as text.
- Reject-file confirmation defaults to cancellation when the selection UI is
  dismissed.
- Cleanup is idempotent and attempts every project state even if one cleanup
  operation fails.

## Testing strategy

The existing headless harness remains authoritative. External integrations are
injected or mocked for most tests so `make test` does not need network access or
a running Pi process.

### Checkpoint and Git regression tests

- session and accepted trees initially match;
- new turns change only the turn tree and number;
- file, text, all acceptance and file rejection preserve their established
  working-tree/tree directions;
- pre-existing tracked and untracked changes begin accepted;
- new and deleted files appear in views;
- repeated changes to one file across turns remain correct;
- two project roots retain independent state;
- the real index bytes and index path metadata remain unchanged.

### CodeCompanion tests

- adapter command and ACP shape;
- only Pi chats receive lifecycle callbacks;
- one chat per root, hide/restore reuse, explicit stop, and cross-project
  isolation;
- exact source context capture before UI focus changes;
- save then checkpoint ordering;
- cancellation on either failure;
- no duplicate checkpoint for CodeCompanion internal auto-submit turns;
- effective cwd guard and exact restoration of global, tab-local, and
  window-local cwd;
- completion reload and status refresh;
- composer draft recovery after cancellation;
- legacy context-token translation;
- terminal fallback only when explicitly enabled.

### MiniDiff tests

- source attachment, reference loading, overlay, detachment, and exact previous
  configuration restoration;
- added, deleted, replaced, first-line, last-line, and empty-file hunks;
- missing final newline;
- multiple hunks applied bottom-to-top;
- repeated acceptance after reference changes;
- reject hunk modifies only the buffer/worktree;
- accept file/all modify only accepted trees;
- read-only scope restrictions;
- unsupported file-level actions;
- loaded-buffer confirmation on reject file;
- refresh of every attached buffer after accept-all.

### Integration and smoke tests

- `make test` runs after each implementation task.
- `make smoke` runs at every milestone.
- An opt-in integration target loads real CodeCompanion, codecompanion-ui, and
  MiniDiff and uses a controlled ACP fixture to prove callback and UI behavior.
- A real-stack target, guarded by executable checks, starts `pi-acp` and Pi in a
  temporary Git project and proves prompt, abort, model/session configuration,
  cwd, and process reuse.
- The terminal and old reviewer are removed only after both integration layers
  pass.

## Milestones

### 1. ACP integration bridge

- Protect and project-scope checkpoint semantics.
- Add license and third-party notices.
- Add dependency health checks and the Pi ACP adapter.
- Add lifecycle callbacks and headless CodeCompanion integration tests.
- Make `:Pi prompt`, `:Pi abort`, and delegated model controls work.
- Retain the terminal as an explicit fallback.
- Run `make test` and `make smoke`, then stop for review.

### 2. CodeCompanion UI lifecycle

- Route toggle, focus, ask, prompt selection, and context through
  CodeCompanion/codecompanion-ui.
- Preserve drafts across hide/show and failed pre-submit.
- Add compatibility translation for legacy context tokens.
- Verify streaming, completion reload, cwd, process reuse, and no focus theft.
- Leave the terminal present only as removable fallback code.
- Run `make test` and `make smoke`, then stop for review.

### 3. MiniDiff review and legacy removal

- Replace the two-pane reviewer with the Pi MiniDiff source.
- Complete hunk/file/all and audit-scope tests.
- Run controlled and real-stack integration tests.
- Remove terminal fallback and duplicate context implementation.
- Update commands, health, README, help, license, and notices.
- Run `make test` and `make smoke`, then stop for final review.

## Licensing

A root MIT `LICENSE` file will match the declaration already present in the
README. `THIRD_PARTY.md` will identify runtime dependencies and licenses:

- CodeCompanion.nvim: Apache-2.0;
- codecompanion-ui.nvim: MIT;
- pi-acp: MIT;
- mini.diff: MIT.

No dependency source is copied into this repository. If a small generic portion
must be adapted, its notice and origin will be recorded explicitly before the
code is committed.
