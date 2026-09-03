local M = {}

local MiniDiff = require("mini.diff")
local attachments = {}

local function err(operation, message)
  return { kind = "minidiff", operation = operation, message = message }
end

function M.refresh(buf_id)
  local attachment = attachments[buf_id]
  if not attachment then
    return nil, err("refresh", "buffer is not attached to Pi review")
  end
  local state = require("pi.checkpoint").state(attachment.cwd)
  if not state or not state.available then
    return nil, err("refresh", "review requires an active Git checkpoint")
  end
  local tree = attachment.scope == "pending" and state.accepted_tree or attachment.base_tree
  local entry, read_err = state.git:read_file(tree, attachment.path)
  if read_err then
    return nil, read_err
  end
  attachment.ref_data = entry and entry.data or ""
  MiniDiff.set_ref_text(buf_id, attachment.ref_data)
  return true
end

function M.refresh_all(cwd)
  local root = cwd and vim.fs.normalize(vim.fn.fnamemodify(cwd, ":p")) or nil
  for buf_id, attachment in pairs(attachments) do
    if not vim.api.nvim_buf_is_valid(buf_id) then
      attachments[buf_id] = nil
    elseif root == nil or attachment.cwd == root then
      local ok, refresh_err = M.refresh(buf_id)
      if not ok then
        return nil, refresh_err
      end
    end
  end
  return true
end

local function apply_hunks(buf_id, hunks)
  local attachment = attachments[buf_id]
  local patch = require("pi.review.patch")
  local reference_lines = patch.data_to_lines(attachment.ref_data)
  local buffer_lines = vim.api.nvim_buf_get_lines(buf_id, 0, -1, false)
  local accepted_lines = patch.apply_hunks(reference_lines, buffer_lines, hunks)
  local endofline = attachment.ref_data:sub(-1) == "\n"
  for _, hunk in ipairs(hunks) do
    local hunk_end = hunk.buf_start + math.max(hunk.buf_count - 1, 0)
    if hunk_end >= #buffer_lines then
      endofline = vim.bo[buf_id].endofline
      break
    end
  end
  local data = patch.lines_to_data(accepted_lines, endofline)
  local ok, accept_err = require("pi.checkpoint").accept_text(attachment.path, data, attachment.cwd)
  if not ok then
    return nil, accept_err
  end
  return M.refresh(buf_id)
end

local function restore(buf_id, attachment)
  if MiniDiff.get_buf_data(buf_id) then
    MiniDiff.disable(buf_id)
  end
  vim.b[buf_id].minidiff_config = attachment.previous_config
  attachments[buf_id] = nil
  if attachment.was_enabled then
    MiniDiff.enable(buf_id)
  end
end

function M.attach(buf_id, ctx)
  if attachments[buf_id] then
    return nil, err("attach", "buffer is already attached to Pi review")
  end
  if vim.g.minidiff_disable == true or vim.b[buf_id].minidiff_disable == true then
    return nil, err("attach", "MiniDiff is disabled for buffer")
  end
  local attachment = vim.deepcopy(ctx)
  attachment.previous_config = vim.deepcopy(vim.b[buf_id].minidiff_config)
  attachment.was_enabled = MiniDiff.get_buf_data(buf_id) ~= nil
  attachments[buf_id] = attachment

  local source = {
    name = "pi-accepted-tree",
    attach = function(source_buf)
      local ok, refresh_err = M.refresh(source_buf)
      if not ok then
        attachment.source_error = refresh_err
        return false
      end
    end,
  }
  if attachment.scope == "pending" and not attachment.read_only then
    source.apply_hunks = function(source_buf, hunks)
      local ok, apply_err = apply_hunks(source_buf, hunks)
      attachment.source_error = apply_err
      return ok
    end
  end

  if attachment.was_enabled then
    MiniDiff.disable(buf_id)
  end
  local config = vim.deepcopy(attachment.previous_config or {})
  config.source = source
  vim.b[buf_id].minidiff_config = config
  MiniDiff.enable(buf_id)
  if attachment.source_error then
    local source_error = attachment.source_error
    restore(buf_id, attachment)
    return nil, source_error
  end
  if not MiniDiff.get_buf_data(buf_id) then
    restore(buf_id, attachment)
    return nil, err("attach", "MiniDiff did not enable buffer")
  end
  return true
end

local function current_line(buf_id)
  local line
  vim.api.nvim_buf_call(buf_id, function()
    line = vim.api.nvim_win_get_cursor(0)[1]
  end)
  return line
end

local function hunk_at_line(hunks, line)
  for _, hunk in ipairs(hunks) do
    local from = hunk.buf_count == 0 and math.max(hunk.buf_start, 1) or hunk.buf_start
    local to = hunk.buf_count == 0 and from or hunk.buf_start + hunk.buf_count - 1
    if from <= line and line <= to then
      return from, to, hunk
    end
  end
end

