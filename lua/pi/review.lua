local M = {}

local current
local request_generation = 0

local function notify_error(value)
  local message = type(value) == "table" and value.message or tostring(value or "unknown error")
  vim.notify("Pi: " .. message, vim.log.levels.ERROR)
end

local function normalize_cwd(cwd)
  return vim.fs.normalize(vim.fn.fnamemodify(cwd, ":p"))
end

local function call_minidiff(method, ...)
  local loaded, integration = pcall(require, "pi.review.minidiff")
  if not loaded then
    notify_error(integration)
    return false
  end
  local called, result, action_err = pcall(integration[method], ...)
  if not called then
    notify_error(result)
    return false
  end
  if not result then
    notify_error(action_err)
    return false
  end
  return true
end

local function expanded_lhs(lhs)
  local ok, expanded = pcall(vim.api.nvim_replace_termcodes, lhs, true, true, true)
  return ok and expanded or lhs
end

local function mapping_lhs(mapping)
  return mapping.lhsraw or expanded_lhs(mapping.lhs)
end

local function mapping_for(buf, lhs)
  local target = expanded_lhs(lhs)
  for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    if mapping_lhs(mapping) == target then
      return mapping
    end
  end
end

local function restore_mapping(buf, mapping)
  local rhs = type(mapping.callback) == "function" and mapping.callback or mapping.rhs
  vim.keymap.set("n", mapping.lhs, rhs, {
    buffer = buf,
    desc = mapping.desc,
    expr = mapping.expr == 1,
    nowait = mapping.nowait == 1,
    remap = mapping.noremap == 0,
    replace_keycodes = mapping.replace_keycodes == 1,
    script = mapping.script == 1,
    silent = mapping.silent == 1,
  })
end

local function map(review, lhs, callback, desc)
  if not lhs or not review.buf then
    return
  end
  local previous = mapping_for(review.buf, lhs)
  vim.keymap.set("n", lhs, callback, {
    buffer = review.buf,
    silent = true,
    desc = desc,
  })
  local installed = mapping_for(review.buf, lhs)
  review.mappings[#review.mappings + 1] = {
    lhs = installed and installed.lhs or expanded_lhs(lhs),
    raw_lhs = installed and mapping_lhs(installed) or expanded_lhs(lhs),
    callback = installed and installed.callback or callback,
    previous = previous,
    desc = desc,
  }
end

local function remove_mappings(review)
  if not review.buf or not vim.api.nvim_buf_is_valid(review.buf) then
    return
  end
  for index = #review.mappings, 1, -1 do
    local mapping = review.mappings[index]
    local installed = mapping_for(review.buf, mapping.raw_lhs)
    if installed and installed.desc == mapping.desc and installed.callback == mapping.callback then
      pcall(vim.keymap.del, "n", mapping.lhs, { buffer = review.buf })
      if mapping.previous then
        pcall(restore_mapping, review.buf, mapping.previous)
      end
    end
  end
end

local function winfixbuf(win)
  local ok, value = pcall(function()
    return vim.wo[win].winfixbuf
  end)
  return ok and value == true
end

local function ordinary_window(win)
  if not vim.api.nvim_win_is_valid(win) or winfixbuf(win) then
    return false
  end
  local config = vim.api.nvim_win_get_config(win)
  if config.relative and config.relative ~= "" then
    return false
  end
  local buf = vim.api.nvim_win_get_buf(win)
  return vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buftype == ""
end

local function editing_window()
  local win = vim.api.nvim_get_current_win()
  if ordinary_window(win) then
    return win
  end
  for _, candidate in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if ordinary_window(candidate) then
      return candidate
    end
  end

  local split, split_err = pcall(vim.cmd, "botright split")
  if not split then
    return nil, split_err
  end
  win = vim.api.nvim_get_current_win()
  pcall(function()
    vim.wo[win].winfixbuf = false
  end)
  return win
end

local function absolute_path(root, path)
  local is_absolute = type(path) == "string"
    and (path:match("^[/\\]") ~= nil or path:match("^%a:[/\\]") ~= nil)
  if type(path) ~= "string" or path == "" or path:find("\0", 1, true) or is_absolute then
    return nil
  end
  local absolute = vim.fs.normalize(root .. "/" .. path)
  if absolute == root or not require("pi.project").is_within(root, absolute) then
    return nil
  end
  return absolute
end

local function ordinary_blob(entry)
  return entry
    and entry.type == "blob"
    and (entry.mode == "100644" or entry.mode == "100755")
end

