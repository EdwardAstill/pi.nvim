# Pi Review Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the embedded official Pi TUI integration with explicit project cwd handling and safe Git-tree-backed pending, turn, and session review.

**Architecture:** Keep terminal and context behavior in the existing Lua modules, add a project boundary/autosave module, and isolate all Git object/index work behind `lua/pi/review/git.lua`. `checkpoint.lua` owns the three baselines, `review.lua` owns the native Neovim diff tab, and `review/actions.lua` translates review-local actions into checkpoint or working-buffer mutations.

**Tech Stack:** LuaJIT, Neovim 0.10+ APIs, Git CLI with `GIT_INDEX_FILE`, headless Neovim tests, optional `snacks.nvim`, official Pi CLI.

**Spec:** `docs/superpowers/specs/2026-09-02-pi-review-design.md`

## Global Constraints

- The project remains a Lua Neovim plugin; do not add Node, Python, RPC, or a replacement Pi frontend.
- Pi remains the official TUI/backend in the embedded terminal.
- Review requires a non-bare Git worktree; Pi remains functional outside Git.
- Never run an index-mutating Git command without the plugin-owned `GIT_INDEX_FILE` environment variable.
- Snapshots cover the containing Git worktree and include non-ignored untracked files.
- `session_start_tree` is immutable, `accepted_tree` is mutable, and only the latest `turn_base_tree` is retained.
- `:Pi review` is actionable; `:Pi review turn` and `:Pi review session` are read-only.
- Save modified project buffers before every submitted plugin prompt and manual checkpoint.
- Do not checkpoint text inserted into Pi with `submit = false`.
- Use argv arrays for Git processes and validate all worktree-relative paths.
- Preserve Neovim 0.10 compatibility.
- Follow strict red-green-refactor for every production behavior below.

---

## File Map

### Existing files to modify

- `lua/pi/config.lua` — add and validate `project` and `review` options.
- `lua/pi/init.lua` — centralize tracked prompt submission and expose review APIs.
- `lua/pi/terminal.lua` — accept an explicit cwd, report it, and stop/restart on mismatch.
- `lua/pi/health.lua` — report resolved cwd, Git, and review capability.
- `plugin/pi.lua` — parse and complete checkpoint/review/status/action commands and clean up state.
- `README.md` — document configuration, commands, safety model, and direct-TUI limitation.
- `doc/pi.txt` — add matching Vim help tags and command/API documentation.

### New production files

- `lua/pi/project.lua` — normalize cwd, validate containment, discover the save boundary, and save modified buffers.
- `lua/pi/review/git.lua` — run Git with a temporary index and manipulate tree/blob entries.
- `lua/pi/checkpoint.lua` — own session state, scope baselines, and accepted-tree transitions.
- `lua/pi/review/actions.lua` — implement native hunk and file/all review actions.
- `lua/pi/review.lua` — create the picker, review tab, diff buffers, local mappings, and teardown.

### New test/support files

- `Makefile` — expose `make test` and `make smoke`.
- `tests/minimal_init.lua` — add the repository to runtimepath and configure deterministic headless behavior.
- `tests/run.lua` — load specs, run registered tests, print failures, and exit nonzero.
- `tests/helpers.lua` — assertions, temporary repository creation, real Git execution, and cleanup.
- `tests/config_spec.lua`
- `tests/project_spec.lua`
- `tests/terminal_spec.lua`
- `tests/git_spec.lua`
- `tests/checkpoint_spec.lua`
- `tests/init_spec.lua`
- `tests/actions_spec.lua`
- `tests/review_spec.lua`
- `tests/commands_spec.lua`
- `tests/smoke.lua`

---

### Task 1: Test Harness, Configuration, and Project Buffer Saving

**Files:**
- Create: `Makefile`
- Create: `tests/minimal_init.lua`
- Create: `tests/run.lua`
- Create: `tests/helpers.lua`
- Create: `tests/config_spec.lua`
- Create: `tests/project_spec.lua`
- Create: `lua/pi/project.lua`
- Modify: `lua/pi/config.lua`

**Interfaces:**
- Produces: `require("pi.project").resolve_cwd(): string`
- Produces: `require("pi.project").is_within(root, path): boolean`
- Produces: `require("pi.project").save_modified(root): boolean, string|nil`
- Produces: `config.opts.project.cwd: string|nil`
- Produces: `config.opts.review.enabled`, `save_before_prompt`, and review keymaps.

- [ ] **Step 1: Create the dependency-free test harness**

Create `tests/minimal_init.lua` with repository runtimepath setup derived from
the script location, not the process cwd:

```lua
local source = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(source, ":p:h:h")
vim.opt.runtimepath:prepend(root)
vim.opt.swapfile = false
vim.opt.undofile = false
vim.g.mapleader = " "
```

Create `tests/helpers.lua` with these exact public helpers:

```lua
local M = { tests = {}, tempdirs = {} }

function M.test(name, fn)
  M.tests[#M.tests + 1] = { name = name, fn = fn }
end

function M.eq(want, got, message)
  if not vim.deep_equal(want, got) then
    error((message or "values differ") .. "\nwant: " .. vim.inspect(want) .. "\ngot: " .. vim.inspect(got), 2)
  end
end

function M.truthy(value, message)
  if not value then
    error(message or "expected truthy value", 2)
  end
end

function M.tmpdir()
  local path = vim.fn.tempname()
  vim.fn.mkdir(path, "p")
  M.tempdirs[#M.tempdirs + 1] = path
  return vim.fs.normalize(path)
end

function M.write(path, text)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile(vim.split(text, "\n", { plain = true }), path, "b")
end

function M.read(path)
  return table.concat(vim.fn.readfile(path, "b"), "\n")
end

function M.run(argv, opts)
  local result = vim.system(argv, opts or {}):wait()
  if result.code ~= 0 then
    error(string.format("command failed (%d): %s", result.code, result.stderr or ""), 2)
  end
  return vim.trim(result.stdout or "")
end

function M.git(root, args)
  return M.run(vim.list_extend({ "git" }, args), { cwd = root })
end

function M.repo()
  local root = M.tmpdir()
  M.git(root, { "init", "-q" })
  M.git(root, { "config", "user.name", "pi.nvim tests" })
  M.git(root, { "config", "user.email", "pi.nvim@example.invalid" })
  M.write(root .. "/tracked.txt", "base\n")
  M.git(root, { "add", "tracked.txt" })
  M.git(root, { "commit", "-qm", "base" })
  return root
end

function M.cleanup()
  for _, path in ipairs(M.tempdirs) do
    assert(path:match("^/"), "test temp path must be absolute")
    vim.fn.delete(path, "rf")
  end
end

return M
```

