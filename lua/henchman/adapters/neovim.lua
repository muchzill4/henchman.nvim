local notify = require "henchman.notify"
local workspace = require "henchman.workspace"

---@class HenchmanNeovimAdapterOpts
---@field command string[]
---@field initial_send_delay_ms? integer

---@class HenchmanNeovimAdapterConfig
---@field command string[]
---@field initial_send_delay_ms integer

local M = {}

local function terminal_payload(message)
  -- Bracketed paste keeps multi-line prompts together in the henchman terminal editor.
  return "\027[200~" .. message .. "\027[201~\r"
end

local function command_string(command)
  local parts = vim.tbl_map(vim.fn.shellescape, command)
  return table.concat(parts, " ")
end

local function valid_terminal(bufnr)
  return bufnr and vim.api.nvim_buf_is_valid(bufnr) and vim.b[bufnr].terminal_job_id ~= nil
end

local function mark_henchman_terminal(bufnr, current_workspace)
  vim.b[bufnr].henchman_terminal = true
  vim.b[bufnr].henchman_workspace_id = current_workspace.id
  vim.b[bufnr].henchman_workspace_cwd = current_workspace.cwd
end

local function open_terminal(adapter_config, current_workspace)
  vim.cmd "botright vertical split"
  vim.cmd.terminal(command_string(adapter_config.command))
  local bufnr = vim.api.nvim_get_current_buf()
  mark_henchman_terminal(bufnr, current_workspace)
  return bufnr
end

local function terminal_name_matches_command(bufnr, command)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if not name:match "term://" then
    return false
  end

  local terminal_command = name:match ":([^:]*)$"
  if not terminal_command then
    return false
  end

  return vim.trim(terminal_command) == command_string(command)
end

local function find_henchman_terminal(adapter_config, current_workspace)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if
      valid_terminal(bufnr)
      and vim.b[bufnr].henchman_terminal
      and vim.b[bufnr].henchman_workspace_id == current_workspace.id
      and vim.b[bufnr].henchman_workspace_cwd == current_workspace.cwd
      and terminal_name_matches_command(bufnr, adapter_config.command)
    then
      return bufnr
    end
  end
end

local function ensure_terminal(adapter_config, current_workspace)
  local bufnr = find_henchman_terminal(adapter_config, current_workspace)
  if bufnr then
    return bufnr, false
  end

  bufnr = open_terminal(adapter_config, current_workspace)
  if valid_terminal(bufnr) then
    return bufnr, true
  end
end

local function focus_terminal(bufnr)
  for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(tabpage)) do
      if vim.api.nvim_win_get_buf(winid) == bufnr then
        vim.api.nvim_set_current_tabpage(tabpage)
        vim.api.nvim_set_current_win(winid)
        return
      end
    end
  end

  vim.cmd "botright vertical split"
  vim.api.nvim_win_set_buf(0, bufnr)
end

function M.open(adapter_config, open_opts)
  open_opts = open_opts or {}
  local previous_win = vim.api.nvim_get_current_win()
  local current_workspace = workspace.current()
  local bufnr, opened = ensure_terminal(adapter_config, current_workspace)
  if not bufnr then
    notify("Could not open Neovim henchman terminal", vim.log.levels.ERROR)
    return
  end

  if open_opts.focus == false and opened and vim.api.nvim_win_is_valid(previous_win) then
    vim.api.nvim_set_current_win(previous_win)
    return
  end

  if open_opts.focus ~= false then
    focus_terminal(bufnr)
  end
end

function M.send(adapter_config, message, send_opts)
  send_opts = send_opts or {}
  local previous_win = vim.api.nvim_get_current_win()
  local current_workspace = workspace.current()
  local bufnr, opened = ensure_terminal(adapter_config, current_workspace)
  if not bufnr then
    notify("Could not open Neovim henchman terminal", vim.log.levels.ERROR)
    return
  end

  if not send_opts.focus and opened and vim.api.nvim_win_is_valid(previous_win) then
    vim.api.nvim_set_current_win(previous_win)
  end

  local function send_payload()
    if valid_terminal(bufnr) then
      vim.api.nvim_chan_send(
        vim.b[bufnr].terminal_job_id,
        terminal_payload(message)
      )
      if send_opts.focus then
        focus_terminal(bufnr)
      end
    end
  end

  if opened then
    vim.defer_fn(send_payload, adapter_config.initial_send_delay_ms)
  else
    send_payload()
  end
end

---@param adapter_opts HenchmanNeovimAdapterOpts
---@return HenchmanAdapter
function M.new(adapter_opts)
  adapter_opts = adapter_opts or {}
  if not adapter_opts.command then
    error("Missing Neovim adapter command")
  end

  local adapter_config = {
    command = adapter_opts.command,
    initial_send_delay_ms = adapter_opts.initial_send_delay_ms or 100,
  }
  return {
    open = function(open_opts) return M.open(adapter_config, open_opts) end,
    send = function(message, send_opts) return M.send(adapter_config, message, send_opts) end,
  }
end

return M
