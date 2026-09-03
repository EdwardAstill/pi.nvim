local M = {}

local chats = {}

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

local function connected_chat(cwd)
  local chat = M.get(cwd)
  if not chat or not chat.acp_connection then
    return nil
  end
  if type(chat.acp_connection.is_connected) == "function" then
    local checked, connected = pcall(chat.acp_connection.is_connected, chat.acp_connection)
    if not checked or not connected then
      return nil
    end
  end
  return chat
end

function M.model(cwd)
  local chat = connected_chat(cwd)
  if not chat then
    return false
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

function M.thinking(cwd)
  local chat = connected_chat(cwd)
  if not chat or type(chat.acp_connection.get_config_options) ~= "function" then
    return false
  end
  local fetched, options = pcall(chat.acp_connection.get_config_options, chat.acp_connection)
  if not fetched then
    return false
  end
  local thinking
  for _, option in ipairs(options or {}) do
    if option.category == "thought_level" or option.id == "thought_level" then
      thinking = option
      break
    end
  end
  if not thinking then
    return false
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
  return selected
end

function M.stop(cwd)
  local root = root_for(cwd)
  local chat = M.get(root)
  if not chat then
    return false
  end
  chats[root] = nil
  chat:close()
  return true
end

function M.forget(cwd, bufnr)
  local root = root_for(cwd)
  if bufnr == nil or chats[root] == bufnr then
    chats[root] = nil
  end
end

return M
