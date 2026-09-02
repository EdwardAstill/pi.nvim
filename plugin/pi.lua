-- pi.nvim plugin auto-load
-- Runs automatically when lazy.nvim loads the plugin

if vim.g.loaded_pi then
  return
end
vim.g.loaded_pi = 1

-- Highlight groups
vim.api.nvim_set_hl(0, "PiContextPlaceholder", { default = true, link = "Special" })
vim.api.nvim_set_hl(0, "PiContextValue", { default = true, link = "String" })
vim.api.nvim_set_hl(0, "PiTerminalBorder", { default = true, link = "FloatBorder" })

-- File reload autocmds: detect files edited by pi
local reload_group = vim.api.nvim_create_augroup("PiFileReload", { clear = true })

vim.api.nvim_create_autocmd({ "FocusGained", "BufEnter" }, {
  group = reload_group,
  callback = function()
    -- Check if pi.nvim is configured and reload is enabled
    local ok, config = pcall(require, "pi.config")
    if not ok or not config.opts or not config.opts.events.reload then
      return
    end
    -- Schedule to avoid blocking event loop
    vim.schedule(function()
      pcall(vim.cmd, "checktime")
    end)
  end,
  desc = "pi.nvim: reload buffers when files change externally",
})

-- Terminal cleanup on VimLeavePre
vim.api.nvim_create_autocmd("VimLeavePre", {
  group = vim.api.nvim_create_augroup("PiCleanup", { clear = true }),
  callback = function()
    local review_ok, review = pcall(require, "pi.review")
    if review_ok then
      pcall(review.close)
    end
    local ok, terminal = pcall(require, "pi.terminal")
    if ok then
      pcall(terminal.stop)
    end
    local checkpoint_ok, checkpoint = pcall(require, "pi.checkpoint")
    if checkpoint_ok then
      pcall(checkpoint.cleanup)
    end
  end,
  desc = "pi.nvim: clean up terminal and review state on exit",
})

-- User commands
vim.api.nvim_create_user_command("Pi", function(cmd_opts)
  local args = cmd_opts.fargs
  local subcmd = args[1] or "toggle"
  local pi = require("pi")

  if subcmd == "toggle" then
    pi.toggle()
  elseif subcmd == "ask" then
    local text = table.concat(vim.list_slice(args, 2), " ")
    pi.ask(text ~= "" and text or nil)
  elseif subcmd == "prompt" then
    local text = table.concat(vim.list_slice(args, 2), " ")
    if text ~= "" then
      pi.prompt(text)
    else
      vim.notify("Pi: prompt requires text argument", vim.log.levels.WARN)
    end
  elseif subcmd == "select" then
    pi.select()
  elseif subcmd == "abort" then
    pi.abort()
  elseif subcmd == "checkpoint" then
    pi.checkpoint()
  elseif subcmd == "review" then
    local scope = args[2]
    if scope == nil or vim.tbl_contains({ "turn", "session" }, scope) then
      pi.review(scope)
    else
      vim.notify("Pi: review scope must be turn or session", vim.log.levels.WARN)
    end
  elseif subcmd == "accept" then
    local target = args[2]
    if vim.tbl_contains({ "hunk", "file", "all" }, target) then
      pi.accept(target)
    else
      vim.notify("Pi: accept target must be hunk, file, or all", vim.log.levels.WARN)
    end
  elseif subcmd == "reject" then
    local target = args[2]
    if vim.tbl_contains({ "hunk", "file" }, target) then
      pi.reject(target)
    else
      vim.notify("Pi: reject target must be hunk or file", vim.log.levels.WARN)
    end
  elseif subcmd == "status" then
    pi.status()
  else
    -- Treat entire input as a prompt
    local text = table.concat(args, " ")
    pi.prompt(text)
  end
end, {
  nargs = "*",
  desc = "Pi coding agent",
  complete = function(arg_lead, line)
    local subcmds = { "toggle", "ask", "prompt", "select", "abort", "checkpoint", "review", "accept", "reject", "status" }
    local parts = vim.split(vim.trim(line), "%s+")
    if #parts <= 1 or (#parts == 2 and not line:match("%s$")) then
      local prefix = arg_lead or ""
      return vim.tbl_filter(function(s)
        return s:find(prefix, 1, true) == 1
      end, subcmds)
    end
    -- For :Pi prompt <name>, complete with named prompts
    if parts[2] == "prompt" and #parts <= 3 then
      local ok, config = pcall(require, "pi.config")
      if ok and config.opts then
        local prefix = parts[3] or ""
        local names = vim.tbl_keys(config.opts.prompts)
        return vim.tbl_filter(function(s)
          return s:find(prefix, 1, true) == 1
        end, names)
      end
    end
    local choices = {
      review = { "turn", "session" },
      accept = { "hunk", "file", "all" },
      reject = { "hunk", "file" },
    }
    if choices[parts[2]] then
      return vim.tbl_filter(function(s)
        return s:find(arg_lead, 1, true) == 1
      end, choices[parts[2]])
    end
    return {}
  end,
})
