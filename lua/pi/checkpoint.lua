local M = {}

local current

local function err(kind, operation, message)
  return { kind = kind, operation = operation, message = message }
end

local function normalized_cwd(cwd)
  return vim.fs.normalize(vim.fn.fnamemodify(cwd, ":p"))
end

function M.state()
  return current
end

function M.cleanup()
  if current and current.git then
    current.git:cleanup()
  end
  current = nil
end

M.reset = M.cleanup

function M.ensure(cwd)
  cwd = normalized_cwd(cwd)
  if current and current.cwd == cwd then
    return current, nil
  end
  M.cleanup()

  local git, git_err = require("pi.review.git").new(cwd)
  if not git then
    if git_err and git_err.kind == "not_git" then
      current = { cwd = cwd, available = false, turn_number = 0 }
      return current, nil
    end
    return nil, git_err
  end

  local tree, snapshot_err = git:snapshot()
  if not tree then
    git:cleanup()
    return nil, snapshot_err
  end
  current = {
    cwd = cwd,
    git_root = git.root,
    git = git,
    available = true,
    session_start_tree = tree,
    accepted_tree = tree,
    turn_base_tree = nil,
    turn_number = 0,
  }
  return current, nil
end

function M.start_turn(cwd)
  local state, ensure_err = M.ensure(cwd)
  if not state then
    return nil, ensure_err
  end
  if not state.available then
    return false, nil
  end
  local tree, snapshot_err = state.git:snapshot()
  if not tree then
    return nil, snapshot_err
  end
  state.turn_base_tree = tree
  state.turn_number = state.turn_number + 1
  return true, nil
end

function M.view(scope)
  if not current then
    return nil, err("state", "view", "no Pi review session")
  end
  if not current.available then
    return nil, err("not_git", "view", "review requires a Git worktree")
  end

  local base
  local read_only = false
  if scope == nil or scope == "pending" then
    scope = "pending"
    base = current.accepted_tree
  elseif scope == "turn" then
    if not current.turn_base_tree then
      return nil, err("no_turn", "view", "no turn checkpoint")
    end
    base = current.turn_base_tree
    read_only = true
  elseif scope == "session" then
    base = current.session_start_tree
    read_only = true
  else
    return nil, err("scope", "view", "unknown review scope: " .. tostring(scope))
  end

  local tree, snapshot_err = current.git:snapshot()
  if not tree then
    return nil, snapshot_err
  end
  local files, files_err = current.git:changed_files(base, tree)
  if not files then
    return nil, files_err
  end
  return {
    scope = scope,
    base_tree = base,
    current_tree = tree,
    read_only = read_only,
    files = files,
  }, nil
end

local function require_available(operation)
  if not current or not current.available then
    return nil, err("not_git", operation, "review requires a Git worktree")
  end
  return current, nil
end

function M.accept_file(path)
  local state, state_err = require_available("accept_file")
  if not state then
    return nil, state_err
  end
  local worktree, snapshot_err = state.git:snapshot()
  if not worktree then
    return nil, snapshot_err
  end
  local accepted, copy_err = state.git:copy_path(state.accepted_tree, worktree, path)
  if not accepted then
    return nil, copy_err
  end
  state.accepted_tree = accepted
  return true, nil
end

function M.accept_text(path, data)
  local state, state_err = require_available("accept_text")
  if not state then
    return nil, state_err
  end
  local entry, entry_err = state.git:entry(state.accepted_tree, path)
  if entry_err then
    return nil, entry_err
  end
  if not entry then
    local worktree, snapshot_err = state.git:snapshot()
    if not worktree then
      return nil, snapshot_err
    end
    entry, entry_err = state.git:entry(worktree, path)
    if entry_err then
      return nil, entry_err
    end
  end
  if not entry or entry.type ~= "blob" then
    return nil, err("git", "accept_text", "path is not a text file: " .. path)
  end
  local oid, blob_err = state.git:write_blob(data)
  if not oid then
    return nil, blob_err
  end
  local accepted, update_err = state.git:update_path(state.accepted_tree, path, {
    mode = entry.mode,
    oid = oid,
  })
  if not accepted then
    return nil, update_err
  end
  state.accepted_tree = accepted
  return true, nil
end

function M.accept_all()
  local state, state_err = require_available("accept_all")
  if not state then
    return nil, state_err
  end
  local tree, snapshot_err = state.git:snapshot()
  if not tree then
    return nil, snapshot_err
  end
  state.accepted_tree = tree
  return true, nil
end

function M.reject_file(path)
  local state, state_err = require_available("reject_file")
  if not state then
    return nil, state_err
  end
  return state.git:restore_path(state.accepted_tree, path)
end

function M.status()
  if not current then
    return nil, err("state", "status", "no Pi review session")
  end
  local result = {
    cwd = current.cwd,
    git_root = current.git_root,
    available = current.available,
    turn_number = current.turn_number,
    pending_files = 0,
    pending_hunks = 0,
  }
  if not current.available then
    return result, nil
  end
  local view, view_err = M.view("pending")
  if not view then
    return nil, view_err
  end
  result.pending_files = #view.files
  for _, file in ipairs(view.files) do
    if not file.binary then
      local count, count_err = current.git:hunk_count(view.base_tree, view.current_tree, file.path)
      if count == nil then
        return nil, count_err
      end
      result.pending_hunks = result.pending_hunks + count
    end
  end
  return result, nil
end

return M
