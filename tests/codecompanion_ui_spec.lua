local H = require("tests.helpers")

local function with_modules(stubs, fn)
  local saved = {}
  for name, value in pairs(stubs) do
    saved[name] = package.loaded[name]
    package.loaded[name] = value
  end
  local saved_bridge = package.loaded["pi.codecompanion"]
  package.loaded["pi.codecompanion"] = nil
  local ok, test_err = xpcall(fn, debug.traceback)
  package.loaded["pi.codecompanion"] = saved_bridge
  for name in pairs(stubs) do
    package.loaded[name] = saved[name]
  end
  if not ok then
    error(test_err, 0)
  end
end

local function fake_frontend()
  local chats = {}
  local sessions = {}
  local calls = { created = 0, focused = 0, hidden = 0, restored = 0 }
  local cc = { extensions = { ui = {} } }

  function cc.extensions.ui.focus_input()
    calls.focused = calls.focused + 1
  end

  function cc.chat(args)
    calls.created = calls.created + 1
    local chat_buf = vim.api.nvim_create_buf(false, true)
    local input_buf = vim.api.nvim_create_buf(false, true)
    local visible = not args.hidden
    local chat = {
      adapter = { name = "pi", type = "acp" },
      bufnr = chat_buf,
      buffer_context = nil,
      submitted = 0,
      ui = {},
    }
    function chat.ui:is_visible()
      return visible
    end
    function chat.ui:hide()
      visible = false
      calls.hidden = calls.hidden + 1
    end
    function chat.ui:unlock_buf() end
    function chat:submit()
      self.submitted = self.submitted + 1
      return true
    end
    function chat:stop() end
    function chat:close() end
    chats[chat_buf] = chat
    vim.api.nvim_win_set_buf(0, input_buf)
    sessions[chat_buf] = {
      chat_bufnr = chat_buf,
      input_bufnr = input_buf,
      input_winid = vim.api.nvim_get_current_win(),
    }
    if args.callbacks and args.callbacks.on_created then
      args.callbacks.on_created(chat)
    end
    return chat
  end

  function cc.buf_get_chat(bufnr)
    return chats[bufnr]
  end

  function cc.restore(bufnr)
    calls.restored = calls.restored + 1
    local chat = chats[bufnr]
    if chat then
      local was_visible = chat.ui:is_visible()
      if not was_visible then
        chat.ui.is_visible = function() return true end
      end
    end
  end

  return cc, calls, {
    get_by_bufnr = function(bufnr)
      return sessions[bufnr]
    end,
  }
end

local function frontend_stubs(cc, state, context_get, compatibility)
  return {
    codecompanion = cc,
    ["codecompanion-ui.state"] = state,
    ["codecompanion-ui.input"] = { refresh_placeholder = function() end },
    ["codecompanion.utils.context"] = { get = context_get or function() return {} end },
    ["pi.config"] = {
      opts = {
        codecompanion = { adapter = "pi", command = { "pi-acp" } },
        compatibility = { legacy_context_tokens = compatibility ~= false },
        events = { reload = false },
      },
    },
    ["pi.lifecycle"] = {
      attach = function(chat, cwd)
        chat._pi_cwd = cwd
        return true
      end,
    },
  }
end

H.test("legacy context tokens translate to CodeCompanion editor context", function()
  local cc, _, state = fake_frontend()
  with_modules(frontend_stubs(cc, state), function()
    local bridge = require("pi.codecompanion")
    local text = "@this @buffer @buffers @visible @diagnostics @quickfix @diff @buffered"

    H.eq(
      "#{selection} #{buffer} #{buffers} #{viewport} #{diagnostics} #{quickfix} #{diff} @buffered",
      bridge.translate_context(text, { is_visual = true })
    )
    H.eq("#{buffer}", bridge.translate_context("@this", { is_visual = false }))
    H.eq(
      "email@buffer.dev identifier@this_value (#{buffer})",
      bridge.translate_context("email@buffer.dev identifier@this_value (@buffer)", { is_visual = false })
    )
  end)
end)

H.test("legacy context translation can be disabled", function()
  local cc, _, state = fake_frontend()
  with_modules(frontend_stubs(cc, state, nil, false), function()
    H.eq("@this @buffer", require("pi.codecompanion").translate_context("@this @buffer", { is_visual = true }))
  end)
end)

