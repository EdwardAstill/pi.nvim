local M = {}

local chats = {}

local expand_chat -- defined after chat_window; expands the chat to full editor width

local function normalize(cwd)
  local path = vim.fs.normalize(vim.fn.fnamemodify(cwd, ":p"))
  return path == "/" and path or path:gsub("/+$", "")
end

local function root_for(cwd)
  return normalize(cwd or require("pi.project").resolve_cwd())
end

local function configured_adapter()
  local config = require("pi.config").opts.codecompanion or {}
  return config.adapter or "pi"
end

function M.adapter(opts)
  opts = vim.tbl_deep_extend("force", {}, require("pi.config").opts.codecompanion or {}, opts or {})
  local helpers = require("codecompanion.adapters.acp.helpers")
  local command = opts.command or { "pi-acp" }
  if type(command) == "string" then
    command = { command }
  end

  return {
    name = "pi",
    formatted_name = "Pi",
    type = "acp",
    roles = {
      llm = "assistant",
      user = "user",
    },
    commands = {
      default = vim.deepcopy(command),
    },
    defaults = {
      mcpServers = {},
      timeout = opts.timeout or 30000,
    },
    parameters = {
      protocolVersion = 1,
      clientCapabilities = {
        fs = { readTextFile = true, writeTextFile = true },
      },
      clientInfo = {
        name = "pi.nvim",
        version = "1.0.0",
      },
    },
    handlers = {
      setup = function(self)
        return require("pi.lifecycle").prepare_acp_cwd(self._pi_cwd)
      end,
      auth = function(self)
        return require("pi.lifecycle").prepare_acp_cwd(self._pi_cwd)
      end,
      form_messages = function(self, messages, capabilities)
        return helpers.form_messages(self, messages, capabilities)
      end,
      on_exit = function() end,
    },
  }
end

function M.get(cwd)
  local root = root_for(cwd)
  local bufnr = chats[root]
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    chats[root] = nil
    return nil
  end

  local loaded, codecompanion = pcall(require, "codecompanion")
  if not loaded then
    return nil
  end
  local chat = codecompanion.buf_get_chat(bufnr)
  if not chat or not chat.adapter or chat.adapter.name ~= "pi" then
    chats[root] = nil
    return nil
  end
  return chat
end

function M.register(chat, cwd)
  if not chat
    or not chat.adapter
    or chat.adapter.name ~= "pi"
    or not chat.bufnr
    or not vim.api.nvim_buf_is_valid(chat.bufnr)
  then
    return false
  end

  local root = root_for(cwd or chat._pi_cwd)
  local existing = M.get(root)
  if existing and existing ~= chat then
    return false
  end
  chats[root] = chat.bufnr
  return true
end

function M.ensure(cwd, opts)
  opts = opts or {}
  local root = root_for(cwd)
  local chat = M.get(root)
  if chat then
    if opts.context then
      chat.buffer_context = opts.context
    end
    if opts.restore ~= false and not opts.hidden then
      require("codecompanion").restore(chat.bufnr)
      expand_chat(chat)
    end
    return chat, nil
  end

  local lifecycle = require("pi.lifecycle")
  local args = {
    auto_submit = false,
    callbacks = {
      on_created = function(created)
        lifecycle.attach(created, root)
      end,
    },
    hidden = opts.hidden == true,
    context = opts.context,
    params = {
      adapter = opts.adapter or configured_adapter(),
      command = opts.command,
    },
  }
  chat = require("codecompanion").chat(args)
  if not chat then
    return nil, "CodeCompanion could not create a Pi chat"
  end

  chat.buffer_context = opts.context or chat.buffer_context
  chats[root] = chat.bufnr
  lifecycle.attach(chat, root)
  if not opts.hidden then
    expand_chat(chat)
  end
  return chat, nil
end

function M.capture_context(opts)
  local ok, context = pcall(require, "codecompanion.utils.context")
  if not ok or type(context.get) ~= "function" then
    return nil, "CodeCompanion context support is unavailable"
  end
  local captured, value = pcall(context.get, vim.api.nvim_get_current_buf(), opts)
  if not captured then
    return nil, value
  end
  return value, nil
end