Create `tests/run.lua` to require each spec in a literal list, run every
registered test with `xpcall`, call `helpers.cleanup()`, print a summary, and
execute `vim.cmd("cquit 1")` when any test failed or `vim.cmd("qa!")` when all
passed. Start the list with `config_spec` and `project_spec`; later tasks append
their spec name.

Create `Makefile`:

```make
.PHONY: test smoke

test:
	nvim --headless --clean -u tests/minimal_init.lua -c "lua dofile('tests/run.lua')"

smoke:
	nvim --headless --clean -u tests/minimal_init.lua -c "lua dofile('tests/smoke.lua')"
```

- [ ] **Step 2: Write failing configuration tests**

In `tests/config_spec.lua`, reset `package.loaded["pi.config"]` for each test
and register literal checks:

```lua
local H = require("tests.helpers")

H.test("review defaults are enabled and cwd is dynamic", function()
  package.loaded["pi.config"] = nil
  local config = require("pi.config")
  H.eq(nil, config.opts.project.cwd)
  H.eq(true, config.opts.review.enabled)
  H.eq(true, config.opts.review.save_before_prompt)
  H.eq({ accept_hunk = "a", reject_hunk = "r", accept_file = "A", reject_file = "R", close = "q" }, config.opts.review.keymaps)
end)

H.test("review keymaps accept false and project cwd rejects non-strings", function()
  package.loaded["pi.config"] = nil
  local config = require("pi.config")
  config.setup({ review = { keymaps = { accept_hunk = false } }, project = { cwd = "/tmp/project" } })
  H.eq(nil, config.opts.review.keymaps.accept_hunk)
  local ok = pcall(config.setup, { project = { cwd = 42 } })
  H.eq(false, ok)
end)
```

- [ ] **Step 3: Run the configuration specs and confirm RED**

Run: `make test`

Expected: both configuration tests fail because `project` and `review` do not
exist in the defaults.

- [ ] **Step 4: Implement and validate the new configuration**

Add `pi.Config.Project`, `pi.Config.Review`, and `pi.Config.ReviewKeymaps`
annotations. Add the exact defaults from the design spec. Extend both
top-level and field validation:

```lua
project = { opts.project, "table" },
review = { opts.review, "table" },
```

```lua
["project.cwd"] = {
  opts.project.cwd,
  function(v)
    return v == nil or type(v) == "string"
  end,
  "string or nil",
},
["review.enabled"] = { opts.review.enabled, "boolean" },
["review.save_before_prompt"] = { opts.review.save_before_prompt, "boolean" },
["review.keymaps"] = { opts.review.keymaps, "table" },
```

Validate each review keymap as `string|nil`, and remove user-supplied `false`
entries after merging exactly as existing global keymaps are removed.

- [ ] **Step 5: Run the configuration specs and confirm GREEN**

Run: `make test`

Expected: `2 passed, 0 failed`.

- [ ] **Step 6: Write failing project-path and autosave tests**

In `tests/project_spec.lua`, register these observable behaviors:

```lua
local H = require("tests.helpers")

H.test("resolve_cwd normalizes fixed and dynamic cwd values", function()
  local config = require("pi.config")
  local project = require("pi.project")
  local root = H.tmpdir()
  config.setup({ project = { cwd = root .. "/." } })
  H.eq(root, project.resolve_cwd())
  config.setup({ project = { cwd = nil } })
  local previous = vim.fn.getcwd()
  vim.cmd.lcd(vim.fn.fnameescape(root))
  H.eq(root, project.resolve_cwd())
  vim.cmd.lcd(vim.fn.fnameescape(previous))
end)

H.test("is_within rejects sibling prefix collisions", function()
  local project = require("pi.project")
  H.eq(true, project.is_within("/tmp/app", "/tmp/app/lua/a.lua"))
  H.eq(true, project.is_within("/tmp/app", "/tmp/app"))
  H.eq(false, project.is_within("/tmp/app", "/tmp/application/a.lua"))
end)

H.test("save_modified writes only normal buffers inside the boundary", function()
  local project = require("pi.project")
  local root = H.tmpdir()
  local outside = H.tmpdir()
  H.write(root .. "/inside.txt", "disk\n")
  H.write(outside .. "/outside.txt", "outside-disk\n")
  local inside_buf = vim.fn.bufadd(root .. "/inside.txt")
  local outside_buf = vim.fn.bufadd(outside .. "/outside.txt")
  vim.fn.bufload(inside_buf)
  vim.fn.bufload(outside_buf)
  vim.api.nvim_buf_set_lines(inside_buf, 0, -1, false, { "inside-buffer" })
  vim.api.nvim_buf_set_lines(outside_buf, 0, -1, false, { "outside-buffer" })
  local ok, err = project.save_modified(root)
  H.eq(true, ok)
  H.eq(nil, err)
  H.eq("inside-buffer", H.read(root .. "/inside.txt"))
  H.eq("outside-disk", H.read(outside .. "/outside.txt"))
  H.eq(true, vim.bo[outside_buf].modified)
end)
```

Add a fourth test using a read-only target and `pcall(vim.api.nvim_buf_call,
...)` cleanup to prove `save_modified` returns `false, <path-containing error>`
instead of continuing after `:update` fails.

- [ ] **Step 7: Run the project specs and confirm RED**

Run: `make test`

Expected: project specs fail with `module 'pi.project' not found`.

- [ ] **Step 8: Implement `lua/pi/project.lua`**

Use `vim.fs.normalize`, convert relative fixed cwd values through
`vim.fn.fnamemodify(value, ":p")`, trim trailing separators without converting
`/` to an empty string, and compare containment as `path == root` or a
`root .. "/"` prefix.

Implement `save_modified(root)` by iterating `vim.api.nvim_list_bufs()`, then
requiring all of these before saving:

```lua
vim.api.nvim_buf_is_loaded(buf)
vim.bo[buf].modified
vim.bo[buf].buftype == ""
vim.api.nvim_buf_get_name(buf) ~= ""
M.is_within(root, vim.api.nvim_buf_get_name(buf))
```

