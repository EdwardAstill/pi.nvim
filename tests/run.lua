local helpers = require("tests.helpers")

for _, spec in ipairs({ "config_spec", "project_spec", "terminal_spec", "git_spec" }) do
  require("tests." .. spec)
end

local passed, failed = 0, 0
for _, test in ipairs(helpers.tests) do
  local ok, err = xpcall(test.fn, debug.traceback)
  if ok then
    passed = passed + 1
    print("PASS " .. test.name)
  else
    failed = failed + 1
    print("FAIL " .. test.name .. "\n" .. err)
  end
end

helpers.cleanup()
print(string.format("%d passed, %d failed", passed, failed))

if failed > 0 then
  vim.cmd("cquit 1")
else
  vim.cmd("qa!")
end