H.test("composer captures source context before opening and uses codecompanion-ui input", function()
  local cc, calls, state = fake_frontend()
  local captured_buf
  with_modules(frontend_stubs(cc, state, function(bufnr)
    captured_buf = bufnr
    return { bufnr = bufnr, is_visual = true }
  end), function()
    local source = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(source)
    local bridge = require("pi.codecompanion")
    local root = H.tmpdir()
    local chat = assert(bridge.compose("@this simplify", { cwd = root }))
    local session = state.get_by_bufnr(chat.bufnr)

    H.eq(source, captured_buf)
    H.eq(source, chat.buffer_context.bufnr)
    H.eq({ "#{selection} simplify" }, vim.api.nvim_buf_get_lines(session.input_bufnr, 0, -1, false))
    H.eq({ 1, #"#{selection} simplify" }, vim.api.nvim_win_get_cursor(session.input_winid))
    H.eq(0, chat.submitted)
    H.eq(1, calls.focused)
  end)
end)

H.test("composer leaves the cursor after text inserted into an existing draft", function()
  local cc, _, state = fake_frontend()
  with_modules(frontend_stubs(cc, state), function()
    local bridge = require("pi.codecompanion")
    local root = H.tmpdir()
    local context = { bufnr = 10, is_visual = false }
    local chat = assert(bridge.compose("first", { cwd = root, context = context }))
    local session = state.get_by_bufnr(chat.bufnr)

    assert(bridge.compose(" second", { cwd = root, context = context }))

    H.eq({ "first second" }, vim.api.nvim_buf_get_lines(session.input_bufnr, 0, -1, false))
    H.eq({ 1, #"first second" }, vim.api.nvim_win_get_cursor(session.input_winid))
  end)
end)

H.test("toggle hides and restores one project chat without recreating it", function()
  local cc, calls, state = fake_frontend()
  with_modules(frontend_stubs(cc, state), function()
    local bridge = require("pi.codecompanion")
    local root = H.tmpdir()
    local context = { bufnr = 7, is_visual = false }
    local chat = assert(bridge.toggle(root, { context = context }))

    H.eq(chat, bridge.toggle(root, { context = context }))
    H.eq(chat, bridge.toggle(root, { context = context }))
    H.eq(1, calls.created)
    H.eq(1, calls.hidden)
    H.eq(1, calls.restored)
    H.eq(2, calls.focused)
  end)
end)

H.test("focus restores the project composer and direct prompt submits through the same chat", function()
  local cc, calls, state = fake_frontend()
  with_modules(frontend_stubs(cc, state), function()
    local bridge = require("pi.codecompanion")
    local root = H.tmpdir()
    local first_context = { bufnr = 10, is_visual = false }
    local second_context = { bufnr = 11, is_visual = true }
    local chat = assert(bridge.compose("draft", { cwd = root, context = first_context }))
    chat.ui:hide()

    H.eq(chat, bridge.focus(root, { context = second_context }))
    H.eq(chat, assert(bridge.prompt("fix @this", { cwd = root, context = second_context })))
    H.eq(second_context, chat.buffer_context)
    H.eq(1, chat.submitted)
    H.eq(1, calls.created)
    H.eq(2, calls.restored)
  end)
end)

H.test("focusing an existing composer preserves its captured source context", function()
  local cc, calls, state = fake_frontend()
  local captures = 0
  with_modules(frontend_stubs(cc, state, function()
    captures = captures + 1
    return { bufnr = 99, is_visual = false }
  end), function()
    local bridge = require("pi.codecompanion")
    local root = H.tmpdir()
    local source_context = { bufnr = 10, is_visual = true }
    local chat = assert(bridge.compose("draft", { cwd = root, context = source_context }))

    H.eq(chat, bridge.focus(root))
    H.eq(source_context, chat.buffer_context)
    H.eq(0, captures)
    H.eq(2, calls.focused)
  end)
end)

H.test("composer fails explicitly when the codecompanion-ui extension is unavailable", function()
  local cc, _, state = fake_frontend()
  cc.extensions.ui = nil
  with_modules(frontend_stubs(cc, state), function()
    local chat, compose_err = require("pi.codecompanion").compose("draft", { cwd = H.tmpdir(), context = {} })

    H.eq(nil, chat)
    H.truthy(compose_err:find("codecompanion%-ui"))
  end)
end)

H.test("fullscreen expands and restores the project chat window", function()
  local cc, calls, state = fake_frontend()
  with_modules(frontend_stubs(cc, state), function()
    local bridge = require("pi.codecompanion")
    local root = H.tmpdir()
    local chat = assert(bridge.ensure(root, { hidden = true }))
    local win = vim.api.nvim_open_win(chat.bufnr, false, { split = "right" })
    H.truthy(win)
    local columns = vim.o.columns

    H.eq(true, bridge.fullscreen(root))
    local full = vim.api.nvim_win_get_width(win)
    H.truthy(full >= columns - 2)
    H.eq(1, calls.restored)

    H.eq(true, bridge.fullscreen(root))
    H.eq(math.floor(columns * 0.35), vim.api.nvim_win_get_width(win))

    H.eq(true, bridge.fullscreen(root, true))
    H.truthy(vim.api.nvim_win_get_width(win) >= columns - 2)
    H.eq(true, bridge.fullscreen(root, false))
    H.eq(math.floor(columns * 0.35), vim.api.nvim_win_get_width(win))
  end)
end)

H.test("fullscreen fails explicitly when the chat window is unavailable", function()
  local cc, _, state = fake_frontend()
  with_modules(frontend_stubs(cc, state), function()
    local bridge = require("pi.codecompanion")
    local root = H.tmpdir()
    assert(bridge.ensure(root, { hidden = true }))

    local ok, err = bridge.fullscreen(root)
    H.eq(false, ok)
    H.truthy(err:find("chat window"))
  end)
end)
