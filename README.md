# pi.nvim

Pi-specific integration for [CodeCompanion.nvim](https://github.com/olimorris/codecompanion.nvim). CodeCompanion owns chat, streaming, tools, sessions, models, and editor context; [codecompanion-ui.nvim](https://github.com/mrjones2014/codecompanion-ui.nvim) provides the native composer; [pi-acp](https://github.com/svkozak/pi-acp) bridges ACP to Pi RPC. pi.nvim adds project-scoped checkpoints and change acceptance.

There is no embedded-terminal frontend or fallback.

## Requirements

- Neovim 0.11+
- Node.js 22+
- Pi 0.80.4+
- `git`
- [`pi`](https://github.com/earendil-works/pi) and [`pi-acp`](https://github.com/svkozak/pi-acp) in `PATH`
- [`olimorris/codecompanion.nvim`](https://github.com/olimorris/codecompanion.nvim)
- [`mrjones2014/codecompanion-ui.nvim`](https://github.com/mrjones2014/codecompanion-ui.nvim)
- [`nvim-mini/mini.diff`](https://github.com/nvim-mini/mini.diff)

Install the external processes with:

```sh
npm install -g @earendil-works/pi-coding-agent pi-acp
```

## Installation

Example for lazy.nvim:

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
    "nvim-mini/mini.diff",
  },
  opts = {},
}
```

`render-markdown.nvim` may be configured for CodeCompanion, but pi.nvim does not require it.

## Usage

`<leader>pt` opens or hides the project chat. Hiding it preserves the chat, composer draft, and ACP process. The composer is a normal editable codecompanion-ui buffer, so ordinary Vim motions, operators, registers, undo, paste, and user mappings work normally.

`<leader>pa` captures CodeCompanion editor context before changing windows and opens the composer. Visual selections are retained even if you switch windows before submitting. pi.nvim also translates its old prompt tokens to CodeCompanion context during one compatibility release:

| Old token | CodeCompanion context |
|---|---|
| `@this` | `#{selection}` for a visual selection, otherwise `#{buffer}` |
| `@buffer` | `#{buffer}` |
| `@buffers` | `#{buffers}` |
| `@visible` | `#{viewport}` |
| `@diagnostics` | `#{diagnostics}` |
| `@quickfix` | `#{quickfix}` |
| `@diff` | `#{diff}` |

CodeCompanion's `#{...}` syntax is canonical. Set `compatibility.legacy_context_tokens = false` to disable translation.

## Checkpoints and review

Immediately before CodeCompanion submits a Pi prompt, pi.nvim synchronously:

1. saves modified project buffers;
2. captures `turn_base_tree`;
3. allows submission only if both operations succeed.

If saving or checkpointing fails, submission is cancelled and the composer draft is restored. The first project snapshot initializes `session_start_tree` and mutable `accepted_tree`, including pre-existing worktree changes.

| Scope | Baseline | Mutable? |
|---|---|---|
| pending | `accepted_tree` | yes |
| turn | `turn_base_tree` | audit only |
| session | `session_start_tree` | audit only |

Accepting a hunk, file, or all files advances only the private accepted tree. Rejecting restores accepted content into the working tree. pi.nvim uses a temporary Git index: it never stages files, writes the real index, or creates commits or branches.

## Commands

| Command | Action |
|---|---|
| `:Pi`, `:Pi toggle` | Show or hide the project chat |
| `:Pi focus` | Focus the composer |
| `:Pi ask [text]` | Open the composer, optionally with draft text |
| `:Pi prompt <text-or-name>` | Submit text or a configured prompt |
| `:Pi select` | Select a configured prompt or control action |
| `:Pi abort` | Abort the active Pi request |
| `:Pi model` | Open CodeCompanion's model selector |
| `:Pi thinking` | Open CodeCompanion's ACP thinking selector |
| `:Pi checkpoint` | Capture a manual turn baseline |
| `:Pi review [turn\|session]` | Review pending changes or an audit scope |
| `:Pi accept hunk\|file\|all` | Advance the accepted baseline |
| `:Pi reject hunk\|file` | Restore accepted content |
| `:Pi status` | Show checkpoint/review status |
| `:Pi stop` | Close the project chat and ACP process |

Pending review mappings default to `[h`, `]h`, `a`, `r`, `A`, `R`, and `q`. They are buffer-local. Turn and session scopes do not install mutating mappings.

## Configuration

```lua
require("pi").setup({
  codecompanion = {
    adapter = "pi",
    command = { "pi-acp" },
    -- Or without a global installation:
    -- command = { "npx", "-y", "pi-acp" },
  },
  compatibility = {
    legacy_context_tokens = true,
  },
  project = {
    cwd = nil,
  },
  review = {
    enabled = true,
    save_before_prompt = true, -- required invariant; false is rejected
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
  },
  events = {
    reload = true,
  },
})
```

Passing the removed `terminal` configuration is an error. Run `:checkhealth pi` to verify the full dependency stack.

## License

MIT. See [THIRD_PARTY.md](THIRD_PARTY.md) for integrated projects and their licenses.
