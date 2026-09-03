local H = require("tests.helpers")

local function fake_minidiff()
  local M = { calls = {} }
  local function record(name, ...)
    M.calls[#M.calls + 1] = { name, ... }
    return true
  end
  function M.attach(buf, ctx) return record("attach", buf, vim.deepcopy(ctx)) end
  function M.detach(buf) return record("detach", buf) end
  function M.refresh(buf) return record("refresh", buf) end
  function M.refresh_all(cwd) return record("refresh_all", cwd) end
  function M.accept_hunk(buf) return record("accept_hunk", buf) end
  function M.reject_hunk(buf) return record("reject_hunk", buf) end
  function M.goto_hunk(buf, direction) return record("goto_hunk", buf, direction) end
  return M
end

local function fresh(root)
  package.loaded["pi.checkpoint"] = nil
  package.loaded["pi.review"] = nil
  local mini = fake_minidiff()
  package.loaded["pi.review.minidiff"] = mini
  local checkpoint = require("pi.checkpoint")
  assert(checkpoint.ensure(root))
  return checkpoint, require("pi.review"), mini
end

local function with_picker(choice, fn)
  local original = vim.ui.select
  vim.ui.select = function(items, _, callback)
    callback(choice and items[choice] or nil, choice)
  end
  local ok, result = pcall(fn)
  vim.ui.select = original
  if not ok then error(result) end
  return result
end

local function choose_first(fn) return with_picker(1, fn) end
local function cancel_picker(fn) return with_picker(nil, fn) end

local function test_tab()
  local original_tab = vim.api.nvim_get_current_tabpage()
  vim.cmd.tabnew()
  local ui = {
    original_tab = original_tab,
    tab = vim.api.nvim_get_current_tabpage(),
    win = vim.api.nvim_get_current_win(),
    buf = vim.api.nvim_create_buf(false, false),
  }
  vim.api.nvim_buf_set_lines(ui.buf, 0, -1, false, { "source buffer" })
  vim.api.nvim_win_set_buf(ui.win, ui.buf)
  return ui
end

local function cleanup_ui(ui, review)
  if review then pcall(review.close) end
  if vim.api.nvim_tabpage_is_valid(ui.tab) then
    pcall(vim.api.nvim_set_current_tabpage, ui.tab)
    pcall(vim.cmd, "tabclose!")
  end
  if vim.api.nvim_tabpage_is_valid(ui.original_tab) then
    pcall(vim.api.nvim_set_current_tabpage, ui.original_tab)
  end
  if vim.api.nvim_buf_is_valid(ui.buf) then
    pcall(vim.api.nvim_buf_delete, ui.buf, { force = true })
  end
end

local function pi_mappings(buf)
  local result = {}
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return result end
  for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    if mapping.desc and vim.startswith(mapping.desc, "Pi: ") then
      result[#result + 1] = mapping.lhs
    end
  end
  table.sort(result)
  return result
end

local function mapping_callback(buf, lhs)
  if not buf then return nil end
  for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    if mapping.lhs == lhs then return mapping.callback end
  end
end

local function call_names(calls)
  return vim.tbl_map(function(call) return call[1] end, calls)
end

local function current_buf(current)
  return current and (current.buf or current.work_buf) or nil
end

local function index_fingerprint(root)
  local index = H.git(root, { "rev-parse", "--git-path", "index" })
  return {
    tree = H.git(root, { "write-tree" }),
    bytes = H.git(root, { "hash-object", index }),
  }
end

local function write_bytes(path, data)
  local fd = assert(vim.uv.fs_open(path, "w", 420))
  assert(vim.uv.fs_write(fd, data, 0))
  assert(vim.uv.fs_close(fd))
end

H.test("pending review opens the real file in the current tab and owns only Pi mappings", function()
  local root = H.repo()
  local checkpoint, review, mini = fresh(root)
  H.write(root .. "/tracked.txt", "working\n")
  local ui = test_tab()
  local tab_count = #vim.api.nvim_list_tabpages()
  local win_count = #vim.api.nvim_tabpage_list_wins(ui.tab)

  local opened = choose_first(function() return review.open("pending", root) end)
  local current = review.current()
  local buf = current_buf(current)
  local observed = {
    opened = opened,
    tab_count = #vim.api.nvim_list_tabpages(),
    win_count = #vim.api.nvim_tabpage_list_wins(ui.tab),
    tab = vim.api.nvim_get_current_tabpage(),
    win = vim.api.nvim_get_current_win(),
    name = buf and vim.api.nvim_buf_get_name(buf) or nil,
    buftype = buf and vim.bo[buf].buftype or nil,
    scope = current and current.scope or nil,
    cwd = current and current.cwd or nil,
    path = current and current.path or nil,
    supported = current and current.supported or nil,
    read_only = current and current.read_only,
    mappings = pi_mappings(buf),
  }
  local previous = mapping_callback(buf, "[h")
  local next = mapping_callback(buf, "]h")
  if previous then previous() end
  if next then next() end
  observed.closed = review.close()
  observed.mappings_after_close = pi_mappings(buf)
  observed.buffer_valid_after_close = buf and vim.api.nvim_buf_is_valid(buf) or false
  observed.window_valid_after_close = vim.api.nvim_win_is_valid(ui.win)
  observed.calls = vim.deepcopy(mini.calls)

  cleanup_ui(ui)
  checkpoint.cleanup()

  H.eq(true, observed.opened)
  H.eq(tab_count, observed.tab_count, "review must not create a tab")
  H.eq(win_count, observed.win_count, "the current ordinary window must be reused")
  H.eq(ui.tab, observed.tab)
  H.eq(ui.win, observed.win)
  H.eq(vim.fs.normalize(root .. "/tracked.txt"), vim.fs.normalize(observed.name))
  H.eq("", observed.buftype)
  H.eq("pending", observed.scope)
  H.eq(vim.fs.normalize(root), observed.cwd)
  H.eq("tracked.txt", observed.path)
  H.eq(true, observed.supported)
  H.eq(false, observed.read_only)
  H.eq({ "A", "R", "[h", "]h", "a", "q", "r" }, observed.mappings)
  H.eq(true, observed.closed)
  H.eq({}, observed.mappings_after_close)
  H.eq(true, observed.buffer_valid_after_close)
  H.eq(true, observed.window_valid_after_close)
  H.eq({ "attach", "goto_hunk", "goto_hunk", "detach" }, call_names(observed.calls))
  H.eq("previous", observed.calls[2][3])
  H.eq("next", observed.calls[3][3])
end)

H.test("review picker cancellation leaves editor and review state unchanged", function()
  local root = H.repo()
  local checkpoint, review, mini = fresh(root)
  H.write(root .. "/tracked.txt", "working\n")
  local ui = test_tab()
  local before = {
    tab = vim.api.nvim_get_current_tabpage(), win = vim.api.nvim_get_current_win(),
    buf = vim.api.nvim_get_current_buf(), tabs = #vim.api.nvim_list_tabpages(),
    wins = #vim.api.nvim_tabpage_list_wins(ui.tab),
  }
  local opened = cancel_picker(function() return review.open("pending", root) end)
  local after = {
    tab = vim.api.nvim_get_current_tabpage(), win = vim.api.nvim_get_current_win(),
    buf = vim.api.nvim_get_current_buf(), tabs = #vim.api.nvim_list_tabpages(),
    wins = #vim.api.nvim_tabpage_list_wins(ui.tab),
  }
  local current = review.current()
  local calls = #mini.calls
  cleanup_ui(ui, review)
  checkpoint.cleanup()
  H.eq(true, opened)
  H.eq(nil, current)
  H.eq(before, after)
  H.eq(0, calls)
end)

H.test("pending hunk actions delegate solely to MiniDiff", function()
  local root = H.repo()
  local checkpoint, review, mini = fresh(root)
  H.write(root .. "/tracked.txt", "working\n")
  local ui = test_tab()
  choose_first(function() return review.open("pending", root) end)
  local buf = current_buf(review.current())
  local accepted = review.accept("hunk")
  local rejected = review.reject("hunk")
  local calls = vim.deepcopy(mini.calls)
  cleanup_ui(ui, review)
  checkpoint.cleanup()
  H.eq(true, accepted)
  H.eq(true, rejected)
  H.eq({ "attach", "accept_hunk", "reject_hunk" }, call_names(calls))
  H.eq(buf, calls[2][2])
  H.eq(buf, calls[3][2])
end)

H.test("pending file acceptance uses the selected project and refreshes its reference", function()
  local root = H.repo()
  local checkpoint, review, mini = fresh(root)
  H.write(root .. "/tracked.txt", "working\n")
  local ui = test_tab()
  choose_first(function() return review.open("pending", root) end)
  local buf = current_buf(review.current())
  local original = checkpoint.accept_file
  local arguments
  checkpoint.accept_file = function(path, cwd)
    arguments = { path, cwd }
    return original(path, cwd)
  end
  local accepted = review.accept("file")
  local working = H.read(root .. "/tracked.txt")
  local pending = #assert(checkpoint.view("pending", root)).files
  local calls = vim.deepcopy(mini.calls)
  checkpoint.accept_file = original
  cleanup_ui(ui, review)
  checkpoint.cleanup()
  H.eq(true, accepted)
  H.eq({ "tracked.txt", vim.fs.normalize(root) }, arguments)
  H.eq("working\n", working)
  H.eq(0, pending)
  H.eq({ "attach", "refresh" }, call_names(calls))
  H.eq(buf, calls[2][2])
end)

H.test("accept all uses the selected project and refreshes every Pi attachment without changing files or index", function()
  local first_root = H.repo()
  local second_root = H.repo()
  local checkpoint, review, mini = fresh(first_root)
  assert(checkpoint.ensure(second_root))
  H.write(first_root .. "/tracked.txt", "first working\n")
  H.write(second_root .. "/tracked.txt", "second working\n")
  local first_index = index_fingerprint(first_root)
  local second_index = index_fingerprint(second_root)
  local ui = test_tab()
  choose_first(function() return review.open("pending", first_root) end)
  local original = checkpoint.accept_all
  local argument
  checkpoint.accept_all = function(cwd)
    argument = cwd
    return original(cwd)
  end
  local accepted = review.accept("all")
  local result = {
    first_working = H.read(first_root .. "/tracked.txt"),
    second_working = H.read(second_root .. "/tracked.txt"),
    first_pending = #assert(checkpoint.view("pending", first_root)).files,
    second_pending = #assert(checkpoint.view("pending", second_root)).files,
    first_index = index_fingerprint(first_root), second_index = index_fingerprint(second_root),
    calls = vim.deepcopy(mini.calls),
  }
  checkpoint.accept_all = original
  cleanup_ui(ui, review)
  checkpoint.cleanup()
  H.eq(true, accepted)
  H.eq(vim.fs.normalize(first_root), argument)
  H.eq("first working\n", result.first_working)
  H.eq("second working\n", result.second_working)
  H.eq(0, result.first_pending)
  H.eq(1, result.second_pending)
  H.eq(first_index, result.first_index)
  H.eq(second_index, result.second_index)
  H.eq({ "attach", "refresh_all" }, call_names(result.calls))
  H.eq(vim.fs.normalize(first_root), result.calls[2][2])
end)

H.test("turn review exposes only navigation and close and cannot mutate checkpoint state", function()
  local root = H.repo()
  local checkpoint, review, mini = fresh(root)
  assert(checkpoint.start_turn(root))
  H.write(root .. "/tracked.txt", "turn working\n")
  local accepted_tree = checkpoint.state(root).accepted_tree
  local working = H.read(root .. "/tracked.txt")
  local ui = test_tab()
  choose_first(function() return review.open("turn", root) end)
  local current = review.current()
  local buf = current_buf(current)
  local mappings = pi_mappings(buf)
  local previous = mapping_callback(buf, "[h")
  local next = mapping_callback(buf, "]h")
  if previous then previous() end
  if next then next() end
  local results = {
    review.accept("hunk"), review.reject("hunk"), review.accept("file"),
    review.reject("file"), review.accept("all"),
  }
  local tree_after = checkpoint.state(root).accepted_tree
  local working_after = H.read(root .. "/tracked.txt")
  local calls = vim.deepcopy(mini.calls)
  cleanup_ui(ui, review)
  checkpoint.cleanup()
  H.eq(true, current and current.read_only)
  H.eq({ "[h", "]h", "q" }, mappings)
  H.eq({ false, false, false, false, false }, results)
  H.eq(accepted_tree, tree_after)
  H.eq(working, working_after)
  H.eq({ "attach", "goto_hunk", "goto_hunk" }, call_names(calls))
end)

H.test("reject file cancellation preserves an unsaved loaded buffer and checkpoint", function()
  local root = H.repo()
  local checkpoint, review = fresh(root)
  H.write(root .. "/tracked.txt", "working\n")
  local accepted_tree = checkpoint.state(root).accepted_tree
  local ui = test_tab()
  choose_first(function() return review.open("pending", root) end)
  local buf = current_buf(review.current())
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "unsaved" })
  vim.bo[buf].modified = true
  local original_confirm = vim.fn.confirm
  local original_reject = checkpoint.reject_file
  local confirmations, rejections = 0, 0
  vim.fn.confirm = function() confirmations = confirmations + 1; return 2 end
  checkpoint.reject_file = function(...)
    rejections = rejections + 1
    return original_reject(...)
  end
  local rejected = review.reject("file")
  local result = {
    lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false), modified = vim.bo[buf].modified,
    disk = H.read(root .. "/tracked.txt"), tree = checkpoint.state(root).accepted_tree,
  }
  vim.fn.confirm = original_confirm
  checkpoint.reject_file = original_reject
  cleanup_ui(ui, review)
  checkpoint.cleanup()
  H.eq(false, rejected)
  H.eq(1, confirmations)
  H.eq(0, rejections)
  H.eq({ "unsaved" }, result.lines)
  H.eq(true, result.modified)
  H.eq("working\n", result.disk)
  H.eq(accepted_tree, result.tree)