local function hunk_reaches_eof(buf_id, attachment, hunk)
  local buffer_count = vim.api.nvim_buf_line_count(buf_id)
  local reference_count = #require("pi.review.patch").data_to_lines(attachment.ref_data)
  local reaches_buffer_eof = hunk.buf_start + hunk.buf_count - 1 >= buffer_count
  local reaches_reference_eof = hunk.ref_start + hunk.ref_count - 1 >= reference_count
  return reaches_buffer_eof or reaches_reference_eof
end

local function restore_buffer_state(buf_id, state)
  local rollback_errors = {}
  local function restore(label, action)
    local ok, restore_err = pcall(action)
    if not ok then
      rollback_errors[#rollback_errors + 1] = label .. ": " .. tostring(restore_err)
    end
  end

  restore("enable modification", function()
    vim.bo[buf_id].modifiable = true
  end)
  restore("lines", function()
    vim.api.nvim_buf_set_lines(buf_id, 0, -1, false, state.lines)
  end)
  restore("endofline", function()
    vim.bo[buf_id].endofline = state.endofline
  end)
  restore("fixendofline", function()
    vim.bo[buf_id].fixendofline = state.fixendofline
  end)
  restore("restore modifiable", function()
    vim.bo[buf_id].modifiable = state.modifiable
  end)
  restore("modified", function()
    vim.bo[buf_id].modified = state.modified
  end)

  if #rollback_errors > 0 then
    return nil, table.concat(rollback_errors, "; ")
  end
  return true
end

local function reject_failure(buf_id, state, operation_error)
  local restored, rollback_error = restore_buffer_state(buf_id, state)
  local message = tostring(operation_error)
  if not restored then
    message = message .. "; rollback failed: " .. rollback_error
  end
  return nil, err("reject_hunk", message)
end

function M.accept_hunk(buf_id)
  local attachment = attachments[buf_id]
  if not attachment or attachment.scope ~= "pending" or attachment.read_only then
    return nil, err("accept_hunk", "buffer is not attached to mutable pending review")
  end
  local data = MiniDiff.get_buf_data(buf_id)
  if not data then
    return nil, err("accept_hunk", "MiniDiff is not enabled for buffer")
  end
  local line_start, line_end = hunk_at_line(data.hunks, current_line(buf_id))
  if not line_start then
    return nil, err("accept_hunk", "cursor is not on a hunk")
  end

  attachment.source_error = nil
  local ok, apply_err = pcall(MiniDiff.do_hunks, buf_id, "apply", {
    line_start = line_start,
    line_end = line_end,
  })
  if not ok then
    return nil, err("accept_hunk", apply_err)
  end
  if attachment.source_error then
    return nil, attachment.source_error
  end
  return true
end

function M.reject_hunk(buf_id)
  local attachment = attachments[buf_id]
  if not attachment or attachment.scope ~= "pending" or attachment.read_only then
    return nil, err("reject_hunk", "buffer is not attached to mutable pending review")
  end
  local data = MiniDiff.get_buf_data(buf_id)
  if not data then
    return nil, err("reject_hunk", "MiniDiff is not enabled for buffer")
  end
  local line_start, line_end, hunk = hunk_at_line(data.hunks, current_line(buf_id))
  if not line_start then
    return nil, err("reject_hunk", "cursor is not on a hunk")
  end

  local original = {
    lines = vim.api.nvim_buf_get_lines(buf_id, 0, -1, false),
    endofline = vim.bo[buf_id].endofline,
    fixendofline = vim.bo[buf_id].fixendofline,
    modifiable = vim.bo[buf_id].modifiable,
    modified = vim.bo[buf_id].modified,
  }
  local endofline = original.endofline
  if hunk_reaches_eof(buf_id, attachment, hunk) then
    endofline = attachment.ref_data:sub(-1) == "\n"
  end
  local ok, reset_err = pcall(MiniDiff.do_hunks, buf_id, "reset", {
    line_start = line_start,
    line_end = line_end,
  })
  if not ok then
    return reject_failure(buf_id, original, reset_err)
  end
  vim.bo[buf_id].endofline = endofline
  if not endofline then
    vim.bo[buf_id].fixendofline = false
  end
  local wrote, write_err = pcall(vim.api.nvim_buf_call, buf_id, function()
    vim.cmd("silent write")
  end)
  vim.bo[buf_id].fixendofline = original.fixendofline
  vim.bo[buf_id].endofline = endofline
  if not wrote then
    return reject_failure(buf_id, original, write_err)
  end
  return true
end

function M.goto_hunk(buf_id, direction)
  if not attachments[buf_id] then
    return nil, err("goto_hunk", "buffer is not attached to Pi review")
  end
  local ok, goto_err = pcall(vim.api.nvim_buf_call, buf_id, function()
    MiniDiff.goto_hunk(direction)
  end)
  if not ok then
    return nil, err("goto_hunk", goto_err)
  end
  return true
end

function M.detach(buf_id)
  local attachment = attachments[buf_id]
  if not attachment then
    return nil, err("detach", "buffer is not attached to Pi review")
  end
  restore(buf_id, attachment)
  return true
end

return M
