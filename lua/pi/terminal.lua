local config = require("pi.config")

local M = {}

---@type integer|nil Terminal buffer number
M.buf = nil
---@type integer|nil Terminal window id
M.win = nil
---@type integer|nil Terminal job channel id (for chansend)
M.chan = nil
---@type string|nil Terminal working directory
M.cwd = nil

--- Snacks.nvim detection
---@type boolean, table
local has_snacks, Snacks = pcall(require, "snacks")

--- Snacks terminal instance (if using snacks)
---@type table|nil
local snacks_term = nil

---@type boolean Whether pi.nvim has sent input to the current terminal process
local sent_once = false

---@type integer Incremented whenever terminal process state is reset
local process_generation = 0

---@type table[] Sends waiting to be dispatched to the current terminal process
local send_queue = {}

---@type boolean Whether a queued send is waiting for its paste delay
local send_active = false

---@type number Monotonic time after which Ctrl-C is safe for this process
local clear_safe_at = 0

---@type table[] Sends waiting for the requested terminal process to start
local startup_queue = {}

---@type boolean Whether the head of the startup queue is being polled
local startup_polling = false

---@type integer Incremented when queued startup sends are cancelled
local startup_generation = 0

local function cancel_startup_sends()
  startup_generation = startup_generation + 1
  startup_queue = {}
  startup_polling = false
end

local function now_ms()
  return vim.uv.hrtime() / 1000000
end

--- Build the pi command with flags.
---@return string
local function build_cmd()
  local cmd = config.opts.terminal.cmd
  if config.opts.terminal.continue_session then
    cmd = cmd .. " -c"
  end
  return cmd
end

--- Get split size in columns or rows depending on position.
---@return integer
local function split_size()
  local pos = config.opts.terminal.position
  if pos == "bottom" then
    return math.floor(vim.o.lines * config.opts.terminal.size)
  else
    return math.floor(vim.o.columns * config.opts.terminal.size)
  end
end

--- Reset internal state (called when terminal buffer is deleted or process exits).
local function reset_state()
  M.buf = nil
  M.win = nil
  M.chan = nil
  M.cwd = nil
  snacks_term = nil
  sent_once = false
  process_generation = process_generation + 1
  send_queue = {}
  send_active = false
  clear_safe_at = 0
end

--- Set up autocmds to track terminal lifecycle.
---@param buf integer
local function setup_autocmds(buf)
  local group = vim.api.nvim_create_augroup("PiTerminal", { clear = true })

  vim.api.nvim_create_autocmd("BufDelete", {
    group = group,
    buffer = buf,
    callback = function(args)
      if M.buf == args.buf then
        reset_state()
      end
    end,
    desc = "pi.nvim: reset terminal state on buffer delete",
  })

  vim.api.nvim_create_autocmd("TermClose", {
    group = group,
    buffer = buf,
    callback = function(args)
      -- Defer so the buffer can be cleaned up
      vim.schedule(function()
        if M.buf == args.buf then
          reset_state()
        end
      end)
    end,
    desc = "pi.nvim: reset terminal state on process exit",
  })
end

--- Open the terminal panel using snacks.terminal.
---@param cmd string
---@param enter boolean
---@param cwd string
local function open_snacks(cmd, enter, cwd)
  local pos = config.opts.terminal.position
  local snacks_opts = {
    win = {
      position = pos,
      enter = enter,
      wo = { winbar = "" },
    },
    bo = { filetype = "pi_terminal" },
    cwd = cwd,
  }

  if pos == "bottom" then
    snacks_opts.win.height = split_size()
  else
    snacks_opts.win.width = split_size()
  end

  local ok, result = pcall(Snacks.terminal.open, cmd, snacks_opts)
  if not ok then
    vim.notify("Pi: failed to open terminal via snacks.nvim: " .. tostring(result), vim.log.levels.ERROR)
    return
  end

  snacks_term = result

  if snacks_term and snacks_term.buf then
    M.buf = snacks_term.buf
    M.win = snacks_term.win
    -- Find the terminal channel from the buffer
    M.chan = vim.bo[M.buf].channel
    M.cwd = cwd
    setup_autocmds(M.buf)
  else
    vim.notify("Pi: snacks.terminal.open returned unexpected result", vim.log.levels.ERROR)
    snacks_term = nil
  end
end

--- Open the terminal panel using manual split + termopen.
---@param cmd string
---@param enter boolean
---@param cwd string
local function open_manual(cmd, enter, cwd)
  local pos = config.opts.terminal.position
  local size = split_size()
  local source_win = vim.api.nvim_get_current_win()

  if pos == "bottom" then
    vim.cmd("botright " .. size .. "split")
  elseif pos == "left" then
    vim.cmd("topleft " .. size .. "vsplit")
  else -- right
    vim.cmd("botright " .. size .. "vsplit")
  end

  M.win = vim.api.nvim_get_current_win()
  M.chan = vim.fn.termopen(cmd, { cwd = cwd })
  M.cwd = cwd
  M.buf = vim.api.nvim_get_current_buf()

  vim.bo[M.buf].filetype = "pi_terminal"

  -- Minimize rendering overhead for the terminal window
  vim.wo[M.win].winbar = ""
  vim.wo[M.win].number = false
  vim.wo[M.win].relativenumber = false
  vim.wo[M.win].signcolumn = "no"
  vim.wo[M.win].foldcolumn = "0"
  vim.wo[M.win].spell = false

  -- Limit terminal scrollback to reduce memory/rendering cost
  vim.bo[M.buf].scrollback = 5000

  setup_autocmds(M.buf)

  if not enter then
    vim.api.nvim_set_current_win(source_win)
  end
