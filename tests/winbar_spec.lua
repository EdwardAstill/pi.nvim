local H = require("tests.helpers")

local function with_modules(stubs, fn)
  local saved = {}
  for name, value in pairs(stubs) do
    saved[name] = package.loaded[name]
    package.loaded[name] = value
  end
  local saved_winbar = package.loaded["pi.winbar"]
  package.loaded["pi.winbar"] = nil
  local ok, test_err = xpcall(fn, debug.traceback)
  package.loaded["pi.winbar"] = saved_winbar
  for name in pairs(stubs) do
    package.loaded[name] = saved[name]
  end
  if not ok then
    error(test_err, 0)
  end
end

local function fake_config(codecompanion)
  return {
    opts = {
      codecompanion = codecompanion or {},
      compatibility = { legacy_context_tokens = false },
      events = { reload = false },
    },
  }
end

local function fake_thinking_option(current)
  return {
    currentValue = current,
    options = {
      { value = "off", name = "Off" },
      { value = "low", name = "Low" },
      { value = "high", name = "High" },
    },
  }
end

local function pi_chat(option)
  return {
    adapter = { name = "pi", type = "acp" },
    acp_connection = {
      _find_config_option = function(_, id)
        if id == "thought_level" then
          return fake_thinking_option(option or "high")
        end
        return nil
      end,
    },
  }
end

