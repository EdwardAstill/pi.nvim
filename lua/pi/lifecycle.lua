local M = {}
local cwd_guards = {}

local function pack(...)
  return { n = select("#", ...), ... }
end

local function normalize(cwd)
  local path = vim.fs.normalize(vim.fn.fnamemodify(cwd, ":p"))
  return path == "/" and path or path:gsub("/+$", "")
end

local function notify_error(message)
  vim.notify("pi.nvim: " .. tostring(message), vim.log.levels.ERROR)
end

local function error_message(value)
  return type(value) == "table" and value.message or value
end

local function is_pi_chat(chat)
  return chat and chat.adapter and chat.adapter.name == "pi"
end

local function cwd_command()
  if vim.fn.haslocaldir() == 1 then
    return "lcd"
  elseif vim.fn.haslocaldir(-1, 0) == 1 then
    return "tcd"
  end
  return "cd"
end

local function cwd_scope()
  return {
    command = cwd_command(),
    previous = vim.fn.getcwd(),
    tabpage = vim.api.nvim_get_current_tabpage(),
    window = vim.api.nvim_get_current_win(),
  }
end

local function scope_window(scope)
  if scope.command == "lcd" then
    return vim.api.nvim_win_is_valid(scope.window) and scope.window or nil
  end
  if scope.command == "tcd" then
    if not vim.api.nvim_tabpage_is_valid(scope.tabpage) then
      return nil
    end
    if vim.api.nvim_win_is_valid(scope.window) then
      return scope.window
    end
    return vim.api.nvim_tabpage_list_wins(scope.tabpage)[1]
  end
  if vim.api.nvim_win_is_valid(scope.window) then
    return scope.window
  end
  return vim.api.nvim_get_current_win()
end

local function set_scope_cwd(scope, cwd)
  local change = function()
    vim.cmd[scope.command](vim.fn.fnameescape(cwd))
  end
  local window = scope_window(scope)
  if not window then
    return false
  end
  vim.api.nvim_win_call(window, change)
  return true
end

local function scope_key(scope)
  if scope.command == "lcd" then
    return "window:" .. tostring(scope.window)
  elseif scope.command == "tcd" then
    return "tab:" .. tostring(scope.tabpage)
  end
  return "global"
end

local function with_cwd(cwd, callback)
  local scope = cwd_scope()
  if not set_scope_cwd(scope, cwd) then
    error("cwd scope no longer exists", 0)
  end
  local result = pack(xpcall(callback, debug.traceback))
  local restored, restore_err = pcall(set_scope_cwd, scope, scope.previous)
  if not result[1] then
    error(result[2], 0)
  end
  if not restored then
    error(restore_err, 0)
  end
  return unpack(result, 2, result.n)
end

function M.prepare_acp_cwd(cwd)
  if type(cwd) ~= "string" or cwd == "" then
    return true
  end
  local scope = cwd_scope()
  local key = scope_key(scope)
  local guard = cwd_guards[key]
  local new_guard = guard == nil
  if new_guard then
    guard = { pending = 0, scope = scope }
    cwd_guards[key] = guard
  end
  local call_ok, scope_changed = pcall(set_scope_cwd, scope, normalize(cwd))
  if not call_ok or not scope_changed then
    if new_guard then
      cwd_guards[key] = nil
    end
    if not call_ok then
      error(scope_changed, 0)
    end
    error("cwd scope no longer exists", 0)
  end
  guard.pending = guard.pending + 1
  vim.schedule(function()
    guard.pending = guard.pending - 1
    if guard.pending > 0 or cwd_guards[key] ~= guard then
      return
    end
    cwd_guards[key] = nil
    local restored, restore_err = pcall(set_scope_cwd, guard.scope, guard.scope.previous)
    if not restored then
      notify_error(restore_err)
    end
  end)
  return true
end

local function before_submit(cwd)
  return function(chat)
    if not is_pi_chat(chat) then
      return
    end
    local save_result = pack(pcall(require("pi.project").save_modified, cwd))
    if not save_result[1] then
      notify_error(error_message(save_result[2]))
      return false
    end
    local saved, save_err = save_result[2], save_result[3]
    if not saved then
      notify_error(save_err)
      return false
    end

    local checkpoint_result = pack(pcall(require("pi.checkpoint").start_turn, cwd))
    if not checkpoint_result[1] then
      notify_error(error_message(checkpoint_result[2]))
      return false
    end
    local started, checkpoint_err = checkpoint_result[2], checkpoint_result[3]
    if started == nil then
      notify_error(error_message(checkpoint_err))
      return false
    end
  end
end

local function refresh_project(cwd)
  local project = require("pi.project")
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    local path = vim.api.nvim_buf_get_name(bufnr)
    if vim.api.nvim_buf_is_loaded(bufnr)
      and vim.bo[bufnr].buftype == ""
      and path ~= ""
      and project.is_within(cwd, path)
    then
      local ok, reload_err = pcall(vim.api.nvim_buf_call, bufnr, function()
        vim.cmd.checktime()
      end)
      if not ok then
        notify_error(reload_err)
      end
    end
  end

  local ok, minidiff = pcall(require, "pi.review.minidiff")
  if ok and type(minidiff.refresh_all) == "function" then
    local refreshed, refresh_err = pcall(minidiff.refresh_all, cwd)
    if not refreshed then
      notify_error(refresh_err)
    end
  end
end