local function inspect_file(state, view, file)
  local root = vim.fs.normalize(state.git_root)
  local absolute = absolute_path(root, file.path)
  local base_entry, base_err = state.git:entry(view.base_tree, file.path)
  if base_err then
    return nil, base_err
  end
  local work_entry, work_err = state.git:entry(view.current_tree, file.path)
  if work_err then
    return nil, work_err
  end
  local stat = absolute and vim.uv.fs_lstat(absolute) or nil
  local exists = stat
    and (stat.type == "file" or stat.type == "link")
    and vim.fn.filereadable(absolute) == 1
    or false
  local supported = absolute ~= nil
    and exists
    and stat.type == "file"
    and not file.binary
    and ordinary_blob(work_entry)
    and (base_entry == nil or ordinary_blob(base_entry))
    or false
  return {
    absolute = absolute,
    base_entry = base_entry,
    work_entry = work_entry,
    exists = exists,
    supported = supported,
  }
end

local function open_real_file(inspection)
  if not inspection.exists then
    return nil, nil, nil
  end
  local win, win_err = editing_window()
  if not win then
    return nil, nil, win_err
  end
  local buf = vim.fn.bufadd(inspection.absolute)
  local loaded, load_err = pcall(vim.fn.bufload, buf)
  if not loaded then
    return nil, nil, load_err
  end
  pcall(vim.api.nvim_buf_call, buf, function()
    vim.cmd.checktime()
  end)
  local shown, show_err = pcall(vim.api.nvim_win_set_buf, win, buf)
  if not shown then
    return nil, nil, show_err
  end
  vim.api.nvim_set_current_win(win)
  return buf, win, nil
end

local function install_mappings(review)
  if not review.buf then
    return
  end
  local keys = require("pi.config").opts.review.keymaps
  if review.supported then
    map(review, keys.previous_hunk, function()
      call_minidiff("goto_hunk", review.buf, "previous")
    end, "Pi: Previous hunk")
    map(review, keys.next_hunk, function()
      call_minidiff("goto_hunk", review.buf, "next")
    end, "Pi: Next hunk")
  end
  if not review.read_only then
    if review.supported then
      map(review, keys.accept_hunk, function()
        M.accept("hunk")
      end, "Pi: Accept hunk")
      map(review, keys.reject_hunk, function()
        M.reject("hunk")
      end, "Pi: Reject hunk")
    end
    map(review, keys.accept_file, function()
      M.accept("file")
    end, "Pi: Accept file")
    map(review, keys.reject_file, function()
      M.reject("file")
    end, "Pi: Reject file")
  end
  map(review, keys.close, M.close, "Pi: Close review")
end

local function open_file(cwd, state, view, file)
  local inspection, inspect_err = inspect_file(state, view, file)
  if not inspection then
    return nil, inspect_err
  end
  local buf, win, open_err = open_real_file(inspection)
  if open_err then
    return nil, open_err
  end

  local review = {
    scope = view.scope,
    cwd = cwd,
    path = file.path,
    buf = buf,
    win = win,
    read_only = view.read_only,
    supported = inspection.supported,
    attached = false,
    file = file,
    view = view,
    mappings = {},
  }
  current = review

  if review.supported then
    local attached = call_minidiff("attach", buf, {
      cwd = cwd,
      path = file.path,
      scope = view.scope,
      base_tree = view.base_tree,
      read_only = view.read_only,
      overlay = require("pi.config").opts.review.overlay,
    })
    if attached then
      review.attached = true
    else
      review.supported = false
    end
  end
  install_mappings(review)
  return true
end

function M.current()
  return current
end

function M.close()
  request_generation = request_generation + 1
  local review = current
  if not review then
    return false
  end
  if review.attached and review.buf and vim.api.nvim_buf_is_valid(review.buf) then
    if not call_minidiff("detach", review.buf) then
      return false
    end
  end
  current = nil
  remove_mappings(review)
  return true
end

function M.open(scope, cwd)
  request_generation = request_generation + 1
  local request = request_generation
  scope = scope or "pending"
  cwd = normalize_cwd(cwd or require("pi.project").resolve_cwd())
  local checkpoint = require("pi.checkpoint")
  local state = checkpoint.state(cwd)
  if not state then
    local ensure_err
    state, ensure_err = checkpoint.ensure(cwd)
    if not state then
      notify_error(ensure_err)
      return false
    end
  end
  local view, view_err = checkpoint.view(scope, cwd)
  if not view then
    notify_error(view_err)
    return false
  end
  if #view.files == 0 then
    vim.notify("Pi: no changes for " .. scope .. " review")
    return false
  end

  vim.ui.select(view.files, {
    prompt = "Pi " .. scope .. " review",
    format_item = function(file)
      if file.binary then
        return string.format("%s %s  binary", file.status, file.path)
      end
      return string.format("%s %s  +%d -%d", file.status, file.path, file.additions, file.deletions)
    end,
  }, function(file)
    if request ~= request_generation then
      return
    end
    request_generation = request_generation + 1
    if not file then
      return
    end
    if current and not M.close() then
      return
    end
    local opened, open_err = open_file(cwd, state, view, file)
    if not opened then
      notify_error(open_err)
    end
  end)
  return true
