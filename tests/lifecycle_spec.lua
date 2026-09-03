local H = require("tests.helpers")

local function with_modules(stubs, fn)
  local saved = {}
  for name, value in pairs(stubs) do
    saved[name] = package.loaded[name]
    package.loaded[name] = value
  end
  local saved_lifecycle = package.loaded["pi.lifecycle"]
  package.loaded["pi.lifecycle"] = nil
  local ok, test_err = xpcall(fn, debug.traceback)
  package.loaded["pi.lifecycle"] = saved_lifecycle
  for name in pairs(stubs) do
    package.loaded[name] = saved[name]
  end
  if not ok then
    error(test_err, 0)
  end
end

local function fake_chat(adapter_name)
  local callbacks = {}
  local chat = {
    adapter = { name = adapter_name or "pi", type = "acp" },
    bufnr = vim.api.nvim_create_buf(false, true),
    callbacks = callbacks,
  }

  function chat:add_callback(name, callback)
    callbacks[name] = callbacks[name] or {}
    callbacks[name][#callbacks[name] + 1] = callback
  end

  function chat:submit()
    for _, callback in ipairs(callbacks.on_before_submit or {}) do
      if callback(self, { adapter = self.adapter }) == false then
        self.cancelled = true
        return false
      end
    end
    self.cwd_during_submit = vim.fn.getcwd()
    self.sent = (self.sent or 0) + 1
    return true
  end

  return chat
end

local function lifecycle_stubs(overrides)
  local stubs = {
    ["pi.config"] = {
      opts = {
        events = { reload = false },
        review = { enabled = true, save_before_prompt = true },
      },
    },
    ["pi.project"] = {
      save_modified = function() return true end,
      is_within = function(root, path)
        return path == root or vim.startswith(path, root .. "/")
      end,
      resolve_cwd = function() return vim.fn.getcwd() end,
    },
    ["pi.checkpoint"] = {
      start_turn = function() return true end,
      cleanup = function() end,
    },
  }
  for name, value in pairs(overrides or {}) do
    stubs[name] = value
  end
  return stubs
end

H.test("lifecycle ignores non-Pi chats and attaches Pi chats once", function()
  with_modules(lifecycle_stubs(), function()
    local lifecycle = require("pi.lifecycle")
    local root = H.tmpdir()
    local other = fake_chat("other")
    local pi_chat = fake_chat("pi")

    H.eq(false, lifecycle.attach(other, root))
    H.eq(0, vim.tbl_count(other.callbacks))
    H.eq(true, lifecycle.attach(pi_chat, root))
    H.eq(true, lifecycle.attach(pi_chat, root))
    H.eq(1, #(pi_chat.callbacks.on_before_submit or {}))

    pi_chat.adapter = { name = "pi", type = "acp" }
    H.eq(true, lifecycle.attach(pi_chat, root))
    H.eq(root, pi_chat.adapter._pi_cwd)
    H.eq(1, #(pi_chat.callbacks.on_before_submit or {}))
  end)
end)

H.test("pre-submit saves project buffers before capturing the turn", function()
  local order = {}
  with_modules(lifecycle_stubs({
    ["pi.project"] = {
      save_modified = function(root)
        order[#order + 1] = "save:" .. root
        return true
      end,
      is_within = function() return false end,
      resolve_cwd = function() return vim.fn.getcwd() end,
    },
    ["pi.checkpoint"] = {
      start_turn = function(root)
        order[#order + 1] = "checkpoint:" .. root
        return true
      end,
      cleanup = function() end,
    },
  }), function()
    local lifecycle = require("pi.lifecycle")
    local root = H.tmpdir()
    local chat = fake_chat()
    local original_submit = chat.submit
    chat.submit = function(self)
      local result = original_submit(self)
      if result then
        order[#order + 1] = "send:" .. self.cwd_during_submit
      end
      return result
    end
    lifecycle.attach(chat, root)

    H.eq(true, chat:submit())
    H.eq({ "save:" .. root, "checkpoint:" .. root, "send:" .. root }, order)
  end)
end)

H.test("disabled review still saves and checkpoints before submission", function()
  local save_calls = 0
  local checkpoint_calls = 0
  with_modules(lifecycle_stubs({
    ["pi.config"] = {
      opts = {
        events = { reload = false },
        review = { enabled = false, save_before_prompt = false },
      },
    },
    ["pi.project"] = {
      save_modified = function()
        save_calls = save_calls + 1
        return true
      end,
      is_within = function() return false end,
      resolve_cwd = function() return vim.fn.getcwd() end,
    },
    ["pi.checkpoint"] = {
      start_turn = function()
        checkpoint_calls = checkpoint_calls + 1
        return true
      end,
      cleanup = function() end,
    },
  }), function()
    local lifecycle = require("pi.lifecycle")
    local chat = fake_chat()
    lifecycle.attach(chat, H.tmpdir())

    H.eq(true, chat:submit())
  end)

  H.eq(1, save_calls)
  H.eq(1, checkpoint_calls)
end)

H.test("save failure cancels submission before checkpointing", function()
  local checkpoint_calls = 0
  local notices = {}
  with_modules(lifecycle_stubs({
    ["pi.project"] = {
      save_modified = function() return false, "save failed" end,
      is_within = function() return false end,
      resolve_cwd = function() return vim.fn.getcwd() end,
    },
    ["pi.checkpoint"] = {
      start_turn = function()
        checkpoint_calls = checkpoint_calls + 1
        return true
      end,
      cleanup = function() end,
    },
  }), function()
    local original_notify = vim.notify
    vim.notify = function(message)
      notices[#notices + 1] = message
    end
    local lifecycle = require("pi.lifecycle")
    local chat = fake_chat()
    lifecycle.attach(chat, H.tmpdir())
    local call_ok, submitted = pcall(chat.submit, chat)
    vim.notify = original_notify

    H.eq(true, call_ok)
    H.eq(false, submitted)
    H.eq(true, chat.cancelled)
    H.eq(nil, chat.sent)
    H.eq(0, checkpoint_calls)
    H.eq(1, #notices)
  end)
end)

H.test("checkpoint failure cancels submission", function()
  local notices = {}
  with_modules(lifecycle_stubs({
    ["pi.checkpoint"] = {
      start_turn = function()
        return nil, { message = "snapshot failed" }
      end,
      cleanup = function() end,
    },
  }), function()
    local original_notify = vim.notify
    vim.notify = function(message)
      notices[#notices + 1] = message
    end
    local lifecycle = require("pi.lifecycle")
    local chat = fake_chat()
    lifecycle.attach(chat, H.tmpdir())
    local call_ok, submitted = pcall(chat.submit, chat)
    vim.notify = original_notify

    H.eq(true, call_ok)
    H.eq(false, submitted)
    H.eq(true, chat.cancelled)
    H.eq(nil, chat.sent)
    H.truthy(notices[1]:find("snapshot failed", 1, true))
  end)
end)

H.test("thrown save error cancels submission before checkpointing", function()
  local checkpoint_calls = 0
  local notices = {}
  with_modules(lifecycle_stubs({
    ["pi.project"] = {
      save_modified = function() error("save exploded") end,
      is_within = function() return false end,
      resolve_cwd = function() return vim.fn.getcwd() end,
    },
    ["pi.checkpoint"] = {
      start_turn = function()
        checkpoint_calls = checkpoint_calls + 1
        return true
      end,
      cleanup = function() end,
    },
  }), function()
    local original_notify = vim.notify
    vim.notify = function(message)
      notices[#notices + 1] = message
    end
    local lifecycle = require("pi.lifecycle")
    local chat = fake_chat()
    lifecycle.attach(chat, H.tmpdir())
    local call_ok, submitted = pcall(chat.submit, chat)
    vim.notify = original_notify

    H.eq(true, call_ok)
    H.eq(false, submitted)
    H.eq(nil, chat.sent)
    H.eq(0, checkpoint_calls)
    H.truthy(notices[1]:find("save exploded", 1, true))
  end)
end)

H.test("thrown checkpoint error cancels submission", function()
  local notices = {}
  with_modules(lifecycle_stubs({
    ["pi.checkpoint"] = {
      start_turn = function() error("checkpoint exploded") end,
      cleanup = function() end,
    },
  }), function()
    local original_notify = vim.notify
    vim.notify = function(message)
      notices[#notices + 1] = message
    end
    local lifecycle = require("pi.lifecycle")
    local chat = fake_chat()
    lifecycle.attach(chat, H.tmpdir())
    local call_ok, submitted = pcall(chat.submit, chat)
    vim.notify = original_notify

    H.eq(true, call_ok)
    H.eq(false, submitted)
    H.eq(nil, chat.sent)
    H.truthy(notices[1]:find("checkpoint exploded", 1, true))
  end)
end)

H.test("attached chat stops Pi lifecycle effects after changing adapters", function()
  local save_calls = 0
  local checkpoint_calls = 0
  local observed_cwd
  local original_global = vim.fn.getcwd(-1, -1)
  local expected_previous
  with_modules(lifecycle_stubs({
    ["pi.project"] = {
      save_modified = function()
        save_calls = save_calls + 1
        return true
      end,
      is_within = function() return false end,
      resolve_cwd = function() return vim.fn.getcwd() end,
    },
    ["pi.checkpoint"] = {
      start_turn = function()
        checkpoint_calls = checkpoint_calls + 1
        return true
      end,
      cleanup = function() end,
    },
  }), function()
    local lifecycle = require("pi.lifecycle")
    local root = H.tmpdir()
    expected_previous = H.tmpdir()
    vim.cmd.cd(vim.fn.fnameescape(expected_previous))
    local chat = fake_chat()
    lifecycle.attach(chat, root)
    chat.adapter = { name = "other", type = "acp" }
    chat:submit()
    observed_cwd = chat.cwd_during_submit
    vim.cmd.cd(vim.fn.fnameescape(original_global))
  end)

  H.eq(0, save_calls)
  H.eq(0, checkpoint_calls)
  H.eq(expected_previous, observed_cwd)
end)

H.test("submission cwd guard preserves global tab and window directories", function()
  with_modules(lifecycle_stubs(), function()
    local lifecycle = require("pi.lifecycle")
    local original_window = vim.api.nvim_get_current_win()
    local original_global = vim.fn.getcwd(-1, -1)
    local cases = {
      { command = "cd", window_local = 0, tab_local = 0 },
      { command = "tcd", window_local = 0, tab_local = 1 },
      { command = "lcd", window_local = 1, tab_local = 0 },
    }

    for _, case in ipairs(cases) do
      vim.cmd.tabnew()
      local previous = H.tmpdir()
      local root = H.tmpdir()
      vim.cmd[case.command](vim.fn.fnameescape(previous))
      local chat = fake_chat()
      lifecycle.attach(chat, root)

      H.eq(true, chat:submit())
      H.eq(root, chat.cwd_during_submit)
      H.eq(previous, vim.fn.getcwd())
      H.eq(case.window_local, vim.fn.haslocaldir())
      H.eq(case.tab_local, vim.fn.haslocaldir(-1, 0))
      H.eq(case.command == "cd" and previous or original_global, vim.fn.getcwd(-1, -1))

      if case.command == "cd" then
        vim.cmd.cd(vim.fn.fnameescape(original_global))
      end
      vim.cmd.tabclose({ bang = true })
    end
    vim.api.nvim_set_current_win(original_window)
  end)
end)

H.test("submission cwd guard restores the original window after an error switches focus", function()
  local restored_cwd
  local submit_error
  local expected_previous
  with_modules(lifecycle_stubs(), function()
    local lifecycle = require("pi.lifecycle")
    vim.cmd.tabnew()
    local root = H.tmpdir()
    expected_previous = H.tmpdir()
    vim.cmd.lcd(vim.fn.fnameescape(expected_previous))
    local original_window = vim.api.nvim_get_current_win()
    vim.cmd.vsplit()
    local other_window = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(original_window)
    local chat = fake_chat()
    local submit = chat.submit
    chat.submit = function(self)
      submit(self)
      vim.api.nvim_set_current_win(other_window)
      error("forced submit failure")
    end
    lifecycle.attach(chat, root)

    local ok, err = pcall(chat.submit, chat)
    submit_error = ok and nil or err
    restored_cwd = vim.api.nvim_win_call(original_window, vim.fn.getcwd)
    vim.cmd.tabclose({ bang = true })
  end)

  H.truthy(submit_error and submit_error:find("forced submit failure", 1, true))
  H.eq(expected_previous, restored_cwd)
end)

H.test("submission cwd guard restores the original tab after an error switches tabs", function()
  local restored_cwd
  local submit_error
  local expected_previous
  with_modules(lifecycle_stubs(), function()
    local lifecycle = require("pi.lifecycle")
    local runner_tab = vim.api.nvim_get_current_tabpage()
    vim.cmd.tabnew()
    local original_tab = vim.api.nvim_get_current_tabpage()
    local original_window = vim.api.nvim_get_current_win()
    local root = H.tmpdir()
    expected_previous = H.tmpdir()
    vim.cmd.tcd(vim.fn.fnameescape(expected_previous))
    vim.cmd.tabnew()
    local other_tab = vim.api.nvim_get_current_tabpage()
    vim.api.nvim_set_current_tabpage(original_tab)
    local chat = fake_chat()
    local submit = chat.submit
    chat.submit = function(self)
      submit(self)
      vim.api.nvim_set_current_tabpage(other_tab)
      error("forced submit failure")
    end
    lifecycle.attach(chat, root)

    local ok, err = pcall(chat.submit, chat)
    submit_error = ok and nil or err
    restored_cwd = vim.api.nvim_win_call(original_window, vim.fn.getcwd)
    vim.api.nvim_set_current_tabpage(other_tab)
    vim.cmd.tabclose({ bang = true })
    vim.api.nvim_set_current_tabpage(original_tab)
    vim.cmd.tabclose({ bang = true })
    vim.api.nvim_set_current_tabpage(runner_tab)
  end)

  H.truthy(submit_error and submit_error:find("forced submit failure", 1, true))
  H.eq(expected_previous, restored_cwd)
end)

H.test("adapter hooks use the project cwd for eager ACP process and session setup", function()
  local during_setup
  local during_auth
  local restored_after_setup
  local restored_after_auth
  local expected_previous
  local root = H.tmpdir()
  with_modules(lifecycle_stubs({
    ["codecompanion.adapters.acp.helpers"] = {
      form_messages = function() return {} end,
    },
  }), function()
    package.loaded["pi.codecompanion"] = nil
    local lifecycle = require("pi.lifecycle")
    local adapter = require("pi.codecompanion").adapter()
    local chat = fake_chat()
    chat.adapter = adapter
    lifecycle.attach(chat, root)
    vim.cmd.tabnew()
    expected_previous = H.tmpdir()
    vim.cmd.tcd(vim.fn.fnameescape(expected_previous))

    H.eq(true, adapter.handlers.setup(adapter))
    during_setup = vim.fn.getcwd()
    restored_after_setup = vim.wait(200, function()
      return vim.fn.getcwd() == expected_previous
    end)
    H.eq(true, adapter.handlers.auth(adapter))
    during_auth = vim.fn.getcwd()
    restored_after_auth = vim.wait(200, function()
      return vim.fn.getcwd() == expected_previous
    end)
    vim.cmd.tabclose({ bang = true })
    package.loaded["pi.codecompanion"] = nil
  end)

  H.eq(root, during_setup)
  H.eq(root, during_auth)
  H.eq(true, restored_after_setup)
  H.eq(true, restored_after_auth)
end)

H.test("overlapping ACP cwd hooks restore the original directory", function()
  local final_cwd
  local expected_previous
  with_modules(lifecycle_stubs({
    ["codecompanion.adapters.acp.helpers"] = {
      form_messages = function() return {} end,
    },
  }), function()
    package.loaded["pi.codecompanion"] = nil
    local lifecycle = require("pi.lifecycle")
    local first = require("pi.codecompanion").adapter()
    local second = require("pi.codecompanion").adapter()
    local first_chat = fake_chat()
    local second_chat = fake_chat()
    first_chat.adapter = first
    second_chat.adapter = second
    lifecycle.attach(first_chat, H.tmpdir())
    lifecycle.attach(second_chat, H.tmpdir())
    vim.cmd.tabnew()
    expected_previous = H.tmpdir()
    vim.cmd.tcd(vim.fn.fnameescape(expected_previous))

    H.eq(true, first.handlers.setup(first))
    H.eq(true, second.handlers.setup(second))
    vim.wait(50, function() return false end)
    final_cwd = vim.fn.getcwd()
    vim.cmd.tabclose({ bang = true })
    package.loaded["pi.codecompanion"] = nil
  end)

  H.eq(expected_previous, final_cwd)
end)

H.test("ACP cwd restoration ignores a destroyed tab-local scope", function()
  local runner_cwd
  local final_cwd
  with_modules(lifecycle_stubs({
    ["codecompanion.adapters.acp.helpers"] = {
      form_messages = function() return {} end,
    },
  }), function()
    package.loaded["pi.codecompanion"] = nil
    local lifecycle = require("pi.lifecycle")
    local adapter = require("pi.codecompanion").adapter()
    local chat = fake_chat()
    chat.adapter = adapter
    lifecycle.attach(chat, H.tmpdir())
    runner_cwd = vim.fn.getcwd()
    vim.cmd.tabnew()
    vim.cmd.tcd(vim.fn.fnameescape(H.tmpdir()))

    H.eq(true, adapter.handlers.setup(adapter))
    vim.cmd.tabclose({ bang = true })
    vim.wait(50, function() return false end)
    final_cwd = vim.fn.getcwd()
    package.loaded["pi.codecompanion"] = nil
  end)

  H.eq(runner_cwd, final_cwd)
end)

H.test("ACP cwd restoration ignores a destroyed window-local scope", function()
  local surviving_cwd
  local final_cwd
  with_modules(lifecycle_stubs({
    ["codecompanion.adapters.acp.helpers"] = {
      form_messages = function() return {} end,
    },
  }), function()
    package.loaded["pi.codecompanion"] = nil
    local lifecycle = require("pi.lifecycle")
    local adapter = require("pi.codecompanion").adapter()
    local chat = fake_chat()
    chat.adapter = adapter
    lifecycle.attach(chat, H.tmpdir())
    vim.cmd.tabnew()
    surviving_cwd = H.tmpdir()
    vim.cmd.tcd(vim.fn.fnameescape(surviving_cwd))
    vim.cmd.vsplit()
    local guarded_window = vim.api.nvim_get_current_win()
    vim.cmd.lcd(vim.fn.fnameescape(H.tmpdir()))

    H.eq(true, adapter.handlers.setup(adapter))
    vim.api.nvim_win_close(guarded_window, true)
    vim.wait(50, function() return false end)
    final_cwd = vim.fn.getcwd()
    vim.cmd.tabclose({ bang = true })
    package.loaded["pi.codecompanion"] = nil
  end)

  H.eq(surviving_cwd, final_cwd)
end)

H.test("completion reloads project buffers and refreshes pending review", function()
  local refreshed
  local root = H.repo()
  local path = root .. "/tracked.txt"
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  with_modules(lifecycle_stubs({
    ["pi.project"] = require("pi.project"),
    ["pi.review.minidiff"] = {
      refresh_all = function(cwd)
        refreshed = cwd
      end,
    },
  }), function()
    local lifecycle = require("pi.lifecycle")
    local chat = fake_chat()
    lifecycle.attach(chat, root)
    H.write(path, "reloaded\n")

    for _, callback in ipairs(chat.callbacks.on_completed) do
      callback(chat, { status = "success" })
    end

    H.eq({ "reloaded" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    H.eq(root, refreshed)
  end)
end)

H.test("restored CodeCompanion submission returns the draft to codecompanion-ui", function()
  local input_buf = vim.api.nvim_create_buf(false, true)
  local chat_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "keep this draft" })
  vim.api.nvim_buf_set_lines(chat_buf, 0, -1, false, { "history" })
  local session = { input_bufnr = input_buf, chat_bufnr = chat_buf }
  local input = {
    refresh_placeholder = function() end,
    submit = function(current)
      local lines = vim.api.nvim_buf_get_lines(current.input_bufnr, 0, -1, false)
      vim.api.nvim_buf_set_lines(current.input_bufnr, 0, -1, false, { "" })
      vim.api.nvim_buf_set_lines(current.chat_bufnr, -1, -1, false, lines)
    end,
  }
  with_modules(lifecycle_stubs({
    ["codecompanion-ui.input"] = input,
    ["codecompanion-ui.state"] = {
      get_by_bufnr = function(bufnr)
        return bufnr == chat_buf and session or nil
      end,
    },
    codecompanion = {
      buf_get_chat = function()
        return { adapter = { name = "pi" }, bufnr = chat_buf }
      end,
    },
  }), function()
    local lifecycle = require("pi.lifecycle")
    lifecycle.setup()
    input.submit(session)
    H.eq({ "" }, vim.api.nvim_buf_get_lines(input_buf, 0, -1, false))

    vim.api.nvim_exec_autocmds("User", {
      pattern = "CodeCompanionChatRestored",
      data = { bufnr = chat_buf },
    })

    H.eq({ "keep this draft" }, vim.api.nvim_buf_get_lines(input_buf, 0, -1, false))
    H.eq({ "history" }, vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false))
  end)
end)

H.test("draft recovery hook installs when codecompanion-ui loads after setup", function()
  local chat = fake_chat()
  local input = {
    submit = function() end,
  }
  with_modules(lifecycle_stubs({
    ["codecompanion-ui.input"] = false,
    codecompanion = {
      buf_get_chat = function(bufnr)
        return bufnr == chat.bufnr and chat or nil
      end,
    },
    ["pi.codecompanion"] = {
      register = function() end,
    },
  }), function()
    local lifecycle = require("pi.lifecycle")
    lifecycle.setup()
    package.loaded["codecompanion-ui.input"] = input

    vim.api.nvim_exec_autocmds("User", {
      pattern = "CodeCompanionChatCreated",
      data = { bufnr = chat.bufnr },
    })

    H.truthy(input._pi_original_submit)
  end)
end)

H.test("cancelled submission restores composer whitespace exactly", function()
  local input_buf = vim.api.nvim_create_buf(false, true)
  local chat_buf = vim.api.nvim_create_buf(false, true)
  local original = { "  indented", "", "trailing  ", "" }
  vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, original)
  vim.api.nvim_buf_set_lines(chat_buf, 0, -1, false, { "history" })
  local session = { input_bufnr = input_buf, chat_bufnr = chat_buf }
  local input = {
    refresh_placeholder = function() end,
    submit = function(current)
      local lines = vim.api.nvim_buf_get_lines(current.input_bufnr, 0, -1, false)
      local text = vim.trim(table.concat(lines, "\n"))
      vim.api.nvim_buf_set_lines(current.input_bufnr, 0, -1, false, { "" })
      vim.api.nvim_buf_set_lines(current.chat_bufnr, -1, -1, false, vim.split(text, "\n", { plain = true }))
    end,
  }
  with_modules(lifecycle_stubs({
    ["codecompanion-ui.input"] = input,
    ["codecompanion-ui.state"] = {
      get_by_bufnr = function(bufnr)
        return bufnr == chat_buf and session or nil
      end,
    },
    codecompanion = {
      buf_get_chat = function()
        return { adapter = { name = "pi" }, bufnr = chat_buf }
      end,
    },
  }), function()
    local lifecycle = require("pi.lifecycle")
    lifecycle.setup()
    input.submit(session)
    vim.api.nvim_exec_autocmds("User", {
      pattern = "CodeCompanionChatRestored",
      data = { bufnr = chat_buf },
    })

    H.eq(original, vim.api.nvim_buf_get_lines(input_buf, 0, -1, false))
    H.eq({ "history" }, vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false))
  end)
end)

H.test("codecompanion-ui draft recovery ignores non-Pi chats", function()
  local input_buf = vim.api.nvim_create_buf(false, true)
  local chat_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "other draft" })
  vim.api.nvim_buf_set_lines(chat_buf, 0, -1, false, { "history" })
  local session = { input_bufnr = input_buf, chat_bufnr = chat_buf }
  local input = {
    refresh_placeholder = function() end,
    submit = function(current)
      local lines = vim.api.nvim_buf_get_lines(current.input_bufnr, 0, -1, false)
      vim.api.nvim_buf_set_lines(current.input_bufnr, 0, -1, false, { "" })
      vim.api.nvim_buf_set_lines(current.chat_bufnr, -1, -1, false, lines)
    end,
  }
  with_modules(lifecycle_stubs({
    ["codecompanion-ui.input"] = input,
    ["codecompanion-ui.state"] = {
      get_by_bufnr = function(bufnr)
        return bufnr == chat_buf and session or nil
      end,
    },
    codecompanion = {
      buf_get_chat = function()
        return { adapter = { name = "other" }, bufnr = chat_buf }
      end,
    },
  }), function()
    local lifecycle = require("pi.lifecycle")
    lifecycle.setup()
    input.submit(session)
    vim.api.nvim_exec_autocmds("User", {
      pattern = "CodeCompanionChatRestored",
      data = { bufnr = chat_buf },
    })

    H.eq({ "" }, vim.api.nvim_buf_get_lines(input_buf, 0, -1, false))
    H.eq({ "history", "other draft" }, vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false))
  end)
end)

H.test("CodeCompanion-created Pi chat is registered for facade reuse", function()
  local registered
  local chat = fake_chat()
  with_modules(lifecycle_stubs({
    codecompanion = {
      buf_get_chat = function(bufnr)
        return bufnr == chat.bufnr and chat or nil
      end,
    },
    ["pi.codecompanion"] = {
      register = function(current, cwd)
        registered = { chat = current, cwd = cwd }
      end,
    },
  }), function()
    local lifecycle = require("pi.lifecycle")
    lifecycle.setup()
    vim.api.nvim_exec_autocmds("User", {
      pattern = "CodeCompanionChatCreated",
      data = { bufnr = chat.bufnr },
    })
  end)

  H.eq(chat, registered.chat)
  H.eq(chat._pi_cwd, registered.cwd)
end)

H.test("a managed chat must start fresh instead of switching back to Pi", function()
  local chat = fake_chat()
  local root = H.tmpdir()
  local changes = {}
  chat.change_adapter = function(self, name)
    changes[#changes + 1] = name
    self.adapter = { name = name, type = name == "pi" and "acp" or "http" }
    return true
  end
  with_modules(lifecycle_stubs({
    ["pi.codecompanion"] = { forget = function() end },
  }), function()
    local lifecycle = require("pi.lifecycle")
    lifecycle.attach(chat, root)

    H.eq(true, chat:change_adapter("other"))
    H.eq("other", chat.adapter.name)
    H.eq(false, chat:change_adapter("pi"))
    H.eq("other", chat.adapter.name)
    H.eq({ "other" }, changes)
  end)
end)
