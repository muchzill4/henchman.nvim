local M = {}

local function display_path(path)
  if path == "" then
    return "[No file]"
  end
  return path
end

local function current_buffer_info()
  local path = vim.api.nvim_buf_get_name(0)
  local line = vim.api.nvim_win_get_cursor(0)[1]
  return {
    path = display_path(path),
    cursor_line = line,
    filetype = vim.bo.filetype,
  }
end

local function context_block(lines)
  table.insert(lines, 1, "<context>")
  table.insert(lines, "</context>")
  return table.concat(lines, "\n")
end

local function visual_positions()
  local mode = vim.fn.mode()
  if mode == "v" or mode == "V" or mode == "\22" then
    return mode, vim.fn.getpos "v", vim.fn.getpos "."
  end

  return vim.fn.visualmode(), vim.fn.getpos "'<", vim.fn.getpos "'>"
end

local function dedent(lines)
  local min_indent

  for _, line in ipairs(lines) do
    local indent = line:match "^(%s*)%S"
    if indent then
      min_indent = min_indent and math.min(min_indent, #indent) or #indent
    end
  end

  if not min_indent or min_indent == 0 then
    return lines
  end

  for i, line in ipairs(lines) do
    lines[i] = line:sub(min_indent + 1)
  end

  return lines
end

local function selection_info()
  local mode, start_pos, end_pos = visual_positions()
  local start_line, start_col = start_pos[2], start_pos[3]
  local end_line, end_col = end_pos[2], end_pos[3]

  if start_line > end_line or (start_line == end_line and start_col > end_col) then
    start_line, end_line = end_line, start_line
    start_col, end_col = end_col, start_col
  end

  local lines = vim.api.nvim_buf_get_lines(0, start_line - 1, end_line, false)
  if #lines == 0 then
    return { text = "" }
  end

  if mode ~= "V" then
    if #lines == 1 then
      lines[1] = string.sub(lines[1], start_col, end_col)
    else
      lines[1] = string.sub(lines[1], start_col)
      lines[#lines] = string.sub(lines[#lines], 1, end_col)
    end
  end

  return {
    text = table.concat(dedent(lines), "\n"),
    start_line = start_line,
    end_line = end_line,
    mode = mode,
  }
end

function M.current_file()
  local buffer = current_buffer_info()
  return context_block { string.format("File: %s:%d", buffer.path, buffer.cursor_line) }
end

function M.selection()
  local selection = selection_info()
  if selection.text == "" then
    return ""
  end

  local buffer = current_buffer_info()
  local language = buffer.filetype ~= "" and buffer.filetype or "text"
  return context_block {
    string.format("File: %s:%d-%d", buffer.path, selection.start_line, selection.end_line),
    "",
    string.format("```%s", language),
    selection.text,
    "```",
  }
end

return M
