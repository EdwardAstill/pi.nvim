local H = require("tests.helpers")

local function fake_minidiff()
  local M = { enabled = {}, data = {}, sources = {} }

  function M.setup()
    error("the source must not configure MiniDiff globally")
  end

  function M.enable(buf_id)
    if M.enabled[buf_id] then
      return
    end
    if vim.g.minidiff_disable == true or vim.b[buf_id].minidiff_disable == true then
      return
    end
    M.enabled[buf_id] = true
    local config = vim.deepcopy(vim.b[buf_id].minidiff_config or {})
    M.data[buf_id] = { config = config, hunks = {}, overlay = false, ref_text = nil, summary = {} }
    M.sources[buf_id] = config.source
    if config.source and config.source.attach then
      local attached = config.source.attach(buf_id)
      if attached == false then
        M.enabled[buf_id] = nil
        M.data[buf_id] = nil
        M.sources[buf_id] = nil
      end
    end
  end

  function M.disable(buf_id)
    if not M.enabled[buf_id] then
      return
    end
    local source = M.sources[buf_id]
    M.enabled[buf_id] = nil
    M.data[buf_id] = nil
    M.sources[buf_id] = nil
    if source and source.detach then
      source.detach(buf_id)
    end
  end

  function M.get_buf_data(buf_id)
    return M.enabled[buf_id] and vim.deepcopy(M.data[buf_id]) or nil
  end

  function M.set_ref_text(buf_id, text)
    assert(M.enabled[buf_id], "reference text requires an enabled buffer")
    M.data[buf_id].ref_text = text
  end

  function M.set_hunks(buf_id, hunks)
    M.data[buf_id].hunks = vim.deepcopy(hunks)
  end

  function M.do_hunks(buf_id, action, opts)
    local selected = {}
    for _, hunk in ipairs(M.data[buf_id].hunks) do
      local from = hunk.buf_count == 0 and math.max(hunk.buf_start, 1) or hunk.buf_start
      local to = hunk.buf_count == 0 and from or hunk.buf_start + hunk.buf_count - 1
      if math.max(from, opts.line_start) <= math.min(to, opts.line_end) then
        selected[#selected + 1] = vim.deepcopy(hunk)
      end
    end
    if #selected == 0 then
      return
    end
    if action == "apply" then
      return M.sources[buf_id].apply_hunks(buf_id, selected)
    end
    if action == "reset" then
      local ref_lines = vim.split(M.data[buf_id].ref_text, "\n", { plain = true })
      for hunk_index = #selected, 1, -1 do
        local hunk = selected[hunk_index]
        local replacement = {}
        for index = hunk.ref_start, hunk.ref_start + hunk.ref_count - 1 do
          replacement[#replacement + 1] = ref_lines[index]
        end
        local start = hunk.buf_start - 1 + (hunk.buf_count == 0 and 1 or 0)
        vim.api.nvim_buf_set_lines(buf_id, start, start + hunk.buf_count, false, replacement)
      end
      return
    end
    error("unsupported fake MiniDiff action: " .. tostring(action))
  end

  function M.goto_hunk(direction)
    M.last_goto = { buf_id = vim.api.nvim_get_current_buf(), direction = direction }
  end

  return M
end

local function fresh(root, mini)
  package.loaded["pi.checkpoint"] = nil
  package.loaded["pi.review.minidiff"] = nil
  package.loaded["mini.diff"] = mini
  local checkpoint = require("pi.checkpoint")
  assert(checkpoint.ensure(root))
  return checkpoint, require("pi.review.minidiff")
end

local function buffer(path, lines, endofline)
  local buf_id = vim.fn.bufadd(path)
  vim.fn.bufload(buf_id)
  vim.api.nvim_buf_set_lines(buf_id, 0, -1, false, lines)
  vim.bo[buf_id].endofline = endofline ~= false
  return buf_id
end

local function delete_buffers(...)
  for _, buf_id in ipairs({ ... }) do
    if vim.api.nvim_buf_is_valid(buf_id) then
      vim.api.nvim_buf_delete(buf_id, { force = true })
    end
  end
end

H.test("MiniDiff attach loads accepted and absent paths as reference text", function()
  local root = H.repo()
  local mini = fake_minidiff()
  local checkpoint, review_diff = fresh(root, mini)
  local tracked = buffer(root .. "/tracked.txt", { "working" })
  local added = buffer(root .. "/added.txt", { "added" })
  local base_tree = checkpoint.state(root).accepted_tree

  H.eq(true, review_diff.attach(tracked, {
    cwd = root,
    path = "tracked.txt",
    scope = "pending",
    base_tree = base_tree,
    read_only = false,
  }))
  H.eq(true, review_diff.attach(added, {
    cwd = root,
    path = "added.txt",
    scope = "pending",
    base_tree = base_tree,
    read_only = false,
  }))

  H.eq("base\n", mini.get_buf_data(tracked).ref_text)
  H.eq("", mini.get_buf_data(added).ref_text)
  H.eq("pi-accepted-tree", mini.get_buf_data(tracked).config.source.name)

  delete_buffers(tracked, added)
  checkpoint.cleanup()
end)

H.test("MiniDiff detach restores exact buffer-local config and enabled state", function()
  local root = H.repo()
  local mini = fake_minidiff()
  local checkpoint, review_diff = fresh(root, mini)
  local enabled_buf = buffer(root .. "/tracked.txt", { "working" })
  local disabled_buf = buffer(root .. "/disabled.txt", { "working" })
  local unset_buf = buffer(root .. "/unset.txt", { "working" })
  local old_attaches, old_detaches = 0, 0
  local old_source = {
    name = "old-source",
    attach = function(buf_id)
      old_attaches = old_attaches + 1
      mini.set_ref_text(buf_id, "old reference\n")
    end,
    detach = function()
      old_detaches = old_detaches + 1
    end,
  }
  local enabled_config = { source = old_source, delay = { text_change = 17 }, view = { style = "sign" } }
  local disabled_config = { delay = { text_change = 23 }, view = { style = "number" } }
  vim.b[enabled_buf].minidiff_config = enabled_config
  vim.b[disabled_buf].minidiff_config = disabled_config
  mini.enable(enabled_buf)
  local base_tree = checkpoint.state(root).accepted_tree

  assert(review_diff.attach(enabled_buf, {
    cwd = root,
    path = "tracked.txt",
    scope = "pending",
    base_tree = base_tree,
    read_only = false,
  }))
  assert(review_diff.attach(disabled_buf, {
    cwd = root,
    path = "disabled.txt",
    scope = "pending",
    base_tree = base_tree,
    read_only = false,
  }))
  assert(review_diff.attach(unset_buf, {
    cwd = root,
    path = "unset.txt",
    scope = "pending",
    base_tree = base_tree,
    read_only = false,
  }))
  H.eq({ text_change = 17 }, mini.get_buf_data(enabled_buf).config.delay)
  H.eq({ text_change = 23 }, mini.get_buf_data(disabled_buf).config.delay)

  H.eq(true, review_diff.detach(enabled_buf))
  H.eq(true, review_diff.detach(disabled_buf))
  H.eq(true, review_diff.detach(unset_buf))

  H.eq(enabled_config, vim.b[enabled_buf].minidiff_config)
  H.eq(disabled_config, vim.b[disabled_buf].minidiff_config)
  H.eq(nil, vim.b[unset_buf].minidiff_config)
  H.eq(true, mini.enabled[enabled_buf] == true)
  H.eq(true, mini.enabled[disabled_buf] == nil)
  H.eq(true, mini.enabled[unset_buf] == nil)
  H.eq(2, old_attaches)
  H.eq(1, old_detaches)

  delete_buffers(enabled_buf, disabled_buf, unset_buf)
  checkpoint.cleanup()
end)

H.test("MiniDiff attach failure restores the prior source and does not stay attached", function()
  local root = H.repo()
  local mini = fake_minidiff()
  local checkpoint, review_diff = fresh(root, mini)
  local buf_id = buffer(root .. "/tracked.txt", { "working" })
  local old_source = {
    name = "old-source",
    attach = function(source_buf)
      mini.set_ref_text(source_buf, "old reference\n")
    end,
  }
  local previous_config = { source = old_source, delay = { text_change = 19 } }
  vim.b[buf_id].minidiff_config = previous_config
  mini.enable(buf_id)
  local base_tree = checkpoint.state(root).accepted_tree
  checkpoint.cleanup(root)

  local attached, attach_err = review_diff.attach(buf_id, {
    cwd = root,
    path = "tracked.txt",
    scope = "pending",
    base_tree = base_tree,
    read_only = false,
  })

  H.eq(nil, attached)
  H.eq("refresh", attach_err.operation)
  H.eq(previous_config, vim.b[buf_id].minidiff_config)
  H.eq(true, mini.enabled[buf_id] == true)
  H.eq("old reference\n", mini.get_buf_data(buf_id).ref_text)
  local detached, detach_err = review_diff.detach(buf_id)
  H.eq(nil, detached)
  H.eq("detach", detach_err.operation)

  mini.disable(buf_id)
  delete_buffers(buf_id)
end)

H.test("MiniDiff attach rolls back when buffer policy prevents enabling", function()
  local root = H.repo()
  local mini = fake_minidiff()
  local checkpoint, review_diff = fresh(root, mini)
  local buf_id = buffer(root .. "/tracked.txt", { "working" })
  local previous_config = { delay = { text_change = 31 }, view = { style = "number" } }
  vim.b[buf_id].minidiff_config = previous_config
  vim.b[buf_id].minidiff_disable = true

  local attached, attach_err = review_diff.attach(buf_id, {
    cwd = root,
    path = "tracked.txt",
    scope = "pending",
    base_tree = checkpoint.state(root).accepted_tree,
    read_only = false,
  })
  local config_after_attach = vim.deepcopy(vim.b[buf_id].minidiff_config)
  local enabled_after_attach = mini.enabled[buf_id] == true
  local detached, detach_err = review_diff.detach(buf_id)

  vim.b[buf_id].minidiff_disable = nil
  delete_buffers(buf_id)
  checkpoint.cleanup()

  H.eq(nil, attached)
  H.eq("attach", attach_err.operation)
  H.eq(previous_config, config_after_attach)
  H.eq(false, enabled_after_attach)
  H.eq(nil, detached)
  H.eq("detach", detach_err.operation)
end)

local function attach_with_enabled_source_under_disable_policy(policy)
  local root = H.repo()
  local mini = fake_minidiff()
  local checkpoint, review_diff = fresh(root, mini)
  local buf_id = buffer(root .. "/tracked.txt", { "working" })
  local old_attaches = 0
  local old_detaches = 0
  local old_source = {
    name = "old-source",
    attach = function(source_buf)
      old_attaches = old_attaches + 1
      mini.set_ref_text(source_buf, "old reference\n")
    end,
    detach = function()
      old_detaches = old_detaches + 1
    end,
  }
  local previous_config = { source = old_source, delay = { text_change = 41 } }
  vim.b[buf_id].minidiff_config = previous_config
  mini.enable(buf_id)
  if policy == "global" then
    vim.g.minidiff_disable = true
  else
    vim.b[buf_id].minidiff_disable = true
  end

  local attached, attach_err = review_diff.attach(buf_id, {
    cwd = root,
    path = "tracked.txt",
    scope = "pending",
    base_tree = checkpoint.state(root).accepted_tree,
    read_only = false,
  })
  local result = {
    attached = attached,
    attach_err = attach_err,
    config = vim.deepcopy(vim.b[buf_id].minidiff_config),
    enabled = mini.enabled[buf_id] == true,
    reference = mini.get_buf_data(buf_id) and mini.get_buf_data(buf_id).ref_text or nil,
    old_attaches = old_attaches,
    old_detaches = old_detaches,
  }

  vim.g.minidiff_disable = nil
  vim.b[buf_id].minidiff_disable = nil
  mini.disable(buf_id)
  delete_buffers(buf_id)
  checkpoint.cleanup()
  return result, previous_config
end

local function assert_disable_policy_preserves_enabled_source(policy)
  local result, previous_config = attach_with_enabled_source_under_disable_policy(policy)

  H.eq(nil, result.attached)
  H.eq("attach", result.attach_err.operation)
  H.eq(previous_config, result.config)
  H.eq(true, result.enabled)
  H.eq("old reference\n", result.reference)
  H.eq(1, result.old_attaches)
  H.eq(0, result.old_detaches)
end

H.test("MiniDiff attach preserves an enabled source under global disable policy", function()
  assert_disable_policy_preserves_enabled_source("global")
end)

H.test("MiniDiff attach preserves an enabled source under buffer disable policy", function()
  assert_disable_policy_preserves_enabled_source("buffer")
end)

H.test("MiniDiff rejects duplicate attach without losing the original restore state", function()
  local root = H.repo()
  local mini = fake_minidiff()
  local checkpoint, review_diff = fresh(root, mini)
  local buf_id = buffer(root .. "/tracked.txt", { "working" })
  local old_source = {
    name = "old-source",
    attach = function(source_buf)
      mini.set_ref_text(source_buf, "old reference\n")
    end,
  }
  local previous_config = { source = old_source, delay = { text_change = 37 } }
  vim.b[buf_id].minidiff_config = previous_config
  mini.enable(buf_id)
  local ctx = {
    cwd = root,
    path = "tracked.txt",
    scope = "pending",
    base_tree = checkpoint.state(root).accepted_tree,
    read_only = false,
  }
  assert(review_diff.attach(buf_id, ctx))

  local duplicate, duplicate_err = review_diff.attach(buf_id, ctx)
  local detached, detach_err = review_diff.detach(buf_id)
  local restored_config = vim.deepcopy(vim.b[buf_id].minidiff_config)
  local restored_enabled = mini.enabled[buf_id] == true
  local restored_reference = mini.get_buf_data(buf_id) and mini.get_buf_data(buf_id).ref_text or nil

  mini.disable(buf_id)
  delete_buffers(buf_id)
  checkpoint.cleanup()

  H.eq(nil, duplicate)
  H.eq("attach", duplicate_err.operation)
  H.eq(true, detached, vim.inspect(detach_err))
  H.eq(previous_config, restored_config)
  H.eq(true, restored_enabled)
  H.eq("old reference\n", restored_reference)
end)

H.test("MiniDiff accept_hunk repeatedly advances only the accepted tree", function()
  local root = H.repo()
  H.write(root .. "/tracked.txt", "old first\nkeep\nold second\nend\n")
  H.git(root, { "add", "tracked.txt" })
  H.git(root, { "commit", "-qm", "review base" })
  local mini = fake_minidiff()
  local checkpoint, review_diff = fresh(root, mini)
  local buf_id = buffer(root .. "/tracked.txt", { "new first", "keep", "new second a", "new second b", "end" })
  local working_lines = vim.api.nvim_buf_get_lines(buf_id, 0, -1, false)
  local base_tree = checkpoint.state(root).accepted_tree
  assert(review_diff.attach(buf_id, {
    cwd = root,
    path = "tracked.txt",
    scope = "pending",
    base_tree = base_tree,
    read_only = false,
  }))
  vim.api.nvim_win_set_buf(0, buf_id)

  mini.set_hunks(buf_id, {
    { type = "change", ref_start = 1, ref_count = 1, buf_start = 1, buf_count = 1 },
    { type = "change", ref_start = 3, ref_count = 1, buf_start = 3, buf_count = 2 },
  })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  H.eq(true, review_diff.accept_hunk(buf_id))
  H.eq(
    "new first\nkeep\nold second\nend\n",
    assert(checkpoint.state(root).git:read_file(checkpoint.state(root).accepted_tree, "tracked.txt")).data
  )
  H.eq("new first\nkeep\nold second\nend\n", mini.get_buf_data(buf_id).ref_text)

  mini.set_hunks(buf_id, {
    { type = "change", ref_start = 3, ref_count = 1, buf_start = 3, buf_count = 2 },
  })
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  H.eq(true, review_diff.accept_hunk(buf_id))
  H.eq(
    "new first\nkeep\nnew second a\nnew second b\nend\n",
    assert(checkpoint.state(root).git:read_file(checkpoint.state(root).accepted_tree, "tracked.txt")).data
  )
  H.eq(working_lines, vim.api.nvim_buf_get_lines(buf_id, 0, -1, false))
  H.eq("old first\nkeep\nold second\nend", H.git(root, { "show", ":tracked.txt" }))

  assert(review_diff.detach(buf_id))
  delete_buffers(buf_id)
  checkpoint.cleanup()
end)

H.test("MiniDiff acceptance preserves reference newline until accepting the buffer EOF", function()
  local root = H.repo()
  H.write(root .. "/tracked.txt", "old first\nold tail")
  H.git(root, { "add", "tracked.txt" })
  H.git(root, { "commit", "-qm", "no final newline" })
  local mini = fake_minidiff()
  local checkpoint, review_diff = fresh(root, mini)
  local buf_id = buffer(root .. "/tracked.txt", { "new first", "new tail" }, true)
  assert(review_diff.attach(buf_id, {
    cwd = root,
    path = "tracked.txt",
    scope = "pending",
    base_tree = checkpoint.state(root).accepted_tree,
    read_only = false,
  }))
  vim.api.nvim_win_set_buf(0, buf_id)

  mini.set_hunks(buf_id, {
    { type = "change", ref_start = 1, ref_count = 1, buf_start = 1, buf_count = 1 },
    { type = "change", ref_start = 2, ref_count = 1, buf_start = 2, buf_count = 1 },
  })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  assert(review_diff.accept_hunk(buf_id))
  H.eq(
    "new first\nold tail",
    assert(checkpoint.state(root).git:read_file(checkpoint.state(root).accepted_tree, "tracked.txt")).data
  )

  mini.set_hunks(buf_id, {
    { type = "change", ref_start = 2, ref_count = 1, buf_start = 2, buf_count = 1 },
  })
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  assert(review_diff.accept_hunk(buf_id))
  H.eq(
    "new first\nnew tail\n",
    assert(checkpoint.state(root).git:read_file(checkpoint.state(root).accepted_tree, "tracked.txt")).data
  )

  assert(review_diff.detach(buf_id))
  delete_buffers(buf_id)
  checkpoint.cleanup()
end)

H.test("MiniDiff reject_hunk resets only the cursor hunk and writes with the buffer final newline", function()
  local root = H.repo()
  H.write(root .. "/tracked.txt", "old first\nkeep\nold second\ntail\n")
  H.git(root, { "add", "tracked.txt" })
  H.git(root, { "commit", "-qm", "review base" })
  local mini = fake_minidiff()
  local checkpoint, review_diff = fresh(root, mini)
  local buf_id = buffer(root .. "/tracked.txt", { "new first", "keep", "new second", "tail" }, false)
  local accepted_tree = checkpoint.state(root).accepted_tree
  assert(review_diff.attach(buf_id, {
    cwd = root,
    path = "tracked.txt",
    scope = "pending",
    base_tree = accepted_tree,
    read_only = false,
  }))
  mini.set_hunks(buf_id, {
    { type = "change", ref_start = 1, ref_count = 1, buf_start = 1, buf_count = 1 },
    { type = "change", ref_start = 3, ref_count = 1, buf_start = 3, buf_count = 1 },
  })
  vim.api.nvim_win_set_buf(0, buf_id)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })

  local rejected, reject_err = review_diff.reject_hunk(buf_id)
  H.eq(true, rejected, vim.inspect(reject_err))

  local expected = "old first\nkeep\nnew second\ntail"
  H.eq({ "old first", "keep", "new second", "tail" }, vim.api.nvim_buf_get_lines(buf_id, 0, -1, false))
  H.eq(false, vim.bo[buf_id].endofline)
  H.eq(expected, H.read(root .. "/tracked.txt"))
  H.eq(#expected, vim.uv.fs_stat(root .. "/tracked.txt").size)
  H.eq(accepted_tree, checkpoint.state(root).accepted_tree)

  assert(review_diff.detach(buf_id))
  delete_buffers(buf_id)
  checkpoint.cleanup()
end)

local function reject_eof_case(reference_data, buffer_endofline)
  local root = H.repo()
  H.write(root .. "/tracked.txt", reference_data)
  H.git(root, { "add", "tracked.txt" })
  H.git(root, { "commit", "-qm", "eof review base" })
  local mini = fake_minidiff()
  local checkpoint, review_diff = fresh(root, mini)
  local buf_id = buffer(root .. "/tracked.txt", { "first", "new tail" }, buffer_endofline)
  local accepted_tree = checkpoint.state(root).accepted_tree
  assert(review_diff.attach(buf_id, {
    cwd = root,
    path = "tracked.txt",
    scope = "pending",
    base_tree = accepted_tree,
    read_only = false,
  }))
  mini.set_hunks(buf_id, {
    { type = "change", ref_start = 2, ref_count = 1, buf_start = 2, buf_count = 1 },
  })
  vim.api.nvim_win_set_buf(0, buf_id)
  vim.api.nvim_win_set_cursor(0, { 2, 0 })

  local rejected, reject_err = review_diff.reject_hunk(buf_id)
  local result = {
    rejected = rejected,
    reject_err = reject_err,
    data = H.read(root .. "/tracked.txt"),
    size = vim.uv.fs_stat(root .. "/tracked.txt").size,
    endofline = vim.bo[buf_id].endofline,
    accepted_tree = checkpoint.state(root).accepted_tree,
    original_tree = accepted_tree,
  }
  assert(review_diff.detach(buf_id))
  delete_buffers(buf_id)
  checkpoint.cleanup()
  return result
end

H.test("MiniDiff rejecting an EOF hunk restores an accepted final newline", function()
  local result = reject_eof_case("first\nold tail\n", false)

  H.eq(true, result.rejected, vim.inspect(result.reject_err))
  H.eq("first\nold tail\n", result.data)
  H.eq(15, result.size)
  H.eq(true, result.endofline)
  H.eq(result.original_tree, result.accepted_tree)
end)

H.test("MiniDiff rejecting an EOF hunk restores an accepted missing final newline", function()
  local result = reject_eof_case("first\nold tail", true)

  H.eq(true, result.rejected, vim.inspect(result.reject_err))
  H.eq("first\nold tail", result.data)
  H.eq(14, result.size)
  H.eq(false, result.endofline)
  H.eq(result.original_tree, result.accepted_tree)
end)

H.test("MiniDiff failed EOF rejection preserves working text and final newline", function()
  local root = H.repo()
  H.write(root .. "/tracked.txt", "first\nold tail\n")
  H.git(root, { "add", "tracked.txt" })
  H.git(root, { "commit", "-qm", "failed EOF review base" })
  local mini = fake_minidiff()
  local checkpoint, review_diff = fresh(root, mini)
  local buf_id = buffer(root .. "/tracked.txt", { "first", "new tail" }, false)
  local accepted_tree = checkpoint.state(root).accepted_tree
  assert(review_diff.attach(buf_id, {
    cwd = root,
    path = "tracked.txt",
    scope = "pending",
    base_tree = accepted_tree,
    read_only = false,
  }))
  mini.set_hunks(buf_id, {
    { type = "change", ref_start = 2, ref_count = 1, buf_start = 2, buf_count = 1 },
  })
  vim.api.nvim_win_set_buf(0, buf_id)
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  vim.bo[buf_id].modifiable = false
  local original_lines = vim.api.nvim_buf_get_lines(buf_id, 0, -1, false)

  local rejected, reject_err = review_diff.reject_hunk(buf_id)
  local result = {
    rejected = rejected,
    reject_err = reject_err,
    lines = vim.api.nvim_buf_get_lines(buf_id, 0, -1, false),
    endofline = vim.bo[buf_id].endofline,
    modifiable = vim.bo[buf_id].modifiable,
    data = H.read(root .. "/tracked.txt"),
    accepted_tree = checkpoint.state(root).accepted_tree,
  }

  vim.bo[buf_id].modifiable = true
  assert(review_diff.detach(buf_id))
  delete_buffers(buf_id)
  checkpoint.cleanup()

  H.eq(nil, result.rejected)
  H.eq("reject_hunk", result.reject_err.operation)
  H.eq(original_lines, result.lines)
  H.eq(false, result.endofline)
  H.eq(false, result.modifiable)
  H.eq("first\nold tail\n", result.data)
  H.eq(accepted_tree, result.accepted_tree)
end)

H.test("MiniDiff rejection rolls back a reset that mutates then throws", function()
  local root = H.repo()
  H.write(root .. "/tracked.txt", "first\nold tail\n")
  H.git(root, { "add", "tracked.txt" })
  H.git(root, { "commit", "-qm", "partial reset review base" })
  local mini = fake_minidiff()
  local checkpoint, review_diff = fresh(root, mini)
  local buf_id = buffer(root .. "/tracked.txt", { "first", "new tail" }, false)
  assert(review_diff.attach(buf_id, {
    cwd = root,
    path = "tracked.txt",
    scope = "pending",
    base_tree = checkpoint.state(root).accepted_tree,
    read_only = false,
  }))
  mini.set_hunks(buf_id, {
    { type = "change", ref_start = 2, ref_count = 1, buf_start = 2, buf_count = 1 },
  })
  vim.api.nvim_win_set_buf(0, buf_id)
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  vim.bo[buf_id].fixendofline = false
  vim.bo[buf_id].modified = false
  local original_do_hunks = mini.do_hunks
  mini.do_hunks = function(...)
    original_do_hunks(...)
    error("reset mutated then failed")
  end
  local original = {
    lines = vim.api.nvim_buf_get_lines(buf_id, 0, -1, false),
    endofline = vim.bo[buf_id].endofline,
    fixendofline = vim.bo[buf_id].fixendofline,
    modifiable = vim.bo[buf_id].modifiable,
    modified = vim.bo[buf_id].modified,
    data = H.read(root .. "/tracked.txt"),
  }

  local rejected, reject_err = review_diff.reject_hunk(buf_id)
  local result = {
    lines = vim.api.nvim_buf_get_lines(buf_id, 0, -1, false),
    endofline = vim.bo[buf_id].endofline,
    fixendofline = vim.bo[buf_id].fixendofline,
    modifiable = vim.bo[buf_id].modifiable,
    modified = vim.bo[buf_id].modified,
    data = H.read(root .. "/tracked.txt"),
  }

  assert(review_diff.detach(buf_id))
  delete_buffers(buf_id)
  checkpoint.cleanup()

  H.eq(nil, rejected)
  H.eq("reject_hunk", reject_err.operation)
  assert(tostring(reject_err.message):find("reset mutated then failed", 1, true))
  H.eq(original, result)
  H.eq("first\nold tail\n", result.data)
end)

H.test("MiniDiff rejection rolls back when writing the reset buffer fails", function()
  local root = H.repo()
  H.write(root .. "/tracked.txt", "first\nold tail")
  H.git(root, { "add", "tracked.txt" })
  H.git(root, { "commit", "-qm", "failed write review base" })
  local mini = fake_minidiff()
  local checkpoint, review_diff = fresh(root, mini)
  local buf_id = buffer(root .. "/tracked.txt", { "first", "new tail" }, true)
  assert(review_diff.attach(buf_id, {
    cwd = root,
    path = "tracked.txt",
    scope = "pending",
    base_tree = checkpoint.state(root).accepted_tree,
    read_only = false,
  }))
  mini.set_hunks(buf_id, {
    { type = "change", ref_start = 2, ref_count = 1, buf_start = 2, buf_count = 1 },
  })
  vim.api.nvim_win_set_buf(0, buf_id)
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  vim.bo[buf_id].fixendofline = true
  vim.bo[buf_id].modified = false
  vim.bo[buf_id].buftype = "nofile"
  local original = {
    lines = vim.api.nvim_buf_get_lines(buf_id, 0, -1, false),
    endofline = vim.bo[buf_id].endofline,
    fixendofline = vim.bo[buf_id].fixendofline,
    modifiable = vim.bo[buf_id].modifiable,
    modified = vim.bo[buf_id].modified,
    data = H.read(root .. "/tracked.txt"),
  }

  local rejected, reject_err = review_diff.reject_hunk(buf_id)
  local result = {
    lines = vim.api.nvim_buf_get_lines(buf_id, 0, -1, false),
    endofline = vim.bo[buf_id].endofline,
    fixendofline = vim.bo[buf_id].fixendofline,
    modifiable = vim.bo[buf_id].modifiable,
    modified = vim.bo[buf_id].modified,
    data = H.read(root .. "/tracked.txt"),
  }

  vim.bo[buf_id].buftype = ""
  assert(review_diff.detach(buf_id))
  delete_buffers(buf_id)
  checkpoint.cleanup()

  H.eq(nil, rejected)
  H.eq("reject_hunk", reject_err.operation)
  assert(tostring(reject_err.message):find("E382", 1, true))
  H.eq(original, result)
  H.eq("first\nold tail", result.data)
end)

H.test("MiniDiff audit attachments keep their fixed base tree and cannot apply hunks", function()
  local root = H.repo()
  local mini = fake_minidiff()
  local checkpoint, review_diff = fresh(root, mini)
  local fixed_tree = checkpoint.state(root).accepted_tree
  assert(checkpoint.accept_text("tracked.txt", "accepted later\n", root))
  local accepted_tree = checkpoint.state(root).accepted_tree
  local buf_id = buffer(root .. "/tracked.txt", { "working" })

  H.eq(true, review_diff.attach(buf_id, {
    cwd = root,
    path = "tracked.txt",
    scope = "turn",
    base_tree = fixed_tree,
    read_only = true,
  }))
  H.eq("base\n", mini.get_buf_data(buf_id).ref_text)
  H.eq(nil, mini.get_buf_data(buf_id).config.source.apply_hunks)

  mini.set_hunks(buf_id, {
    { type = "change", ref_start = 1, ref_count = 1, buf_start = 1, buf_count = 1 },
  })
  vim.api.nvim_win_set_buf(0, buf_id)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local applied, apply_err = review_diff.accept_hunk(buf_id)
  H.eq(nil, applied)
  H.eq("accept_hunk", apply_err.operation)
  H.eq(accepted_tree, checkpoint.state(root).accepted_tree)

  assert(checkpoint.accept_text("tracked.txt", "accepted newest\n", root))
  H.eq(true, review_diff.refresh(buf_id))
  H.eq("base\n", mini.get_buf_data(buf_id).ref_text)

  assert(review_diff.detach(buf_id))
  delete_buffers(buf_id)
  checkpoint.cleanup()
end)

H.test("MiniDiff refresh_all follows accept-all for every attached buffer in one project", function()
  local first_root = H.repo()
  H.write(first_root .. "/second.txt", "second base\n")
  local second_root = H.repo()
  local mini = fake_minidiff()
  local checkpoint, review_diff = fresh(first_root, mini)
  assert(checkpoint.ensure(second_root))
  local first = buffer(first_root .. "/tracked.txt", { "first working" })
  local second = buffer(first_root .. "/second.txt", { "second working" })
  local other = buffer(second_root .. "/tracked.txt", { "other working" })
  local function attach(buf_id, cwd, path)
    return review_diff.attach(buf_id, {
      cwd = vim.fs.normalize(vim.fn.fnamemodify(cwd, ":p")),
      path = path,
      scope = "pending",
      base_tree = checkpoint.state(cwd).accepted_tree,
      read_only = false,
    })
  end
  assert(attach(first, first_root, "tracked.txt"))
  assert(attach(second, first_root, "second.txt"))
  assert(attach(other, second_root, "tracked.txt"))

  H.write(first_root .. "/tracked.txt", "first accepted\n")
  H.write(first_root .. "/second.txt", "second accepted\n")
  H.write(second_root .. "/tracked.txt", "other accepted\n")
  assert(checkpoint.accept_all(first_root))
  H.eq(true, review_diff.refresh_all(first_root .. "/"))
  H.eq("first accepted\n", mini.get_buf_data(first).ref_text)
  H.eq("second accepted\n", mini.get_buf_data(second).ref_text)
  H.eq("base\n", mini.get_buf_data(other).ref_text)
  H.eq({ "first working" }, vim.api.nvim_buf_get_lines(first, 0, -1, false))
  H.eq({ "second working" }, vim.api.nvim_buf_get_lines(second, 0, -1, false))

  assert(checkpoint.accept_all(second_root))
  H.eq(true, review_diff.refresh_all())
  H.eq("other accepted\n", mini.get_buf_data(other).ref_text)

  assert(review_diff.detach(first))
  assert(review_diff.detach(second))
  assert(review_diff.detach(other))
  delete_buffers(first, second, other)
  checkpoint.cleanup()
end)

H.test("MiniDiff goto_hunk delegates navigation for the requested buffer", function()
  local root = H.repo()
  local mini = fake_minidiff()
  local checkpoint, review_diff = fresh(root, mini)
  local buf_id = buffer(root .. "/tracked.txt", { "working" })
  local other = vim.api.nvim_create_buf(true, false)
  assert(review_diff.attach(buf_id, {
    cwd = root,
    path = "tracked.txt",
    scope = "pending",
    base_tree = checkpoint.state(root).accepted_tree,
    read_only = false,
  }))
  vim.api.nvim_win_set_buf(0, other)

  H.eq(true, review_diff.goto_hunk(buf_id, "next"))
  H.eq({ buf_id = buf_id, direction = "next" }, mini.last_goto)
  H.eq(other, vim.api.nvim_get_current_buf())

  assert(review_diff.detach(buf_id))
  delete_buffers(buf_id, other)
  checkpoint.cleanup()
end)
