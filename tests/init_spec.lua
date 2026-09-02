local H = require("tests.helpers")

local function load_pi(root, sent)
  package.loaded.pi = nil
  package.loaded["pi.checkpoint"] = nil
  package.loaded["pi.terminal"] = {
    send = function(text, opts)
      sent[#sent + 1] = { text = text, opts = opts }
    end,
    get_cwd = function()
      return root
    end,
  }
  require("pi.config").setup({ project = { cwd = root } })
  return require("pi")
end

H.test("submitted plugin prompt saves buffers before its turn checkpoint", function()
  local root = H.repo()
  local sent = {}
  local pi = load_pi(root, sent)
  local buf = vim.fn.bufadd(root .. "/tracked.txt")
  vim.fn.bufload(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "buffer state" })

  H.eq(true, pi._submit("change it", { submit = true }))

  H.eq("buffer state\n", H.read(root .. "/tracked.txt"))
  local state = require("pi.checkpoint").state()
  H.eq("buffer state\n", assert(state.git:read_file(state.turn_base_tree, "tracked.txt")).data)
  H.eq(root, sent[1].opts.cwd)
  H.eq(1, state.turn_number)
  require("pi.checkpoint").cleanup()
end)

H.test("unsubmitted terminal text skips autosave and checkpoint", function()
  local root = H.repo()
  local sent = {}
  local pi = load_pi(root, sent)
  local buf = vim.fn.bufadd(root .. "/tracked.txt")
  vim.fn.bufload(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "unsaved" })

  H.eq(true, pi._submit("reference", { submit = false }))

  H.eq("base\n", H.read(root .. "/tracked.txt"))
  H.eq(nil, require("pi.checkpoint").state())
  H.eq(false, sent[1].opts.submit)
end)

H.test("autosave failure prevents prompt submission", function()
  local root = H.repo()
  local sent = {}
  local pi = load_pi(root, sent)
  local buf = vim.fn.bufadd(root .. "/tracked.txt")
  vim.fn.bufload(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "blocked" })
  vim.bo[buf].readonly = true

  local original_notify = vim.notify
  vim.notify = function() end
  local submitted = pi._submit("must not send", { submit = true })
  vim.notify = original_notify
  H.eq(false, submitted)
  H.eq(0, #sent)
  H.eq(nil, require("pi.checkpoint").state())
  vim.bo[buf].readonly = false
  vim.api.nvim_buf_set_option(buf, "modified", false)
end)

H.test("submitted prompt still runs outside Git with review unavailable", function()
  local root = H.tmpdir()
  local sent = {}
  local pi = load_pi(root, sent)

  local original_notify = vim.notify
  vim.notify = function() end
  local submitted = pi._submit("plain project", { submit = true })
  vim.notify = original_notify
  H.eq(true, submitted)
  H.eq(1, #sent)
  H.eq(false, require("pi.checkpoint").state().available)
  require("pi.checkpoint").cleanup()
end)
