local H = require("tests.helpers")

local function with_modules(stubs, fn)
  local saved = {}
  for name, value in pairs(stubs) do
    saved[name] = package.loaded[name]
    package.loaded[name] = value
  end
  local saved_pi = package.loaded["pi.codecompanion"]
  package.loaded["pi.codecompanion"] = nil
  local ok, test_err = xpcall(fn, debug.traceback)
  package.loaded["pi.codecompanion"] = saved_pi
  for name in pairs(stubs) do
    package.loaded[name] = saved[name]
  end
  if not ok then
    error(test_err, 0)
  end
end

local function fake_codecompanion()
  local chats = {}
  local created = 0
  local restored = {}
  local attached_during_create
  local cc = {}

  function cc.chat(args)
    created = created + 1
    local buf = vim.api.nvim_create_buf(false, true)
    local chat = {
      adapter = { name = "pi", type = "acp" },
      bufnr = buf,
      opts = args,
      submitted = 0,
      stopped = 0,
      closed = 0,
      ui = {
        unlock_buf = function() end,
      },
    }
    function chat:submit()
      self.submitted = self.submitted + 1
    end
    function chat:stop()
      self.stopped = self.stopped + 1
    end
    function chat:close()
      self.closed = self.closed + 1
      vim.api.nvim_buf_delete(self.bufnr, { force = true })
    end
    chats[buf] = chat
    if args.callbacks and type(args.callbacks.on_created) == "function" then
      args.callbacks.on_created(chat)
    end
    attached_during_create = chat._attached_cwd
    return chat
  end

  function cc.buf_get_chat(buf)
    return chats[buf]
  end

  function cc.restore(buf)
    restored[#restored + 1] = buf
  end

  return cc, function()
    return created
  end, restored, function()
    return attached_during_create
  end, function(chat)
    chats[chat.bufnr] = chat
  end
end

H.test("Pi ACP adapter uses pi-acp and CodeCompanion message framing", function()
  local framed
  with_modules({
    ["codecompanion.adapters.acp.helpers"] = {
      form_messages = function(self, messages, capabilities)
        framed = { self = self, messages = messages, capabilities = capabilities }
        return { prompt = "framed" }
      end,
    },
  }, function()
    local bridge = require("pi.codecompanion")
    local adapter = bridge.adapter({ command = { "custom-pi-acp" }, timeout = 4321 })

    H.eq("pi", adapter.name)
    H.eq("Pi", adapter.formatted_name)
    H.eq("acp", adapter.type)
    H.eq({ default = { "custom-pi-acp" } }, adapter.commands)
    H.eq(4321, adapter.defaults.timeout)
    H.eq({ llm = "assistant", user = "user" }, adapter.roles)
    H.eq(true, adapter.handlers.setup(adapter))
    H.eq(true, adapter.handlers.auth(adapter))
    H.eq({ prompt = "framed" }, adapter.handlers.form_messages(adapter, { "message" }, { fs = true }))
    H.eq(adapter, framed.self)
    H.eq({ "message" }, framed.messages)
    H.eq({ fs = true }, framed.capabilities)
  end)
end)

H.test("project root is attached before CodeCompanion finishes chat creation", function()
  local cc, _, _, attached_during_create = fake_codecompanion()
  with_modules({
    codecompanion = cc,
    ["pi.lifecycle"] = {
      attach = function(chat, cwd)
        chat._attached_cwd = cwd
        return true
      end,
    },
  }, function()
    local bridge = require("pi.codecompanion")
    local root = H.tmpdir()
    assert(bridge.ensure(root, { hidden = true }))

    H.eq(root, attached_during_create())
  end)
end)

H.test("project chat creation reuses and restores the same valid chat", function()
  local cc, created, restored = fake_codecompanion()
  local attached = {}
  with_modules({
    codecompanion = cc,
    ["pi.lifecycle"] = {
      attach = function(chat, cwd)
        attached[#attached + 1] = { chat = chat, cwd = cwd }
        return true
      end,
    },
  }, function()
    local bridge = require("pi.codecompanion")
    local root = H.tmpdir()
    local first = assert(bridge.ensure(root, { hidden = true }))
    local second = assert(bridge.ensure(root .. "/"))

    H.eq(first, second)
    H.eq(1, created())
    H.eq({ first.bufnr }, restored)
    H.eq(root, attached[1].cwd)

    first.adapter = { name = "other", type = "http" }
    H.eq(nil, bridge.get(root))
  end)
end)

H.test("project chat creation isolates different roots", function()
  local cc, created = fake_codecompanion()
  with_modules({
    codecompanion = cc,
    ["pi.lifecycle"] = { attach = function() return true end },
  }, function()
    local bridge = require("pi.codecompanion")
    local first = assert(bridge.ensure(H.tmpdir(), { hidden = true }))
    local second = assert(bridge.ensure(H.tmpdir(), { hidden = true }))

    H.truthy(first ~= second)
    H.eq(2, created())
  end)
end)

H.test("externally created Pi chats are reused by the project facade", function()
  local cc, created, restored, _, remember = fake_codecompanion()
  with_modules({
    codecompanion = cc,
    ["pi.lifecycle"] = { attach = function() return true end },
  }, function()
    local bridge = require("pi.codecompanion")
    local root = H.tmpdir()
    local external = {
      adapter = { name = "pi", type = "acp" },
      bufnr = vim.api.nvim_create_buf(false, true),
    }
    remember(external)

    H.eq(true, bridge.register(external, root))
    H.eq(external, bridge.ensure(root))
    H.eq(0, created())
    H.eq({ external.bufnr }, restored)
  end)
end)

H.test("direct project prompt enters the reusable chat and submits", function()
  local cc = fake_codecompanion()
  with_modules({
    codecompanion = cc,
    ["pi.lifecycle"] = { attach = function() return true end },
  }, function()
    local bridge = require("pi.codecompanion")
    local root = H.tmpdir()
    local chat = assert(bridge.prompt("inspect this", { cwd = root, hidden = true }))

    H.eq({ "inspect this" }, vim.api.nvim_buf_get_lines(chat.bufnr, 0, -1, false))
    H.eq(1, chat.submitted)
  end)
end)

H.test("abort and stop control only the selected project chat", function()
  local cc = fake_codecompanion()
  with_modules({
    codecompanion = cc,
    ["pi.lifecycle"] = { attach = function() return true end },
  }, function()
    local bridge = require("pi.codecompanion")
    local first_root = H.tmpdir()
    local second_root = H.tmpdir()
    local first = assert(bridge.ensure(first_root, { hidden = true }))
    local second = assert(bridge.ensure(second_root, { hidden = true }))

    H.eq(true, bridge.abort(first_root))
    H.eq(1, first.stopped)
    H.eq(0, second.stopped)
    H.eq(true, bridge.stop(first_root))
    H.eq(1, first.closed)
    H.eq(nil, bridge.get(first_root))
    H.eq(second, bridge.get(second_root))
  end)
end)

H.test("model and thinking controls use CodeCompanion's ACP pickers", function()
  local cc = fake_codecompanion()
  local selected_model
  local selected_options
  with_modules({
    codecompanion = cc,
    ["pi.lifecycle"] = { attach = function() return true end },
    ["codecompanion.interactions.chat.keymaps.change_adapter"] = {
      select_model = function(chat)
        selected_model = chat
      end,
    },
    ["codecompanion.interactions.chat.slash_commands.builtin.acp_session_options"] = {
      new = function(args)
        return {
          show_values = function(_, option)
            selected_options = { chat = args.Chat, option = option }
          end,
        }
      end,
    },
  }, function()
    local bridge = require("pi.codecompanion")
    local root = H.tmpdir()
    local chat = assert(bridge.ensure(root, { hidden = true }))
    chat.acp_connection = {
      is_connected = function() return true end,
      get_config_options = function()
        return {
          { id = "model", category = "model" },
          { id = "thought_level", category = "thought_level" },
        }
      end,
    }

    H.eq(true, bridge.model(root))
    H.eq(true, bridge.thinking(root))
    H.eq(chat, selected_model)
    H.eq(chat, selected_options.chat)
    H.eq("thought_level", selected_options.option.id)
  end)
end)

H.test("model controls reject an ACP connection that is not ready", function()
  local cc = fake_codecompanion()
  local picker_calls = 0
  with_modules({
    codecompanion = cc,
    ["pi.lifecycle"] = { attach = function() return true end },
    ["codecompanion.interactions.chat.keymaps.change_adapter"] = {
      select_model = function()
        picker_calls = picker_calls + 1
      end,
    },
  }, function()
    local bridge = require("pi.codecompanion")
    local root = H.tmpdir()
    local chat = assert(bridge.ensure(root, { hidden = true }))
    chat.acp_connection = {
      is_connected = function() return false end,
      get_config_options = function() return {} end,
    }

    H.eq(false, bridge.model(root))
    H.eq(false, bridge.thinking(root))
    H.eq(0, picker_calls)
  end)
end)

H.test("model controls wait for the ACP connection", function()
  local cc = fake_codecompanion()
  with_modules({
    codecompanion = cc,
    ["pi.lifecycle"] = { attach = function() return true end },
  }, function()
    local bridge = require("pi.codecompanion")
    local root = H.tmpdir()
    assert(bridge.ensure(root, { hidden = true }))

    H.eq(false, bridge.model(root))
    H.eq(false, bridge.thinking(root))
  end)
end)
