# 🕴️ henchman.nvim

An extension for neovim that lets you delegate code context to terminal-based coding agents.

Useful when you want to stay in vim, grab the current file or visual selection, and ship it to a nearby agent prompt without copy/paste gymnastics.

## Setup

### Install

```lua
vim.pack.add {
  "https://github.com/muchzill4/henchman.nvim",
}
```

### Configure

```lua
local henchman = require "henchman"

local client = henchman.new {
  adapter = henchman.adapter.neovim {
    command = { "pi" },
    launch_type = "window",
    initial_send_delay_ms = 1500,
  },
}

vim.keymap.set("n", "<leader>A", function() client.open { focus = true } end)
vim.keymap.set("n", "<leader>a", function() client.send { focus = true, compose = true } end)
vim.keymap.set("v", "<leader>a", function() client.send_selection { focus = true, compose = true } end)
```

## API

```lua
client.open()
client.send()
client.send "explain the code around my cursor"
client.send_selection "refactor this"
```

## Compose

Compose opens a temporary markdown buffer before sending the prompt.

```lua
client.send { compose = true }
client.send_selection { compose = true }
```

Write the compose buffer to submit it:

```vim
:wq
```

## Focus

Pass `focus = true` when you want henchman to jump to the agent after opening or sending.

```lua
client.open { focus = true }
client.send { focus = true }
client.send_selection { focus = true }
```

## Adapters

### Kitty

Uses kitty remote control to find or create a dedicated agent window for the current workspace.

```lua
local client = require("henchman").new {
  adapter = require("henchman").adapter.kitty {
    command = { vim.env.SHELL, "-c", "pi" },
    launch_type = "window", -- window | tab | os-window
  },
}
```

### Neovim terminal

Uses a neovim terminal split as the agent window.

```lua
local client = require("henchman").new {
  adapter = require("henchman").adapter.neovim {
    command = { "pi" },
  },
}
```