Save with:

```lua
local ok, err = pcall(vim.api.nvim_buf_call, buf, function()
  vim.cmd.update({ mods = { silent = true } })
end)
```

Return `false, string.format("failed to save %s: %s", name, err)` on the first
failure and `true, nil` otherwise.

- [ ] **Step 9: Run all Task 1 tests and commit**

Run: `make test`

Expected: `6 passed, 0 failed` with no warnings.

Run: `git diff --check`

Commit:

```bash
git add Makefile tests lua/pi/config.lua lua/pi/project.lua
git commit -m "feat: add project cwd and buffer autosave"
```

---

### Task 2: Explicit Terminal CWD and Project Switching

**Files:**
- Create: `tests/terminal_spec.lua`
- Modify: `tests/run.lua`
- Modify: `lua/pi/terminal.lua`

**Interfaces:**
- Consumes: `pi.project.resolve_cwd()`.
- Produces: `terminal.open({ enter?: boolean, cwd?: string })`.
- Produces: `terminal.toggle({ cwd?: string })`.
- Produces: `terminal.send(text, { submit?: boolean, cwd?: string })`.
- Produces: `terminal.get_cwd(): string|nil` and `terminal.stop()`.

- [ ] **Step 1: Write real-terminal failing tests**

Append `terminal_spec` to the literal spec list. In
`tests/terminal_spec.lua`, use the built-in terminal with no Snacks module and
real short-lived shell jobs:

```lua
local H = require("tests.helpers")

local function wait_for(predicate)
  H.truthy(vim.wait(2000, predicate, 20), "timed out waiting for terminal")
end

H.test("manual terminal launches in the explicit cwd", function()
  package.loaded.snacks = nil
  package.loaded["pi.terminal"] = nil
  local config = require("pi.config")
  local terminal = require("pi.terminal")
  local root = H.tmpdir()
  config.setup({ terminal = { cmd = "sh -c 'pwd; sleep 30'", continue_session = false } })
  terminal.open({ cwd = root })
  wait_for(function()
    return terminal.is_alive()
  end)
  H.eq(root, terminal.get_cwd())
  H.truthy(table.concat(vim.api.nvim_buf_get_lines(terminal.buf, 0, -1, false), "\n"):find(root, 1, true))
  terminal.stop()
end)

H.test("opening another cwd replaces the terminal job", function()
  package.loaded["pi.terminal"] = nil
  local config = require("pi.config")
  local terminal = require("pi.terminal")
  local first = H.tmpdir()
  local second = H.tmpdir()
  config.setup({ terminal = { cmd = "sh -c 'pwd; sleep 30'", continue_session = false } })
  terminal.open({ cwd = first })
  wait_for(terminal.is_alive)
  local first_buf = terminal.buf
  terminal.open({ cwd = second })
  wait_for(function()
    return terminal.is_alive() and terminal.get_cwd() == second
  end)
  H.truthy(terminal.buf ~= first_buf)
  H.eq(false, vim.api.nvim_buf_is_valid(first_buf))
  terminal.stop()
end)

H.test("snacks terminal receives the explicit cwd", function()
  local root = H.tmpdir()
  local received
  package.loaded.snacks = {
    terminal = {
      open = function(_, opts)
        received = opts
        local buf = vim.api.nvim_create_buf(false, true)
        return { buf = buf, win = nil }
      end,
    },
  }
  package.loaded["pi.terminal"] = nil
  local terminal = require("pi.terminal")
  terminal.open({ cwd = root })
  H.eq(root, received.cwd)
  terminal.stop()
  package.loaded.snacks = nil
end)
```

- [ ] **Step 2: Run the terminal specs and confirm RED**

Run: `make test`

Expected: failures report missing `get_cwd`/`stop` and the child prints the
process cwd rather than the explicit test cwd.

- [ ] **Step 3: Implement explicit cwd for both terminal backends**

Add `M.cwd`. Resolve `opts.cwd` through `pi.project.resolve_cwd()` when absent.
Before the existing open/reopen checks, compare the requested cwd with `M.cwd`;
call `M.stop()` on mismatch.

For the built-in backend, change startup to:

```lua
M.chan = vim.fn.termopen(cmd, { cwd = cwd })
M.cwd = cwd
```

For Snacks, include `cwd = cwd` in `snacks_opts` and assign `M.cwd = cwd` only
after a valid terminal object is returned. Preserve cwd when hiding/reopening
the same buffer. Clear cwd in `reset_state`.

Implement `stop()` by closing the visible window, stopping a live channel with
`vim.fn.jobstop`, deleting the terminal buffer with
`vim.api.nvim_buf_delete(buf, { force = true })`, closing a Snacks terminal
object when it exposes `close`, and finally resetting state. Make repeated
calls safe.

Thread the explicit cwd through `open`, `toggle`, `wait_and_send`, and `send`.

- [ ] **Step 4: Run Task 2 tests and commit**

Run: `make test`

Expected: all tests pass and no terminal jobs remain after the suite.

Run: `git diff --check`

Commit:

```bash
git add tests/terminal_spec.lua tests/run.lua lua/pi/terminal.lua
git commit -m "feat: bind Pi terminal to project cwd"
```

---

### Task 3: Temporary-index Git Tree Engine

**Files:**
- Create: `tests/git_spec.lua`
- Modify: `tests/run.lua`
- Create: `lua/pi/review/git.lua`

**Interfaces:**
- Produces: `Git.discover_root(cwd): string|nil, pi.Error|nil`.
- Produces: `Git.new(cwd, { runner?: function }): pi.Git|nil, pi.Error|nil`.
- Produces instance methods `snapshot`, `entry`, `read_file`, `changed_files`,
  `diff`, `hunk_count`, `write_blob`, `update_path`, `copy_path`,
  `restore_path`, and `cleanup`.
- Error shape: `{ kind: "not_git"|"git", operation: string, message: string }`.
- Entry shape: `{ mode: string, type: string, oid: string, path: string }`.

- [ ] **Step 1: Write failing snapshot isolation tests**

Append `git_spec` to `tests/run.lua`. Create a repository where the real index
contains a staged file, while the worktree also has a tracked edit, deletion,
and untracked file. Register:

