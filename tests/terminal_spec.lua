local H = require("tests.helpers")

local function wait_for(predicate)
  H.truthy(vim.wait(2000, predicate, 20), "timed out waiting for terminal")
end

H.test("manual terminal launches in the explicit cwd", function()
  package.loaded.snacks = nil
  package.loaded["pi.terminal"] = nil
  local config = require("pi.config")
  local terminal = require("pi.terminal")
  local root = H.tmpdir()
  config.setup({ terminal = { cmd = "sh -c 'pwd; sleep 30'", continue_session = false } })
  terminal.open({ cwd = root })
  wait_for(function()
    return terminal.is_alive()
  end)
  wait_for(function()
    return table.concat(vim.api.nvim_buf_get_lines(terminal.buf, 0, -1, false), "\n"):find(root, 1, true)
  end)
  H.eq(root, terminal.get_cwd())
  H.truthy(table.concat(vim.api.nvim_buf_get_lines(terminal.buf, 0, -1, false), "\n"):find(root, 1, true))
  terminal.stop()
end)

H.test("first terminal send skips clear and later sends clear", function()
  package.loaded.snacks = nil
  package.loaded["pi.terminal"] = nil
  local config = require("pi.config")
  local terminal = require("pi.terminal")
  local root = H.tmpdir()
  config.setup({
    terminal = {
      cmd = "sh -c 'sleep 30'",
      continue_session = false,
      send_delay = 100,
      startup_timeout = 10,
      clear_before_send = true,
    },
  })

  local original_chansend = vim.fn.chansend
  local payloads = {}
  vim.fn.chansend = function(_, data)
    payloads[#payloads + 1] = data
    return 1
  end

  local ok, test_err = xpcall(function()
    terminal.send("first", { submit = false, cwd = root })
    terminal.send("second", { submit = false, cwd = root })
    wait_for(function()
      return vim.tbl_contains(payloads, "second")
    end)
    H.eq({ "first", "\x03", "second" }, payloads)
  end, debug.traceback)

  vim.fn.chansend = original_chansend
  terminal.stop()
  if not ok then
    error(test_err, 0)
  end
end)

H.test("deferred send does not cross a same-cwd process restart", function()
  package.loaded.snacks = nil
  package.loaded["pi.terminal"] = nil
  local config = require("pi.config")
  local terminal = require("pi.terminal")
  local root = H.tmpdir()
  config.setup({
    terminal = {
      cmd = "sh -c 'sleep 30'",
      continue_session = false,
      send_delay = 100,
      startup_timeout = 10,
      clear_before_send = true,
    },
  })
  terminal.open({ cwd = root })
  wait_for(terminal.is_alive)

  local original_chansend = vim.fn.chansend
  local payloads = {}
  vim.fn.chansend = function(_, data)
    payloads[#payloads + 1] = data
    return 1
  end

  local ok, test_err = xpcall(function()
    terminal.send("initial", { submit = false, cwd = root })
    wait_for(function()
      return vim.tbl_contains(payloads, "initial")
    end)

    payloads = {}
    terminal.send("stale", { submit = false, cwd = root })
    terminal.stop()
    terminal.open({ cwd = root })
    wait_for(terminal.is_alive)

    payloads = {}
    terminal.send("fresh", { submit = false, cwd = root })
    wait_for(function()
      return vim.tbl_contains(payloads, "fresh")
    end)
    H.eq({ "fresh" }, payloads)
  end, debug.traceback)

  vim.fn.chansend = original_chansend
  terminal.stop()
  if not ok then
    error(test_err, 0)
  end
end)

H.test("opening another cwd replaces the terminal job", function()
  package.loaded["pi.terminal"] = nil
  local config = require("pi.config")
  local terminal = require("pi.terminal")
  local first = H.tmpdir()
  local second = H.tmpdir()
  config.setup({ terminal = { cmd = "sh -c 'pwd; sleep 30'", continue_session = false } })
  terminal.open({ cwd = first })
  wait_for(terminal.is_alive)
  local first_buf = terminal.buf
  terminal.open({ cwd = second })
  wait_for(function()
    return terminal.is_alive() and terminal.get_cwd() == second
  end)
  H.truthy(terminal.buf ~= first_buf)
  H.eq(false, vim.api.nvim_buf_is_valid(first_buf))
  terminal.stop()
end)

H.test("sending with another cwd replaces a live terminal", function()
  package.loaded.snacks = nil
  package.loaded["pi.terminal"] = nil
  local config = require("pi.config")
  local terminal = require("pi.terminal")
  local first = H.tmpdir()
  local second = H.tmpdir()
  config.setup({
    terminal = {
      cmd = "sh -c 'pwd; sleep 30'",
      continue_session = false,
      send_delay = 0,
      clear_before_send = false,
    },
  })
  terminal.open({ cwd = first })
  wait_for(terminal.is_alive)
  local first_buf = terminal.buf
  terminal.send("prompt", { submit = false, cwd = second })
  wait_for(function()
    return terminal.is_alive() and terminal.get_cwd() == second
  end)
  H.eq(false, vim.api.nvim_buf_is_valid(first_buf))
  wait_for(function()
    return table.concat(vim.api.nvim_buf_get_lines(terminal.buf, 0, -1, false), "\n"):find("prompt", 1, true)
  end)
  terminal.stop()
end)

H.test("sending for another cwd supersedes a queued send", function()
  package.loaded.snacks = nil
  package.loaded["pi.terminal"] = nil
  local config = require("pi.config")
  local terminal = require("pi.terminal")
  local first = H.tmpdir()
  local second = H.tmpdir()
  config.setup({
    terminal = {
      cmd = "sh -c 'sleep 30'",
      continue_session = false,
      startup_timeout = 10,
      send_delay = 100,
      clear_before_send = true,
    },
  })

  local original_chansend = vim.fn.chansend
  local payloads = {}
  vim.fn.chansend = function(_, data)
    payloads[#payloads + 1] = data
    return 1
  end

  local ok, test_err = xpcall(function()
    terminal.send("superseded", { submit = false, cwd = first })
    terminal.send("replacement", { submit = false, cwd = second })
    wait_for(function()
      return vim.tbl_contains(payloads, "replacement")
    end)
    H.eq({ "replacement" }, payloads)
    H.eq(second, terminal.get_cwd())
  end, debug.traceback)

  vim.fn.chansend = original_chansend
  terminal.stop()
  if not ok then
    error(test_err, 0)
  end
end)

H.test("deferred send restores its requested cwd after replacement", function()
  package.loaded.snacks = nil
  package.loaded["pi.terminal"] = nil
  local config = require("pi.config")
  local terminal = require("pi.terminal")
  local first = H.tmpdir()
  local second = H.tmpdir()
  config.setup({
    terminal = {
      cmd = "sh -c 'pwd; sleep 30'",
      continue_session = false,
      startup_timeout = 200,
      max_retries = 4,
      send_delay = 0,
      clear_before_send = false,
    },
  })
  terminal.send("queued prompt", { submit = false, cwd = first })
  terminal.open({ cwd = second })
  wait_for(function()
    return terminal.is_alive() and terminal.get_cwd() == first
  end)
  wait_for(function()
    return table.concat(vim.api.nvim_buf_get_lines(terminal.buf, 0, -1, false), "\n"):find("queued prompt", 1, true)
  end)
  terminal.stop()
end)

H.test("snacks terminal receives the explicit cwd", function()
  local root = H.tmpdir()
  local received
  package.loaded.snacks = {
    terminal = {
      open = function(_, opts)
        received = opts
        local buf = vim.api.nvim_create_buf(false, true)
        return { buf = buf, win = nil }
      end,
    },
  }
  package.loaded["pi.terminal"] = nil
  local terminal = require("pi.terminal")
  terminal.open({ cwd = root })
  H.eq(root, received.cwd)
  terminal.stop()
  package.loaded.snacks = nil
end)
