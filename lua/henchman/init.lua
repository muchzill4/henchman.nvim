local context = require "henchman.context"
local notify = require "henchman.notify"
local prompt_buffer = require "henchman.prompt_buffer"

---@class HenchmanSendOpts
---@field focus? boolean
---@field compose? boolean

---@class HenchmanAdapterOpts
---@field focus? boolean

---@class HenchmanAdapter
---@field send fun(message: string, opts?: HenchmanAdapterOpts): any
---@field open fun(opts?: HenchmanAdapterOpts): any

---@class HenchmanConfig
---@field adapter HenchmanAdapter
---@field prompt_buffer? HenchmanPromptBufferOpts

---@class HenchmanInstance
---@field open fun(opts?: HenchmanAdapterOpts): any
---@field send fun(instruction_or_opts?: string|HenchmanSendOpts, send_opts?: HenchmanSendOpts): any
---@field send_selection fun(instruction_or_opts?: string|HenchmanSendOpts, send_opts?: HenchmanSendOpts): any

---@class HenchmanAdapterConstructors
---@field neovim fun(adapter_opts: HenchmanNeovimAdapterOpts): HenchmanAdapter
---@field kitty fun(adapter_opts: HenchmanKittyAdapterOpts): HenchmanAdapter
---@field tmux fun(adapter_opts: HenchmanTmuxAdapterOpts): HenchmanAdapter

local M = {}

---@type HenchmanAdapterConstructors
M.adapter = {
  neovim = require("henchman.adapters.neovim").new,
  kitty = require("henchman.adapters.kitty").new,
  tmux = require("henchman.adapters.tmux").new,
}

---@param context_text string
---@param instruction? string
---@return string
local function with_instruction(context_text, instruction)
  context_text = context_text:gsub("\n*$", "")

  if not instruction or instruction == "" then
    return context_text .. "\n\n"
  end

  return context_text .. "\n\n" .. instruction
end

---@param instruction_or_opts? string|HenchmanSendOpts
---@param send_opts? HenchmanSendOpts
---@return string? instruction
---@return HenchmanSendOpts? send_opts
local function normalize_send_args(instruction_or_opts, send_opts)
  if type(instruction_or_opts) == "table" then
    return nil, instruction_or_opts
  end

  return instruction_or_opts, send_opts
end

---@param send_opts? HenchmanSendOpts
---@return HenchmanAdapterOpts
local function normalize_send_opts(send_opts)
  local result = vim.tbl_deep_extend("force", {}, send_opts or {})
  result.compose = nil
  return result
end

---@param henchman_config HenchmanConfig
---@return HenchmanInstance
function M.new(henchman_config)
  henchman_config = henchman_config or {}

  local adapter = henchman_config.adapter
  if not adapter then
    error("Missing henchman adapter")
  end

  local function send_payload(payload, send_opts)
    if send_opts and send_opts.compose then
      return prompt_buffer.open {
        message = payload,
        prompt_buffer = henchman_config.prompt_buffer,
        on_submit = function(edited_payload)
          adapter.send(edited_payload, normalize_send_opts(send_opts))
        end,
      }
    end

    return adapter.send(payload, normalize_send_opts(send_opts))
  end

  return {
    open = function(open_opts)
      return adapter.open(open_opts)
    end,
    send = function(instruction_or_opts, send_opts)
      local instruction, opts = normalize_send_args(instruction_or_opts, send_opts)
      return send_payload(with_instruction(context.current_file(), instruction), opts)
    end,
    send_selection = function(instruction_or_opts, send_opts)
      local instruction, opts = normalize_send_args(instruction_or_opts, send_opts)
      local context_text = context.selection()
      if context_text == "" then
        notify("No visual selection", vim.log.levels.WARN)
        return
      end

      return send_payload(with_instruction(context_text, instruction), opts)
    end,
  }
end

return M