end

local function refresh_current()
  if not current or not current.attached then
    return true
  end
  return call_minidiff("refresh", current.buf)
end

function M.accept(target)
  local review = current
  if review and review.read_only then
    return false
  end
  if target == "all" then
    local cwd = review and review.cwd or normalize_cwd(require("pi.project").resolve_cwd())
    local ok, action_err = require("pi.checkpoint").accept_all(cwd)
    if not ok then
      notify_error(action_err)
      return false
    end
    return call_minidiff("refresh_all", cwd)
  end
  if not review then
    return false
  end
  if target == "hunk" then
    if not review.supported or not review.attached then
      return false
    end
    return call_minidiff("accept_hunk", review.buf)
  end
  if target ~= "file" then
    return false
  end
  local ok, action_err = require("pi.checkpoint").accept_file(review.path, review.cwd)
  if not ok then
    notify_error(action_err)
    return false
  end
  return refresh_current()
end

local function loaded_buffer(review)
  if review.buf and vim.api.nvim_buf_is_valid(review.buf) and vim.api.nvim_buf_is_loaded(review.buf) then
    return review.buf
  end
  local state = require("pi.checkpoint").state(review.cwd)
  local absolute = state and state.git_root and absolute_path(vim.fs.normalize(state.git_root), review.path) or nil
  local buf = absolute and vim.fn.bufnr(absolute, false) or -1
  if buf >= 0 and vim.api.nvim_buf_is_loaded(buf) then
    return buf
  end
end

function M.reject(target)
  local review = current
  if review and review.read_only then
    return false
  end
  if target == "all" then
    local cwd = review and review.cwd or normalize_cwd(require("pi.project").resolve_cwd())
    local view, view_err = require("pi.checkpoint").view("pending", cwd)
    if not view then
      notify_error(view_err)
      return false
    end
    if #view.files > 0 then
      local choice = vim.fn.confirm(
        string.format("Reject all %d changed files?", #view.files),
        "&Reject\n&Cancel",
        2
      )
      if choice ~= 1 then
        return false
      end
    end
    local rejected = 0
    for _, file in ipairs(view.files) do
      local ok, action_err = require("pi.checkpoint").reject_file(file.path, cwd)
      if not ok then
        notify_error(action_err)
      else
        rejected = rejected + 1
        local buf = loaded_buffer({ path = file.path, cwd = cwd })
        if buf and vim.api.nvim_buf_is_valid(buf) then
          local reloaded, reload_err = pcall(vim.api.nvim_buf_call, buf, function()
            vim.cmd("silent edit!")
          end)
          if not reloaded then
            notify_error(reload_err)
          end
        end
      end
    end
    if rejected > 0 then
      vim.notify(string.format("Pi: rejected %d file%s", rejected, rejected == 1 and "" or "s"))
    else
      vim.notify("Pi: nothing to reject")
    end
    return call_minidiff("refresh_all", cwd)
  end
  if not review then
    return false
  end
  if target == "hunk" then
    if not review.supported or not review.attached then
      return false
    end
    return call_minidiff("reject_hunk", review.buf)
  end
  if target ~= "file" then
    return false
  end

  local buf = loaded_buffer(review)
  if buf and vim.bo[buf].modified then
    local choice = vim.fn.confirm(
      "Discard unsaved changes and reject " .. review.path .. "?",
      "&Reject\n&Cancel",
      2
    )
    if choice ~= 1 then
      return false
    end
  end

  local ok, action_err = require("pi.checkpoint").reject_file(review.path, review.cwd)
  if not ok then
    notify_error(action_err)
    return false
  end
  if buf and vim.api.nvim_buf_is_valid(buf) then
    local reloaded, reload_err = pcall(vim.api.nvim_buf_call, buf, function()
      vim.cmd("silent edit!")
    end)
    if not reloaded then
      notify_error(reload_err)
      return false
    end
  end
  return true
end

return M
