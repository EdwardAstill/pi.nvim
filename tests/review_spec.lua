local H = require("tests.helpers")

local function lines(prefix)
  local result = {}
  for index = 1, 25 do
    result[index] = prefix .. index
  end
  return result
end

local function write_lines(path, values)
  H.write(path, table.concat(values, "\n") .. "\n")
end

local function choose_first(fn)
  local original = vim.ui.select
  vim.ui.select = function(items, _, callback)
    callback(items[1], 1)
  end
  local ok, result = pcall(fn)
  vim.ui.select = original
  if not ok then
    error(result)
  end
  return result
end

local function fresh(root)
  package.loaded["pi.checkpoint"] = nil
  package.loaded["pi.review"] = nil
  local checkpoint = require("pi.checkpoint")
  assert(checkpoint.ensure(root))
  return checkpoint, require("pi.review")
end

H.test("pending review opens native diff and accepts or rejects individual hunks", function()
  local root = H.repo()
  local base = lines("old ")
  write_lines(root .. "/tracked.txt", base)
  local checkpoint, review = fresh(root)
  assert(checkpoint.start_turn(root))
  local changed = vim.deepcopy(base)
  changed[2] = "accepted first"
  changed[22] = "rejected second"
  write_lines(root .. "/tracked.txt", changed)

  H.eq(true, choose_first(function()
    return review.open("pending")
  end))
  local current = review.current()
  H.eq(true, vim.wo[current.base_win].diff)
  H.eq(true, vim.wo[current.work_win].diff)
  H.eq("pending", current.scope)
  H.truthy(vim.api.nvim_buf_get_keymap(current.work_buf, "n")[1] ~= nil)

  vim.api.nvim_win_set_cursor(current.work_win, { 2, 0 })
  H.eq(true, review.accept("hunk"))
  current = review.current()
  local accepted = assert(checkpoint.state().git:read_file(checkpoint.state().accepted_tree, "tracked.txt")).data
  H.truthy(accepted:find("accepted first", 1, true))
  H.truthy(accepted:find("old 22", 1, true))

  vim.api.nvim_win_set_cursor(current.work_win, { 22, 0 })
  H.eq(true, review.reject("hunk"))
  H.truthy(H.read(root .. "/tracked.txt"):find("old 22", 1, true))
  review.close()
  checkpoint.cleanup()
end)

H.test("turn and session review are read-only and preserve the opening tab", function()
  local root = H.repo()
  local checkpoint, review = fresh(root)
  assert(checkpoint.start_turn(root))
  H.write(root .. "/tracked.txt", "changed\n")
  local original_tab = vim.api.nvim_get_current_tabpage()

  H.eq(true, choose_first(function()
    return review.open("turn")
  end))
  local current = review.current()
  H.eq(true, current.read_only)
  H.eq(false, vim.tbl_contains(vim.tbl_map(function(map)
    return map.lhs
  end, vim.api.nvim_buf_get_keymap(current.work_buf, "n")), "a"))
  H.eq(false, review.accept("file"))
  review.close()
  H.eq(original_tab, vim.api.nvim_get_current_tabpage())
  checkpoint.cleanup()
end)

H.test("file and all actions converge pending review", function()
  local root = H.repo()
  H.write(root .. "/second.txt", "base second\n")
  local checkpoint, review = fresh(root)
  H.write(root .. "/tracked.txt", "changed first\n")
  H.write(root .. "/second.txt", "changed second\n")

  H.eq(true, choose_first(function()
    return review.open("pending")
  end))
  H.eq(true, review.accept("file"))
  H.eq(1, #assert(checkpoint.view("pending")).files)
  H.eq(true, review.accept("all"))
  H.eq(0, #assert(checkpoint.view("pending")).files)
  review.close()
  checkpoint.cleanup()
end)
