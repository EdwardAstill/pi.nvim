---Composer winbar integration for codecompanion-ui.
---
---Pi's ACP session exposes a `thought_level` config option but no `mode`, so
---codecompanion-ui's default mode chip always renders the useless "Default"
---text at the top of the composer input. This module replaces that chip with
---one showing the current Pi thinking level, while non-Pi chats keep the
---original mode chip.

local M = {}

local COMPONENT = "pi_thinking"
local OPTION_ID = "thought_level"
local DEFAULT_ICONS = { default = "󰧠", off = "󰝟" }

local function thinking_winbar_enabled()
  local ok, config = pcall(require, "pi.config")
  local codecompanion = ok and config.opts and config.opts.codecompanion or nil
  if type(codecompanion) ~= "table" then
    return true
  end
  return codecompanion.thinking_winbar ~= false
end

local function flatten_options(option)
  local ok, acp = pcall(require, "codecompanion.acp")
  if ok and type(acp.flatten_config_options) == "function" then
    local flattened_ok, flattened = pcall(acp.flatten_config_options, option.options or {})
    if flattened_ok then
      return flattened or {}
    end
  end
  return option.options or {}
end

---Current Pi thinking level as `{ id, name }`, or nil when unavailable.
local function thinking_level(chat)
  local connection = chat and chat.acp_connection
  if not connection or type(connection._find_config_option) ~= "function" then
    return nil
  end
  local ok, option = pcall(connection._find_config_option, connection, OPTION_ID)
  if not ok or not option then
    return nil
  end
  local current = option.currentValue or ""
  for _, value in ipairs(flatten_options(option)) do
    if value.value == current then
      return { id = value.value, name = value.name or value.value }
    end
  end
  if current == "" then
    return nil
  end
  return { id = current, name = current }
end

---Component rendering the Pi thinking level in place of the mode chip.
---Non-Pi chats delegate to codecompanion-ui's original mode component.
local function pi_thinking_component(chat, session, opts)
  if not chat or not chat.adapter or chat.adapter.name ~= "pi" then
    local ok, components = pcall(require, "codecompanion-ui.components")
    if ok and type(components.mode) == "function" then
      return components.mode(chat, session, opts)
    end
    return ""
  end

  local level = thinking_level(chat)
  if not level then
    return ""
  end
  local icons = (opts and opts.icons) or {}
  local icon = icons[level.id] or icons.default or ""
  return { text = (icon ~= "" and icon .. " " or "") .. level.name, hl = "CcuiMode" }
end

---Re-apply the (possibly patched) winbar to already-open composer inputs.
local function apply_to_open_inputs()
  local ok, state = pcall(require, "codecompanion-ui.state")
  local sessions = ok and state.sessions or nil
  if type(sessions) ~= "table" then
    return
  end
  local winbar_ok, winbar = pcall(require, "codecompanion-ui.winbar")
  if not winbar_ok and not winbar then
    return
  end
  if type(winbar.set_input_winbar) ~= "function" then
    return
  end
  for _, session in pairs(sessions) do
    if session.input_winid and vim.api.nvim_win_is_valid(session.input_winid) then
      pcall(winbar.set_input_winbar, session.input_winid)
    end
  end
end

---Install the Pi thinking-level chip into codecompanion-ui's input winbar.
---Idempotent; safe to call before codecompanion-ui is loaded (returns false).
---@return boolean
function M.install()
  local ok, components = pcall(require, "codecompanion-ui.components")
  if not ok or type(components) ~= "table" then
    return false
  end
  if not thinking_winbar_enabled() then
    return false
  end

  if components[COMPONENT] ~= pi_thinking_component then
    components[COMPONENT] = pi_thinking_component
  end

  local config_ok, ui_config = pcall(require, "codecompanion-ui.config")
  local input = config_ok and ui_config.config and ui_config.config.input or nil
  if type(input) ~= "table" or type(input.winbar) ~= "table" then
    return false
  end
  if ui_config._pi_thinking_patched then
    return true
  end

  local replaced = false
  local winbar = {}
  for _, item in ipairs(input.winbar) do
    if type(item) == "table" and item.component == "mode" then
      winbar[#winbar + 1] = { component = COMPONENT, icons = vim.deepcopy(DEFAULT_ICONS) }
      replaced = true
    else
      winbar[#winbar + 1] = item
    end
  end
  if not replaced then
    -- The user customized the winbar without a mode chip; leave it alone.
    return false
  end

  input.winbar = winbar
  ui_config._pi_thinking_patched = true
  apply_to_open_inputs()
  return true
end

---Redraw the composer winbar for a chat (after a session option changes).
---@param chat table|nil
---@return boolean
function M.refresh(chat)
  local ok, state = pcall(require, "codecompanion-ui.state")
  local session = ok
    and type(state.get_by_bufnr) == "function"
    and chat
    and chat.bufnr
    and state.get_by_bufnr(chat.bufnr)
    or nil
  if not session then
    return false
  end
  local events_ok, events = pcall(require, "codecompanion-ui.events")
  if events_ok and type(events.redraw_winbar) == "function" then
    pcall(events.redraw_winbar, events, session)
    return true
  end
  return false
end

return M