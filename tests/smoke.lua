local ok, smoke_err = xpcall(function()
  package.preload["codecompanion.adapters.acp.helpers"] = function()
    return { form_messages = function() return {} end }
  end

  require("pi").setup()
  local config = require("pi.config").opts
  assert(config.terminal == nil, "terminal fallback must not be configured")
  local adapter = require("pi.codecompanion").adapter()
  assert(adapter.type == "acp", "Pi adapter is not ACP")
  assert(adapter.commands.default[1] == "pi-acp", "Pi adapter does not launch pi-acp")
end, debug.traceback)

package.preload["codecompanion.adapters.acp.helpers"] = nil

if not ok then
  print("FAIL Pi ACP adapter loads without a terminal fallback\n" .. smoke_err)
  vim.cmd("cquit 1")
else
  local suffix = vim.fn.executable("pi-acp") == 1 and "" or " (live pi-acp check skipped: executable not installed)"
  print("PASS Pi ACP adapter loads without a terminal fallback" .. suffix)
  vim.cmd("qa!")
end