end

--- Re-open the existing terminal buffer in a new split.
---@param enter boolean
---@return boolean success
local function reopen_split(enter)
  -- Guard: ensure buffer is still valid before attempting to reopen
  if not M.buf or not vim.api.nvim_buf_is_valid(M.buf) then
    reset_state()
    return false
  end

  local pos = config.opts.terminal.position
  local size = split_size()
  local source_win = vim.api.nvim_get_current_win()

  if pos == "bottom" then
    vim.cmd("botright " .. size .. "split")
  elseif pos == "left" then
    vim.cmd("topleft " .. size .. "vsplit")
  else
    vim.cmd("botright " .. size .. "vsplit")
  end

  M.win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(M.win, M.buf)

  -- Minimize rendering overhead for the terminal window
  vim.wo[M.win].winbar = ""
  vim.wo[M.win].number = false
  vim.wo[M.win].relativenumber = false
  vim.wo[M.win].signcolumn = "no"
  vim.wo[M.win].foldcolumn = "0"
  vim.wo[M.win].spell = false

  if not enter then
    vim.api.nvim_set_current_win(source_win)
  end

  return true
end

--- Check if the terminal window is currently visible.
---@return boolean
function M.is_open()
  return M.win ~= nil and vim.api.nvim_win_is_valid(M.win)
end

--- Check if the terminal buffer and process are alive.
---@return boolean
function M.is_alive()
  return M.buf ~= nil and vim.api.nvim_buf_is_valid(M.buf) and M.chan ~= nil
end

--- Get the current terminal working directory.
---@return string|nil
function M.get_cwd()
  return M.cwd
end

--- Open the pi terminal panel.
---@param opts? { enter?: boolean, cwd?: string }
function M.open(opts)
  opts = opts or {}
  local enter = opts.enter ~= nil and opts.enter or false
  local cwd = opts.cwd or require("pi.project").resolve_cwd()

  if cwd ~= M.cwd then
    M.stop({ preserve_sends = true })
  end

  -- Already open and visible — just focus if requested
  if M.is_open() then
    if enter then
      vim.api.nvim_set_current_win(M.win)
    end
    return
  end

  -- Buffer exists but window was closed — reopen in a split
  if M.is_alive() then
    if reopen_split(enter) then
      return
    end
    -- Buffer became invalid between is_alive() check and reopen — fall through to fresh start
  end

  -- Fresh start: launch pi in a new terminal
  local cmd = build_cmd()

  if has_snacks then
    open_snacks(cmd, enter, cwd)
  else
    open_manual(cmd, enter, cwd)
  end
  if M.is_alive() and M.cwd == cwd then
    clear_safe_at = now_ms() + config.opts.terminal.startup_timeout
  end
end

--- Close the terminal window (keeps buffer/process alive).
function M.close()
  if M.is_open() then
    vim.api.nvim_win_close(M.win, false)
    M.win = nil
  end
end

--- Stop the terminal process and discard its buffer.
---@param opts? { preserve_sends?: boolean }
function M.stop(opts)
  opts = opts or {}
  if not opts.preserve_sends then
    cancel_startup_sends()
  end
  pcall(M.close)

  if M.chan and M.chan > 0 then
    local ok, status = pcall(vim.fn.jobwait, { M.chan }, 0)
    if ok and status[1] == -1 then
      pcall(vim.fn.jobstop, M.chan)
    end
  end

  if M.buf and vim.api.nvim_buf_is_valid(M.buf) then
    pcall(vim.api.nvim_buf_delete, M.buf, { force = true })
  end

  if snacks_term and snacks_term.close then
    pcall(snacks_term.close, snacks_term)
  end

  reset_state()
end

--- Toggle the terminal panel.
---@param opts? { cwd?: string }
function M.toggle(opts)
  if M.is_open() then
    M.close()
  else
    M.open(opts)
  end
end

--- Focus the terminal window.
function M.focus()
  if M.is_open() then
    vim.api.nvim_set_current_win(M.win)
  end
end

local function is_current_process(item)
  return item.generation == process_generation and item.chan == M.chan and item.cwd == M.cwd
end

local dispatch_next

local function send_payload(item)
  vim.defer_fn(function()
    if not is_current_process(item) then
      return
    end

    if item.submit then
      vim.fn.chansend(item.chan, "\x1b[200~" .. item.text .. "\x1b[201~")
      vim.fn.chansend(item.chan, "\r")
    else
      vim.fn.chansend(item.chan, item.text)
    end
    sent_once = true
    send_active = false
    dispatch_next()
  end, item.send_delay)
