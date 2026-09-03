---@class HenchmanPromptBufferOpts
---@field split? string

---@class HenchmanPromptBufferConfig
---@field split string

local M = {}

local defaults = {
  split = "botright split",
}

local prompt_buffer_name = "henchman://prompt"
local current_bufnr

local function trim_trailing_blank_lines(lines)
  local last = #lines
  while last > 0 and lines[last] == "" do
    last = last - 1
  end
  return vim.list_slice(lines, 1, last)
end

local function message_from_buffer(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  lines = trim_trailing_blank_lines(lines)
  return table.concat(lines, "\n")
end

local function current_buffer()
  if current_bufnr and vim.api.nvim_buf_is_valid(current_bufnr) then
    return current_bufnr
  end

  current_bufnr = nil
  return nil
end

local function focus_buffer(bufnr, split)
  local winid = vim.fn.bufwinid(bufnr)
  if winid ~= -1 then
    vim.api.nvim_set_current_win(winid)
  else
    vim.cmd(split)
    vim.api.nvim_win_set_buf(0, bufnr)
  end
end

local function create_buffer(split, on_submit)
  vim.cmd(split)

  local bufnr = vim.api.nvim_create_buf(false, true)
  current_bufnr = bufnr
  vim.api.nvim_win_set_buf(0, bufnr)

  vim.api.nvim_buf_set_name(bufnr, prompt_buffer_name)
  vim.bo[bufnr].buftype = "acwrite"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].filetype = "markdown"
  vim.bo[bufnr].swapfile = false
  vim.b[bufnr].henchman_on_submit = on_submit

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = bufnr,
    callback = function()
      if current_bufnr == bufnr then
        current_bufnr = nil
      end
    end,
  })

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = bufnr,
    callback = function()
      local message = message_from_buffer(bufnr)
      local submit = vim.b[bufnr].henchman_on_submit
      vim.bo[bufnr].modified = false

      vim.schedule(function()
        submit(message)

        if vim.api.nvim_buf_is_valid(bufnr) then
          vim.api.nvim_buf_delete(bufnr, { force = true })
        end
      end)
    end,
  })

  return bufnr
end

local function focus_or_create_buffer(split, on_submit)
  local bufnr = current_buffer()
  if bufnr then
    vim.b[bufnr].henchman_on_submit = on_submit
    focus_buffer(bufnr, split)
    return { bufnr = bufnr, is_new = false }
  end

  bufnr = create_buffer(split, on_submit)
  return { bufnr = bufnr, is_new = true }
end

local function initial_lines(message)
  if not message or message == "" then
    return { "" }
  end
  return vim.split(message, "\n", { plain = true })
end

---@param prompt_buffer_opts? HenchmanPromptBufferOpts
---@return HenchmanPromptBufferConfig
local function normalize_prompt_buffer_config(prompt_buffer_opts)
  return vim.tbl_deep_extend("force", {}, defaults, prompt_buffer_opts or {})
end

---@class HenchmanPromptBufferOpenArgs
---@field message string
---@field prompt_buffer? HenchmanPromptBufferOpts
---@field on_submit fun(message: string)

---@param args HenchmanPromptBufferOpenArgs
---@return integer bufnr
function M.open(args)
  args = args or {}
  if args.message == nil then
    error "Missing prompt buffer message"
  end
  if not args.on_submit then
    error "Missing prompt buffer on_submit callback"
  end

  local prompt_buffer_config = normalize_prompt_buffer_config(args.prompt_buffer)

  local buffer = focus_or_create_buffer(prompt_buffer_config.split, args.on_submit)
  local bufnr = buffer.bufnr

  local message = args.message
  if not buffer.is_new then
    local previous_message = message_from_buffer(bufnr)
    if previous_message ~= "" then
      message = previous_message .. "\n\n" .. message
    end
  end

  local lines = initial_lines(message)
  local last_line = lines[#lines] or ""
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_win_set_cursor(0, { #lines, #last_line })
  vim.cmd "startinsert"

  return bufnr
end

return M
