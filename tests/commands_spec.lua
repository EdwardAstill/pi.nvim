local H = require("tests.helpers")

H.test("Pi commands expose checkpoint review actions and status", function()
  local calls = {}
  package.loaded.pi = {
    toggle = function()
      calls[#calls + 1] = { "toggle" }
    end,
    checkpoint = function()
      calls[#calls + 1] = { "checkpoint" }
    end,
    review = function(scope)
      calls[#calls + 1] = { "review", scope }
    end,
    accept = function(target)
      calls[#calls + 1] = { "accept", target }
    end,
    reject = function(target)
      calls[#calls + 1] = { "reject", target }
    end,
    status = function()
      calls[#calls + 1] = { "status" }
    end,
  }
  vim.g.loaded_pi = nil
  pcall(vim.api.nvim_del_user_command, "Pi")
  vim.cmd.runtime("plugin/pi.lua")

  vim.cmd("Pi checkpoint")
  vim.cmd("Pi review")
  vim.cmd("Pi review turn")
  vim.cmd("Pi review session")
  vim.cmd("Pi accept hunk")
  vim.cmd("Pi accept file")
  vim.cmd("Pi accept all")
  vim.cmd("Pi reject hunk")
  vim.cmd("Pi reject file")
  vim.cmd("Pi status")

  H.eq({
    { "checkpoint" },
    { "review", nil },
    { "review", "turn" },
    { "review", "session" },
    { "accept", "hunk" },
    { "accept", "file" },
    { "accept", "all" },
    { "reject", "hunk" },
    { "reject", "file" },
    { "status" },
  }, calls)
  H.truthy(vim.tbl_contains(vim.fn.getcompletion("Pi review ", "cmdline"), "turn"))

  pcall(vim.api.nvim_del_user_command, "Pi")
  vim.g.loaded_pi = nil
  package.loaded.pi = nil
end)