```lua
H.test("snapshot captures the worktree without changing the real index", function()
  local Git = require("pi.review.git")
  local root = H.repo()
  H.write(root .. "/staged.txt", "staged\n")
  H.git(root, { "add", "staged.txt" })
  local real_index_before = H.git(root, { "write-tree" })
  H.write(root .. "/tracked.txt", "worktree\n")
  H.write(root .. "/untracked.txt", "untracked\n")
  local git, err = Git.new(root)
  H.eq(nil, err)
  local tree = assert(git:snapshot())
  H.eq(real_index_before, H.git(root, { "write-tree" }))
  H.eq("worktree", H.git(root, { "show", tree .. ":tracked.txt" }))
  H.eq("untracked", H.git(root, { "show", tree .. ":untracked.txt" }))
  H.eq("staged", H.git(root, { "show", tree .. ":staged.txt" }))
  git:cleanup()
end)
```

Add separate tests proving ignored untracked files are absent, `Git.new` returns
`kind = "not_git"` outside Git, and an unborn repository snapshots successfully.

- [ ] **Step 2: Run snapshot specs and confirm RED**

Run: `make test`

Expected: `module 'pi.review.git' not found`.

- [ ] **Step 3: Implement command execution, discovery, and snapshotting**

The default runner must call `vim.system(argv, opts):wait()` and return the raw
result. `discover_root` runs:

```lua
{ "git", "rev-parse", "--show-toplevel" }
```

with `cwd = cwd`; map exit code 128/non-worktree output to `not_git`.

Create one absolute index path per instance with `vim.fn.tempname()`. For every
index-mutating call, pass:

```lua
{ cwd = self.root, env = { GIT_INDEX_FILE = self.index_path } }
```

Before initializing it, remove only `self.index_path` and
`self.index_path .. ".lock"`. Detect `HEAD` with `git rev-parse --verify HEAD`;
run `git read-tree HEAD` when present or `git read-tree --empty` otherwise.
Then run `git add -A -- .` and `git write-tree`. Strip only surrounding
whitespace from the object ID.

- [ ] **Step 4: Run snapshot specs and confirm GREEN**

Run: `make test`

Expected: snapshot, ignored-file, non-Git, and unborn-repository tests pass.

- [ ] **Step 5: Write failing tree-entry and diff tests**

Register tests that create two real snapshots and assert literal results:

```lua
local first = assert(git:snapshot())
H.write(root .. "/tracked.txt", "changed\n")
H.write(root .. "/new file.txt", "new\n")
local second = assert(git:snapshot())
local files = assert(git:changed_files(first, second))
H.eq({
  { path = "new file.txt", status = "A", additions = 1, deletions = 0, binary = false },
  { path = "tracked.txt", status = "M", additions = 1, deletions = 1, binary = false },
}, files)
H.eq(1, assert(git:hunk_count(first, second, "tracked.txt")))
```

Add tests for:

- `entry`/`read_file` preserving mode `100755` and final-newline bytes;
- `copy_path(base, source, path)` changing only one path;
- `update_path(base, path, nil)` removing only that path;
- `write_blob` plus `update_path` accepting literal partial content;
- `restore_path` restoring content/mode and removing a path absent from the
  supplied tree;
- `restore_path` recreating a symbolic link from its blob target;
- Gitlink rejection checking out the accepted object in an initialized clean
  submodule without changing the superproject index;
- a sibling-prefix path such as `../repository-evil/file` returning a Git error
  without writing or deleting anything; and
- the real index tree remaining identical after every method.

- [ ] **Step 6: Run the tree-operation specs and confirm RED**

Run: `make test`

Expected: failures identify the first missing method, beginning with
`changed_files`.

- [ ] **Step 7: Implement tree parsing and mutation**

Use NUL output everywhere paths are returned:

```text
git diff --no-ext-diff --no-renames --name-status -z <base> <current>
git diff --no-ext-diff --no-renames --numstat -z <base> <current>
git ls-tree -z <tree> -- <path>
```

Merge name-status and numstat records by exact path and sort the final array by
path. Represent `-` numstat fields as `binary = true`, `additions = nil`, and
`deletions = nil`.

For mutations, reinitialize the temporary index with `git read-tree <base>`,
then use one of:

```text
git update-index --add --cacheinfo <mode>,<oid>,<path>
git update-index --force-remove -- <path>
```

and finish with `git write-tree`. `copy_path` reads the source entry then calls
`update_path`. `write_blob` sends exact bytes to
`git hash-object -w --stdin`. `read_file` uses `git cat-file blob <oid>` without
trimming stdout.

Before every path operation, normalize separators, reject absolute paths,
reject `.`/`..` segments, join with the root, and confirm
`pi.project.is_within(root, absolute)`.

For `restore_path`, write regular-file blob bytes through
`vim.uv.fs_open/fs_write`, create parent directories, and apply executable mode
from the tree entry. Recreate mode `120000` as a symbolic link whose target is
the exact blob data. For mode `160000`, require an initialized submodule and a
clean nested worktree, then run `git -C <validated-path> checkout --detach
--force <accepted-oid>`; refuse the rejection when the nested worktree is dirty
or uninitialized. When the supplied tree has no entry, unlink a validated
regular file/symlink. Remove a new submodule directory only after proving it is
an initialized Git worktree with empty `git status --porcelain`; otherwise
return a safety error. All these operations leave the superproject index
untouched.

- [ ] **Step 8: Run all Git specs and commit**

Run: `make test`

Expected: all Git tests pass, including literal real-index equality checks.

Run: `git diff --check`

Commit:

```bash
git add tests/git_spec.lua tests/run.lua lua/pi/review/git.lua
git commit -m "feat: add isolated Git tree snapshots"
```

---

### Task 4: Three-baseline Checkpoint State Machine

**Files:**
- Create: `tests/checkpoint_spec.lua`
- Modify: `tests/run.lua`
- Create: `lua/pi/checkpoint.lua`

**Interfaces:**
- Consumes: `pi.review.git`.
- Produces: `checkpoint.ensure(cwd): pi.ReviewState|nil, pi.Error|nil`.
- Produces: `checkpoint.start_turn(cwd): boolean, pi.Error|nil`.
- Produces: `checkpoint.view(scope): pi.ReviewView|nil, pi.Error|nil`.
- Produces: `checkpoint.accept_file(path)`, `accept_text(path, data)`,
  `accept_all()`, and `reject_file(path)`.
