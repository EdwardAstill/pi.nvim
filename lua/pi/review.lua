local M = {}

local current

local function notify_error(err)
  vim.notify("Pi: " .. (err.message or tostring(err)), vim.log.levels.ERROR)
end

local function buffer_lines(data)
  if data == "" then
    return { "" }, false
  end
  local endofline = data:sub(-1) == "\n"
  if endofline then
    data = data:sub(1, -2)
  end
  return vim.split(data, "\n", { plain = true }), endofline
end

local function buffer_data(buf)
  local data = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  if vim.bo[buf].endofline then
    data = data .. "\n"
  end
  return data
end

local function set_data(buf, data)
  local lines, endofline = buffer_lines(data)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].endofline = endofline
  vim.bo[buf].modified = false
end

local function file_for_path(files, path)
  for _, file in ipairs(files) do
    if file.path == path then
      return file
    end
  end
end

local function map(buf, lhs, rhs, desc)
  if lhs then
    vim.keymap.set("n", lhs, rhs, { buffer = buf, silent = true, desc = desc })
  end
end

local function open_file(view, file, original_tab)
  local state = require("pi.checkpoint").state()
  local git = state.git
  local base_entry, base_err = git:entry(view.base_tree, file.path)
  if base_err then
    return nil, base_err
  end
  local work_entry, work_err = git:entry(view.current_tree, file.path)
  if work_err then
    return nil, work_err
  end
  local text = not file.binary
    and (not base_entry or base_entry.type == "blob")
    and (not work_entry or work_entry.type == "blob")
    and (not base_entry or base_entry.mode ~= "120000")
    and (not work_entry or work_entry.mode ~= "120000")

  local base_data = ""
  if text and base_entry then
    local base_file, read_err = git:read_file(view.base_tree, file.path)
    if not base_file then
      return nil, read_err
    end
    base_data = base_file.data
  end

  vim.cmd.tabnew()
  local tab = vim.api.nvim_get_current_tabpage()
  local base_win = vim.api.nvim_get_current_win()
  local base_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(base_win, base_buf)
  vim.api.nvim_buf_set_name(base_buf, string.format("[Pi %s] %s", view.scope, file.path))
  set_data(base_buf, text and base_data or "Non-text change; use file accept/reject.")

  vim.cmd.vsplit()
  local work_win = vim.api.nvim_get_current_win()
  local work_buf
  if text then
    local absolute = state.git_root .. "/" .. file.path
    work_buf = vim.fn.bufadd(absolute)
    vim.fn.bufload(work_buf)
    pcall(vim.api.nvim_buf_call, work_buf, function()
      vim.cmd.checktime()
    end)
  else
    work_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(work_buf, "[Pi current] " .. file.path)
    set_data(work_buf, "Non-text change; use file accept/reject.")
  end
  vim.api.nvim_win_set_buf(work_win, work_buf)

  vim.api.nvim_win_call(base_win, function()
    vim.cmd.diffthis()
  end)
  vim.api.nvim_win_call(work_win, function()
    vim.cmd.diffthis()
  end)

  current = {
    scope = view.scope,
    read_only = view.read_only,
    view = view,
    file = file,
    original_tab = original_tab,
    tab = tab,
    base_buf = base_buf,
    work_buf = work_buf,
    base_win = base_win,
    work_win = work_win,
    text = text,
  }

  local keys = require("pi.config").opts.review.keymaps
  for _, buf in ipairs({ base_buf, work_buf }) do
    map(buf, keys.close, M.close, "Pi: Close review")
  end
  if not view.read_only then
    if text then
      map(work_buf, keys.accept_hunk, function()
        M.accept("hunk")
      end, "Pi: Accept hunk")
      map(work_buf, keys.reject_hunk, function()
        M.reject("hunk")
      end, "Pi: Reject hunk")
    end
    map(work_buf, keys.accept_file, function()
      M.accept("file")
    end, "Pi: Accept file")
    map(work_buf, keys.reject_file, function()
      M.reject("file")
    end, "Pi: Reject file")
  end
  vim.api.nvim_set_current_win(work_win)
  return true, nil
end

function M.current()
  return current
end

