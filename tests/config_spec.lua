local H = require("tests.helpers")

H.test("review defaults are enabled and cwd is dynamic", function()
  package.loaded["pi.config"] = nil
  local config = require("pi.config")
  H.eq(nil, config.opts.project.cwd)
  H.eq(true, config.opts.review.enabled)
  H.eq(true, config.opts.review.save_before_prompt)
  H.eq({ accept_hunk = "a", reject_hunk = "r", accept_file = "A", reject_file = "R", close = "q" }, config.opts.review.keymaps)
end)

H.test("review keymaps accept false and project cwd rejects non-strings", function()
  package.loaded["pi.config"] = nil
  local config = require("pi.config")
  config.setup({ review = { keymaps = { accept_hunk = false } }, project = { cwd = "/tmp/project" } })
  H.eq(nil, config.opts.review.keymaps.accept_hunk)
  local ok = pcall(config.setup, { project = { cwd = 42 } })
  H.eq(false, ok)
end)