- Produces: `checkpoint.status()`, `state()`, `reset()`, and `cleanup()`.
- `pi.ReviewView` is `{ scope, base_tree, current_tree, read_only, files }`.

- [ ] **Step 1: Write failing initialization and turn tests**

Append `checkpoint_spec` and register:

```lua
H.test("ensure captures immutable session and accepted trees", function()
  package.loaded["pi.checkpoint"] = nil
  local checkpoint = require("pi.checkpoint")
  local root = H.repo()
  H.write(root .. "/tracked.txt", "preexisting\n")
  local state = assert(checkpoint.ensure(root))
  H.eq(true, state.available)
  H.eq(state.session_start_tree, state.accepted_tree)
  H.eq(nil, state.turn_base_tree)
  H.eq(0, state.turn_number)
  H.eq("preexisting", state.git:read_file(state.session_start_tree, "tracked.txt").data)
  checkpoint.cleanup()
end)

H.test("start_turn replaces only the latest turn baseline", function()
  package.loaded["pi.checkpoint"] = nil
  local checkpoint = require("pi.checkpoint")
  local root = H.repo()
  local state = assert(checkpoint.ensure(root))
  local session = state.session_start_tree
  local accepted = state.accepted_tree
  H.write(root .. "/tracked.txt", "turn-one-base\n")
  H.eq(true, checkpoint.start_turn(root))
  local first_turn = checkpoint.state().turn_base_tree
  H.write(root .. "/tracked.txt", "turn-two-base\n")
  H.eq(true, checkpoint.start_turn(root))
  H.truthy(first_turn ~= checkpoint.state().turn_base_tree)
  H.eq(session, checkpoint.state().session_start_tree)
  H.eq(accepted, checkpoint.state().accepted_tree)
  H.eq(2, checkpoint.state().turn_number)
  checkpoint.cleanup()
end)
```

Add a non-Git test asserting `ensure` returns a state with
`available = false`, and `start_turn` returns `false, nil` rather than an
operational error.

- [ ] **Step 2: Run checkpoint initialization specs and confirm RED**

Run: `make test`

Expected: `module 'pi.checkpoint' not found`.

- [ ] **Step 3: Implement session initialization and turn replacement**

Keep one local `current` state. If `ensure(cwd)` receives a different normalized
cwd, call `cleanup()` before discovery. Store non-Git state rather than raising
an error. On a Git session, create the Git instance and one initial snapshot,
then assign the same object ID to session and accepted trees.

`start_turn` calls `ensure`, returns `false, nil` for unavailable review, and
otherwise snapshots current worktree into `turn_base_tree` and increments
`turn_number` only after success.

- [ ] **Step 4: Run checkpoint initialization specs and confirm GREEN**

Run: `make test`

Expected: initialization, replacement, and non-Git tests pass.

- [ ] **Step 5: Write failing scope and acceptance transition tests**

Register the repeated-edit scenario from the design:

```lua
local state = assert(checkpoint.ensure(root))
local session = state.session_start_tree
assert(checkpoint.start_turn(root))
H.write(root .. "/tracked.txt", "turn-one\n")
assert(checkpoint.accept_file("tracked.txt"))
local accepted_after_one = checkpoint.state().accepted_tree
assert(checkpoint.start_turn(root))
local turn_two_base = checkpoint.state().turn_base_tree
H.write(root .. "/tracked.txt", "turn-two\n")
local pending = assert(checkpoint.view("pending"))
local turn = assert(checkpoint.view("turn"))
local audit = assert(checkpoint.view("session"))
H.eq(accepted_after_one, pending.base_tree)
H.eq(turn_two_base, turn.base_tree)
H.eq(session, audit.base_tree)
H.eq(false, pending.read_only)
H.eq(true, turn.read_only)
H.eq(true, audit.read_only)
```

Add literal tests proving:

- `view("turn")` returns a `no_turn` error before the first checkpoint;
- `accept_text` changes only the named accepted blob;
- `accept_file` handles addition, deletion, and executable mode;
- `accept_all` advances accepted only;
- `reject_file` restores disk and a loaded buffer while accepted/session/turn
  tree IDs remain unchanged; and
- every transition leaves the real index tree unchanged.

- [ ] **Step 6: Run transition tests and confirm RED**

Run: `make test`

Expected: first failure identifies missing `accept_file` or `view`.

- [ ] **Step 7: Implement scoped views and baseline transitions**

`view(scope)` snapshots once, selects the documented base tree, calls
`git:changed_files(base, current)`, and returns the exact view shape.
`accept_file` snapshots current and copies only the selected entry into
accepted. `accept_text` writes exact data and uses the accepted entry mode,
falling back to the current entry mode for a new path. `accept_all` assigns one
fresh current snapshot. `reject_file` calls `git:restore_path`, then runs
`checktime` for a loaded path buffer.

`status()` returns a data table rather than notifying:

```lua
{
  cwd = current.cwd,
  git_root = current.git_root,
  available = current.available,
  turn_number = current.turn_number,
  pending_files = #files,
  pending_hunks = total_hunks,
}
```

This keeps command/UI formatting out of the state machine.

- [ ] **Step 8: Run Task 4 tests and commit**

Run: `make test`

Expected: all checkpoint transitions and real-index assertions pass.

Run: `git diff --check`

Commit:

```bash
git add tests/checkpoint_spec.lua tests/run.lua lua/pi/checkpoint.lua
git commit -m "feat: track session accepted and turn trees"
```

---

### Task 5: Tracked Prompt Submission and Manual Checkpoint

**Files:**
- Create: `tests/init_spec.lua`
- Modify: `tests/run.lua`
- Modify: `lua/pi/init.lua`

**Interfaces:**
- Consumes: `pi.project`, `pi.checkpoint`, and cwd-aware `pi.terminal`.
- Produces: `pi._submit(text, { submit?: boolean }): boolean` as a documented
  internal orchestration function used by every public prompt path.
- Produces: public `pi.checkpoint(): boolean`.

- [ ] **Step 1: Write failing tracked-send tests**

Append `init_spec`. Use a real temporary repository and real loaded buffer;
replace only `pi.terminal` with a boundary fake that records submitted text and
cwd. Register:

