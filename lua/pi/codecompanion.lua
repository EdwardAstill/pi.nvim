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
  opts = opts or {}
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

  local chat = require("codecompanion").buf_get_chat(bufnr)
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

  chats[root] = chat.bufnr
  lifecycle.attach(chat, root)
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
  local chat, chat_err = M.ensure(opts.cwd, {
    hidden = opts.hidden,
    restore = opts.restore,
    context = opts.context,
  })
  if not chat then
    return nil, chat_err
  end
  append_prompt(chat, text)
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