function M.attach(chat, cwd)
  if not is_pi_chat(chat) then
    return false
  end
  cwd = normalize(cwd or chat._pi_cwd)
  chat._pi_cwd = cwd
  chat.adapter._pi_cwd = cwd
  if chat._pi_lifecycle_attached then
    return true
  end

  chat._pi_lifecycle_attached = true
  chat:add_callback("on_before_submit", before_submit(cwd))
  chat:add_callback("on_completed", function(current, data)
    if not is_pi_chat(current) or (data and data.status ~= "success") then
      return
    end
    refresh_project(cwd)
  end)
  chat:add_callback("on_closed", function(current)
    if not is_pi_chat(current) then
      return
    end
    require("pi.checkpoint").cleanup(cwd)
    local ok, bridge = pcall(require, "pi.codecompanion")
    if ok then
      bridge.forget(cwd, current.bufnr)
    end
  end)

  local submit = chat.submit
  chat.submit = function(self, ...)
    local args = { n = select("#", ...), ... }
    if not is_pi_chat(self) then
      return submit(self, unpack(args, 1, args.n))
    end
    return with_cwd(cwd, function()
      return submit(self, unpack(args, 1, args.n))
    end)
  end

  if type(chat.change_adapter) == "function" then
    local change_adapter = chat.change_adapter
    chat.change_adapter = function(self, adapter, ...)
      local name = type(adapter) == "table" and adapter.name or adapter
      if not is_pi_chat(self) and name == "pi" then
        vim.notify("pi.nvim: start a new Pi chat instead of switching this chat back to Pi", vim.log.levels.WARN)
        return false
      end
      return change_adapter(self, adapter, ...)
    end
  end
  return true
end

local function install_input_compatibility()
  local ok, input = pcall(require, "codecompanion-ui.input")
  if not ok or type(input.submit) ~= "function" or input._pi_original_submit then
    return
  end

  input._pi_original_submit = input.submit
  input.submit = function(session, ...)
    local chat
    if session and session.chat_bufnr then
      local loaded, codecompanion = pcall(require, "codecompanion")
      chat = loaded and codecompanion.buf_get_chat(session.chat_bufnr) or nil
    end
    if is_pi_chat(chat) and session.input_bufnr and vim.api.nvim_buf_is_valid(session.input_bufnr) then
      local lines = vim.api.nvim_buf_get_lines(session.input_bufnr, 0, -1, false)
      local text = vim.trim(table.concat(lines, "\n"))
      if text ~= "" then
        session._pi_submitted_draft = vim.deepcopy(lines)
        session._pi_submitted_lines = vim.split(text, "\n", { plain = true })
      end
    end
    return input._pi_original_submit(session, ...)
  end
end

local function session_for_chat(bufnr)
  local ok, state = pcall(require, "codecompanion-ui.state")
  if not ok or type(state.get_by_bufnr) ~= "function" then
    return nil
  end
  return state.get_by_bufnr(bufnr)
end

local function recover_draft(bufnr)
  local loaded, codecompanion = pcall(require, "codecompanion")
  if not loaded or not is_pi_chat(codecompanion.buf_get_chat(bufnr)) then
    return
  end
  local session = session_for_chat(bufnr)
  local draft = session and session._pi_submitted_draft
  if not draft or not session.input_bufnr or not vim.api.nvim_buf_is_valid(session.input_bufnr) then
    return
  end

  if session.chat_bufnr and vim.api.nvim_buf_is_valid(session.chat_bufnr) then
    local submitted = session._pi_submitted_lines or draft
    local chat_lines = vim.api.nvim_buf_get_lines(session.chat_bufnr, 0, -1, false)
    local start = #chat_lines - #submitted + 1
    local matches = start > 0
    for index, line in ipairs(submitted) do
      matches = matches and chat_lines[start + index - 1] == line
    end
    if matches then
      vim.api.nvim_buf_set_lines(session.chat_bufnr, start - 1, #chat_lines, false, {})
    end
  end

  vim.api.nvim_buf_set_lines(session.input_bufnr, 0, -1, false, draft)
  session._pi_submitted_draft = nil
  session._pi_submitted_lines = nil
  local ok, input = pcall(require, "codecompanion-ui.input")
  if ok and type(input.refresh_placeholder) == "function" then
    input.refresh_placeholder(session.input_bufnr)
  end
end

function M.setup()
  install_input_compatibility()
  local group = vim.api.nvim_create_augroup("pi-codecompanion", { clear = true })

  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "CodeCompanionChatCreated",
    callback = function(args)
      local data = args.data or {}
      if not data.bufnr then
        return
      end
      local ok, codecompanion = pcall(require, "codecompanion")
      local chat = ok and codecompanion.buf_get_chat(data.bufnr) or nil
      if is_pi_chat(chat) then
        install_input_compatibility()
        local cwd = chat._pi_cwd or require("pi.project").resolve_cwd()
        M.attach(chat, cwd)
        local bridge_ok, bridge = pcall(require, "pi.codecompanion")
        if bridge_ok then
          bridge.register(chat, cwd)
        end
      end
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "CodeCompanionChatRestored",
    callback = function(args)
      local data = args.data or {}
      if data.bufnr then
        recover_draft(data.bufnr)
      end
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "CodeCompanionChatSubmitted",
    callback = function(args)
      local data = args.data or {}
      local session = data.bufnr and session_for_chat(data.bufnr) or nil
      local loaded, codecompanion = pcall(require, "codecompanion")
      local chat = loaded and data.bufnr and codecompanion.buf_get_chat(data.bufnr) or nil
      if session and is_pi_chat(chat) then
        session._pi_submitted_draft = nil
        session._pi_submitted_lines = nil
      end
    end,
  })
end

return M
