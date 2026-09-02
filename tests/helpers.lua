local M = { tests = {}, tempdirs = {} }

function M.test(name, fn)
  M.tests[#M.tests + 1] = { name = name, fn = fn }
end

function M.eq(want, got, message)
  if not vim.deep_equal(want, got) then
    error((message or "values differ") .. "\nwant: " .. vim.inspect(want) .. "\ngot: " .. vim.inspect(got), 2)
  end
end

function M.truthy(value, message)
  if not value then
    error(message or "expected truthy value", 2)
  end
end

function M.tmpdir()
  local path = vim.fn.tempname()
  vim.fn.mkdir(path, "p")
  M.tempdirs[#M.tempdirs + 1] = path
  return vim.fs.normalize(path)
end

function M.write(path, text)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile(vim.split(text, "\n", { plain = true }), path, "b")
end

function M.read(path)
  return table.concat(vim.fn.readfile(path, "b"), "\n")
end

function M.run(argv, opts)
  local result = vim.system(argv, opts or {}):wait()
  if result.code ~= 0 then
    error(string.format("command failed (%d): %s", result.code, result.stderr or ""), 2)
  end
  return vim.trim(result.stdout or "")
end

function M.git(root, args)
  return M.run(vim.list_extend({ "git" }, args), { cwd = root })
end

function M.repo()
  local root = M.tmpdir()
  M.git(root, { "init", "-q" })
  M.git(root, { "config", "user.name", "pi.nvim tests" })
  M.git(root, { "config", "user.email", "pi.nvim@example.invalid" })
  M.write(root .. "/tracked.txt", "base\n")
  M.git(root, { "add", "tracked.txt" })
  M.git(root, { "commit", "-qm", "base" })
  return root
end

function M.cleanup()
  for _, path in ipairs(M.tempdirs) do
    assert(path:match("^/"), "test temp path must be absolute")
    vim.fn.delete(path, "rf")
  end
end

return M