function M.translate_context(text, context)
  if not require("pi.config").opts.compatibility.legacy_context_tokens then
    return text
  end
  local replacements = {
    { "@buffers", "#{buffers}" },
    { "@buffer", "#{buffer}" },
    { "@visible", "#{viewport}" },
    { "@diagnostics", "#{diagnostics}" },
    { "@quickfix", "#{quickfix}" },
    { "@diff", "#{diff}" },
    { "@this", context and context.is_visual and "#{selection}" or "#{buffer}" },
  }

  local function replace_token(value, token, replacement)
    local output = {}
    local offset = 1
    while true do
      local first, last = value:find(token, offset, true)
      if not first then
        output[#output + 1] = value:sub(offset)
        break
      end
      local before = first > 1 and value:sub(first - 1, first - 1) or ""
      local after = last < #value and value:sub(last + 1, last + 1) or ""
      local left_boundary = before == "" or not before:match("[%w_]")
      local right_boundary = after == "" or not after:match("[%w_]")
      if left_boundary and right_boundary then
        output[#output + 1] = value:sub(offset, first - 1)
        output[#output + 1] = replacement
        offset = last + 1
      else
        output[#output + 1] = value:sub(offset, first)
        offset = first + 1
      end
    end
    return table.concat(output)
  end

  for _, replacement in ipairs(replacements) do
    text = replace_token(text, replacement[1], replacement[2])
  end
  return text
end

local function ui_exports()
  local ok, codecompanion = pcall(require, "codecompanion")
  local ui = ok and codecompanion.extensions and codecompanion.extensions.ui or nil
  if not ui or type(ui.focus_input) ~= "function" then
    return nil, "codecompanion-ui extension is unavailable"
  end
  return ui, nil
end

local function composer_session(chat)
  local ok, state = pcall(require, "codecompanion-ui.state")
  local session = ok and type(state.get_by_bufnr) == "function" and state.get_by_bufnr(chat.bufnr) or nil
  if not session or not session.input_bufnr or not vim.api.nvim_buf_is_valid(session.input_bufnr) then
    return nil, "codecompanion-ui composer is unavailable"
  end
  return session, nil
end

local function insert_composer_text(session, text)
  if text == "" then
    return
  end
  local bufnr = session.input_bufnr
  local lines = vim.split(text, "\n", { plain = true })
  local current = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local end_row
  local end_col
  if #current == 1 and current[1] == "" then
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    end_row = #lines - 1
    end_col = #lines[#lines]
  else
    local row = #current - 1
    local col = #current[#current]
    vim.api.nvim_buf_set_text(bufnr, row, col, row, col, lines)
    end_row = row + #lines - 1
    end_col = #lines == 1 and col + #lines[1] or #lines[#lines]
  end
  if session.input_winid and vim.api.nvim_win_is_valid(session.input_winid) then
    local virtualedit = vim.wo[session.input_winid].virtualedit
    vim.wo[session.input_winid].virtualedit = "onemore"
    pcall(vim.api.nvim_win_set_cursor, session.input_winid, { end_row + 1, end_col })
    vim.wo[session.input_winid].virtualedit = virtualedit
  end
  local ok, input = pcall(require, "codecompanion-ui.input")
  if ok and type(input.refresh_placeholder) == "function" then
    input.refresh_placeholder(bufnr)
  end
end

function M.focus(cwd, opts)
  opts = opts or {}
  local ui, ui_err = ui_exports()
  if not ui then
    return nil, ui_err
  end
  local chat = M.get(cwd)
  local context, context_err = opts.context, nil
  if not chat and not context then
    context, context_err = M.capture_context(opts.context_opts)
  end
  if not chat and not context then
    return nil, context_err
  end
  local chat_err
  chat, chat_err = M.ensure(cwd, { context = context })
  if not chat then
    return nil, chat_err
  end
  ui.focus_input()
  return chat, nil
end

function M.compose(text, opts)
  opts = opts or {}
  local context, context_err = opts.context, nil
  if not context then
    context, context_err = M.capture_context(opts.context_opts)
  end
  if not context then
    return nil, context_err
  end
  local chat, chat_err = M.focus(opts.cwd, { context = context })
  if not chat then
    return nil, chat_err
  end
  local session, session_err = composer_session(chat)
  if not session then
    return nil, session_err
  end
  insert_composer_text(session, M.translate_context(text or "", chat.buffer_context))
  return chat, nil
end

function M.toggle(cwd, opts)
  opts = opts or {}
  local ui, ui_err = ui_exports()
  if not ui then
    return nil, ui_err
  end
  local chat = M.get(cwd)
  if chat and chat.ui and type(chat.ui.is_visible) == "function" and chat.ui:is_visible() then
    chat.ui:hide()
    return chat, nil
  end
  local context, context_err = opts.context, nil
  if not chat and not context then
    context, context_err = M.capture_context(opts.context_opts)
  end
  if not chat and not context then
    return nil, context_err
  end
  chat, ui_err = M.ensure(cwd, { context = context })
  if not chat then
    return nil, ui_err
  end
  ui.focus_input()
  return chat, nil
end

local function append_prompt(chat, text)
  if chat.ui and chat.ui.unlock_buf then
    chat.ui:unlock_buf()
  end
  local lines = vim.split(vim.trim(text), "\n", { plain = true })
  local existing = vim.api.nvim_buf_get_lines(chat.bufnr, 0, -1, false)
  if #existing == 1 and existing[1] == "" then
    vim.api.nvim_buf_set_lines(chat.bufnr, 0, -1, false, lines)
  else
    vim.api.nvim_buf_set_lines(chat.bufnr, -1, -1, false, lines)
  end
end

function M.prompt(text, opts)
  opts = opts or {}
  local context, context_err = opts.context, nil
  if not context then
    context, context_err = M.capture_context(opts.context_opts)
  end
  if not context then
    return nil, context_err
  end
  local chat, chat_err = M.ensure(opts.cwd, {
    hidden = opts.hidden,
    restore = opts.restore,
    context = context,
  })
  if not chat then
    return nil, chat_err
  end
  append_prompt(chat, M.translate_context(text, context))
  chat:submit()
  return chat, nil
end

function M.abort(cwd)
  local chat = M.get(cwd)
  if not chat then
    return false
  end
  chat:stop()
  return true
end

local function is_connected(connection)
  if not connection then
    return false
  end
  if type(connection.is_connected) ~= "function" then
    return true
  end
  local checked, connected = pcall(connection.is_connected, connection)
  return checked and connected == true
end

local function connected_chat(cwd)
  local chat = M.get(cwd)
  if not chat or not is_connected(chat.acp_connection) then
    return nil
  end
  return chat
end

local pending_connection_actions = {}
local pending_connection_group
local CONNECTION_ACTION_TIMEOUT_MS = 10000

local function notify_action_error(label, err)
  local message = type(err) == "table" and (err.message or vim.inspect(err)) or tostring(err or "frontend unavailable")
  vim.notify("Pi: " .. label .. " failed: " .. message, vim.log.levels.ERROR)
end

local function run_pending_action(entry)
  local ok, result, action_err = pcall(entry.action)
  if not ok then
    notify_action_error(entry.label, result)
  elseif not result then
    notify_action_error(entry.label, action_err)
  end
end

local function drain_pending_connection_actions()
  for key, entry in pairs(pending_connection_actions) do
    local chat = M.get(entry.cwd)
    if not chat or chat.bufnr ~= entry.bufnr then
      pending_connection_actions[key] = nil
      notify_action_error(entry.label, "chat closed before the ACP session was ready")
    elseif is_connected(chat.acp_connection) then
      pending_connection_actions[key] = nil
      vim.schedule(function()
        run_pending_action(entry)
      end)
    end
  end
end

local function clear_pending_connection_actions(bufnr)
  for key, entry in pairs(pending_connection_actions) do
    if entry.bufnr == bufnr then
      pending_connection_actions[key] = nil
    end
  end
end

local function ensure_connection_action_handler()
  if pending_connection_group then
    return
  end
  pending_connection_group = vim.api.nvim_create_augroup("pi-acp-pending-actions", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = pending_connection_group,
    pattern = { "CodeCompanionACPSessionPost", "CodeCompanionACPChatRestored" },
    callback = function()
      -- Let CodeCompanion finish the event that establishes the session before
      -- issuing another ACP request from the queued action.
      vim.schedule(drain_pending_connection_actions)
    end,
  })
end

local function queue_connection_action(cwd, chat, id, label, action)
  ensure_connection_action_handler()
  local key = tostring(chat.bufnr) .. ":" .. id
  local entry = pending_connection_actions[key]
  if entry then
    -- Repeated presses before the session is ready collapse to the latest
    -- request instead of cycling several times unexpectedly on connect.
    entry.action = action
    return true
  end

  entry = {
    action = action,
    bufnr = chat.bufnr,
    cwd = root_for(cwd),
    key = key,
    label = label,
  }
  pending_connection_actions[key] = entry
  vim.notify("Pi: waiting for the ACP session to " .. label .. "…")

  vim.defer_fn(function()
    if pending_connection_actions[key] ~= entry then
      return
    end
    pending_connection_actions[key] = nil
    notify_action_error(label, "ACP session did not become ready")
  end, CONNECTION_ACTION_TIMEOUT_MS)

  -- Covers the race where the session became ready between the caller's check
  -- and installing the session event handler.
  vim.schedule(drain_pending_connection_actions)
  return true
end

local function find_session_option(chat, wanted)
  if not chat or not chat.acp_connection or type(chat.acp_connection.get_config_options) ~= "function" then
    return nil
  end
  local fetched, options = pcall(chat.acp_connection.get_config_options, chat.acp_connection)
  if not fetched then
    return nil
  end
  for _, option in ipairs(options or {}) do
    if option.category == wanted or option.id == wanted then
      return option
    end
  end
  return nil
end

local function refresh_winbar(chat)
  local ok, winbar = pcall(require, "pi.winbar")
  if ok and type(winbar.refresh) == "function" then
    pcall(winbar.refresh, chat)
  end
end

local function set_session_option(chat, option, value)
  if not option or not value or value == "" or type(chat.acp_connection.set_config_option) ~= "function" then
    return false
  end
  local ok, changed = pcall(chat.acp_connection.set_config_option, chat.acp_connection, option.id, value)
  if not ok or not changed then
    return false
  end
  if chat.update_metadata then
    pcall(chat.update_metadata, chat)
  end
  refresh_winbar(chat)
  return true
end

local function set_model(chat, model)
  local changed
  if chat.acp_connection and type(chat.acp_connection.set_model) == "function" then
    local ok, result = pcall(chat.acp_connection.set_model, chat.acp_connection, model)
    changed = ok and result
    if changed and chat.update_metadata then
      pcall(chat.update_metadata, chat)
    end
    if changed then
      refresh_winbar(chat)
    end
  elseif chat.change_model then
    local ok, result = pcall(chat.change_model, chat, { model = model })
    changed = ok and result ~= false
    if changed then
      refresh_winbar(chat)
    end
  else
    changed = set_session_option(chat, find_session_option(chat, "model"), model)
  end
  return changed == true
end

local function glob_to_lua(glob)
  local out = {}
  for i = 1, #glob do
    local char = glob:sub(i, i)
    if char == "*" then
      out[#out + 1] = ".*"
    elseif char == "?" then
      out[#out + 1] = "."
    else
      out[#out + 1] = char:gsub("(%W)", "%%%1")
    end
  end
  return "^" .. table.concat(out) .. "$"
end

---Match a Pi --models-style pattern against a model id.
---Supports exact provider/model references, bare model ids, and * / ? globs.
local function model_pattern_matches(pattern, model_id)
  local id = model_id:lower()
  local pat = vim.trim(pattern or ""):lower()
  if pat == "" or id == "" then
    return false
  end
  if id == pat then
    return true
  end
  if not pat:find("/", 1, true) and id:match("([^/]+)$") == pat then
    return true
  end
  if pat:find("[*?]", 1, false) then
    return id:find(glob_to_lua(pat)) ~= nil
  end
  return false
end

local function read_enabled_models(cwd)
  local candidates = {
    root_for(cwd) .. "/.pi/settings.json",
    vim.fn.expand("~/.pi/agent/settings.json"),
  }
  for _, path in ipairs(candidates) do
    local ok, lines = pcall(vim.fn.readfile, path)
    if ok and type(lines) == "table" and #lines > 0 then
      local decoded, data = pcall(vim.json.decode, table.concat(lines, "\n"))
      if decoded and type(data) == "table" and type(data.enabledModels) == "table" then
        local models = {}
        for _, value in ipairs(data.enabledModels) do
          if type(value) == "string" and vim.trim(value) ~= "" then
            models[#models + 1] = value
          end
        end
        if #models > 0 then
          return models
        end
      end
    end
  end
  return nil
end

---Resolve the scoped model patterns restricting model selection.
---@return string[]|nil nil means no restriction
local function scoped_patterns(cwd)
  local config = require("pi.config").opts.codecompanion or {}
  if config.models == false then
    return nil
  end
  if type(config.models) == "table" and #config.models > 0 then
    return config.models
  end
  return read_enabled_models(cwd)
end

local function model_id(model)
  if type(model) ~= "table" then
    return model
  end
  return model.modelId or model.id or model.name
end

---Filter models to the scoped patterns, ordered by pattern order.
local function filter_models(models, patterns)
  if not patterns or #patterns == 0 then
    return models
  end
  local out = {}
  for _, pattern in ipairs(patterns) do
    for _, model in ipairs(models) do
      if model_pattern_matches(pattern, model_id(model)) then
        local duplicate = false
        for _, existing in ipairs(out) do
          if model_id(existing) == model_id(model) then
            duplicate = true
            break
          end
        end
        if not duplicate then
          out[#out + 1] = model
        end
      end
    end
  end
  return out
end

local function model_allowed(patterns, model)
  for _, pattern in ipairs(patterns) do
    if model_pattern_matches(pattern, model) then
      return true
    end
  end
  return false
end

local function option_values(option)
  if not option then
    return {}
  end
  local ok, acp = pcall(require, "codecompanion.acp")
  local values
  if ok and type(acp.flatten_config_options) == "function" then
    local flattened
    ok, flattened = pcall(acp.flatten_config_options, option.options or {})
    values = ok and flattened or nil
  else
    values = option.options or {}
  end
  local out = {}
  for _, value in ipairs(values or {}) do
    if value.value then
      out[#out + 1] = value.value
    end
  end
  return out
end

local function available_models(chat)
  if chat.acp_connection and type(chat.acp_connection.get_models) == "function" then
    local ok, models = pcall(chat.acp_connection.get_models, chat.acp_connection)
    if ok and models and models.availableModels then
      return models.availableModels, models.currentModelId
    end
  end
  local values = option_values(find_session_option(chat, "model"))
  local available = {}
  for _, id in ipairs(values) do
    available[#available + 1] = { modelId = id, name = id }
  end
  return available, nil
end

local function scoped_model_picker(chat, patterns)
  local available, current = available_models(chat)
  local filtered = filter_models(available, patterns)
  if #filtered == 0 then
    return false, "no available models match the scoped model list"
  end
  local items = {}
  for _, model in ipairs(filtered) do
    local id = model_id(model)
    local label = (id == current and "* " or "  ")
      .. (model.name and model.name ~= id and (model.name .. " (" .. id .. ")") or id)
    items[#items + 1] = { id = id, label = label }
  end
  vim.ui.select(items, {
    prompt = "Select Model",
    kind = "codecompanion.nvim",
    format_item = function(item) return item.label end,
  }, function(selected)
    if not selected or selected.id == current then
      return
    end
    set_model(chat, selected.id)
  end)
  return true
end

function M.model(cwd, model)
  local chat = connected_chat(cwd)
  if not chat then
    return false
  end
  local patterns = scoped_patterns(cwd)
  if model and model ~= "" then
    if patterns and not model_allowed(patterns, model) then
      return false, "model is not in the scoped model list"
    end
    return set_model(chat, model)
  end
  if patterns then
    return scoped_model_picker(chat, patterns)
  end
  -- CodeCompanion does not currently export a callable model picker. Keep its
  -- own picker behind this feature-detected compatibility boundary.
  local ok, picker = pcall(require, "codecompanion.interactions.chat.keymaps.change_adapter")
  if not ok then
    return false
  end
  local selected = pcall(picker.select_model, chat)
  return selected
end

function M.thinking(cwd, level)
  local chat = connected_chat(cwd)
  local thinking = find_session_option(chat, "thought_level")
  if not thinking then
    return false
  end
  if level and level ~= "" then
    return set_session_option(chat, thinking, level)
  end
  -- As above, delegate the UI to CodeCompanion while no public callable
  -- session-option picker is available.
  local ok, command = pcall(require, "codecompanion.interactions.chat.slash_commands.builtin.acp_session_options")
  if not ok then
    return false
  end
  local picker = command.new({ Chat = chat })
  if not picker or type(picker.show_values) ~= "function" then
    return false
  end
  local selected = pcall(picker.show_values, picker, thinking)
  if selected then
    -- The selection callback runs later; redraw the winbar once it applies.
    vim.schedule(function()
      refresh_winbar(chat)
    end)
  end
  return selected
end

---Cycle to the next available model (respecting the scoped model list).
---@param cwd string
---@return boolean, string|nil
function M.cycle_model(cwd)
  local root = root_for(cwd)
  local chat = M.get(root)
  if not chat then
    return false, "no project Pi chat"
  end
  if not is_connected(chat.acp_connection) then
    return queue_connection_action(root, chat, "cycle_model", "cycle model", function()
      return M.cycle_model(root)
    end)
  end
  local available, current = available_models(chat)
  local filtered = filter_models(available, scoped_patterns(cwd))
  if #filtered == 0 then
    return false, "no available models match the scoped model list"
  end
  local index = 1
  for position, model in ipairs(filtered) do
    if model_id(model) == current then
      index = position
      break
    end
  end
  local next_model = filtered[(index % #filtered) + 1]
  if model_id(next_model) == current then
    return false, "only one model available"
  end
  if not set_model(chat, model_id(next_model)) then
    return false, "failed to switch model"
  end
  vim.notify("Pi: model → " .. model_id(next_model))
  return true, nil
end

---Cycle to the next thinking level supported by the current model.
---@param cwd string
---@return boolean, string|nil
function M.cycle_thinking(cwd)
  local root = root_for(cwd)
  local chat = M.get(root)
  if not chat then
    return false, "no project Pi chat"
  end
  if not is_connected(chat.acp_connection) then
    return queue_connection_action(root, chat, "cycle_thinking", "cycle thinking", function()
      return M.cycle_thinking(root)
    end)
  end
  local thinking = find_session_option(chat, "thought_level")
  if not thinking then
    return false, "model does not support thinking levels"
  end
  local values = option_values(thinking)
  if #values < 2 then
    return false, "no other thinking level available"
  end
  local index = 1
  for position, value in ipairs(values) do
    if value == thinking.currentValue then
      index = position
      break
    end
  end
  local next_level = values[(index % #values) + 1]
  if not set_session_option(chat, thinking, next_level) then
    return false, "failed to set thinking level"
  end
  vim.notify("Pi: thinking → " .. next_level)
  return true, nil
end

---Set the Pi session display name (sent as an immediate /name command).
---@param cwd string
---@param name string
---@return boolean, string|nil
function M.session_name(cwd, name)
  name = vim.trim(name or "")
  if name == "" then
    return false, "session name is empty"
  end
  local chat = M.get(cwd)
  if not chat then
    return false, "no project Pi chat"
  end
  append_prompt(chat, "/name " .. name)
  chat:submit()
  return true, nil
end

function M.completions(cwd, kind)
  local chat = connected_chat(cwd)
  if not chat then
    return {}
  end
  if kind == "model" then
    local available = available_models(chat)
    local out = {}
    for _, model in ipairs(available) do
      out[#out + 1] = model_id(model)
    end
    return filter_models(out, scoped_patterns(cwd))
  end
  if kind == "thinking" then
    return option_values(find_session_option(chat, "thought_level"))
  end
  return {}
end

local function chat_window(chat)
  local ok, state = pcall(require, "codecompanion-ui.state")
  local session = ok and type(state.get_by_bufnr) == "function" and state.get_by_bufnr(chat.bufnr) or nil
  local winid = session and session.chat_winid or nil
  if not winid or not vim.api.nvim_win_is_valid(winid) then
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(win) == chat.bufnr then
        winid = win
        break
      end
    end
  end
  if winid and vim.api.nvim_win_is_valid(winid) then
    return winid
  end
  return nil
end

---Expand the chat window to the full editor width. The chat has no side
---column layout; it always opens fullscreen. Best effort: a failure to resize
---never blocks the chat from being usable.
---@param chat table
function expand_chat(chat)
  local winid = chat_window(chat)
  if winid then
    pcall(vim.api.nvim_win_set_width, winid, vim.o.columns)
  end
end

function M.stop(cwd)
  local root = root_for(cwd)
  local chat = M.get(root)
  if not chat then
    return false
  end
  clear_pending_connection_actions(chat.bufnr)
  chats[root] = nil
  chat:close()
  return true
end

function M.forget(cwd, bufnr)
  local root = root_for(cwd)
  if bufnr then
    clear_pending_connection_actions(bufnr)
  end
  if bufnr == nil or chats[root] == bufnr then
    chats[root] = nil
  end
end

return M
