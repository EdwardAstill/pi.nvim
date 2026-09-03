local H = require("tests.helpers")

H.test("patch applies every MiniDiff hunk shape including empty files", function()
  package.loaded["pi.review.patch"] = nil
  local patch = require("pi.review.patch")

  local cases = {
    {
      name = "add before the first reference line",
      reference = { "beta", "gamma" },
      buffer = { "alpha", "beta", "gamma" },
      hunk = { type = "add", ref_start = 0, ref_count = 0, buf_start = 1, buf_count = 1 },
      want = { "alpha", "beta", "gamma" },
    },
    {
      name = "change reference lines",
      reference = { "alpha", "old", "gamma" },
      buffer = { "alpha", "new", "gamma" },
      hunk = { type = "change", ref_start = 2, ref_count = 1, buf_start = 2, buf_count = 1 },
      want = { "alpha", "new", "gamma" },
    },
    {
      name = "delete the first reference line",
      reference = { "remove", "keep" },
      buffer = { "keep" },
      hunk = { type = "delete", ref_start = 1, ref_count = 1, buf_start = 0, buf_count = 0 },
      want = { "keep" },
    },
    {
      name = "add to an empty reference",
      reference = {},
      buffer = { "only" },
      hunk = { type = "add", ref_start = 0, ref_count = 0, buf_start = 1, buf_count = 1 },
      want = { "only" },
    },
    {
      name = "delete the whole file",
      reference = { "only" },
      buffer = {},
      hunk = { type = "delete", ref_start = 1, ref_count = 1, buf_start = 0, buf_count = 0 },
      want = {},
    },
  }

  for _, case in ipairs(cases) do
    H.eq(case.want, patch.apply_hunks(case.reference, case.buffer, { case.hunk }), case.name)
  end
end)

H.test("patch applies multiple hunks from bottom to top", function()
  package.loaded["pi.review.patch"] = nil
  local patch = require("pi.review.patch")
  local reference = { "old first", "remove", "keep", "old second", "tail" }
  local buffer = { "new first", "keep", "new second a", "new second b", "tail" }
  local hunks = {
    { type = "change", ref_start = 1, ref_count = 2, buf_start = 1, buf_count = 1 },
    { type = "change", ref_start = 4, ref_count = 1, buf_start = 3, buf_count = 2 },
  }

  H.eq({ "new first", "keep", "new second a", "new second b", "tail" }, patch.apply_hunks(reference, buffer, hunks))
end)

H.test("patch parses empty data and serializes final newlines exactly", function()
  package.loaded["pi.review.patch"] = nil
  local patch = require("pi.review.patch")

  H.eq({}, patch.data_to_lines(""))
  H.eq({ "" }, patch.data_to_lines("\n"))
  H.eq({ "alpha" }, patch.data_to_lines("alpha\n"))
  H.eq({ "alpha", "" }, patch.data_to_lines("alpha\n\n"))
  H.eq({ "alpha", "beta" }, patch.data_to_lines("alpha\nbeta"))

  H.eq("", patch.lines_to_data({}, false))
  H.eq("", patch.lines_to_data({}, true))
  H.eq("", patch.lines_to_data({ "" }, false))
  H.eq("\n", patch.lines_to_data({ "" }, true))
  H.eq("alpha", patch.lines_to_data({ "alpha" }, false))
  H.eq("alpha\n", patch.lines_to_data({ "alpha" }, true))
  H.eq("alpha\n\n", patch.lines_to_data({ "alpha", "" }, true))
end)