function M.close()
  local review = current
  if not review then
    return false
  end
  current = nil
  for _, win in ipairs({ review.base_win, review.work_win }) do
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_call, win, function()
        vim.cmd.diffoff()
      end)
    end
  end
  if vim.api.nvim_tabpage_is_valid(review.tab) then
    pcall(vim.api.nvim_set_current_tabpage, review.tab)
    pcall(vim.cmd, "tabclose!")
  end
  if vim.api.nvim_buf_is_valid(review.base_buf) then
    pcall(vim.api.nvim_buf_delete, review.base_buf, { force = true })
  end
  if review.work_buf ~= review.base_buf
    and vim.api.nvim_buf_is_valid(review.work_buf)
    and vim.bo[review.work_buf].buftype == "nofile"
  then
    pcall(vim.api.nvim_buf_delete, review.work_buf, { force = true })
  end
  if vim.api.nvim_tabpage_is_valid(review.original_tab) then
    pcall(vim.api.nvim_set_current_tabpage, review.original_tab)
  end
  return true
end

local function refresh(path)
  local original_tab = current and current.original_tab or vim.api.nvim_get_current_tabpage()
  M.close()
  local view, view_err = require("pi.checkpoint").view("pending")
  if not view then
    notify_error(view_err)
    return false
  end
  if #view.files == 0 then
    return true
  end
  local file = file_for_path(view.files, path) or view.files[1]
  local opened, open_err = open_file(view, file, original_tab)
  if not opened then
    notify_error(open_err)
    return false
  end
  return true
end

function M.open(scope)
  scope = scope or "pending"
  local checkpoint = require("pi.checkpoint")
  local state = checkpoint.state()
  if not state then
    local ensure_err
    state, ensure_err = checkpoint.ensure(require("pi.project").resolve_cwd())
    if not state then
      notify_error(ensure_err)
      return false
    end
  end
  local view, view_err = checkpoint.view(scope)
  if not view then
    notify_error(view_err)
    return false
  end
  if #view.files == 0 then
    vim.notify("Pi: no changes for " .. scope .. " review")
    return false
  end

  local original_tab = vim.api.nvim_get_current_tabpage()
  vim.ui.select(view.files, {
    prompt = "Pi " .. scope .. " review",
    format_item = function(file)
      if file.binary then
        return string.format("%s %s  binary", file.status, file.path)
      end
      return string.format("%s %s  +%d -%d", file.status, file.path, file.additions, file.deletions)
    end,
  }, function(file)
    if not file then
      return
    end
    local ok, open_err = open_file(view, file, original_tab)
    if not ok then
      notify_error(open_err)
      return
    end
  end)
  return true
end

function M.accept(target)
  if target == "all" then
    local ok, action_err = require("pi.checkpoint").accept_all()
    if not ok then
      notify_error(action_err)
      return false
    end
    if current then
      return refresh(current.file.path)
    end
    return true
  end
  if not current or current.read_only then
    return false
  end
  local path = current.file.path
  if target == "file" then
    local ok, action_err = require("pi.checkpoint").accept_file(path)
    if not ok then
      notify_error(action_err)
      return false
    end
    return refresh(path)
  end
  if target ~= "hunk" or not current.text then
    return false
  end
  local ok, diff_err = pcall(vim.api.nvim_win_call, current.work_win, function()
    vim.cmd.diffput()
  end)
  if not ok then
    vim.notify("Pi: " .. tostring(diff_err), vim.log.levels.WARN)
    return false
  end
  local accepted, action_err = require("pi.checkpoint").accept_text(path, buffer_data(current.base_buf))
  if not accepted then
    notify_error(action_err)
    return false
  end
  return refresh(path)
end

function M.reject(target)
  if not current or current.read_only then
    return false
  end
  local path = current.file.path
  if target == "file" then
    local ok, action_err = require("pi.checkpoint").reject_file(path)
    if not ok then
      notify_error(action_err)
      return false
    end
    if vim.api.nvim_buf_is_valid(current.work_buf) and vim.bo[current.work_buf].buftype == "" then
      pcall(vim.api.nvim_buf_call, current.work_buf, function()
        vim.cmd("edit!")
      end)
    end
    return refresh(path)
  end
  if target ~= "hunk" or not current.text then
    return false
  end
  local ok, diff_err = pcall(vim.api.nvim_win_call, current.work_win, function()
    vim.cmd.diffget()
    vim.cmd.write()
  end)
  if not ok then
    vim.notify("Pi: " .. tostring(diff_err), vim.log.levels.WARN)
    return false
  end
  return refresh(path)
end

return M