end)

H.test("confirmed file rejection uses the selected project and reloads the real buffer", function()
  local root = H.repo()
  local checkpoint, review = fresh(root)
  H.write(root .. "/tracked.txt", "working\n")
  local index = index_fingerprint(root)
  local ui = test_tab()
  choose_first(function() return review.open("pending", root) end)
  local buf = current_buf(review.current())
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "unsaved" })
  vim.bo[buf].modified = true
  local original_confirm = vim.fn.confirm
  local original_reject = checkpoint.reject_file
  local arguments
  vim.fn.confirm = function() return 1 end
  checkpoint.reject_file = function(path, cwd)
    arguments = { path, cwd }
    return original_reject(path, cwd)
  end
  local rejected = review.reject("file")
  local result = {
    lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false), modified = vim.bo[buf].modified,
    disk = H.read(root .. "/tracked.txt"), index = index_fingerprint(root),
  }
  vim.fn.confirm = original_confirm
  checkpoint.reject_file = original_reject
  cleanup_ui(ui, review)
  checkpoint.cleanup()
  H.eq(true, rejected)
  H.eq({ "tracked.txt", vim.fs.normalize(root) }, arguments)
  H.eq({ "base" }, result.lines)
  H.eq(false, result.modified)
  H.eq("base\n", result.disk)
  H.eq(index, result.index)
