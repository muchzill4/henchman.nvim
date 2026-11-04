local notify = require "henchman.notify"
local workspace = require "henchman.workspace"

---@alias HenchmanRexLaunchType 'split'|'window'
---@alias HenchmanRexSplitDirection 'right'|'left'|'above'|'below'

---@class HenchmanRexAdapterOpts
---@field command string[]
---@field launch_type? HenchmanRexLaunchType
---@field split_direction? HenchmanRexSplitDirection
---@field initial_send_delay_ms? integer

---@class HenchmanRexAdapterConfig
---@field command string[]
---@field launch_type HenchmanRexLaunchType
---@field split_direction HenchmanRexSplitDirection
---@field initial_send_delay_ms integer
---@field session string

local M = {}

local function terminal_payload(message)
  return "\027[200~" .. message .. "\027[201~\r"
end

local function system_ok(cmd, input)
  local output = vim.fn.system(cmd, input)
  return vim.v.shell_error == 0, output
end

local function rex_cmd(session, args)
  local cmd = { "rex", "-s", session }
  vim.list_extend(cmd, args)
  return cmd
end

local function find_block(adapter_config, current_workspace)
  local ok, output = system_ok(rex_cmd(adapter_config.session, { "block", "list", "--json" }))
  if not ok then
    return nil, output
  end

  local decoded = vim.json.decode(output)
  for _, block in ipairs(decoded.blocks or {}) do
    if block.label == current_workspace.title then
      return block.block_id
    end
  end
end

local function launch_block(adapter_config, current_workspace, launch_opts)
  local args
  if adapter_config.launch_type == "window" then
    args = { "run" }
  else
    args = { "split", "--split=" .. adapter_config.split_direction }
  end

  vim.list_extend(args, {
    "--label",
    current_workspace.title,
    "-c",
    current_workspace.cwd,
    "--json",
  })

  if not launch_opts.focus then
    table.insert(args, "--focus=false")
  end

  table.insert(args, "--")
  vim.list_extend(args, adapter_config.command)

  local ok, output = system_ok(rex_cmd(adapter_config.session, args))
  if not ok then
    return nil, output
  end

  local decoded = vim.json.decode(output)
  if decoded and decoded.block_ids and decoded.block_ids[1] then
    return decoded.block_ids[1]
  end

  return nil, "no block_id in response"
end

local function ensure_block(adapter_config, launch_opts)
  launch_opts = launch_opts or {}
  local current_workspace = workspace.current()
  local block_id, find_error = find_block(adapter_config, current_workspace)
  if block_id then
    return block_id, false
  end

  if find_error then
    notify("Could not inspect rex blocks: " .. find_error, vim.log.levels.ERROR)
    return nil, false
  end

  local launch_error
  block_id, launch_error = launch_block(adapter_config, current_workspace, launch_opts)
  if not block_id then
    notify("Could not open rex henchman block: " .. tostring(launch_error), vim.log.levels.ERROR)
    return nil, false
  end

  return block_id, true
end

local function focus_block(adapter_config, block_id)
  return system_ok(rex_cmd(adapter_config.session, { "block", "focus", block_id }))
end

local function open(adapter_config, open_opts)
  open_opts = open_opts or {}
  local block_id = ensure_block(adapter_config, open_opts)
  if not block_id then
    return
  end

  if open_opts.focus ~= false then
    local focused, output = focus_block(adapter_config, block_id)
    if not focused then
      notify("Could not focus rex henchman block: " .. output, vim.log.levels.ERROR)
    end
  end
end

local function send(adapter_config, message, send_opts)
  send_opts = send_opts or {}
  local launch_opts = vim.tbl_extend("force", send_opts, { focus = false })
  local block_id, opened = ensure_block(adapter_config, launch_opts)
  if not block_id then
    return
  end

  local function send_payload()
    local sent, output = system_ok(
      rex_cmd(adapter_config.session, { "send", "-b", block_id }),
      terminal_payload(message)
    )
    if not sent then
      notify("Could not send to rex henchman block: " .. output, vim.log.levels.ERROR)
      return
    end

    if send_opts.focus then
      local focused, focus_output = focus_block(adapter_config, block_id)
      if not focused then
        notify("Could not focus rex henchman block: " .. focus_output, vim.log.levels.ERROR)
      end
    end
  end

  if opened then
    vim.defer_fn(send_payload, adapter_config.initial_send_delay_ms)
  else
    send_payload()
  end
end

---@param adapter_opts? HenchmanRexAdapterOpts
---@return HenchmanRexAdapterConfig
local function normalize_adapter_config(adapter_opts)
  adapter_opts = adapter_opts or {}
  if not adapter_opts.command then
    error("Missing rex adapter command")
  end

  local session = vim.env.REX_SESSION
  if not session then
    error("REX_SESSION is not set")
  end

  local adapter_config = {
    command = adapter_opts.command,
    launch_type = adapter_opts.launch_type or "split",
    split_direction = adapter_opts.split_direction or "right",
    initial_send_delay_ms = adapter_opts.initial_send_delay_ms or 500,
    session = session,
  }

  if adapter_config.launch_type ~= "split" and adapter_config.launch_type ~= "window" then
    error("Invalid rex launch type: " .. tostring(adapter_opts.launch_type))
  end

  if adapter_opts.split_direction and adapter_config.launch_type ~= "split" then
    error("rex split_direction is only valid when launch_type is 'split'")
  end

  local valid_directions = { right = true, left = true, above = true, below = true }
  if not valid_directions[adapter_config.split_direction] then
    error("Invalid rex split direction: " .. tostring(adapter_opts.split_direction))
  end

  return adapter_config
end

---@param adapter_opts HenchmanRexAdapterOpts
---@return HenchmanAdapter
function M.new(adapter_opts)
  local adapter_config = normalize_adapter_config(adapter_opts)

  return {
    open = function(open_opts) return open(adapter_config, open_opts) end,
    send = function(message, send_opts) return send(adapter_config, message, send_opts) end,
  }
end

return M
