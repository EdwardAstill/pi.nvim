local H = require("tests.helpers")

H.test("native frontend defaults contain only CodeCompanion integration settings", function()
  package.loaded["pi.config"] = nil
  local config = require("pi.config")
  H.eq(nil, config.opts.project.cwd)
  H.eq({ adapter = "pi", command = { "pi-acp" }, thinking_winbar = true }, config.opts.codecompanion)
  H.eq(true, config.opts.compatibility.legacy_context_tokens)
  H.eq(nil, config.opts.terminal)
  H.eq(true, config.opts.review.enabled)
  H.eq(true, config.opts.review.save_before_prompt)
  H.eq(true, config.opts.review.overlay)
  H.eq({
    previous_hunk = "[h",
    next_hunk = "]h",
    accept_hunk = "a",
    reject_hunk = "r",
    accept_file = "A",
    reject_file = "R",
    close = "q",
  }, config.opts.review.keymaps)
end)

H.test("review keymaps accept false and project cwd rejects non-strings", function()
  package.loaded["pi.config"] = nil
  local config = require("pi.config")
  config.setup({ review = { keymaps = { accept_hunk = false } }, project = { cwd = "/tmp/project" } })
  H.eq(nil, config.opts.review.keymaps.accept_hunk)
  local ok = pcall(config.setup, { project = { cwd = 42 } })
  H.eq(false, ok)
end)

H.test("terminal configuration is rejected instead of enabling a fallback", function()
  package.loaded["pi.config"] = nil
  local config = require("pi.config")
  local ok, config_err = pcall(config.setup, { terminal = { cmd = "pi" } })

  H.eq(false, ok)
  H.truthy(tostring(config_err):find("terminal frontend has been removed", 1, true))
end)

H.test("CodeCompanion and compatibility settings are validated", function()
  package.loaded["pi.config"] = nil
  local config = require("pi.config")
  config.setup({
    codecompanion = { adapter = "custom-pi", command = { "/opt/bin/pi-acp" } },
    compatibility = { legacy_context_tokens = false },
  })

  H.eq("custom-pi", config.opts.codecompanion.adapter)
  H.eq({ "/opt/bin/pi-acp" }, config.opts.codecompanion.command)
  H.eq(false, config.opts.compatibility.legacy_context_tokens)
  H.eq(false, pcall(config.setup, { codecompanion = { command = "pi-acp" } }))
  H.eq({ "/opt/bin/pi-acp" }, config.opts.codecompanion.command)
end)

H.test("pre-submit saving cannot be disabled", function()
  package.loaded["pi.config"] = nil
  local config = require("pi.config")

  local ok, config_err = pcall(config.setup, { review = { save_before_prompt = false } })

  H.eq(false, ok)
  H.truthy(tostring(config_err):find("review.save_before_prompt", 1, true))
end)
