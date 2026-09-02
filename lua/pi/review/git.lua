local Git = {}
Git.__index = Git

local function default_runner(argv, opts)
  return vim.system(argv, opts):wait()
end

local function message_for(result)
  local message = result.stderr
  if message == nil or message == "" then
    message = result.stdout
  end
  message = (message or "Git command failed"):gsub("^%s+", ""):gsub("%s+$", "")
  return message ~= "" and message or "Git command failed"
end

local function failure(kind, operation, result)
  return {
    kind = kind,
    operation = operation,
    message = message_for(result),
  }
end

local function git_error(operation, message)
  return {
    kind = "git",
    operation = operation,
    message = message,
  }
end

local function discover(cwd, runner)
  local result = runner({ "git", "rev-parse", "--show-toplevel" }, { cwd = cwd })
  local root = (result.stdout or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if result.code ~= 0 or root == "" then
    local kind = (result.code == 128 or root == "") and "not_git" or "git"
    return nil, failure(kind, "discover_root", result)
  end
  return vim.fs.normalize(root), nil
end

function Git.discover_root(cwd)
  return discover(cwd, default_runner)
end

function Git.new(cwd, opts)
  opts = opts or {}
  local runner = opts.runner or default_runner
  local root, err = discover(cwd, runner)
  if not root then
    return nil, err
  end

  local self = setmetatable({
    root = root,
    index_path = vim.fn.tempname(),
    runner = runner,
  }, Git)
  return self, nil
end

function Git:_run(argv, opts, operation)
  local result = self.runner(argv, opts or { cwd = self.root })
  if result.code ~= 0 then
    return nil, failure("git", operation, result)
  end
  return result.stdout or "", nil
end

function Git:_run_index(argv, operation)
  return self:_run(argv, {
    cwd = self.root,
    env = { GIT_INDEX_FILE = self.index_path },
  }, operation)
end

function Git:_path(path, operation)
  if type(path) ~= "string" or path == "" then
    return nil, nil, git_error(operation, "path must be a non-empty relative path")
  end

  local normalized = path:gsub("\\", "/")
  if normalized:sub(1, 1) == "/" or normalized:match("^%a:/") then
    return nil, nil, git_error(operation, "absolute paths are not allowed: " .. path)
  end
  if normalized:sub(-1) == "/" or normalized:find("//", 1, true) then
    return nil, nil, git_error(operation, "path is not normalized: " .. path)
  end
  for segment in normalized:gmatch("[^/]+") do
    if segment == "." or segment == ".." then
      return nil, nil, git_error(operation, "path traversal is not allowed: " .. path)
    end
  end

  local absolute = vim.fs.normalize(self.root .. "/" .. normalized)
  if not require("pi.project").is_within(self.root, absolute) then
    return nil, nil, git_error(operation, "path escapes the repository: " .. path)
  end
  return normalized, absolute, nil
end

function Git:snapshot()
  vim.uv.fs_unlink(self.index_path)
  vim.uv.fs_unlink(self.index_path .. ".lock")

  local head = self.runner({ "git", "rev-parse", "--verify", "HEAD" }, { cwd = self.root })
  local read_tree
  local err
  if head.code == 0 then
    read_tree, err = self:_run_index({ "git", "read-tree", "HEAD" }, "snapshot.read_tree")
  else
    read_tree, err = self:_run_index({ "git", "read-tree", "--empty" }, "snapshot.read_tree")
  end
  if not read_tree then
    return nil, err
  end

  local added
  added, err = self:_run_index({ "git", "add", "-A", "--", "." }, "snapshot.add")
  if not added then
    return nil, err
  end

  local tree
  tree, err = self:_run_index({ "git", "write-tree" }, "snapshot.write_tree")
  if not tree then
    return nil, err
  end
  return tree:gsub("^%s+", ""):gsub("%s+$", ""), nil
end

function Git:entry(tree, path)
  local normalized, _, path_err = self:_path(path, "entry")
  if not normalized then
    return nil, path_err
  end
  local output, err = self:_run(
    { "git", "--literal-pathspecs", "ls-tree", "-z", tree, "--", normalized },
    { cwd = self.root },
    "entry"
  )
  if not output then
    return nil, err
  end
  if output == "" then
    return nil, nil
  end

  local record, remainder = output:match("^([^%z]*)%z(.*)$")
  if not record or remainder ~= "" then
    return nil, git_error("entry", "unexpected ls-tree output for " .. normalized)
  end
  local mode, entry_type, oid, returned_path = record:match("^(%d+) ([^ ]+) ([0-9a-f]+)\t(.*)$")
  if not mode or returned_path ~= normalized then
    return nil, git_error("entry", "unexpected ls-tree entry for " .. normalized)
  end
  return {
    mode = mode,
    type = entry_type,
    oid = oid,
    path = returned_path,
  }, nil
end

function Git:read_file(tree, path)
  local normalized, _, path_err = self:_path(path, "read_file")
  if not normalized then
    return nil, path_err
  end
  local entry, err = self:entry(tree, normalized)
  if not entry then
    return nil, err
  end
  if entry.type ~= "blob" then
    return nil, git_error("read_file", normalized .. " is not a blob")
  end
  local data
  data, err = self:_run({ "git", "cat-file", "blob", entry.oid }, { cwd = self.root }, "read_file")
  if not data then
    return nil, err
  end
  entry.data = data
  return entry, nil
end

local function nul_records(output)
  local records = {}
  local start = 1
  while start <= #output do
    local finish = output:find("\0", start, true)
    if not finish then
      return nil
    end
    records[#records + 1] = output:sub(start, finish - 1)
    start = finish + 1
  end
  return records
end

function Git:changed_files(base, current)
  local status_output, err = self:_run({
    "git",
    "diff",
    "--no-ext-diff",
    "--no-renames",
    "--name-status",
    "-z",
    base,
    current,
  }, { cwd = self.root }, "changed_files.name_status")
  if not status_output then
    return nil, err
  end
  local numstat_output
  numstat_output, err = self:_run({
    "git",
    "diff",
    "--no-ext-diff",
    "--no-renames",
    "--numstat",
    "-z",
    base,
    current,
  }, { cwd = self.root }, "changed_files.numstat")
  if not numstat_output then
    return nil, err
  end

  local status_records = nul_records(status_output)
  local numstat_records = nul_records(numstat_output)
  if not status_records or not numstat_records then
    return nil, git_error("changed_files", "Git returned non-NUL-terminated path output")
  end
  if #status_records % 2 ~= 0 then
    return nil, git_error("changed_files", "Git returned malformed name-status output")
  end

  local by_path = {}
  for index = 1, #status_records, 2 do
    local status = status_records[index]
    local path = status_records[index + 1]
    by_path[path] = { path = path, status = status }
  end
  for _, record in ipairs(numstat_records) do
    local additions, deletions, path = record:match("^([^\t]*)\t([^\t]*)\t(.*)$")
    local item = path and by_path[path] or nil
    if not item then
      return nil, git_error("changed_files", "Git returned unmatched numstat output")
    end
    if additions == "-" or deletions == "-" then
      item.additions = nil
      item.deletions = nil
      item.binary = true
    else
      item.additions = tonumber(additions)
      item.deletions = tonumber(deletions)
      item.binary = false
      if item.additions == nil or item.deletions == nil then
        return nil, git_error("changed_files", "Git returned malformed numstat counts")
      end
    end
  end

  local files = {}
  for _, item in pairs(by_path) do
    if item.binary == nil then
      return nil, git_error("changed_files", "Git omitted numstat for " .. item.path)
    end
    files[#files + 1] = item
  end
  table.sort(files, function(left, right)
    return left.path < right.path
  end)
  return files, nil
end

function Git:diff(base, current, path)
  local normalized, _, path_err = self:_path(path, "diff")
  if not normalized then
    return nil, path_err
  end
  return self:_run({
    "git",
    "--literal-pathspecs",
    "diff",
    "--no-ext-diff",
    "--no-renames",
    base,
    current,
    "--",
    normalized,
  }, { cwd = self.root }, "diff")
end

function Git:hunk_count(base, current, path)
  local patch, err = self:diff(base, current, path)
  if not patch then
    return nil, err
  end
  local count = 0
  for line in (patch .. "\n"):gmatch("(.-)\n") do
    if line:match("^@@ ") then
      count = count + 1
    end
  end
  return count, nil
end

function Git:write_blob(data)
  if type(data) ~= "string" then
    return nil, git_error("write_blob", "blob data must be a string")
  end
  local oid, err = self:_run(
    { "git", "hash-object", "-w", "--stdin" },
    { cwd = self.root, stdin = data },
    "write_blob"
  )
  if not oid then
    return nil, err
  end
  return oid:gsub("^%s+", ""):gsub("%s+$", ""), nil
end

function Git:update_path(base, path, entry)
  local normalized, _, path_err = self:_path(path, "update_path")
  if not normalized then
    return nil, path_err
  end
  local _, err = self:_run_index({ "git", "read-tree", base }, "update_path.read_tree")
  if err then
    return nil, err
  end

  if entry == nil then
    _, err = self:_run_index(
      { "git", "update-index", "--force-remove", "--", normalized },
      "update_path.remove"
    )
  else
    if type(entry) ~= "table" or type(entry.mode) ~= "string" or type(entry.oid) ~= "string" then
      return nil, git_error("update_path", "entry must contain string mode and oid fields")
    end
    _, err = self:_run_index({
      "git",
      "update-index",
      "--add",
      "--cacheinfo",
      entry.mode .. "," .. entry.oid .. "," .. normalized,
    }, "update_path.add")
  end
  if err then
    return nil, err
  end

  local tree
  tree, err = self:_run_index({ "git", "write-tree" }, "update_path.write_tree")
  if not tree then
    return nil, err
  end
  return tree:gsub("^%s+", ""):gsub("%s+$", ""), nil
end

function Git:copy_path(base, source, path)
  local normalized, _, path_err = self:_path(path, "copy_path")
  if not normalized then
    return nil, path_err
  end
  local entry, err = self:entry(source, normalized)
  if err then
    return nil, err
  end
  return self:update_path(base, normalized, entry)
end

function Git:_nested_worktree(path, operation)
  local top = self.runner(
    { "git", "-C", path, "rev-parse", "--show-toplevel" },
    { cwd = self.root }
  )
  local nested_root = (top.stdout or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if top.code ~= 0 or vim.fs.normalize(nested_root) ~= vim.fs.normalize(path) then
    return nil, git_error(operation, path .. " is not an initialized submodule")
  end
  local status = self.runner(
    { "git", "-C", path, "status", "--porcelain", "-z" },
    { cwd = self.root }
  )
  if status.code ~= 0 then
    return nil, failure("git", operation, status)
  end
  if (status.stdout or "") ~= "" then
    return nil, git_error(operation, "submodule worktree must be clean: " .. path)
  end
  return true, nil
end

function Git:_remove_worktree_path(absolute, operation)
  local stat, stat_err = vim.uv.fs_lstat(absolute)
  if not stat then
    if stat_err and not stat_err:find("ENOENT", 1, true) then
      return nil, git_error(operation, stat_err)
    end
    return true, nil
  end
  if stat.type == "file" or stat.type == "link" then
    local ok, unlink_err = vim.uv.fs_unlink(absolute)
    if not ok then
      return nil, git_error(operation, unlink_err)
    end
    return true, nil
  end
  if stat.type == "directory" then
    local clean, clean_err = self:_nested_worktree(absolute, operation)
    if not clean then
      return nil, clean_err
    end
    local result = vim.fn.delete(absolute, "rf")
    if result ~= 0 then
      return nil, git_error(operation, "failed to remove clean submodule: " .. absolute)
    end
    return true, nil
  end
  return nil, git_error(operation, "refusing to replace unsupported path type: " .. stat.type)
end

function Git:restore_path(tree, path)
  local normalized, absolute, path_err = self:_path(path, "restore_path")
  if not normalized then
    return nil, path_err
  end
  local entry, err = self:entry(tree, normalized)
  if err then
    return nil, err
  end
  if not entry then
    return self:_remove_worktree_path(absolute, "restore_path")
  end

  if entry.mode == "160000" then
    local clean
    clean, err = self:_nested_worktree(absolute, "restore_path")
    if not clean then
      return nil, err
    end
    local result = self.runner(
      { "git", "-C", absolute, "checkout", "--detach", "--force", entry.oid },
      { cwd = self.root }
    )
    if result.code ~= 0 then
      return nil, failure("git", "restore_path", result)
    end
    return true, nil
  end

  if entry.mode ~= "100644" and entry.mode ~= "100755" and entry.mode ~= "120000" then
    return nil, git_error("restore_path", "unsupported Git mode: " .. entry.mode)
  end
  local file
  file, err = self:read_file(tree, normalized)
  if not file then
    return nil, err
  end
  local removed
  removed, err = self:_remove_worktree_path(absolute, "restore_path")
  if not removed then
    return nil, err
  end
  local parent = vim.fn.fnamemodify(absolute, ":h")
  if vim.fn.mkdir(parent, "p") == 0 and not vim.uv.fs_stat(parent) then
    return nil, git_error("restore_path", "failed to create parent directory: " .. parent)
  end

  if entry.mode == "120000" then
    local ok, symlink_err = vim.uv.fs_symlink(file.data, absolute)
    if not ok then
      return nil, git_error("restore_path", symlink_err)
    end
    return true, nil
  end

  local mode = entry.mode == "100755" and 493 or 420
  local fd, open_err = vim.uv.fs_open(absolute, "w", mode)
  if not fd then
    return nil, git_error("restore_path", open_err)
  end
  local offset = 0
  while offset < #file.data do
    local written, write_err = vim.uv.fs_write(fd, file.data:sub(offset + 1), offset)
    if not written then
      vim.uv.fs_close(fd)
      return nil, git_error("restore_path", write_err)
    end
    if written == 0 then
      vim.uv.fs_close(fd)
      return nil, git_error("restore_path", "failed to make progress writing " .. absolute)
    end
    offset = offset + written
  end
  local closed, close_err = vim.uv.fs_close(fd)
  if not closed then
    return nil, git_error("restore_path", close_err)
  end
  local chmod_ok, chmod_err = vim.uv.fs_chmod(absolute, mode)
  if not chmod_ok then
    return nil, git_error("restore_path", chmod_err)
  end
  return true, nil
end

function Git:cleanup()
  vim.uv.fs_unlink(self.index_path)
  vim.uv.fs_unlink(self.index_path .. ".lock")
end

return Git
