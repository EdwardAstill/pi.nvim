# Pi Review Integration Design

## Summary

This project extends `kurochenko/pi.nvim` while preserving its defining
architecture: the official Pi TUI remains the agent backend and user interface
inside an embedded Neovim terminal. Neovim continues to contribute editor
context, and gains a Git-backed review layer for changes made during a Pi
session.

The review layer records immutable Git tree objects through a temporary index.
It never reads from or writes to the user's real Git index. The normal review
compares the mutable accepted state with the current worktree and supports
accepting or rejecting individual hunks and files. Turn and session reviews are
read-only audit views.

## Goals

- Keep Pi itself as the real interactive TUI, agent loop, model selector,
  session manager, and extension host.
- Run the Pi process in an explicit project working directory.
- Preserve user changes that existed before Pi started.
- Attribute changes to the latest plugin-tracked prompt without losing a
  session-wide audit view.
- Review pending changes with native Neovim diff windows.
- Accept or reject a hunk, accept or reject a file, or accept all pending files.
- Handle repeated edits to the same file across multiple Pi turns.
- Save modified project buffers before a tracked prompt so the editor, disk,
  checkpoint, and Pi all see the same content.
- Keep all plugin-side implementation in Lua and avoid a second process or Pi
  RPC frontend.

## Non-goals

- Intercept or approve Pi writes before they reach disk.
- Replace or reproduce the Pi TUI.
- Detect prompt submission typed directly into every possible Pi TUI dialog.
- Persist review sessions across Neovim restarts.
- Review non-Git projects or ignored untracked files.
- Maintain multiple hidden Pi terminals for multiple projects in one Neovim
  instance.

Pi remains usable in a non-Git directory. Only checkpoint and review features
are unavailable there.

## Upstream Base

The local repository starts from `kurochenko/pi.nvim` commit
`b13e47d1d49d08c67c075556f46cb0d73625260f`. Its remote is named `upstream`.
The existing terminal, context placeholder, action picker, command namespace,
and optional `snacks.nvim` integration remain the base behavior.

## Project Identity and CWD

Configuration gains:

```lua
project = {
  cwd = nil,
}
```

When `project.cwd` is a string, it pins Pi to that normalized absolute
directory. When it is `nil`, the plugin resolves `vim.fn.getcwd()` at the time
an operation starts. The resolved directory is stored as the active Pi
project.

Both terminal implementations pass that directory explicitly to the child
process: `termopen(..., { cwd = project_cwd })` for the built-in terminal and
the corresponding `cwd` option for `snacks.terminal`. The terminal module
exposes its active cwd.

If a dynamic cwd resolves to a different directory while a terminal is alive,
the plugin stops and removes the old terminal, clears its in-memory review
session, and starts a new Pi session in the new cwd. It does not silently reuse
a Pi process from another project. A configured fixed cwd is unaffected by
editor cwd changes.

The Pi cwd and Git worktree root are stored separately. Pi may start in a
subdirectory, while snapshots cover the entire containing Git worktree.

## Review State

One in-memory review session is active at a time:

```lua
{
  cwd = "/project/subdirectory",
  git_root = "/project",
  session_start_tree = "<tree oid>",
  accepted_tree = "<tree oid>",
  turn_base_tree = "<tree oid>" or nil,
  turn_number = 0,
}
```

### `session_start_tree`

This is captured when a Git-backed Pi project session first starts. It includes
the worktree exactly as it exists then, including tracked modifications,
staged content as it appears in the worktree, deletions, and non-ignored
untracked files. It never changes and provides the session audit baseline.

### `accepted_tree`

This initially equals `session_start_tree`. It advances when the user accepts a
hunk, a file, or all pending changes. The default pending review compares this
tree with the current worktree.

### `turn_base_tree`

This is replaced immediately before each submitted prompt sent through the
plugin, after modified project buffers are saved. `:Pi checkpoint` performs the
same operation manually. It captures the current worktree, not the accepted
tree, so `:Pi review turn` shows only changes made after that checkpoint even
when older changes are still pending. `turn_number` increments with each
successful checkpoint.

Only the latest turn baseline is retained. Pending review and the immutable
session baseline preserve the two longer-lived views.

## Git Snapshot Engine

Review requires a non-bare Git worktree. The engine discovers the root with
Git, not by assuming the Pi cwd is the root.

Every index operation sets `GIT_INDEX_FILE` to a plugin-owned temporary path.
The engine removes stale temporary index and lock files before use and cleans
them on session reset and Neovim exit. It never runs commands that mutate the
real index.

To snapshot the current worktree:

1. Initialize the temporary index from `HEAD`, or an empty tree in an unborn
   repository.
2. Run `git add -A` against the worktree through the temporary index.
3. Run `git write-tree` and store the returned tree object ID.

This writes deduplicated blobs and trees into Git's object database. The
objects are intentionally dangling and may later be removed by normal Git
garbage collection after the Neovim session no longer references them.

Ignored untracked files follow Git semantics and are excluded. Submodules are
represented by their Gitlink entries. Rename detection is disabled in review
lists so actions always operate on explicit paths.

