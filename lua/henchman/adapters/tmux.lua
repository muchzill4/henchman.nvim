local notify = require "henchman.notify"
local workspace = require "henchman.workspace"

---@alias HenchmanTmuxLaunchType 'window'|'pane'
---@alias HenchmanTmuxPaneDirection 'horizontal'|'vertical'

---@class HenchmanTmuxAdapterOpts
---@field command string[]
---@field launch_type? HenchmanTmuxLaunchType
---@field pane_direction? HenchmanTmuxPaneDirection
---@field initial_send_delay_ms? integer

---@class HenchmanTmuxAdapterConfig
---@field command string[]
---@field launch_type HenchmanTmuxLaunchType
---@field pane_direction HenchmanTmuxPaneDirection
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

local function system_ok(cmd, input)
  local output = vim.fn.system(cmd, input)
  return vim.v.shell_error == 0, output
end

local function tmux_cmd(args)
  local cmd = { "tmux" }
  vim.list_extend(cmd, args)
  return cmd
end

local function find_pane(current_workspace)
  local ok, output = system_ok(tmux_cmd {
    "list-panes",
    "-a",
    "-F",
    "#{pane_id}\t#{@henchman_workspace_id}\t#{@henchman_workspace_cwd}",
  })
  if not ok then
    return nil, output
  end

  for line in output:gmatch "[^\r\n]+" do
    local pane_id, workspace_id, workspace_cwd = line:match "^([^\t]+)\t([^\t]*)\t(.*)$"
    if
      pane_id
      and workspace_id == current_workspace.id
      and workspace_cwd == current_workspace.cwd
    then
      return pane_id
    end
  end
end

local function mark_henchman_pane(pane_id, current_workspace)
  local commands = {
    { "set-option", "-p", "-t", pane_id, "@henchman_workspace_id", current_workspace.id },
    { "set-option", "-p", "-t", pane_id, "@henchman_workspace_cwd", current_workspace.cwd },
    { "select-pane", "-t", pane_id, "-T", current_workspace.title },
  }

  for _, args in ipairs(commands) do
    local ok, output = system_ok(tmux_cmd(args))
    if not ok then
      return false, output
    end
  end

  return true
end

local function launch_pane(adapter_config, current_workspace, launch_opts)
  local args
  if adapter_config.launch_type == "window" then
    args = {
      "new-window",
      "-P",
      "-F",
      "#{pane_id}",
      "-n",
      current_workspace.title,
      "-c",
      current_workspace.cwd,
    }
  else
    args = {
      "split-window",
      "-P",
      "-F",
      "#{pane_id}",
      adapter_config.pane_direction == "vertical" and "-v" or "-h",
      "-c",
      current_workspace.cwd,
    }
  end

  if not launch_opts.focus then
    table.insert(args, 2, "-d")
  end

  table.insert(args, command_string(adapter_config.command))

  local ok, output = system_ok(tmux_cmd(args))
  if not ok then
    return nil, output
  end

  return vim.trim(output)
end

local function ensure_pane(adapter_config, launch_opts)
  launch_opts = launch_opts or {}
  local current_workspace = workspace.current()
  local pane_id, find_error = find_pane(current_workspace)
  if pane_id then
    return pane_id, false, current_workspace
  end

  if find_error then
    notify("Could not inspect tmux panes: " .. find_error, vim.log.levels.ERROR)
    return nil, false, current_workspace
  end

  local launch_error
  pane_id, launch_error = launch_pane(adapter_config, current_workspace, launch_opts)
  if not pane_id or pane_id == "" then
    notify("Could not open tmux henchman pane: " .. tostring(launch_error), vim.log.levels.ERROR)
    return nil, false, current_workspace
  end

  local marked, mark_error = mark_henchman_pane(pane_id, current_workspace)
  if not marked then
    notify("Could not mark tmux henchman pane: " .. mark_error, vim.log.levels.ERROR)
  end

  return pane_id, true, current_workspace
end

local function focus_pane(pane_id)
  local switched, switch_output = system_ok(tmux_cmd { "switch-client", "-t", pane_id })
  if not switched then
    return false, switch_output
  end

  return system_ok(tmux_cmd { "select-pane", "-t", pane_id })
end

local function open(adapter_config, open_opts)
  open_opts = open_opts or {}
  local pane_id = ensure_pane(adapter_config, open_opts)
  if not pane_id then
    return
  end

  if open_opts.focus ~= false then
    local focused, output = focus_pane(pane_id)
    if not focused then
      notify("Could not focus tmux henchman pane: " .. output, vim.log.levels.ERROR)
    end
  end
end

local function send(adapter_config, message, send_opts)
  send_opts = send_opts or {}
  -- Keep the current tmux pane focused until the deferred paste completes.
  local launch_opts = vim.tbl_extend("force", send_opts, { focus = false })
  local pane_id, opened = ensure_pane(adapter_config, launch_opts)
  if not pane_id then
    return
  end

  local function send_payload()
    local buffer_name = "henchman_" .. workspace.current().id
    local loaded, load_output = system_ok(
      tmux_cmd { "load-buffer", "-b", buffer_name, "-" },
      terminal_payload(message)
    )
    if not loaded then
      notify("Could not load tmux paste buffer: " .. load_output, vim.log.levels.ERROR)
      return
    end

    local pasted, paste_output = system_ok(tmux_cmd {
      "paste-buffer",
      "-d",
      "-b",
      buffer_name,
      "-t",
      pane_id,
    })
    if not pasted then
      notify("Could not send to tmux henchman pane: " .. paste_output, vim.log.levels.ERROR)
      return
    end

    if send_opts.focus then
      local focused, focus_output = focus_pane(pane_id)
      if not focused then
        notify("Could not focus tmux henchman pane: " .. focus_output, vim.log.levels.ERROR)
      end
    end
  end

  if opened then
    vim.defer_fn(send_payload, adapter_config.initial_send_delay_ms)
  else
    send_payload()
  end
end

---@param adapter_opts? HenchmanTmuxAdapterOpts
---@return HenchmanTmuxAdapterConfig
local function normalize_adapter_config(adapter_opts)
  adapter_opts = adapter_opts or {}
  if not adapter_opts.command then
    error("Missing tmux adapter command")
  end

  local adapter_config = {
    command = adapter_opts.command,
    launch_type = adapter_opts.launch_type or "window",
    pane_direction = adapter_opts.pane_direction or "horizontal",
    initial_send_delay_ms = adapter_opts.initial_send_delay_ms or 500,
  }

  if adapter_config.launch_type ~= "window" and adapter_config.launch_type ~= "pane" then
    error("Invalid tmux launch type: " .. tostring(adapter_opts.launch_type))
  end

  if adapter_opts.pane_direction and adapter_config.launch_type ~= "pane" then
    error("tmux pane_direction is only valid when launch_type is 'pane'")
  end

  if
    adapter_config.pane_direction ~= "horizontal"
    and adapter_config.pane_direction ~= "vertical"
  then
    error("Invalid tmux pane direction: " .. tostring(adapter_opts.pane_direction))
  end

  return adapter_config
end

---@param adapter_opts HenchmanTmuxAdapterOpts
---@return HenchmanAdapter
function M.new(adapter_opts)
  local adapter_config = normalize_adapter_config(adapter_opts)

  return {
    open = function(open_opts) return open(adapter_config, open_opts) end,
    send = function(message, send_opts) return send(adapter_config, message, send_opts) end,
  }
end

return M