```lua
H.test("submitted prompt saves buffers before capturing turn baseline", function()
  local root = H.repo()
  local buf = vim.fn.bufadd(root .. "/tracked.txt")
  vim.fn.bufload(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "buffer-before-prompt" })
  local sent
  package.loaded["pi.terminal"] = {
    send = function(text, opts)
      sent = { text = text, opts = opts }
    end,
  }
  package.loaded["pi.checkpoint"] = nil
  package.loaded.pi = nil
  require("pi.config").setup({ project = { cwd = root } })
  local pi = require("pi")
  H.eq(true, pi._submit("change it", { submit = true }))
  H.eq("buffer-before-prompt", H.read(root .. "/tracked.txt"))
  local state = require("pi.checkpoint").state()
  H.eq("buffer-before-prompt", state.git:read_file(state.turn_base_tree, "tracked.txt").data)
  H.eq(root, sent.opts.cwd)
end)
```

Add tests proving:

- `submit = false` sends text but leaves `turn_number` unchanged;
- an autosave failure returns false and does not call the terminal boundary;
- a non-Git submitted prompt still calls the terminal and does not invent tree
  IDs;
- two submitted prompts replace the turn tree while preserving session and
  accepted trees;
- `ask`, `prompt`, picker selection, and submitted operator flow all reach
  `_submit` exactly once; and
- `send_context` reaches `_submit` with `submit = false`.

- [ ] **Step 2: Run tracked-send tests and confirm RED**

Run: `make test`

Expected: `pi._submit` is nil and no turn baseline is captured.

- [ ] **Step 3: Implement one tracked submission path**

Implement `_submit` in this order:

```lua
local cwd = project.resolve_cwd()
local submit = opts.submit ~= false
if submit and config.opts.review.save_before_prompt then
  local git_root = require("pi.review.git").discover_root(cwd)
  local ok, err = project.save_modified(git_root or cwd)
  if not ok then
    vim.notify("Pi: " .. err, vim.log.levels.ERROR)
    return false
  end
end
if submit and config.opts.review.enabled then
  local _, err = checkpoint.start_turn(cwd)
  if err then
    vim.notify("Pi: checkpoint failed: " .. err.message, vim.log.levels.ERROR)
    return false
  end
end
terminal.send(text, { submit = submit, cwd = cwd })
return true
```

Notify once per non-Git state that review tracking is unavailable, but treat it
as non-fatal. Route every existing submitted prompt call through `_submit`.
Respect a named prompt's configured `submit` value unless the caller explicitly
provides `opts.submit`. Preserve cancelled input behavior.

- [ ] **Step 4: Implement manual checkpoint with the same save boundary**

`pi.checkpoint()` resolves cwd, saves modified buffers when configured, calls
`checkpoint.start_turn`, and reports either `Pi: checkpoint N captured`,
`Pi: review requires a Git worktree`, or the operational error. It does not
send terminal input.

Change `toggle` and auto-start to pass the resolved cwd to terminal operations.
On a terminal cwd mismatch, call `terminal.stop()` and `checkpoint.reset()`
before opening the new cwd. Ensure the new session before opening when review
is enabled so direct TUI edits have a session baseline.

- [ ] **Step 5: Run Task 5 tests and commit**

Run: `make test`

Expected: tracked, untracked, non-Git, failure, and repeated-prompt tests pass.

Run: `git diff --check`

Commit:

```bash
git add tests/init_spec.lua tests/run.lua lua/pi/init.lua
git commit -m "feat: checkpoint submitted Pi prompts"
```

---

### Task 6: Native Hunk and File Actions

**Files:**
- Create: `tests/actions_spec.lua`
- Modify: `tests/run.lua`
- Create: `lua/pi/review/actions.lua`

**Interfaces:**
- Consumes: review context `{ scope, path, base_buf, work_buf, base_win,
  work_win, base_present, work_present }` and `pi.checkpoint`.
- Produces: `accept_hunk(ctx)`, `reject_hunk(ctx)`, `accept_file(ctx)`,
  `reject_file(ctx)`, and `accept_all(ctx)` returning `boolean, string|nil`.

- [ ] **Step 1: Write failing two-hunk native diff tests**

Append `actions_spec`. Build a real checkpoint session, then edit lines 2 and
20 so Git/Neovim produce two separate hunks. Open two scratch/file buffers in
vertical splits, enable `diffthis`, and put the working cursor on the first
hunk. Register:

```lua
local ok, err = actions.accept_hunk(ctx)
H.eq(true, ok)
H.eq(nil, err)
local accepted = checkpoint.state().git:read_file(checkpoint.state().accepted_tree, "tracked.txt").data
H.truthy(accepted:find("accepted-first-change", 1, true))
H.truthy(accepted:find("old-second-line", 1, true))
H.truthy(H.read(root .. "/tracked.txt"):find("pending-second-change", 1, true))
```

Add the inverse rejection test: `reject_hunk` restores only the first working
hunk, writes the file, leaves the second worktree hunk, and does not change
`accepted_tree`.

- [ ] **Step 2: Run native hunk specs and confirm RED**

Run: `make test`

Expected: `module 'pi.review.actions' not found`.

- [ ] **Step 3: Implement exact buffer serialization and native hunk actions**

Serialize a buffer as lines joined by `\n`, plus a trailing `\n` only when
`vim.bo[buf].endofline` is true. Accept from the working window with
`vim.cmd.diffput()` and call `checkpoint.accept_text(path, serialized_base)`.
Reject into the working window with `vim.cmd.diffget()` and save it using a
silent `:update`. Wrap each native diff command in `nvim_win_call` and return a
concise error when the cursor is not on a change.

If the view scope is not `pending`, return
`false, "turn and session reviews are read-only"` before any mutation.

- [ ] **Step 4: Run native hunk specs and confirm GREEN**

Run: `make test`

Expected: both two-hunk tests pass.

- [ ] **Step 5: Write failing file/all action tests**

Register direct behavior tests for:

- accepting one file while another remains pending;
- rejecting a tracked file and refreshing its loaded buffer;
- accepting a new file then proving reject no longer removes it;
- rejecting a new file before acceptance removes only that exact file;
- accepting a deletion removes the accepted entry;
- accepting/rejecting a symlink preserves its link target;
- accepting a Gitlink copies its tree entry and rejecting an initialized clean
  Gitlink checks out the accepted object;
- accept all leaves turn/session IDs unchanged; and
- every action rejects an audit scope.

