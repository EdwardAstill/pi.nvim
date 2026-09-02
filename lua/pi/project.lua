local M = {}

local function normalize(path)
  local normalized = vim.fs.normalize(path)
  if normalized ~= "/" then
    normalized = normalized:gsub("/+$", "")
  end
  return normalized
end

function M.resolve_cwd()
  local cwd = require("pi.config").opts.project.cwd
  if cwd ~= nil then
    cwd = vim.fn.fnamemodify(cwd, ":p")
  else
    cwd = vim.fn.getcwd()
  end
  return normalize(cwd)
end

function M.is_within(root, path)
  root = normalize(root)
  path = normalize(path)
  return path == root or (root == "/" and vim.startswith(path, "/")) or vim.startswith(path, root .. "/")
end

function M.save_modified(root)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    if vim.api.nvim_buf_is_loaded(buf)
      and vim.bo[buf].modified
      and vim.bo[buf].buftype == ""
      and name ~= ""
      and M.is_within(root, name)
    then
      local ok, err = pcall(vim.api.nvim_buf_call, buf, function()
        vim.cmd.update({ mods = { silent = true } })
      end)
      if not ok then
        return false, string.format("failed to save %s: %s", name, err)
      end
    end
  end
  return true, nil
end

return M
