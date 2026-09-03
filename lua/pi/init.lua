local M = {}

local function notify_error(prefix, err)
  local message = type(err) == "table" and err.message or tostring(err)
  vim.notify("Pi: " .. prefix .. ": " .. message, vim.log.levels.ERROR)
end

local function project_cwd()
  return require("pi.project").resolve_cwd()
end

local function project_boundary(cwd)
  local root, root_err = require("pi.review.git").discover_root(cwd)
  if root then
    return root, nil
  end
  if root_err and root_err.kind ~= "not_git" then
    return nil, root_err
  end
  return cwd, nil
end

local function capture_context(opts)
  if opts and opts.context then
    return opts.context
  end
  local context, context_err = require("pi.codecompanion").capture_context(opts and opts.context_opts)
  if not context then
    notify_error("cannot capture editor context", context_err)
  end
  return context
end

local function frontend_result(action, ...)
  local bridge = require("pi.codecompanion")
  local ok, result, frontend_err = pcall(bridge[action], ...)
  if not ok then
    notify_error(action .. " failed", result)
    return false
  end
  if not result then
    notify_error(action .. " failed", frontend_err or "frontend unavailable")
    return false
  end
  return true
end

--- Route text into CodeCompanion. Checkpointing is owned by on_before_submit.
---@param text string
---@param opts? { submit?: boolean, context?: table, context_opts?: table }
---@return boolean
function M._submit(text, opts)
  opts = opts or {}
  local context = capture_context(opts)
  if not context then
    return false
  end
  local action = opts.submit == false and "compose" or "prompt"
  return frontend_result(action, text, {
    cwd = project_cwd(),
    context = context,
  })
end

---@param opts? pi.Config
function M.setup(opts)
  require("pi.config").setup(opts)
  require("pi.lifecycle").setup()
  M._setup_keymaps()
end

--- Toggle the project Pi chat without stopping its ACP process.
---@return boolean
function M.toggle()
  return frontend_result("toggle", project_cwd())
end

--- Restore and focus the project composer.
---@return boolean
function M.focus()
  return frontend_result("focus", project_cwd())
end

--- Open the native composer with optional initial text.
---@param default_text? string
---@param opts? { submit?: boolean, context?: table, context_opts?: table }
---@return boolean
function M.ask(default_text, opts)
  opts = opts or {}
  return M._submit(default_text or "", {
    submit = opts.submit == true,
    context = opts.context,
    context_opts = opts.context_opts,
  })
end

--- Submit a direct prompt or open a configured draft prompt.
---@param text string
---@param opts? { context?: table, context_opts?: table, submit?: boolean }
---@return boolean
function M.prompt(text, opts)
  opts = opts or {}
  local prompt = require("pi.config").opts.prompts[text]
  local submit = opts.submit
  if prompt then
    text = prompt.text
    if submit == nil then
      submit = prompt.submit
    end
  end
  return M._submit(text, {
    submit = submit ~= false,
    context = opts.context,
    context_opts = opts.context_opts,
  })
end

