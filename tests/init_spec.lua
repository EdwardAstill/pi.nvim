local H = require("tests.helpers")

local function with_pi(stubs, fn)
  local saved = {}
  for name, value in pairs(stubs) do
    saved[name] = package.loaded[name]
    package.loaded[name] = value
  end
  local saved_pi = package.loaded.pi
  package.loaded.pi = nil
  local ok, test_err = xpcall(function()
    fn(require("pi"))
  end, debug.traceback)
  package.loaded.pi = saved_pi
  for name in pairs(stubs) do
    package.loaded[name] = saved[name]
  end
  if not ok then
    error(test_err, 0)
  end
end

local function base_stubs(root, bridge)
  return {
    ["pi.config"] = {
      opts = {
        keymaps = {},
        prompts = {
          explain = { text = "Explain @this", submit = true },
          draft = { text = "Consider @buffer", submit = false },
        },
        project = { cwd = root },
        review = { enabled = true, save_before_prompt = true },
      },
      setup = function() end,
    },
    ["pi.project"] = {
      resolve_cwd = function() return root end,
    },
    ["pi.codecompanion"] = bridge,
  }
end

H.test("public submit delegates checkpoint ownership to CodeCompanion lifecycle", function()
  local root = H.tmpdir()
  local calls = {}
  local context = { bufnr = 17, is_visual = true }
  local bridge = {
    capture_context = function() return context end,
    prompt = function(text, opts)
      calls[#calls + 1] = { "prompt", text, opts }
      return { bufnr = 1 }
    end,
  }
  local stubs = base_stubs(root, bridge)
  stubs["pi.checkpoint"] = {
    start_turn = function() error("duplicate checkpoint") end,
  }

  with_pi(stubs, function(pi)
    H.eq(true, pi._submit("change it", { submit = true }))
  end)

  H.eq("prompt", calls[1][1])
  H.eq("change it", calls[1][2])
  H.eq(root, calls[1][3].cwd)
  H.eq(context, calls[1][3].context)
end)
H.test("unsubmitted text opens the native composer without sending", function()
  local root = H.tmpdir()
  local composed
  local bridge = {
    capture_context = function() return { bufnr = 3, is_visual = false } end,
    compose = function(text, opts)
      composed = { text = text, opts = opts }
      return { bufnr = 2 }
    end,
    prompt = function() error("must not submit") end,
  }

  with_pi(base_stubs(root, bridge), function(pi)
    H.eq(true, pi._submit("reference", { submit = false }))
  end)

  H.eq("reference", composed.text)
  H.eq(root, composed.opts.cwd)
end)

H.test("named prompts choose direct submission or composer", function()
  local root = H.tmpdir()
  local calls = {}
  local bridge = {
    capture_context = function() return { bufnr = 4, is_visual = false } end,
    prompt = function(text)
      calls[#calls + 1] = { "prompt", text }
      return {}
    end,
    compose = function(text)
      calls[#calls + 1] = { "compose", text }
      return {}
    end,
  }

  with_pi(base_stubs(root, bridge), function(pi)
    H.eq(true, pi.prompt("explain"))
    H.eq(true, pi.prompt("draft"))
  end)

  H.eq({ { "prompt", "Explain @this" }, { "compose", "Consider @buffer" } }, calls)
end)

H.test("setup installs lifecycle hooks and the public controls delegate by project", function()
  local root = H.tmpdir()
  local calls = {}
  local config = {
    opts = { keymaps = {}, prompts = {}, project = { cwd = root }, review = {} },
    setup = function(opts)
      calls[#calls + 1] = { "setup", opts }
    end,
  }
  local bridge = {
    capture_context = function() return { bufnr = 8 } end,
    toggle = function(cwd)
      calls[#calls + 1] = { "toggle", cwd }
      return {}
    end,
    focus = function(cwd)
      calls[#calls + 1] = { "focus", cwd }
      return {}
    end,
    abort = function(cwd)
      calls[#calls + 1] = { "abort", cwd }
      return true
    end,
    model = function(cwd)
      calls[#calls + 1] = { "model", cwd }
      return true
    end,
    thinking = function(cwd)
      calls[#calls + 1] = { "thinking", cwd }
      return true
    end,
    stop = function(cwd)
      calls[#calls + 1] = { "stop", cwd }
      return true
    end,
  }
  local stubs = base_stubs(root, bridge)
  stubs["pi.config"] = config
  stubs["pi.lifecycle"] = {
    setup = function()
      calls[#calls + 1] = { "lifecycle" }
    end,
  }

  with_pi(stubs, function(pi)
    local opts = { codecompanion = { adapter = "pi" } }
    pi.setup(opts)
    H.eq(true, pi.toggle())
    H.eq(true, pi.focus())
    H.eq(true, pi.abort())
    H.eq(true, pi.model())
    H.eq(true, pi.thinking())
    H.eq(true, pi.stop())
  end)

  H.eq({
    { "setup", { codecompanion = { adapter = "pi" } } },
    { "lifecycle" },
    { "toggle", root },
    { "focus", root },
    { "abort", root },
    { "model", root },
    { "thinking", root },
    { "stop", root },
  }, calls)
end)
