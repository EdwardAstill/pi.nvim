local M = {}

local states = {}
local active_root

local function err(kind, operation, message)
  return { kind = kind, operation = operation, message = message }
end

local function normalized_cwd(cwd)
  return vim.fs.normalize(vim.fn.fnamemodify(cwd, ":p"))
end

function M.state(cwd)
  local root = cwd and normalized_cwd(cwd) or active_root
  return root and states[root] or nil
end

function M.cleanup(cwd)
  if cwd then
    local root = normalized_cwd(cwd)
    local state = states[root]
    if state and state.git then
      state.git:cleanup()
    end
    states[root] = nil
    if active_root == root then
      active_root = nil
    end
    return
  end

  for root, state in pairs(states) do
    if state.git then
      state.git:cleanup()
    end
    states[root] = nil
  end
  active_root = nil
end

M.reset = M.cleanup

function M.ensure(cwd)
  cwd = normalized_cwd(cwd)
  if states[cwd] then
    active_root = cwd
    return states[cwd], nil
  end

  local git, git_err = require("pi.review.git").new(cwd)
  if not git then
    if git_err and git_err.kind == "not_git" then
      states[cwd] = { cwd = cwd, available = false, turn_number = 0 }
      active_root = cwd
      return states[cwd], nil
    end
    return nil, git_err
  end

  local tree, snapshot_err = git:snapshot()
  if not tree then
    git:cleanup()
    return nil, snapshot_err
  end
  states[cwd] = {
    cwd = cwd,
    git_root = git.root,
    git = git,
    available = true,
    session_start_tree = tree,
    accepted_tree = tree,
    turn_base_tree = nil,
    turn_number = 0,
  }
  active_root = cwd
  return states[cwd], nil
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

function M.view(scope, cwd)
  local state = M.state(cwd)
  if not state then
    return nil, err("state", "view", "no Pi review session")
  end
  if not state.available then
    return nil, err("not_git", "view", "review requires a Git worktree")
  end

  local base
  local read_only = false
  if scope == nil or scope == "pending" then
    scope = "pending"
    base = state.accepted_tree
  elseif scope == "turn" then
    if not state.turn_base_tree then
      return nil, err("no_turn", "view", "no turn checkpoint")
    end
    base = state.turn_base_tree
    read_only = true
  elseif scope == "session" then
    base = state.session_start_tree
    read_only = true
  else
    return nil, err("scope", "view", "unknown review scope: " .. tostring(scope))
  end

  local tree, snapshot_err = state.git:snapshot()
  if not tree then
    return nil, snapshot_err
  end
  local files, files_err = state.git:changed_files(base, tree)
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

local function require_available(operation, cwd)
  local state = M.state(cwd)
  if not state or not state.available then
    return nil, err("not_git", operation, "review requires a Git worktree")
  end
  return state, nil
end

function M.accept_file(path, cwd)
  local state, state_err = require_available("accept_file", cwd)
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

function M.accept_text(path, data, cwd)
  local state, state_err = require_available("accept_text", cwd)
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

function M.accept_all(cwd)
  local state, state_err = require_available("accept_all", cwd)
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

function M.reject_file(path, cwd)
  local state, state_err = require_available("reject_file", cwd)
  if not state then
    return nil, state_err
  end
  return state.git:restore_path(state.accepted_tree, path)
end

function M.status(cwd)
  local state = M.state(cwd)
  if not state then
    return nil, err("state", "status", "no Pi review session")
  end
  local result = {
    cwd = state.cwd,
    git_root = state.git_root,
    available = state.available,
    turn_number = state.turn_number,
    pending_files = 0,
    pending_hunks = 0,
  }
  if not state.available then
    return result, nil
  end
  local view, view_err = M.view("pending", cwd)
  if not view then
    return nil, view_err
  end
  result.pending_files = #view.files
  for _, file in ipairs(view.files) do
    if not file.binary then
      local count, count_err = state.git:hunk_count(view.base_tree, view.current_tree, file.path)
      if count == nil then
        return nil, count_err
      end
      result.pending_hunks = result.pending_hunks + count
    end
  end
  return result, nil
end

return M