- [ ] **Step 6: Run file-action specs and confirm RED**

Run: `make test`

Expected: failures identify missing action delegations.

- [ ] **Step 7: Implement file/all action delegation**

Call the matching checkpoint transition, preserve the review context on error,
and return success to the caller so the UI can refresh. Do not place UI
notifications in this module.

For hunk operations on absent sides, use `base_present` and `work_present`: when
accepting the final deletion hunk, call `checkpoint.accept_file(path)` so the
tree entry is removed; when rejecting the final creation hunk, call
`checkpoint.reject_file(path)` so the file is removed rather than saved empty.

- [ ] **Step 8: Run Task 6 tests and commit**

Run: `make test`

Expected: all hunk/file/all and read-only guard tests pass.

Run: `git diff --check`

Commit:

```bash
git add tests/actions_spec.lua tests/run.lua lua/pi/review/actions.lua
git commit -m "feat: accept and reject review changes"
```

---

### Task 7: Review Picker, Diff Tab, Keymaps, and Teardown

**Files:**
- Create: `tests/review_spec.lua`
- Modify: `tests/run.lua`
- Create: `lua/pi/review.lua`
- Modify: `lua/pi/init.lua`

**Interfaces:**
- Consumes: `checkpoint.view(scope)` and `pi.review.actions`.
- Produces: `review.open(scope)`, `close()`, `refresh()`, `current()`,
  `accept(target)`, and `reject(target)`.
- Produces public `pi.review(scope)`, `pi.accept(target)`, and
  `pi.reject(target)` wrappers.

- [ ] **Step 1: Write failing picker and native diff tests**

Append `review_spec`. Replace only `vim.ui.select` during the test to choose the
first real changed-file item, then restore it. Against a real checkpoint view,
assert:

```lua
local initial_tab = vim.api.nvim_get_current_tabpage()
H.eq(true, review.open("pending"))
local current = review.current()
H.eq("pending", current.scope)
H.eq(true, vim.wo[current.base_win].diff)
H.eq(true, vim.wo[current.work_win].diff)
H.eq("nofile", vim.bo[current.base_buf].buftype)
H.eq(root .. "/tracked.txt", vim.api.nvim_buf_get_name(current.work_buf))
H.truthy(vim.fn.maparg("a", "n", false, true).buffer == 1)
review.close()
H.eq(initial_tab, vim.api.nvim_get_current_tabpage())
```

Add tests that an audit view has `q` but no `a/r/A/R`, no-change review returns
false without creating a tab, and `review.close()` leaves an unrelated
terminal-like buffer/window valid.

- [ ] **Step 2: Run review UI specs and confirm RED**

Run: `make test`

Expected: `module 'pi.review' not found`.

- [ ] **Step 3: Implement the changed-file picker and dedicated tab**

Format picker labels as:

```text
M tracked.txt  +1 -1
A binary.dat   binary
```

Call `vim.ui.select(view.files, { prompt = "Pi pending review", format_item =
... }, callback)`. On selection, create a new tab, populate the accepted/base
scratch buffer from `git:read_file(base_tree, path)`, load the real working file
buffer, split vertically, assign descriptive buffer names, and run `diffthis`
in each window. Set `modifiable = false` on audit buffers and leave the pending
base buffer modifiable only for action execution.

Store one current context table. `close()` must run `diffoff` in both valid
windows, delete only scratch buffers, close only the review tab, clear context,
and return focus to the tab that opened review when it remains valid.

For binary/symlink/Gitlink/type changes, set `text_actions = false`; show the
file with a short scratch explanation and expose file-level actions. Surface
the Git engine's clean/initialized safety error if a Gitlink cannot be
rejected.

- [ ] **Step 4: Implement local mappings and refresh**

On both review buffers, map configured `close` to `review.close`. Keep native
`]c` and `[c` available. In pending text views map `accept_hunk` and
`reject_hunk`; in all supported pending views map file actions. Do not map
mutations in audit views.

After a successful action, call `checkpoint.view("pending")`. If the selected
path remains, rebuild both buffers and `diffupdate`; if it disappeared but
other files remain, close the file view and reopen the picker; if no pending
files remain, close review and notify `Pi: no pending changes`.

- [ ] **Step 5: Run picker/diff/mapping specs and confirm GREEN**

Run: `make test`

Expected: picker, pending, audit, empty, and teardown tests pass.

- [ ] **Step 6: Write failing public wrapper tests**

Call `require("pi").review("turn")`, `accept("hunk")`,
`reject("file")`, and invalid targets. Assert wrappers return booleans and
invalid targets notify without mutating checkpoint state.

- [ ] **Step 7: Implement public review wrappers and commit**

Run: `make test`

Expected: all Task 7 tests pass.

Run: `git diff --check`

Commit:

```bash
git add tests/review_spec.lua tests/run.lua lua/pi/review.lua lua/pi/init.lua
git commit -m "feat: add native Neovim review UI"
```

---

### Task 8: Commands, Status, Cleanup, Health, and Documentation

**Files:**
- Create: `tests/commands_spec.lua`
- Modify: `tests/run.lua`
- Modify: `plugin/pi.lua`
- Modify: `lua/pi/init.lua`
- Modify: `lua/pi/health.lua`
- Modify: `README.md`
- Modify: `doc/pi.txt`

**Interfaces:**
- Produces exact command grammar documented in the spec.
- Produces `pi.status(): table|nil` plus one concise user notification.

- [ ] **Step 1: Write failing command parsing and completion tests**

Append `commands_spec`. Reset `vim.g.loaded_pi`, source `plugin/pi.lua`, and
stub only public `pi` functions while recording boundary calls. Test every
grammar branch:

```text
:Pi review
:Pi review turn
:Pi review session
:Pi checkpoint
:Pi accept hunk
:Pi accept file
:Pi accept all
:Pi reject hunk
:Pi reject file
:Pi status
```

Assert `:Pi reject all`, `:Pi review other`, missing action targets, and unknown
subcommands notify a warning and never become prompt text. Call the command's
completion callback and assert literal candidate lists for each argument
position.

- [ ] **Step 2: Run command specs and confirm RED**

Run: `make test`

Expected: `review` and action subcommands are treated as arbitrary prompts.

- [ ] **Step 3: Implement strict command dispatch and completion**

