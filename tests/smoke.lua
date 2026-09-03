local first_marker = "PI_NVIM_SMOKE_ONE"
local second_marker = "PI_NVIM_SMOKE_TWO"
local terminal

local ok, smoke_err = xpcall(function()
  if vim.fn.executable("pi") ~= 1 then
    error("pi executable is not available")
  end

  require("pi").setup({
    terminal = {
      cmd = table.concat({
        "env PI_OFFLINE=1 pi --no-session",
        "--no-extensions --no-skills --no-prompt-templates",
        "--no-themes --no-context-files",
      }, " "),
      continue_session = false,
      clear_before_send = true,
      startup_timeout = 2000,
    },
  })

  assert(require("pi")._submit(first_marker, { submit = false }))
  assert(require("pi")._submit(second_marker, { submit = false }))
  terminal = require("pi.terminal")

  vim.wait(3000, function()
    return false
  end, 50)

  assert(terminal.is_alive(), "Pi exited during its initial terminal sends")
  local output = table.concat(vim.api.nvim_buf_get_lines(terminal.buf, 0, -1, false), "\n")
  assert(output:find(second_marker, 1, true), "queued terminal sends did not reach Pi's editor in order")
end, debug.traceback)

if terminal then
  terminal.stop()
end
pcall(function()
  require("pi.checkpoint").cleanup()
end)

if not ok then
  print("FAIL real Pi accepts its initial headless sends\n" .. smoke_err)
  vim.cmd("cquit 1")
else
  print("PASS real Pi accepts its initial headless sends")
  vim.cmd("qa!")
end