H.test("install replaces the mode chip with the Pi thinking component", function()
  local components = {}
  local ui_config = { config = { input = { winbar = {
    { component = "mode", icons = { default = "󰺴" } },
    "%=",
    { component = "spinner" },
  } } } }
  with_modules({
    ["codecompanion-ui.components"] = components,
    ["codecompanion-ui.config"] = ui_config,
    ["pi.config"] = fake_config(),
  }, function()
    local winbar = require("pi.winbar")

    H.eq(true, winbar.install())
    H.truthy(type(components.pi_thinking) == "function")
    H.eq("pi_thinking", ui_config.config.input.winbar[1].component)
    H.eq("%=", ui_config.config.input.winbar[2])
    H.eq("spinner", ui_config.config.input.winbar[3].component)
    H.truthy(ui_config._pi_thinking_patched)

    -- Idempotent
    H.eq(true, winbar.install())
    H.eq(3, #ui_config.config.input.winbar)
  end)
end)

H.test("install leaves the winbar alone when there is no mode chip", function()
  local ui_config = { config = { input = { winbar = { { component = "spinner" } } } } }
  with_modules({
    ["codecompanion-ui.components"] = {},
    ["codecompanion-ui.config"] = ui_config,
    ["pi.config"] = fake_config(),
  }, function()
    H.eq(false, require("pi.winbar").install())
    H.eq("spinner", ui_config.config.input.winbar[1].component)
    H.eq(nil, ui_config._pi_thinking_patched)
  end)
end)

H.test("install respects thinking_winbar = false", function()
  local components = {}
  local ui_config = { config = { input = { winbar = { { component = "mode" } } } } }
  with_modules({
    ["codecompanion-ui.components"] = components,
    ["codecompanion-ui.config"] = ui_config,
    ["pi.config"] = fake_config({ thinking_winbar = false }),
  }, function()
    H.eq(false, require("pi.winbar").install())
    H.eq("mode", ui_config.config.input.winbar[1].component)
    H.eq(nil, components.pi_thinking)
  end)
end)

H.test("the thinking chip renders the current Pi thinking level", function()
  local components = {}
  local ui_config = { config = { input = { winbar = { { component = "mode" } } } } }
  with_modules({
    ["codecompanion-ui.components"] = components,
    ["codecompanion-ui.config"] = ui_config,
    ["codecompanion.acp"] = { flatten_config_options = function(options) return options end },
    ["pi.config"] = fake_config(),
  }, function()
    local winbar = require("pi.winbar")
    assert(winbar.install())

    H.eq({ text = "* High", hl = "CcuiMode" }, components.pi_thinking(pi_chat("high"), nil, { icons = { high = "*" } }))
    H.eq({ text = "High", hl = "CcuiMode" }, components.pi_thinking(pi_chat("high"), nil, {}))
    -- Unnamed values fall back to their id
    local option = fake_thinking_option("xhigh")
    option.options[3] = { value = "xhigh" }
    local bare = pi_chat("xhigh")
    H.eq({ text = "xhigh", hl = "CcuiMode" }, components.pi_thinking(bare, nil, {}))
  end)
end)

H.test("the thinking chip is hidden when the model has no thinking levels", function()
  local components = {}
  local ui_config = { config = { input = { winbar = { { component = "mode" } } } } }
  with_modules({
    ["codecompanion-ui.components"] = components,
    ["codecompanion-ui.config"] = ui_config,
    ["codecompanion.acp"] = { flatten_config_options = function(options) return options end },
    ["pi.config"] = fake_config(),
  }, function()
    local winbar = require("pi.winbar")
    assert(winbar.install())

    local chat = pi_chat()
    chat.acp_connection._find_config_option = function() return nil end
    H.eq("", components.pi_thinking(chat, nil, {}))

    chat.acp_connection = nil
    H.eq("", components.pi_thinking(chat, nil, {}))
  end)
end)

H.test("the thinking chip delegates the mode chip for non-Pi chats", function()
  local components = {
    mode = function()
      return { text = "Plan", hl = "CcuiMode" }
    end,
  }
  local ui_config = { config = { input = { winbar = { { component = "mode" } } } } }
  with_modules({
    ["codecompanion-ui.components"] = components,
    ["codecompanion-ui.config"] = ui_config,
    ["codecompanion.acp"] = { flatten_config_options = function(options) return options end },
    ["pi.config"] = fake_config(),
  }, function()
    local winbar = require("pi.winbar")
    assert(winbar.install())
    local chat = pi_chat("high")
    chat.adapter = { name = "claude_code", type = "acp" }

    H.eq({ text = "Plan", hl = "CcuiMode" }, components.pi_thinking(chat, nil, {}))
  end)
end)

H.test("refresh redraws the composer winbar for the chat session", function()
  local redraws = 0
  local session = { input_winid = 1 }
  local state = {
    get_by_bufnr = function(bufnr)
      return bufnr == 42 and session or nil
    end,
  }
  local events = {
    redraw_winbar = function(s)
      redraws = redraws + 1
      H.eq(session, s)
    end,
  }
  with_modules({
    ["codecompanion-ui.state"] = state,
    ["codecompanion-ui.events"] = events,
  }, function()
    local winbar = require("pi.winbar")
    H.eq(true, winbar.refresh({ bufnr = 42 }))
    H.eq(1, redraws)
    H.eq(false, winbar.refresh({ bufnr = 99 }))
    H.eq(false, winbar.refresh(nil))
    H.eq(1, redraws)
  end)
end)

H.test("cycle_thinking redraws the winbar after switching levels", function()
  local redraws = 0
  local buf = vim.api.nvim_create_buf(false, true)
  local set_calls = {}
  local chat = {
    adapter = { name = "pi", type = "acp" },
    bufnr = buf,
    acp_connection = {
      get_config_options = function()
        return { {
          id = "thought_level",
          category = "thought_level",
          currentValue = "off",
          options = { { value = "off" }, { value = "high" } },
        } }
      end,
      set_config_option = function(_, id, value)
        set_calls[#set_calls + 1] = { id = id, value = value }
        return true
      end,
    },
  }
  local state = {
    get_by_bufnr = function(bufnr)
      return bufnr == chat.bufnr and { input_winid = 1 } or nil
    end,
  }
  local events = {
    redraw_winbar = function()
      redraws = redraws + 1
    end,
  }
  local codecompanion = { buf_get_chat = function() return chat end }
  with_modules({
    codecompanion = codecompanion,
    ["codecompanion.acp"] = { flatten_config_options = function(options) return options end },
    ["codecompanion-ui.state"] = state,
    ["codecompanion-ui.events"] = events,
    ["pi.config"] = fake_config(),
  }, function()
    local bridge = require("pi.codecompanion")
    local root = H.tmpdir()
    assert(bridge.register(chat, root))

    H.eq(true, bridge.cycle_thinking(root))
    H.eq({ id = "thought_level", value = "high" }, set_calls[1])
    H.eq(1, redraws)
  end)
end)