The Git module provides focused operations for:

- snapshotting the worktree;
- listing changed paths and line statistics between two trees;
- reading a path's blob, mode, and object ID from a tree;
- replacing or removing one path in a base tree and writing a new tree;
- copying one path's entry between trees;
- restoring one accepted path to the worktree; and
- producing text diffs and hunk counts for status and review.

Paths are passed to Git as argument-list elements after `--`; they are never
interpolated into shell command strings.

## Prompt and Checkpoint Flow

Submitted plugin prompts use one central tracked-send path:

```text
resolve context
  -> resolve project cwd
  -> save modified file buffers inside the project
  -> ensure the review session exists
  -> capture turn_base_tree
  -> submit to the Pi terminal
```

This applies to submitted forms of `ask`, `prompt`, named prompts, the action
picker, and operator prompts. Text inserted into Pi without submission, such as
`send_context()` or `prompt(..., { submit = false })`, does not checkpoint.

Before checkpointing, every loaded, modified, normal file buffer whose absolute
path is inside the active Git worktree (or inside the Pi cwd for a non-Git
project) is saved with the equivalent of `:update`. A save failure aborts the
prompt and reports the file; the checkpoint and send do not proceed.

In a non-Git directory, the autosave and Pi prompt still proceed, with a
once-per-session warning that review tracking is unavailable. An operational
Git failure inside a detected worktree aborts the tracked prompt because Pi
must not edit against a missing baseline.

Direct prompts typed inside the Pi TUI remain part of pending and session
review. Exact turn attribution for those prompts requires running
`:Pi checkpoint` immediately before submitting them. The plugin does not
intercept terminal Enter because Enter is also used by Pi dialogs, pickers, and
extensions.

## Review Views

### Pending review: `:Pi review`

The actionable default compares:

```text
accepted_tree -> current worktree snapshot
```

It opens a changed-file picker using `vim.ui.select`, showing status and
addition/deletion counts. Selecting a text file opens a dedicated review tab
with two native diff windows:

- left: a scratch buffer containing the accepted version;
- right: the real working file buffer, or a normal empty file buffer for a
  currently deleted path.

New and deleted files are represented by an empty side. Neovim's normal `]c`
and `[c` movements navigate hunks. Binary files, symlinks, submodules, and
unsupported type changes remain available for file-level accept or reject but
do not offer text-hunk actions.

### Turn audit: `:Pi review turn`

This compares:

```text
turn_base_tree -> current worktree snapshot
```

It is read-only. It reports clearly when no turn checkpoint exists.

### Session audit: `:Pi review session`

This compares:

```text
session_start_tree -> current worktree snapshot
```

It is read-only, including after all pending changes have been accepted. Audit
views disable accept and reject actions so they cannot ambiguously advance the
pending baseline.

Closing review removes its scratch buffers, disables diff mode in its windows,
and closes only the dedicated review tab. It does not close the Pi terminal.

## Acceptance and Rejection

All mutations are restricted to the actionable pending view.

### Accept hunk

The current hunk is copied from the working buffer into the accepted scratch
buffer using Neovim's native diff operation. The scratch buffer's exact text,
including final-newline state, is written as a Git blob and replaces only that
path in `accepted_tree`. The worktree is unchanged. Other pending paths and
hunks remain based on the previous accepted tree. For a previously absent path,
the mode comes from the current worktree entry. When the working side is absent
and accepting its final deletion hunk leaves no accepted content, the path is
removed from `accepted_tree` rather than recorded as an empty file.

### Reject hunk

The current hunk is copied from the accepted scratch buffer into the working
buffer. The working buffer is written to disk and the accepted tree is
unchanged. The rejected worktree change disappears from pending review. When
rejecting the final creation hunk leaves the working side absent according to
the accepted tree, the new path is removed rather than written as an empty
file.

### Accept file

The current worktree snapshot's entry for the selected path is copied into
`accepted_tree`. This includes creation, deletion, content, and file mode.
No working file is changed.

### Reject file

The accepted tree's entry for the selected path is restored to both disk and
the loaded working buffer. If the accepted tree has no entry, the newly added
path is removed after validating that the target is the exact reviewed path.
The accepted tree is unchanged.

### Accept all

The current worktree is snapshotted and `accepted_tree` is set to that tree.
`session_start_tree` and `turn_base_tree` are not changed. This is exposed only
as `:Pi accept all`, not as a single review key.

After each action, the file list and diff are refreshed. When no pending changes
remain, the plugin reports that state and closes the actionable review.

## Commands

The existing single `:Pi` namespace is retained.

| Command | Behavior |
| --- | --- |
| `:Pi review` | Open actionable pending review. |
| `:Pi review turn` | Open the latest turn audit view. |
| `:Pi review session` | Open the session audit view. |
| `:Pi checkpoint` | Save project buffers and capture a manual turn baseline. |
| `:Pi accept hunk` | Accept the current pending-review hunk. |
| `:Pi reject hunk` | Reject the current pending-review hunk. |
| `:Pi accept file` | Accept the current review file. |
| `:Pi reject file` | Reject the current review file. |
| `:Pi accept all` | Accept all currently pending project changes. |
| `:Pi status` | Report project cwd, review availability, turn number, and pending file/hunk counts. |

