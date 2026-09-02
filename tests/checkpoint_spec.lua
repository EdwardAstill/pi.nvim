local H = require("tests.helpers")

local function fresh()
  package.loaded["pi.checkpoint"] = nil
  return require("pi.checkpoint")
end

H.test("checkpoint initializes all session baselines from the dirty worktree", function()
  local checkpoint = fresh()
  local root = H.repo()
  H.write(root .. "/tracked.txt", "preexisting\n")
  H.write(root .. "/untracked.txt", "untracked\n")

  local state = assert(checkpoint.ensure(root))

  H.eq(true, state.available)
  H.eq(state.session_start_tree, state.accepted_tree)
  H.eq(nil, state.turn_base_tree)
  H.eq(0, state.turn_number)
  H.eq("preexisting\n", assert(state.git:read_file(state.session_start_tree, "tracked.txt")).data)
  H.eq("untracked\n", assert(state.git:read_file(state.session_start_tree, "untracked.txt")).data)
  checkpoint.cleanup()
end)

H.test("checkpoint keeps pending turn and session views separate across repeated edits", function()
  local checkpoint = fresh()
  local root = H.repo()
  local state = assert(checkpoint.ensure(root))
  local session_start = state.session_start_tree

  assert(checkpoint.start_turn(root))
  H.write(root .. "/tracked.txt", "turn one\n")
  assert(checkpoint.accept_file("tracked.txt"))
  local accepted_after_one = checkpoint.state().accepted_tree

  assert(checkpoint.start_turn(root))
  local second_turn = checkpoint.state().turn_base_tree
  H.write(root .. "/tracked.txt", "turn two\n")

  local pending = assert(checkpoint.view("pending"))
  local turn = assert(checkpoint.view("turn"))
  local session = assert(checkpoint.view("session"))
  H.eq(accepted_after_one, pending.base_tree)
  H.eq(second_turn, turn.base_tree)
  H.eq(session_start, session.base_tree)
  H.eq(false, pending.read_only)
  H.eq(true, turn.read_only)
  H.eq(true, session.read_only)
  H.eq(2, checkpoint.state().turn_number)
  checkpoint.cleanup()
end)

H.test("checkpoint accepts text one file or all without moving audit baselines", function()
  local checkpoint = fresh()
  local root = H.repo()
  H.write(root .. "/second.txt", "second base\n")
  local state = assert(checkpoint.ensure(root))
  local session_start = state.session_start_tree
  assert(checkpoint.start_turn(root))
  local turn_start = checkpoint.state().turn_base_tree

  H.write(root .. "/tracked.txt", "working tracked\n")
  H.write(root .. "/second.txt", "working second\n")
  assert(checkpoint.accept_text("tracked.txt", "accepted tracked\n"))
  local accepted = checkpoint.state().accepted_tree
  H.eq("accepted tracked\n", assert(state.git:read_file(accepted, "tracked.txt")).data)
  H.eq("second base\n", assert(state.git:read_file(accepted, "second.txt")).data)
  assert(checkpoint.accept_all())
  H.eq("working second\n", assert(state.git:read_file(checkpoint.state().accepted_tree, "second.txt")).data)
  H.eq(session_start, checkpoint.state().session_start_tree)
  H.eq(turn_start, checkpoint.state().turn_base_tree)
  checkpoint.cleanup()
end)

H.test("checkpoint rejects a file and degrades cleanly outside Git", function()
  local checkpoint = fresh()
  local root = H.repo()
  assert(checkpoint.ensure(root))
  H.write(root .. "/tracked.txt", "pending\n")
  assert(checkpoint.reject_file("tracked.txt"))
  H.eq("base\n", H.read(root .. "/tracked.txt"))
  checkpoint.cleanup()

  local plain = H.tmpdir()
  local state, err = checkpoint.ensure(plain)
  H.eq(nil, err)
  H.eq(false, state.available)
  local tracked, track_err = checkpoint.start_turn(plain)
  H.eq(false, tracked)
  H.eq(nil, track_err)
  checkpoint.cleanup()
end)

