local notify = require "henchman.notify"
local workspace = require "henchman.workspace"

---@alias HenchmanKittyLaunchType 'window'|'tab'|'os-window'

---@class HenchmanKittyAdapterOpts
---@field command string[]
---@field launch_type? HenchmanKittyLaunchType
---@field initial_send_delay_ms? integer

---@class HenchmanKittyAdapterConfig
---@field command string[]
---@field launch_type HenchmanKittyLaunchType
---@field initial_send_delay_ms integer

local M = {}

local function terminal_payload(message)
  -- Bracketed paste keeps multi-line prompts together in the henchman terminal editor.
  return "\027[200~" .. message .. "\027[201~\r"
end

local function system_ok(cmd, input)
  local output = vim.fn.system(cmd, input)
  return vim.v.shell_error == 0, output
end

local function kitty_cmd(args)
  local cmd = { "kitty", "@" }
  vim.list_extend(cmd, args)
  return cmd
end

local function walk_windows(callback)
  local ok, output = system_ok(kitty_cmd { "ls" })
  if not ok then
    return nil, output
  end

  local decoded = vim.json.decode(output)
  for _, os_window in ipairs(decoded or {}) do
    for _, tab in ipairs(os_window.tabs or {}) do
      for _, window in ipairs(tab.windows or {}) do
        local result = callback(window)
        if result ~= nil then
          return result
        end
      end
    end
  end
end

local function find_window(current_workspace)
  return walk_windows(function(window)
    local vars = window.user_vars or window.vars or {}
    if
      vars.henchman_workspace_id == current_workspace.id
      and vars.henchman_workspace_cwd == current_workspace.cwd
    then
      return window
    end
  end)
end

local function ensure_window(adapter_config, launch_opts)
  launch_opts = launch_opts or {}
  local current_workspace = workspace.current()
  local window = find_window(current_workspace)
  if window then
    return window.id, false, current_workspace
  end

  local launch_args = {
    "launch",
    "--type=" .. adapter_config.launch_type,
  }
  if not launch_opts.focus then
    table.insert(launch_args, "--keep-focus")
  end
  vim.list_extend(launch_args, {
    "--title",
    current_workspace.title,
    "--var",
    "henchman_workspace_id=" .. current_workspace.id,
    "--var",
    "henchman_workspace_cwd=" .. current_workspace.cwd,
    "--cwd",
    current_workspace.cwd,
  })
  vim.list_extend(launch_args, adapter_config.command)

  local ok, output = system_ok(kitty_cmd(launch_args))
  if not ok then
    notify("Could not open kitty henchman window: " .. output, vim.log.levels.ERROR)
    return nil, false, current_workspace
  end

  return tonumber(vim.trim(output)), true, current_workspace
end

local function focus_window(id)
  return system_ok(kitty_cmd { "focus-window", "--match", "id:" .. id })
end

local function open(adapter_config, open_opts)
  open_opts = open_opts or {}
  local id = ensure_window(adapter_config, open_opts)
  if not id then
    return
  end

  if open_opts.focus ~= false then
    local focused, focus_output = focus_window(id)
    if not focused then
      notify("Could not focus kitty henchman window: " .. focus_output, vim.log.levels.ERROR)
    end
  end
end

local function send(adapter_config, message, send_opts)
  send_opts = send_opts or {}
  -- When sending to a newly launched kitty window, keep Neovim focused until
  -- after send-text runs. Otherwise kitty can steal focus before the deferred
  -- paste, which is especially noticeable from visual-mode mappings.
  local launch_opts = vim.tbl_extend("force", send_opts, { focus = false })
  local id, opened = ensure_window(adapter_config, launch_opts)
  if not id then
    return
  end

  local function send_payload()
    local sent, output = system_ok(
      kitty_cmd { "send-text", "--match", "id:" .. id, "--stdin" },
      terminal_payload(message)
    )
    if not sent then
      notify("Could not send to kitty henchman window: " .. output, vim.log.levels.ERROR)
      return
    end

    if send_opts.focus then
      local focused, focus_output = focus_window(id)
      if not focused then
        notify("Could not focus kitty henchman window: " .. focus_output, vim.log.levels.ERROR)
      end
    end
  end

  if opened then
    vim.defer_fn(send_payload, adapter_config.initial_send_delay_ms)
  else
    send_payload()
  end
end

---@param adapter_opts? HenchmanKittyAdapterOpts
---@return HenchmanKittyAdapterConfig
local function normalize_adapter_config(adapter_opts)
  adapter_opts = adapter_opts or {}
  if not adapter_opts.command then
    error("Missing kitty adapter command")
  end

  local adapter_config = {
    command = adapter_opts.command,
    launch_type = adapter_opts.launch_type or "window",
    initial_send_delay_ms = adapter_opts.initial_send_delay_ms or 500,
  }
  if
    adapter_config.launch_type ~= "window"
    and adapter_config.launch_type ~= "tab"
    and adapter_config.launch_type ~= "os-window"
  then
    error("Invalid kitty launch type: " .. tostring(adapter_opts.launch_type))
  end

  return adapter_config
end

---@param adapter_opts HenchmanKittyAdapterOpts
---@return HenchmanAdapter
function M.new(adapter_opts)
  local adapter_config = normalize_adapter_config(adapter_opts)

  return {
    open = function(open_opts) return open(adapter_config, open_opts) end,
    send = function(message, send_opts) return send(adapter_config, message, send_opts) end,
  }
end

return M