end

local function clear_then_send(item)
  if not is_current_process(item) then
    return
  end
  vim.fn.chansend(item.chan, "\x03")
  send_payload(item)
end

dispatch_next = function()
  if send_active then
    return
  end

  local item = table.remove(send_queue, 1)
  if not item then
    return
  end
  if not is_current_process(item) then
    dispatch_next()
    return
  end

  send_active = true
  if item.clear_before_send and sent_once then
    local startup_delay = math.max(0, math.ceil(clear_safe_at - now_ms()))
    if startup_delay > 0 then
      vim.defer_fn(function()
        clear_then_send(item)
      end, startup_delay)
    else
      clear_then_send(item)
    end
  else
    send_payload(item)
  end
end

--- Queue a send into the terminal.
--- After the first send, optionally clear with Ctrl-C before inserting text.
--- When submit=true: bracketed paste + Enter (full submit).
--- When submit=false: raw keystrokes (no bracketed paste,
---   no Enter). The text should be a single line (no newlines) so it appears
---   in pi's editor for the user to augment before submitting.
---@param text string
---@param submit boolean Whether to auto-submit or type into the editor
---@param cwd string
local function do_send(text, submit, cwd)
  if M.chan == nil or M.cwd ~= cwd then
    return
  end

  send_queue[#send_queue + 1] = {
    text = text,
    submit = submit,
    cwd = cwd,
    chan = M.chan,
    generation = process_generation,
    clear_before_send = config.opts.terminal.clear_before_send,
    send_delay = config.opts.terminal.send_delay,
  }
  dispatch_next()
end

local start_startup_poll

local function poll_startup_queue(attempt, generation)
  local item = startup_queue[1]
  if generation ~= startup_generation or not item then
    return
  end
  if attempt >= item.max_retries then
    table.remove(startup_queue, 1)
    startup_polling = false
    vim.notify(
      string.format("Pi: terminal failed to start after %dms (%d retries)", item.startup_timeout, item.max_retries),
      vim.log.levels.ERROR
    )
    start_startup_poll()
    return
  end

  vim.defer_fn(function()
    if generation ~= startup_generation or startup_queue[1] ~= item then
      return
    end

    if not M.is_alive() or M.cwd ~= item.cwd then
      M.open({ cwd = item.cwd })
      poll_startup_queue(attempt + 1, generation)
      return
    end
    if not M.is_open() then
      M.open({ cwd = item.cwd })
    end

    if M.is_alive() and M.cwd == item.cwd then
      repeat
        item = table.remove(startup_queue, 1)
        do_send(item.text, item.submit, item.cwd)
        item = startup_queue[1]
      until not item or item.cwd ~= M.cwd
      startup_polling = false
      start_startup_poll()
    else
      poll_startup_queue(attempt + 1, generation)
    end
  end, item.poll_delay)
end

start_startup_poll = function()
  if startup_polling or #startup_queue == 0 then
    return
  end

  startup_polling = true
  local item = startup_queue[1]
  if not M.is_alive() or M.cwd ~= item.cwd then
    M.open({ cwd = item.cwd })
  end
  poll_startup_queue(0, startup_generation)
end

local function queue_startup_send(text, submit, cwd)
  local max_retries = config.opts.terminal.max_retries
  startup_queue[#startup_queue + 1] = {
    text = text,
    submit = submit,
    cwd = cwd,
    max_retries = max_retries,
    startup_timeout = config.opts.terminal.startup_timeout,
    poll_delay = math.floor(config.opts.terminal.startup_timeout / max_retries),
  }
  start_startup_poll()
end

--- Send a prompt to pi via bracketed paste.
--- If the terminal isn't running, starts it and polls until ready (with timeout).
---@param text string
---@param opts? { submit?: boolean, cwd?: string } Whether to press Enter after pasting (default true)
function M.send(text, opts)
  opts = opts or {}
  local submit = opts.submit ~= false -- default true
  local cwd = opts.cwd or require("pi.project").resolve_cwd()

  if startup_polling or #startup_queue > 0 or not M.is_alive() or M.cwd ~= cwd then
    queue_startup_send(text, submit, cwd)
    return
  end

  -- Make sure the panel is visible
  if not M.is_open() then
    M.open({ cwd = cwd })
  end

  if M.is_alive() and M.cwd == cwd then
    do_send(text, submit, cwd)
  else
    queue_startup_send(text, submit, cwd)
  end
end

--- Send abort signal to pi (Escape key).
--- Sends Escape twice with a short delay to avoid ambiguity with escape sequences.
function M.send_abort()
  if M.chan == nil then
    return
  end
  vim.fn.chansend(M.chan, "\x1b")
  vim.defer_fn(function()
    if M.chan ~= nil then
      vim.fn.chansend(M.chan, "\x1b")
    end
  end, 10)
end

return M
