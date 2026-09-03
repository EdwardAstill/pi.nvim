local M = {}

function M.apply_hunks(reference_lines, buffer_lines, hunks)
  local result = vim.deepcopy(reference_lines)
  for hunk_index = #hunks, 1, -1 do
    local hunk = hunks[hunk_index]
    local start = hunk.ref_start + (hunk.ref_count == 0 and 1 or 0)
    for _ = 1, hunk.ref_count do
      table.remove(result, start)
    end
    for index = hunk.buf_count, 1, -1 do
      table.insert(result, start, buffer_lines[hunk.buf_start + index - 1])
    end
  end
  return result
end

function M.lines_to_data(lines, endofline)
  local data = table.concat(lines, "\n")
  if endofline and #lines > 0 then
    data = data .. "\n"
  end
  return data
end

function M.data_to_lines(data)
  if data == "" then
    return {}
  end
  local lines = vim.split(data, "\n", { plain = true })
  if data:sub(-1) == "\n" then
    table.remove(lines)
  end
  return lines
end

return M
