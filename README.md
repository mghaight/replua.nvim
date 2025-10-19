# replua.nvim

An Emacs-style scratch buffer for executing Lua inside Neovim. `replua.nvim` opens a dedicated buffer where you can experiment with Lua, call any Neovim API, and see results printed inline -- much like the classic Emacs Lisp interaction mode.

## Features

- Opens a scratch buffer (`replua://scratch`) with Neovim APIs and the current global environment available.
- Evaluate the current line, visual selection, surrounding block, or the whole buffer.
- Captures both returned values and `print()` output, appending results as Lua comments.
- Keeps the cursor at a fresh spot for continued editing, just like pressing `C-j` in Emacs.
- Provides commands for opening the buffer, evaluating everything, and resetting the Lua environment.

## Installation

```lua
-- lazy.nvim example
{
  "mgh/replua.nvim",
  config = function()
    require("replua").setup()
  end,
}
```

If you prefer to manage configuration manually, require the plugin somewhere in your startup files:

```lua
require("replua").setup()
```

The bundled `plugin/replua.lua` file calls `setup()` on load, so the commands are available even without manual configuration.

## Usage

Open the scratch buffer with:

```
:RepluaOpen
```

The default keymaps inside the buffer mirror Emacs-style interactions:

| Mapping             | Mode | Action                                |
|---------------------|------|---------------------------------------|
| `<localleader>e`    | n    | Evaluate the current line             |
| `<localleader>e`    | v    | Evaluate the visual selection         |
| `<localleader><CR>` | n    | Evaluate the surrounding block        |
| `<localleader>r`    | n    | Evaluate the entire scratch buffer    |

Each evaluation appends comment lines such as `-- => result` or `-- print: output`, and drops you onto a new blank line ready for more Lua.

Additional commands:

- `:RepluaEval` &mdash; Evaluate the entire scratch buffer.
- `:RepluaReset` &mdash; Reset the Lua environment used for evaluation.

Because the environment proxies `_G`, anything you define becomes available to Neovim instantly. For example:

```lua
vim.api.nvim_set_option_value("number", true, { scope = "local", win = 0 })
-- => nil
```

## Configuration

Customize behaviour through `setup()`:

```lua
require("replua").setup({
  open_command = "botright 15split",
  keymaps = {
    eval_line = "<leader>rl",
    eval_visual = "<leader>rs",
    eval_block = nil, -- disable
    eval_buffer = "<leader>ra",
  },
  intro_lines = {
    "-- replua.nvim",
    "-- Custom scratch buffer - happy hacking!",
    "",
  },
  print_prefix = "-- -> ",
  result_prefix = "-- => ",
  newline_after_result = true,
  persist_env = true,
  diagnostics_disable = { "exp-in-action" },
})
```

Any option may be omitted to keep the defaults. Tables are merged, so redefining a single keymap leaves the others untouched.

`diagnostics_disable` injects a `---@diagnostic disable:` directive at the top of the scratch buffer. Keeping `{"exp-in-action"}` mirrors the default behaviour in many Lua LSPs by ignoring warnings about bare expressions while still reporting other issues. Set it to an empty table to keep every diagnostic.
