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