end)

H.test("deleted files retain file-level state without opening or mapping an unrelated buffer", function()
  local root = H.repo()
  local checkpoint, review, mini = fresh(root)
  vim.uv.fs_unlink(root .. "/tracked.txt")
  local ui = test_tab()
  local opened = choose_first(function() return review.open("pending", root) end)
  local current = review.current()
  local observed = {
    opened = opened, path = current and current.path or nil, buf = current and current.buf or nil,
    supported = current and current.supported, current_buf = vim.api.nvim_get_current_buf(),
    mappings = pi_mappings(ui.buf), calls = #mini.calls,
  }
  local rejected = review.reject("file")
  observed.restored = H.read(root .. "/tracked.txt")
  cleanup_ui(ui, review)
  checkpoint.cleanup()
  H.eq(true, observed.opened)
  H.eq("tracked.txt", observed.path)
  H.eq(nil, observed.buf)
  H.eq(false, observed.supported)
  H.eq(ui.buf, observed.current_buf)
  H.eq({}, observed.mappings)
  H.eq(0, observed.calls)
  H.eq(true, rejected)
  H.eq("base\n", observed.restored)
end)

local function unsupported_real_file_case(kind)
  local root = H.repo()
  if kind == "symlink" then
    H.write(root .. "/target.txt", "target\n")
    H.git(root, { "add", "target.txt" })
    H.git(root, { "commit", "-qm", "add target" })
  end
  local checkpoint, review, mini = fresh(root)
  if kind == "binary" then
    write_bytes(root .. "/tracked.txt", "binary\000working")
  else
    vim.uv.fs_unlink(root .. "/tracked.txt")
    assert(vim.uv.fs_symlink("target.txt", root .. "/tracked.txt"))
  end
  local ui = test_tab()
  choose_first(function() return review.open("pending", root) end)
  local current = review.current()
  local buf = current_buf(current)
  local result = {
    name = buf and vim.api.nvim_buf_get_name(buf) or nil,
    buftype = buf and vim.bo[buf].buftype or nil,
    supported = current and current.supported,
    mappings = pi_mappings(buf), calls = #mini.calls,
  }
  cleanup_ui(ui, review)
  checkpoint.cleanup()
  return root, result
