# pi.nvim

`pi.nvim` connects the [Pi coding agent](https://github.com/earendil-works/pi)
to Neovim through
[CodeCompanion.nvim](https://github.com/olimorris/codecompanion.nvim),
[codecompanion-ui.nvim](https://github.com/mrjones2014/codecompanion-ui.nvim),
[pi-acp](https://github.com/svkozak/pi-acp), and
[mini.diff](https://github.com/nvim-mini/mini.diff).

CodeCompanion owns chat, streaming, tool display, sessions, models, and editor
context. codecompanion-ui provides the native editable composer. pi-acp bridges
the Agent Client Protocol (ACP) to Pi's RPC mode. pi.nvim adds the Pi-specific
glue: project-scoped chat reuse, safe pre-submit checkpoints, and an
accepted-tree review workflow.

There is no embedded-terminal frontend or fallback.

## Features

- One reusable Pi chat per normalized project directory.
- Full-screen chat: the chat and composer always open across the whole editor; there is no side-column layout.
- A composer winbar chip showing the current Pi thinking level instead of
  codecompanion-ui's always-"Default" mode chip (`codecompanion.thinking_winbar`).
- A normal Neovim composer with motions, operators, registers, undo, paste,
  completion, and user mappings.
- CodeCompanion context for buffers, selections, diagnostics, quickfix lists,
  viewports, and Git diffs.
- Pi model and thinking-level selection through CodeCompanion's ACP controls.
- Automatic buffer saving and Git-tree checkpointing before every Pi prompt.
- Pending, latest-turn, and whole-session review scopes.
- Inline MiniDiff overlays with hunk navigation and accept/reject actions.
- Private acceptance state that never stages files or changes the real Git
  index.
- Independent chat and checkpoint state for multiple projects in one Neovim
  instance.
- Health checks, command completion, configurable prompts, and configurable
  global and review-local mappings.

## Contents

- [Architecture](#architecture)
- [Requirements](#requirements)
- [Installation](#installation)
- [Quick start](#quick-start)
- [Chat and project lifecycle](#chat-and-project-lifecycle)
- [Editor context](#editor-context)
- [Named prompts](#named-prompts)
- [Checkpoints](#checkpoints)
- [Review workflow](#review-workflow)
- [Git safety model](#git-safety-model)
- [Commands](#commands)
- [Keymaps](#keymaps)
- [Configuration reference](#configuration-reference)
- [Lua API](#lua-api)
- [Health and troubleshooting](#health-and-troubleshooting)
- [Limitations](#limitations)
- [Development](#development)

## Architecture

```text
codecompanion-ui composer
          |
          v
CodeCompanion chat and context
          |
          v  ACP
        pi-acp
          |
          v  RPC
          Pi

pi.nvim lifecycle
  |-- associates a chat with a project
  |-- saves buffers and snapshots the worktree before submission
  `-- supplies accepted-tree reference text to mini.diff
```

| Component | Responsibility |
| --- | --- |
| CodeCompanion.nvim | Chat buffers, messages, streaming, tools, sessions, context, adapter lifecycle, and model controls |
| codecompanion-ui.nvim | Split layout and editable input composer |
| pi-acp | ACP server and translation to `pi --mode rpc` |
| Pi | Agent loop, providers, models, credentials, tools, and session execution |
| mini.diff | Diff calculation, hunk coordinates, navigation, signs, and overlay rendering |
| pi.nvim | Adapter factory, project association, prompt lifecycle, Git-tree baselines, and acceptance semantics |

pi.nvim deliberately does not duplicate an ACP client, Pi RPC client, chat UI,
model picker, context engine, or diff algorithm.

## Requirements

- Neovim 0.11 or newer.
- Node.js 22 or newer.
- Pi 0.80.4 or newer.
- pi-acp 0.0.33 or newer.
- Git available as `git` in `PATH` for checkpoint and review support.
- [`pi`](https://github.com/earendil-works/pi) and
  [`pi-acp`](https://github.com/svkozak/pi-acp) in `PATH`, unless an explicit
  pi-acp command is configured.
- [`olimorris/codecompanion.nvim`](https://github.com/olimorris/codecompanion.nvim).
- [`mrjones2014/codecompanion-ui.nvim`](https://github.com/mrjones2014/codecompanion-ui.nvim).
- [`nvim-mini/mini.diff`](https://github.com/nvim-mini/mini.diff), or the
  `mini.diff` module from `nvim-mini/mini.nvim`.

Install the external processes with npm:

```sh
npm install -g @earendil-works/pi-coding-agent pi-acp
```

Configure Pi's provider credentials separately. A quick installation check is:

```sh
pi --version
pi --list-models
command -v pi-acp
```

pi.nvim never reads or stores provider credentials.

## Installation

### lazy.nvim

The complete setup has three parts: enable codecompanion-ui, register the Pi
ACP adapter, and initialize MiniDiff.

```lua
{
  "olimorris/codecompanion.nvim",
  dependencies = {
    "nvim-lua/plenary.nvim",
    "mrjones2014/codecompanion-ui.nvim",
  },
  opts = {
    adapters = {
      acp = {
        pi = function()
          return require("pi.codecompanion").adapter()
        end,
      },
    },
    extensions = {
      ui = {
        enabled = true,
        opts = {
          input = { height = 5 },
          chat = { width = 0.4 },
        },
      },
    },
  },
},
{
  "EdwardAstill/pi.nvim",
  dependencies = {
    "olimorris/codecompanion.nvim",
    "mrjones2014/codecompanion-ui.nvim",
    {
      "nvim-mini/mini.diff",
      version = false,
      config = function()
        require("mini.diff").setup()
      end,
    },
  },
  opts = {},
}
```

The standalone MiniDiff repository may use `version = "*"` instead if you
prefer its stable branch. If `mini.diff` is already initialized elsewhere, keep
your existing setup and list it as a plain dependency.

`render-markdown.nvim` can be configured for CodeCompanion chat buffers, but
pi.nvim does not require it.

### Manual setup

With another package manager, load all dependencies and then run:

```lua
require("mini.diff").setup()

require("codecompanion").setup({
  adapters = {
    acp = {
      pi = function()
        return require("pi.codecompanion").adapter()
      end,
    },
  },
  extensions = {
    ui = { enabled = true },
  },
})

require("pi").setup()
```

After installation, run `:checkhealth pi` and see `:help pi` for the Vim help
page.

## Quick start

1. Open Neovim in a project directory.
2. Run `:Pi` or press `<leader>pt` to open the project chat.
3. Write a request in the composer and submit it using codecompanion-ui's
   normal submit mapping.
4. Use `:Pi model`, `:Pi model <model-id>`, `:Pi thinking`, or `:Pi thinking <level>` to change the active ACP session settings.
5. After Pi edits files, run `:Pi review`.
6. Pick a file, navigate with `[h` and `]h`, then accept or reject hunks with
   `a` and `r`.
7. Press `q` to leave the review. Run `:Pi stop` when the project chat and ACP
   process are no longer needed.

For a context-first prompt, select text visually and press `<leader>pa`. The
selection is captured before focus moves to the composer.

## Chat and project lifecycle

### Project identity

By default, the project identity is the normalized value of `vim.fn.getcwd()`
when an operation begins. Set `project.cwd` to pin the integration to one
directory:

```lua
require("pi").setup({
  project = { cwd = "/absolute/path/to/project" },
})
```

The project directory is the Pi process working directory and the key used to
reuse a chat. It may be a subdirectory of a Git worktree; checkpointing finds
the containing Git root separately.

Each project gets an independent preferred Pi chat and checkpoint state. A
hidden chat buffer is restored rather than recreated. A closed or invalid chat
is replaced the next time it is requested.

### Hide, abort, and stop

These operations have intentionally different effects:

| Operation | Effect |
| --- | --- |
| `:Pi` / `:Pi toggle` | Show or hide the UI; preserve the chat, draft, and ACP process |
| `:Pi focus` | Restore the UI if needed and focus the composer |
| `:Pi abort` | Stop the active generation; keep the chat and process |
| `:Pi stop` | Close the project chat and its ACP process, then release its checkpoint state |

When Pi completes a request successfully, loaded project buffers are checked
for external changes and active review overlays are refreshed.

## Editor context

CodeCompanion's `#{...}` syntax is canonical:

| Reference | Meaning |
| --- | --- |
| `#{selection}` | Captured visual selection |
| `#{buffer}` | Current/source buffer |
| `#{buffers}` | Available buffers |
| `#{viewport}` | Visible portion of the source window |
| `#{diagnostics}` | Neovim diagnostics |
| `#{quickfix}` | Quickfix list |
| `#{diff}` | Git diff context |

`<leader>pa` captures context before opening the composer, so a visual
selection remains valid after the input window receives focus. `<leader>pp`
adds `#{selection}` or `#{buffer}` to the composer without submitting it.

For compatibility, pi.nvim currently translates the older prompt tokens:

| Legacy token | CodeCompanion reference |
| --- | --- |
| `@this` | `#{selection}` for a visual selection, otherwise `#{buffer}` |
| `@buffer` | `#{buffer}` |
| `@buffers` | `#{buffers}` |
| `@visible` | `#{viewport}` |
| `@diagnostics` | `#{diagnostics}` |
| `@quickfix` | `#{quickfix}` |
| `@diff` | `#{diff}` |

Set `compatibility.legacy_context_tokens = false` to disable translation. The
default named prompts still contain legacy tokens, so replace or remove those
prompts when disabling compatibility.

## Named prompts

`:Pi prompt <name>` resolves configured prompt names before treating its
argument as literal text. A prompt with `submit = true` is sent immediately;
`submit = false` opens it as an editable composer draft.

The defaults are:

| Name | Text | Submit? |
| --- | --- | --- |
| `explain` | `Explain @this and its context` | yes |
| `review` | `Review @this for correctness and readability` | yes |
| `fix` | `Fix @diagnostics` | yes |
| `test` | `Add tests for @this` | yes |
| `document` | `Add documentation comments to @this` | yes |
| `optimize` | `Optimize @this for performance and readability` | yes |
| `implement` | `Implement @this` | yes |
| `diff` | `Review the following git diff for correctness and readability: @diff` | yes |

Add a prompt or remove a default with `false`:

```lua
require("pi").setup({
  prompts = {
    plan = {
      text = "Plan a minimal change for @this",
      submit = false,
    },
    optimize = false,
  },
})
```

`:Pi select` shows configured prompts together with the abort and toggle
controls. Any unrecognized `:Pi` subcommand is treated as literal prompt text,
so `:Pi explain this function` sends `explain this function` directly.

## Checkpoints

Immediately before CodeCompanion submits any managed Pi prompt, pi.nvim
synchronously:

1. saves modified normal file buffers inside the project boundary;
2. snapshots the current Git worktree into `turn_base_tree`;
3. allows submission only when required saving and snapshot operations succeed.

If saving or checkpointing throws or fails, submission is cancelled. When the
composer is provided by codecompanion-ui, its exact draft is restored so it can
be corrected and retried.

The first snapshot for a project initializes three concepts:

| Baseline | Purpose | Changes over time? |
| --- | --- | --- |
| `session_start_tree` | Worktree state when checkpoint tracking began | No |
| `accepted_tree` | State the user has accepted | Yes, on accept actions |
| `turn_base_tree` | Worktree state immediately before the latest submitted prompt or manual checkpoint | Replaced each turn |

The first snapshot includes changes that existed before Pi started. This is
important: pre-existing work is not silently treated as agent-authored, and it
remains represented in the session and accepted baselines.

`:Pi checkpoint` saves buffers and captures a manual latest-turn baseline.
Automatic checkpoints increment the same turn counter.

Outside a Git worktree, Pi chat and prompting continue to work, but checkpoint
review is unavailable.

## Review workflow

### Scopes

| Command | Comparison | Mutable? | Typical use |
| --- | --- | --- | --- |
| `:Pi review` | `accepted_tree` to current worktree | Yes | Decide what to keep or undo |
| `:Pi review turn` | latest `turn_base_tree` to current worktree | No | Audit the latest agent turn |
| `:Pi review session` | `session_start_tree` to current worktree | No | Audit the whole Pi session |

The review opens a `vim.ui.select` file picker. Supported text files open in a
normal editing window and attach MiniDiff to the real file buffer. With
`review.overlay = true`, deleted/reference text is shown as virtual lines and
the current buffer is highlighted inline.

### Actions

- Accepting a hunk advances only that path's content in `accepted_tree`.
- Accepting a file copies the entire current worktree path into
  `accepted_tree`.
- Accepting all replaces `accepted_tree` with a fresh worktree snapshot.
- Rejecting a hunk restores that hunk's accepted text into the buffer and
  writes the file.
- Rejecting a file restores the whole accepted path to disk. It can recreate,
  replace, or remove the worktree path.
- Turn and session reviews expose navigation and close actions only.

Rejecting is the destructive direction: it changes the worktree. If a loaded
file has unsaved changes, file rejection asks for confirmation first. Accepting
does not modify the worktree.

Deleted files, binary files, symbolic links, submodules, and unsupported Git
file modes use file-level actions only; they do not receive text-hunk mappings.
A submodule must be initialized and clean before pi.nvim will replace or remove
its worktree during rejection.

### Diff colors

pi.nvim does not impose a colorscheme. MiniDiff uses these highlight groups,
which should be defined or linked by the active theme:

- `MiniDiffSignAdd`, `MiniDiffSignChange`, and `MiniDiffSignDelete` for signs
  or line numbers.
- `MiniDiffOverAdd` and `MiniDiffOverDelete` for pure additions and deletions.
- `MiniDiffOverChange` and `MiniDiffOverContext` for reference/deleted parts
  of replacements.
- `MiniDiffOverChangeBuf` and `MiniDiffOverContextBuf` for buffer/added parts
  of replacements.

Inspect the resolved definitions with `:highlight MiniDiffOverChange` and
`:highlight MiniDiffOverChangeBuf` if an overlay appears neutral or invisible.

## Git safety model

pi.nvim snapshots and updates trees using a plugin-owned temporary Git index.
Every index-mutating Git command receives an explicit `GIT_INDEX_FILE`; the
real index is never used for checkpoint operations.

The review engine:

- initializes the temporary index from `HEAD`, or an empty tree in an unborn
  repository;
- adds the worktree through that temporary index and writes a tree object;
- includes tracked edits, deletions, and non-ignored untracked files;
- follows normal Git ignore rules;
- disables rename detection so actions always target explicit paths;
- validates relative paths and refuses traversal or symlinked-parent escapes;
- never stages files, changes refs, creates commits, creates branches, or runs
  a checkout against the main worktree.

Writing snapshots creates normal blob/tree objects in the repository's Git
object database. They are not referenced by branches or tags and may later be
collected by normal Git garbage collection after the in-memory session ends.
Temporary index files are removed when a project chat closes and when Neovim
exits.

## Commands

| Command | Action |
| --- | --- |
| `:Pi` | Toggle the current project's Pi chat |
| `:Pi toggle` | Toggle the current project's Pi chat |
| `:Pi focus` | Restore the UI and focus the composer |
| `:Pi ask [text]` | Open an editable composer draft with optional text |
| `:Pi prompt <text-or-name>` | Submit literal text or resolve a configured prompt name |
| `:Pi select` | Select a named prompt or control action |
| `:Pi abort` | Abort the active Pi request without closing the chat |
| `:Pi model [model-id]` | Open CodeCompanion's model selector, or set a model directly for the connected ACP session |
| `:Pi thinking [level]` | Open CodeCompanion's ACP thinking-level selector, or set a thinking level directly |
| `:Pi checkpoint` | Save project buffers and capture a manual turn baseline |
| `:Pi review` | Open mutable pending review against `accepted_tree` |
| `:Pi review turn` | Open read-only latest-turn review |
| `:Pi review session` | Open read-only whole-session review |
| `:Pi accept hunk` | Accept the hunk under the cursor |
| `:Pi accept file` | Accept the selected review file |
| `:Pi accept all` | Accept every currently pending path |
| `:Pi reject hunk` | Restore the cursor hunk from accepted content |
| `:Pi reject file` | Restore the selected file from accepted content |
| `:Pi status` | Show project, turn number, pending file count, and pending hunk count |
| `:Pi stop` | Close the project chat and ACP process |

`:Pi review`, `:Pi accept`, `:Pi reject`, and `:Pi prompt` provide
command-line completion for their supported arguments.

## Keymaps

### Global defaults

| Mapping | Modes | Action |
| --- | --- | --- |
| `<leader>pt` | Normal | Toggle project chat |
| `<leader>pa` | Normal, Visual | Capture context and open `@this:` as a draft |
| `<leader>px` | Normal, Visual | Open the prompt/control selector |
| `<leader>pp` | Normal, Visual | Add buffer or selection context to the composer |
| `<leader>pq` | Normal | Abort the active request |

### Pending-review defaults

| Mapping | Action |
| --- | --- |
| `[h` | Previous hunk |
| `]h` | Next hunk |
| `a` | Accept hunk |
| `r` | Reject hunk |
| `A` | Accept file |
| `R` | Reject file |
| `q` | Close review |

Review mappings are buffer-local and are removed when review closes. If Pi
temporarily replaces an existing buffer mapping, it restores that mapping on
close unless the user replaced Pi's mapping in the meantime. Turn and session
reviews install only navigation and close mappings.

Set any configured global or review mapping to `false` to disable it.

## Configuration reference

The full default configuration is:

```lua
require("pi").setup({
  codecompanion = {
    adapter = "pi",
    command = { "pi-acp" },
    -- timeout = 30000, -- ACP timeout in milliseconds
    -- Without a global pi-acp installation:
    -- command = { "npx", "-y", "pi-acp" },
    -- thinking_winbar = true, -- thinking level chip in the composer winbar
  },

  compatibility = {
    legacy_context_tokens = true,
  },

  prompts = {
    explain = { text = "Explain @this and its context", submit = true },
    review = { text = "Review @this for correctness and readability", submit = true },
    fix = { text = "Fix @diagnostics", submit = true },
    test = { text = "Add tests for @this", submit = true },
    document = { text = "Add documentation comments to @this", submit = true },
    optimize = { text = "Optimize @this for performance and readability", submit = true },
    implement = { text = "Implement @this", submit = true },
    diff = {
      text = "Review the following git diff for correctness and readability: @diff",
      submit = true,
    },
  },

  project = {
    cwd = nil, -- Use vim.fn.getcwd() dynamically
  },

  review = {
    enabled = true,
    save_before_prompt = true, -- Required invariant; false is rejected
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

  keymaps = {
    toggle = "<leader>pt",
    ask = "<leader>pa",
    select = "<leader>px",
    prompt_this = "<leader>pp",
    abort = "<leader>pq",
    cycle_model = "<leader>pm",
    cycle_thinking = "<leader>pn",
  },

  events = {
    reload = true,
  },
})
```

### Option details

| Option | Meaning |
| --- | --- |
| `codecompanion.adapter` | Name used to resolve the registered CodeCompanion ACP adapter |
| `codecompanion.command` | Non-empty argv list used to start pi-acp; shell strings are not accepted |
| `codecompanion.timeout` | Optional ACP request timeout forwarded to the adapter; defaults to 30 seconds |
| `codecompanion.thinking_winbar` | Show the Pi thinking level at the top of the composer input instead of codecompanion-ui's mode chip, which always reads "Default" for Pi; default `true` |
| `keymaps` | Global Pi controls installed by `setup()`; `false` removes a mapping. Includes `toggle`, `ask`, `select`, `prompt_this`, `abort` (stop processing), `cycle_model`, and `cycle_thinking` |
| `compatibility.legacy_context_tokens` | Translate legacy `@...` tokens to CodeCompanion context references |
| `prompts` | Named `{ text, submit }` prompt definitions used by `:Pi prompt` and `:Pi select` |
| `project.cwd` | Fixed project directory, or dynamic Neovim cwd when `nil` |
| `review.enabled` | Enable review commands; pre-submit safety checkpointing still runs when false |
| `review.save_before_prompt` | Required to remain true so disk, checkpoint, and Pi receive the same content |
| `review.overlay` | Show MiniDiff's inline overlay during review; signs/navigation remain available when false |
| `review.keymaps` | Buffer-local pending-review controls |
| `keymaps` | Global Pi controls installed by `setup()` |
| `events.reload` | Run `:checktime` on `FocusGained` and `BufEnter` for externally changed files |

Passing the removed `terminal` configuration is an error. Configure
CodeCompanion and pi-acp instead. The removed `keymaps.fullscreen` mapping is
also an error; the chat always opens fullscreen and `toggle` shows or hides it.

## Lua API

All user-facing operations target the current resolved project and report
errors through `vim.notify`.

| Function | Return | Description |
| --- | --- | --- |
| `require("pi").setup(opts?)` | none | Validate configuration, install lifecycle hooks, and create configured mappings |
| `require("pi").toggle()` | boolean | Show or hide the project chat |
| `require("pi").focus()` | boolean | Restore and focus the composer |
| `require("pi").ask(text?, opts?)` | boolean | Open a draft; set `opts.submit = true` to submit it |
| `require("pi").prompt(text, opts?)` | boolean | Resolve a named prompt or submit literal text; `opts.submit = false` opens a draft |
| `require("pi").select()` | boolean | Open the prompt/control selector |
| `require("pi").abort()` | boolean | Abort the active request |
| `require("pi").model(model?)` | boolean | Open the ACP model picker, or set a model id directly |
| `require("pi").thinking(level?)` | boolean | Open the ACP thinking picker, or set a thinking level directly |
| `require("pi").send_context()` | boolean | Insert the current buffer/selection context token into the composer |
| `require("pi").checkpoint()` | boolean | Save and capture a manual turn checkpoint |
| `require("pi").review(scope?)` | boolean | Open `pending`, `turn`, or `session` review |
| `require("pi").accept(target)` | boolean | Accept `hunk`, `file`, or `all` |
| `require("pi").reject(target)` | boolean | Reject `hunk` or `file` |
| `require("pi").status()` | table or nil | Return and display project checkpoint status |
| `require("pi").stop()` | boolean | Close the project chat/process |
| `require("pi").operator(prefix, opts?)` | `"g@"` | Build a dot-repeatable operator that captures a motion as selection context |

`status()` returns:

```lua
{
  cwd = "/project",
  git_root = "/project", -- nil outside Git
  available = true,
  turn_number = 3,
  pending_files = 2,
  pending_hunks = 4,
}
```

Example dot-repeatable operator mapping:

```lua
vim.keymap.set("n", "<leader>po", function()
  return require("pi").operator("Review this selection: ")
end, { expr = true, desc = "Pi operator" })
```

The adapter factory used by CodeCompanion is also callable directly:

```lua
local adapter = require("pi.codecompanion").adapter({
  command = { "/custom/path/pi-acp" },
  timeout = 60000,
})
```

## Health and troubleshooting

Run:

```vim
:checkhealth pi
```

The report checks Neovim, `pi`, the configured pi-acp executable, `git`,
CodeCompanion, the codecompanion-ui extension, `mini.diff`, the resolved
project, its Git root, and whether `setup()` ran.

### The chat or composer does not open

- Confirm `olimorris/codecompanion.nvim` is installed.
- Confirm `mrjones2014/codecompanion-ui.nvim` is installed and its `ui`
  extension is enabled in CodeCompanion.
- Confirm the adapter is registered under the same name as
  `codecompanion.adapter` (the default is `pi`).
- Run `:messages` after the failure for the original error.

### pi-acp cannot start

- Run `command -v pi-acp` from the same environment that starts Neovim.
- If it is not global, set `command = { "npx", "-y", "pi-acp" }` or provide
  an absolute executable path.
- Remember that `codecompanion.command` is an argv list, not a shell command
  string.

### No model is shown, or model/thinking selection fails

- Open the Pi chat and allow its ACP connection to finish initializing before
  invoking the selector.
- Run `pi --list-models` to confirm Pi has at least one configured provider and
  model.
- The model label is rendered by codecompanion-ui and the selector is delegated
  to CodeCompanion; pi.nvim does not maintain a separate model setting.

### A prompt is cancelled before reaching Pi

Check `:messages`. pi.nvim cancels submission when a modified project buffer
cannot be saved or the Git snapshot fails. The composer draft is restored after
these failures.

### Review is unavailable

- Confirm the resolved project is inside a Git worktree.
- Submit a prompt or run `:Pi checkpoint` before asking for latest-turn review.
- Run `:Pi status` to inspect whether checkpointing is available and whether
  anything is pending.
- Deleted, binary, symlink, and submodule paths support file actions but not
  text-hunk actions.

### Diff signs appear but overlay colors do not

- Ensure `require("mini.diff").setup()` ran.
- Inspect `MiniDiffOverAdd`, `MiniDiffOverDelete`, `MiniDiffOverChange`,
  `MiniDiffOverChangeBuf`, `MiniDiffOverContext`, and
  `MiniDiffOverContextBuf` with `:highlight`.
- Configure those groups in your colorscheme if its standard `DiffAdd`,
  `DiffDelete`, `DiffChange`, and `DiffText` links do not distinguish both
  sides of a replacement.

### The wrong project is used

Check `:pwd`, window-local `:lcd`, and tab-local `:tcd` state. Set
`project.cwd` explicitly if the integration should remain pinned while the
editor cwd changes.

## Limitations

- Checkpoint state is in memory and is not restored across Neovim restarts.
- Only the latest `turn_base_tree` is retained; pending and session baselines
  provide the longer-lived views.
- Review requires Git. Chat and prompting do not.
- Ignored untracked files are absent from checkpoint snapshots by design.
- Rename detection is disabled; a rename appears as an explicit deletion and
  addition.
- pi.nvim reviews changes after they reach the worktree. It does not implement
  pre-write approval or intercept Pi's filesystem tools.
- Text-hunk actions apply only to ordinary text blobs. Other path types use
  file-level actions.
- A managed CodeCompanion chat can switch away from the Pi adapter, but it must
  start a fresh chat rather than switch the same managed chat back to Pi.
- Model and thinking pickers are feature-detected compatibility calls into
  CodeCompanion until it exposes stable public callable pickers. Direct
  `:Pi model <model-id>` and `:Pi thinking <level>` updates use ACP session
  configuration when the connected Pi session exposes those options.
- There is no terminal frontend, custom chat renderer, custom model picker, or
  non-CodeCompanion fallback.

## Development

Run the headless test suite:

```sh
make test
```

Run the adapter smoke check:

```sh
make smoke
```

The unit suite uses temporary Git repositories to verify snapshot, index,
path-safety, checkpoint, review, MiniDiff, lifecycle, command, and UI-bridge
behavior. `make smoke` verifies that the plugin loads, has no terminal fallback,
and produces the expected ACP adapter configuration.

## License

MIT. See [LICENSE](LICENSE) and [THIRD_PARTY.md](THIRD_PARTY.md) for integrated
projects and their licenses.