Keep the existing toggle/ask/prompt/select/abort branches. Add explicit
branches for all new commands and validate argument counts/scopes/targets.
Replace the unknown-subcommand prompt fallback with:

```lua
vim.notify("Pi: unknown subcommand '" .. subcmd .. "'", vim.log.levels.WARN)
```

Completion candidates must be:

```lua
local subcmds = { "toggle", "ask", "prompt", "select", "abort", "checkpoint", "review", "accept", "reject", "status" }
local review_scopes = { "turn", "session" }
local accept_targets = { "hunk", "file", "all" }
local reject_targets = { "hunk", "file" }
```

- [ ] **Step 4: Write failing status and cleanup tests**

Assert `pi.status()` formats both states:

```text
Pi: /repo — turn 2, 3 pending files, 5 hunks
Pi: /plain — review unavailable (not a Git worktree)
```

Trigger the `VimLeavePre` callback directly and assert it calls
`review.close()`, `terminal.stop()`, and `checkpoint.cleanup()` safely even
when no terminal or review is open.

- [ ] **Step 5: Implement status and complete cleanup**

`pi.status()` ensures the current cwd state, gets the checkpoint data table,
chooses singular/plural nouns, notifies, and returns the table. Update the
existing cleanup autocmd to call all three cleanup functions through `pcall`.

- [ ] **Step 6: Extend health output**

Resolve cwd through `pi.project`, report the path, check `git` is executable,
and call `pi.review.git.discover_root`. Report the Git root when review is
enabled, an informational non-Git message when Pi can still run, and an error
only for an operational Git failure. Preserve existing Pi CLI, Snacks, setup,
and terminal-size checks.

- [ ] **Step 7: Update README and Vim help**

Document:

- the three trees and their exact comparison scopes;
- automatic save/checkpoint ordering;
- direct TUI prompts requiring `:Pi checkpoint` for turn attribution;
- every command and review-local mapping;
- fixed versus dynamic cwd and project-switch restart behavior;
- non-Git and ignored-file limitations;
- temporary-index/real-index safety; and
- the new configuration defaults.

Add help tags for `:Pi-review`, `:Pi-checkpoint`, `:Pi-accept`, `:Pi-reject`,
`:Pi-status`, `pi-review`, `pi-checkpoint`, and `pi-review-keymaps`. Run
`nvim --headless --clean -u NONE -c "helptags doc" -c "qa"` and include any
generated `doc/tags` only if the upstream repository already tracks it; it does
not currently, so leave it untracked/removed after validating tags.

- [ ] **Step 8: Run Task 8 tests and commit**

Run: `make test`

Expected: all test files pass with zero warnings or leaked windows/jobs.

Run: `nvim --headless --clean -u NONE -c "set rtp^=." -c "runtime plugin/pi.lua" -c "checkhealth pi" -c "qa"`

Expected: health runs without Lua errors and reports the Pi CLI and current
project state.

Run: `git diff --check`

Commit:

```bash
git add tests/commands_spec.lua tests/run.lua plugin/pi.lua lua/pi/init.lua lua/pi/health.lua README.md doc/pi.txt
git commit -m "feat: expose Pi review commands and docs"
```

---

### Task 9: End-to-end Index-safety Smoke Test and Final Verification

**Files:**
- Create: `tests/smoke.lua`
- Modify: `README.md` only if the verified invocation differs from its current test instructions.

**Interfaces:**
- Consumes the public plugin API and real Git/Neovim processes.
- Produces a repeatable `make smoke` acceptance check.

- [ ] **Step 1: Write the smoke test before changing production code**

Create `tests/smoke.lua` using `tests.helpers` and public modules only. It must:

1. Create a disposable repository and commit two text files.
2. Stage a third file in the real index and save `git write-tree` as
   `index_before`.
3. Add pre-existing tracked/untracked worktree changes.
4. Configure `project.cwd` to the repository and ensure the session.
5. Capture a manual checkpoint.
6. Edit the same file twice across two turn checkpoints.
7. Accept one file, reject another, then accept all remaining pending changes.
8. Assert pending file count is zero while session audit remains non-empty.
9. Assert `git write-tree` still equals `index_before`.
10. Clean plugin state and the disposable directory, print
    `pi.nvim smoke: PASS`, and exit zero.

- [ ] **Step 2: Run the smoke test and confirm it detects index mutation**

Temporarily run the smoke test with its final real-index assertion changed to a
known wrong literal such as `H.eq("wrong", index_after)`. Run `make smoke` and
confirm it exits nonzero at that assertion. Restore the correct assertion
before continuing.

- [ ] **Step 3: Run the complete fresh verification set**

Run all commands from the repository root:

```bash
make test
make smoke
nvim --headless --clean -u NONE -c "set rtp^=." -c "runtime plugin/pi.lua" -c "lua require('pi').setup()" -c "qa"
nvim --headless --clean -u NONE -c "set rtp^=." -c "helptags doc" -c "qa"
git diff --check
git status --short
```

Expected:

- the full suite reports zero failures;
- smoke prints `pi.nvim smoke: PASS`;
- plugin setup exits without Lua errors;
- helptags exits without duplicate-tag errors;
- whitespace check exits zero; and
- status contains only the intended smoke test and any deliberate README test
  command adjustment.

- [ ] **Step 4: Re-read the design success criteria against implementation**

For each success criterion in
`docs/superpowers/specs/2026-09-02-pi-review-design.md`, identify the automated
test or fresh command output that proves it. Add a missing regression test
before claiming completion if any criterion lacks evidence.

- [ ] **Step 5: Commit the smoke test**

```bash
git add tests/smoke.lua README.md
git commit -m "test: verify Pi review index isolation"
```

- [ ] **Step 6: Request independent code review**

Use `superpowers:requesting-code-review` with:

- description: embedded Pi TUI with explicit cwd and three-baseline Git-tree
  review;
- requirements: this implementation plan and its design spec;
- base SHA: `b13e47d1d49d08c67c075556f46cb0d73625260f`;
- head SHA: the current `git rev-parse HEAD`.

Fix every Critical and Important finding through a new failing regression test,
rerun the complete verification set, and commit the fixes before handoff.

- [ ] **Step 7: Run one final verification after review fixes**

Run:

```bash
make test
make smoke
git diff --check
git status --short --branch
git log --oneline --decorate -10
```

Only after reading the complete output and confirming zero failures may the
implementation be reported complete.