--- Select a configured prompt or control action.
function M.select()
  local context = capture_context()
  if not context then
    return false
  end
  local items = {}
  for name, prompt in pairs(require("pi.config").opts.prompts) do
    items[#items + 1] = {
      label = name .. ": " .. prompt.text,
      name = name,
      text = prompt.text,
      submit = prompt.submit,
    }
  end
  table.sort(items, function(left, right) return left.name < right.name end)
  items[#items + 1] = { label = "[control] abort", action = "abort" }
  items[#items + 1] = { label = "[control] toggle", action = "toggle" }

  vim.ui.select(items, {
    prompt = "Pi Action:",
    format_item = function(item) return item.label end,
  }, function(item)
    if not item then
      return
    end
    if item.action then
      M[item.action]()
    else
      M._submit(item.text, { submit = item.submit ~= false, context = context })
    end
  end)
  return true
end

function M.abort()
  return frontend_result("abort", project_cwd())
end

function M.model()
  return frontend_result("model", project_cwd())
end

function M.thinking()
  return frontend_result("thinking", project_cwd())
end

function M.stop()
  return frontend_result("stop", project_cwd())
end

--- Insert canonical CodeCompanion context into the composer.
---@return boolean
function M.send_context()
  local context = capture_context()
  if not context then
    return false
  end
  local token = context.is_visual and "#{selection} " or "#{buffer} "
  return M._submit(token, { submit = false, context = context })
end

--- Capture a manual turn baseline.
---@return boolean
function M.checkpoint()
  local cwd = project_cwd()
  local boundary, boundary_err = project_boundary(cwd)
  if not boundary then
    notify_error("cannot resolve project", boundary_err)
    return false
  end
  local saved, save_err = require("pi.project").save_modified(boundary)
  if not saved then
    notify_error("save failed", save_err)
    return false
  end
  local tracked, checkpoint_err = require("pi.checkpoint").start_turn(cwd)
  if checkpoint_err then
    notify_error("checkpoint failed", checkpoint_err)
    return false
  end
  if not tracked then
    vim.notify("Pi: review requires a Git worktree", vim.log.levels.WARN)
    return false
  end
  local state = require("pi.checkpoint").state(cwd)
  vim.notify(string.format("Pi: checkpoint %d captured", state.turn_number))
  return true
end

---@param scope? "pending"|"turn"|"session"
---@return boolean
function M.review(scope)
  if not require("pi.config").opts.review.enabled then
    vim.notify("Pi: review is disabled", vim.log.levels.WARN)
    return false
  end
  local cwd = project_cwd()
  local state, ensure_err = require("pi.checkpoint").ensure(cwd)
  if not state then
    notify_error("checkpoint failed", ensure_err)
    return false
  end
  return require("pi.review").open(scope, cwd)
end

---@param target "hunk"|"file"|"all"
function M.accept(target)
  return require("pi.review").accept(target)
end

---@param target "hunk"|"file"
function M.reject(target)
  return require("pi.review").reject(target)
end

function M.status()
  local cwd = project_cwd()
  local state, ensure_err = require("pi.checkpoint").ensure(cwd)
  if not state then
    notify_error("checkpoint failed", ensure_err)
    return nil
  end
  local status, status_err = require("pi.checkpoint").status(cwd)
  if not status then
    notify_error("status failed", status_err)
    return nil
  end
  if not status.available then
    vim.notify(string.format("Pi: %s — review unavailable (not a Git worktree)", status.cwd))
  else
    vim.notify(string.format(
      "Pi: %s — turn %d, %d pending files, %d hunks",
      status.cwd,
      status.turn_number,
      status.pending_files,
      status.pending_hunks
    ))
  end
  return status
end

--- Build a dot-repeatable operator using CodeCompanion's selection context.
---@param prefix string
---@param opts? { submit?: boolean }
---@return string
function M.operator(prefix, opts)
  opts = opts or {}
  _G._pi_operatorfunc = function(kind)
    local start_pos = vim.api.nvim_buf_get_mark(0, "[")
    local end_pos = vim.api.nvim_buf_get_mark(0, "]")
    if start_pos[1] > end_pos[1] or (start_pos[1] == end_pos[1] and start_pos[2] > end_pos[2]) then
      start_pos, end_pos = end_pos, start_pos
    end
    if kind == "line" then
      start_pos[2] = 0
      end_pos[2] = #vim.api.nvim_buf_get_lines(0, end_pos[1] - 1, end_pos[1], false)[1]
    end
    vim.fn.setpos("'<", { 0, start_pos[1], start_pos[2] + 1, 0 })
    vim.fn.setpos("'>", { 0, end_pos[1], end_pos[2] + 1, 0 })
    local context = capture_context({ context_opts = { range = 1 } })
    if context then
      M.ask(prefix, { submit = opts.submit, context = context })
    end
  end
  vim.o.operatorfunc = "v:lua._pi_operatorfunc"
  return "g@"
end

function M._setup_keymaps()
  local keymaps = require("pi.config").opts.keymaps
  if keymaps.toggle then
    vim.keymap.set("n", keymaps.toggle, M.toggle, { silent = true, desc = "Pi: Toggle chat" })
  end
  if keymaps.ask then
    vim.keymap.set("n", keymaps.ask, function() M.ask("@this: ") end, { silent = true, desc = "Pi: Ask about code" })
    vim.keymap.set("v", keymaps.ask, function() M.ask("@this: ") end, { silent = true, desc = "Pi: Ask about selection" })
  end
  if keymaps.select then
    vim.keymap.set({ "n", "v" }, keymaps.select, M.select, { silent = true, desc = "Pi: Action picker" })
  end
  if keymaps.prompt_this then
    vim.keymap.set({ "n", "v" }, keymaps.prompt_this, M.send_context, { silent = true, desc = "Pi: Add context" })
  end
  if keymaps.abort then
    vim.keymap.set("n", keymaps.abort, M.abort, { silent = true, desc = "Pi: Abort" })
  end
end

return M