end

H.test("binary files open as real buffers with pending file actions only", function()
  local root, result = unsupported_real_file_case("binary")
  H.eq(vim.fs.normalize(root .. "/tracked.txt"), vim.fs.normalize(result.name))
  H.eq("", result.buftype)
  H.eq(false, result.supported)
  H.eq({ "A", "R", "q" }, result.mappings)
  H.eq(0, result.calls)
end)

H.test("symlinks open as real buffers with pending file actions only", function()
  local root, result = unsupported_real_file_case("symlink")
  H.eq(vim.fs.normalize(root .. "/tracked.txt"), vim.fs.normalize(result.name))
  H.eq(false, result.supported)
  H.eq({ "A", "R", "q" }, result.mappings)
  H.eq(0, result.calls)
end)

H.test("close removes only Pi mappings and leaves the real buffer and window intact", function()
  local root = H.repo()
  local checkpoint, review, mini = fresh(root)
  H.write(root .. "/tracked.txt", "working\n")
  local ui = test_tab()
  choose_first(function() return review.open("pending", root) end)
  local buf = current_buf(review.current())
  vim.keymap.set("n", "z", "zz", { buffer = buf, desc = "User mapping" })
  local closed = review.close()
  local by_lhs = {}
  for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do by_lhs[mapping.lhs] = mapping.desc end
  local result = {
    current = review.current(), pi_mappings = pi_mappings(buf), user_mapping = by_lhs.z,
    buf_valid = vim.api.nvim_buf_is_valid(buf), win_valid = vim.api.nvim_win_is_valid(ui.win),
    win_buf = vim.api.nvim_win_get_buf(ui.win), calls = vim.deepcopy(mini.calls),
  }
  cleanup_ui(ui)
  checkpoint.cleanup()
  H.eq(true, closed)
  H.eq(nil, result.current)
  H.eq({}, result.pi_mappings)
  H.eq("User mapping", result.user_mapping)
  H.eq(true, result.buf_valid)
  H.eq(true, result.win_valid)
  H.eq(buf, result.win_buf)
  H.eq({ "attach", "detach" }, call_names(result.calls))
end)
