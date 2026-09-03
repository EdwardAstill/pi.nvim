local M = {}

local health = vim.fn.has("nvim-0.11") == 1 and {
  start = vim.health.start,
  ok = vim.health.ok,
  warn = vim.health.warn,
  info = vim.health.info,
  error = vim.health.error,
} or {
  start = vim.health.report_start,
  ok = vim.health.report_ok,
  warn = vim.health.report_warn,
  info = vim.health.report_info,
  error = vim.health.report_error,
}

local function executable(name, install)
  if vim.fn.executable(name) == 1 then
    health.ok(name .. " executable found at " .. vim.fn.exepath(name))
    return true
  end
  health.error(name .. " executable not found", { install })
  return false
end

function M.check()
  health.start("pi.nvim")

  if vim.fn.has("nvim-0.11") == 1 then
    health.ok("Neovim >= 0.11")
  else
    health.error("Neovim >= 0.11 required", { "Update Neovim to 0.11 or later" })
  end

  local config = require("pi.config")
  executable("pi", "Install Pi and ensure `pi` is in PATH")
  local acp_command = config.opts.codecompanion.command[1]
  executable(acp_command, "Install pi-acp and ensure its executable is in PATH")
  local git_ok = executable("git", "Install Git and ensure `git` is in PATH")

  local cc_ok, codecompanion = pcall(require, "codecompanion")
  if cc_ok then
    health.ok("CodeCompanion.nvim is available")
    if codecompanion.extensions and codecompanion.extensions.ui then
      health.ok("codecompanion-ui.nvim extension is enabled")
    else
      health.error("codecompanion-ui.nvim extension is not enabled", {
        "Enable the `ui` extension in CodeCompanion configuration",
      })
    end
  else
    health.error("CodeCompanion.nvim is unavailable", { "Install olimorris/codecompanion.nvim" })
  end

  if pcall(require, "mini.diff") then
    health.ok("mini.diff is available")
  else
    health.error("mini.diff is unavailable", { "Install nvim-mini/mini.diff" })
  end

  local cwd = require("pi.project").resolve_cwd()
  health.info("Project: " .. cwd)
  if git_ok then
    local root = require("pi.review.git").discover_root(cwd)
    if root then
      health.ok("Review Git root: " .. root)
    else
      health.warn("Review unavailable outside a Git worktree")
    end
  end

  if config._setup_called then
    health.ok("setup() has been called")
  else
    health.warn("setup() has not been called", { "Call require('pi').setup() in your Neovim config" })
  end
end

return M