Command completion includes subcommands, review scopes, and action targets.
Invalid combinations produce a concise warning rather than becoming arbitrary
Pi prompts.

## Review-local Keymaps

Actionable pending review buffers define:

| Key | Behavior |
| --- | --- |
| `]c` | Next native diff hunk. |
| `[c` | Previous native diff hunk. |
| `a` | Accept current hunk. |
| `r` | Reject current hunk. |
| `A` | Accept current file. |
| `R` | Reject current file. |
| `q` | Close review. |

Audit views retain hunk navigation and `q`, but do not map acceptance or
rejection. All mappings are buffer-local and removed with the review buffers.
Existing global Pi keymaps remain unchanged.

## Module Boundaries

```text
lua/pi/
  init.lua              public prompt/review API and tracked-send orchestration
  config.lua            project and review configuration/defaults
  context.lua           existing context capture and expansion
  terminal.lua          explicit cwd, lifecycle, and terminal I/O
  project.lua           cwd normalization, containment, and buffer autosave
  checkpoint.lua        session state and baseline transitions
  review.lua            file picker, diff tab lifecycle, and view refresh
  review/git.lua        temporary-index Git/tree/blob operations
  review/actions.lua    pending hunk/file/all mutations

plugin/pi.lua           :Pi parsing, completion, reload, and cleanup hooks
lua/pi/health.lua       cwd, Git, and review capability checks
```

The Git module accepts a command runner dependency so its behavior can be
tested with real temporary repositories while orchestration remains isolated.
The checkpoint module owns state transitions; the review UI never mutates tree
IDs directly.

## Error Handling and Safety

- The real Git index path is never passed to an index-mutating Git command.
- Commands use argv arrays and explicit cwd/environment values.
- A failed autosave or failed Git checkpoint prevents a tracked prompt from
  being submitted in a Git project.
- Review commands validate that the current project matches the stored
  session.
- Reject operations validate and normalize the exact reviewed path before any
  disk removal or restore.
- A working buffer changed after the review opened remains the live right-hand
  buffer, avoiding a stale hidden copy. File actions refresh from disk/current
  snapshot immediately before mutation.
- External edits made after a checkpoint are intentionally included in the
  relevant pending/turn/session comparison; the engine tracks state, not the
  identity of the editor.
- Git errors include the failed operation and stderr without exposing an
  interpolated shell command.
- Non-Git projects keep terminal and context features operational.

## Configuration

New defaults are intentionally small:

```lua
project = {
  cwd = nil,
},

review = {
  enabled = true,
  save_before_prompt = true,
  keymaps = {
    accept_hunk = "a",
    reject_hunk = "r",
    accept_file = "A",
    reject_file = "R",
    close = "q",
  },
},
```

Setting an individual review keymap to `false` disables it. Disabling review
skips checkpoint tracking but leaves Pi prompt and terminal behavior intact.

## Testing Strategy

The repository gains a dependency-free Lua test harness executed by headless
Neovim. Tests use real temporary Git repositories for the snapshot engine and
literal expected file content/tree comparisons.

Required automated coverage:

- initial snapshot includes pre-existing tracked and untracked changes;
- the user's real staged index has the same tree before and after every review
  operation;
- tracked prompts save modified project buffers before the turn snapshot;
- modified buffers outside the active project are not saved;
- autosave failure prevents prompt submission;
- non-submitted text does not create a checkpoint;
- manual and automatic checkpoints replace only `turn_base_tree` and increment
  the turn number;
- repeated edits to the same file produce correct pending, turn, and session
  comparisons;
- accepting one hunk advances only that content in `accepted_tree`;
- rejecting one hunk updates only the working file;
- new, deleted, executable, and partially accepted files support file actions;
- accept file and accept all leave session and turn baselines unchanged;
- cwd changes stop the old terminal and reset the review session;
- non-Git projects still submit prompts and report review as unavailable;
- review teardown restores Neovim window/buffer state without closing Pi.

Final verification runs the full headless suite, a Lua formatting/static check
when the tools are locally available, `:checkhealth pi`, and a smoke test that
loads the plugin, creates its commands, snapshots a disposable dirty Git
worktree, reviews it, and proves the disposable repository's real index tree
never changed.

## Success Criteria

- `/home/eastill/Projects/pi.nvim` loads on Neovim 0.10 or newer.
- Pi launches in the resolved explicit cwd and the existing TUI/context
  workflow remains operational.
- Every submitted plugin prompt either receives a valid turn checkpoint first
  or, in a non-Git project, clearly runs without review tracking.
- Pending, turn, and session views compare the documented baselines.
- Hunk, file, and all acceptance/rejection actions converge pending review
  without changing unrelated files.
- Pre-existing worktree changes are baseline content, not misidentified as Pi
  changes.
- The same file can be modified and reviewed across successive turns.
- Automated tests and the smoke test pass, and verification demonstrates that
  the user's real Git index is untouched.
