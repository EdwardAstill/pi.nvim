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
    focus = function()
      calls[#calls + 1] = { "focus" }
    end,
    ask = function(text)
      calls[#calls + 1] = { "ask", text }
    end,
    prompt = function(text)
      calls[#calls + 1] = { "prompt", text }
    end,
    select = function()
      calls[#calls + 1] = { "select" }
    end,
    abort = function()
      calls[#calls + 1] = { "abort" }
    end,
    model = function()
      calls[#calls + 1] = { "model" }
    end,
    thinking = function()
      calls[#calls + 1] = { "thinking" }
    end,
    stop = function()
      calls[#calls + 1] = { "stop" }
    end,
  }
  vim.g.loaded_pi = nil
  pcall(vim.api.nvim_del_user_command, "Pi")
  vim.cmd.runtime("plugin/pi.lua")

  vim.cmd("Pi")
  vim.cmd("Pi focus")
  vim.cmd("Pi ask refactor this")
  vim.cmd("Pi prompt explain")
  vim.cmd("Pi select")
  vim.cmd("Pi abort")
  vim.cmd("Pi model")
  vim.cmd("Pi thinking")
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
  vim.cmd("Pi stop")

  H.eq({
    { "toggle" },
    { "focus" },
    { "ask", "refactor this" },
    { "prompt", "explain" },
    { "select" },
    { "abort" },
    { "model" },
    { "thinking" },
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
    { "stop" },
  }, calls)
  H.truthy(vim.tbl_contains(vim.fn.getcompletion("Pi review ", "cmdline"), "turn"))
  local commands = vim.fn.getcompletion("Pi ", "cmdline")
  H.truthy(vim.tbl_contains(commands, "focus"))
  H.truthy(vim.tbl_contains(commands, "model"))
  H.truthy(vim.tbl_contains(commands, "thinking"))
  H.truthy(vim.tbl_contains(commands, "stop"))

  pcall(vim.api.nvim_del_user_command, "Pi")
  vim.g.loaded_pi = nil
  package.loaded.pi = nil
end)
