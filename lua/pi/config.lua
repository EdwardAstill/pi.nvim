---@class pi.Config
---@field codecompanion pi.Config.CodeCompanion
---@field compatibility pi.Config.Compatibility
---@field prompts table<string, pi.Config.Prompt>
---@field keymaps table<string, string|false>
---@field events pi.Config.Events
---@field project pi.Config.Project
---@field review pi.Config.Review

---@class pi.Config.CodeCompanion
---@field adapter string
---@field command string[]
---@field models string[]|false|nil Model patterns restricting the model picker; nil reads Pi's enabledModels, false disables filtering
---@field thinking_winbar? boolean Show the thinking level in the composer input winbar instead of the mode chip; default true

---@class pi.Config.Compatibility
---@field legacy_context_tokens boolean

---@class pi.Config.Project
---@field cwd? string Fixed project directory, or current directory when nil

---@class pi.Config.ReviewKeymaps
---@field previous_hunk? string
---@field next_hunk? string
---@field accept_hunk? string
---@field reject_hunk? string
---@field accept_file? string
---@field reject_file? string
---@field close? string

---@class pi.Config.Review
---@field enabled boolean
---@field save_before_prompt boolean
---@field overlay boolean
---@field keymaps pi.Config.ReviewKeymaps

---@class pi.Config.Prompt
---@field text string
---@field submit boolean

---@class pi.Config.Events
---@field reload boolean Auto-reload buffers when files change

local M = {}

---@type pi.Config
M.defaults = {
  codecompanion = {
    adapter = "pi",
    command = { "pi-acp" },
    -- Restrict the model picker to these model patterns. nil (default) reads
    -- Pi's enabledModels cycle list from its settings files; false shows all.
    models = nil,
    -- Show the thinking level at the top of the composer input instead of
    -- codecompanion-ui's mode chip, which always reads "Default" for Pi.
    thinking_winbar = true,
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
    diff = { text = "Review the following git diff for correctness and readability: @diff", submit = true },
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
}

---@type pi.Config
M.opts = vim.deepcopy(M.defaults)
M._setup_called = false

local function command_is_valid(command)
  if type(command) ~= "table" or #command == 0 then
    return false
  end
  for _, value in ipairs(command) do
    if type(value) ~= "string" or value == "" then
      return false
    end
  end
  return true
end

---@param opts pi.Config
local function validate(opts)
  vim.validate({
    codecompanion = { opts.codecompanion, "table" },
    compatibility = { opts.compatibility, "table" },
    prompts = { opts.prompts, "table" },
    keymaps = { opts.keymaps, "table" },
    events = { opts.events, "table" },
    project = { opts.project, "table" },
    review = { opts.review, "table" },
  })
  vim.validate({
    ["codecompanion.adapter"] = { opts.codecompanion.adapter, "string" },
    ["codecompanion.command"] = { opts.codecompanion.command, command_is_valid, "non-empty list of strings" },
    ["codecompanion.models"] = {
      opts.codecompanion.models,
      function(value) return value == nil or value == false or command_is_valid(value) end,
      "list of model patterns, false, or nil",
    },
    ["compatibility.legacy_context_tokens"] = { opts.compatibility.legacy_context_tokens, "boolean" },
    ["events.reload"] = { opts.events.reload, "boolean" },
    ["project.cwd"] = {
      opts.project.cwd,
      function(value) return value == nil or type(value) == "string" end,
      "string or nil",
    },
    ["review.enabled"] = { opts.review.enabled, "boolean" },
    ["review.save_before_prompt"] = {
      opts.review.save_before_prompt,
      function(value) return value == true end,
      "true (saving before submission is required)",
    },
    ["review.overlay"] = { opts.review.overlay, "boolean" },
    ["review.keymaps"] = { opts.review.keymaps, "table" },
  })
  for key, value in pairs(opts.review.keymaps) do
    vim.validate({ ["review.keymaps." .. key] = { value, "string" } })
  end
end

---@param user_opts? pi.Config
function M.setup(user_opts)
  if user_opts and user_opts.terminal ~= nil then
    error("pi.nvim: terminal frontend has been removed; configure CodeCompanion and pi-acp instead", 2)
  end

  local candidate = vim.tbl_deep_extend("force", {}, M.defaults, user_opts or {})

  for _, section in ipairs({ "prompts", "keymaps" }) do
    if user_opts and user_opts[section] then
      for key, value in pairs(user_opts[section]) do
        if value == false then
          candidate[section][key] = nil
        end
      end
    end
  end
  if user_opts and user_opts.review and user_opts.review.keymaps then
    for key, value in pairs(user_opts.review.keymaps) do
      if value == false then
        candidate.review.keymaps[key] = nil
      end
    end
  end

  validate(candidate)
  M.opts = candidate
  M._setup_called = true
end

return M
