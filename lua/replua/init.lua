local M = {}

--[[ 
replua.nvim provides an interactive Lua scratch buffer. This module manages
buffer lifecycle, evaluation environment isolation, and result rendering so
that users can iteratively experiment with Neovim APIs without polluting their
editing session. The code is intentionally verbose to keep the control flow
obvious for future maintenance.
]]

-- Default configuration describing how the scratch buffer is created and how
-- evaluation output should be formatted. Users may override any option from
-- Lua by calling `require("replua").setup({ ... })`.
local defaults = {
  open_command = "enew",
  intro_lines = {
    "-- Scratch buffer for Lua evaluation",
    "",
  },
  keymaps = {
    eval_line = "<localleader>e",
    eval_block = "<localleader><CR>",
    eval_buffer = "<localleader>r",
  },
  print_prefix = "-- print: ",
  result_prefix = "-- => ",
  result_continuation_prefix = "--    ",
  error_prefix = "-- Error: ",
  show_nil_results = true,
  newline_after_result = true,
  persist_env = true,
}

-- Runtime configuration, cloned from the defaults and extended via `setup()`.
local config = vim.deepcopy(defaults)

-- Tracks all live scratch buffers and their evaluation environments. Multiple
-- buffers can exist simultaneously, so each buffer id maps to its own state.
local state = {
  buf = nil,
  buffers = {},
  env_by_buf = {},
  commands_created = false,
  counter = 0,
}

local pick_active_buffer

-- Keyword set used when validating identifiers during assignment rewriting.
local lua_keywords = {
  ["and"] = true,
  ["break"] = true,
  ["do"] = true,
  ["else"] = true,
  ["elseif"] = true,
  ["end"] = true,
  ["false"] = true,
  ["for"] = true,
  ["function"] = true,
  ["goto"] = true,
  ["if"] = true,
  ["in"] = true,
  ["local"] = true,
  ["nil"] = true,
  ["not"] = true,
  ["or"] = true,
  ["repeat"] = true,
  ["return"] = true,
  ["then"] = true,
  ["true"] = true,
  ["until"] = true,
  ["while"] = true,
}

-- Merge user supplied options into the active configuration.
local function extend_config(opts)
  if not opts then
    return
  end
  config = vim.tbl_deep_extend("force", vim.deepcopy(config), opts)
end

-- Lazily create user commands. We guard on `commands_created` so repeated calls
-- (e.g. when the module reloads) do not register duplicates.
local function ensure_commands()
  if state.commands_created or not vim.api.nvim_create_user_command then
    return
  end

  vim.api.nvim_create_user_command("RepluaOpen", function(opts)
    M.open({ force_new = opts.bang })
  end, { desc = "Open the replua.nvim scratch buffer", bang = true })

  vim.api.nvim_create_user_command("RepluaEval", function()
    M.eval_current_buffer()
  end, { desc = "Evaluate the entire replua.nvim scratch buffer" })

  vim.api.nvim_create_user_command("RepluaReset", function()
    M.reset_environment()
  end, { desc = "Reset the replua.nvim Lua environment" })

  state.commands_created = true
end

-- Create or reuse the sandboxed environment for a given scratch buffer. The
-- environment proxies `_G` for reads but writes stay scoped to the buffer so
-- separate repl instances cannot stomp on each other.
local function build_env(bufnr)
  local existing = state.env_by_buf[bufnr]
  if existing then
    existing._ENV = existing
    return existing
  end

  local env = {}
  setmetatable(env, {
    __index = function(_, key)
      return rawget(_G, key)
    end,
    __newindex = function(_, key, value)
      rawset(env, key, value)
    end,
  })
  env._ENV = env

  state.env_by_buf[bufnr] = env
  return env
end

-- Replace `print` inside the evaluation environment with a collector so we can
-- render `print()` output alongside returned values. The wrapper returns a
-- cleanup function that restores the original behaviour.
local function capture_print(env)
  local prints = {}
  rawset(env, "print", function(...)
    local pieces = {}
    for i = 1, select("#", ...) do
      local value = select(i, ...)
      pieces[i] = tostring(value)
    end
    table.insert(prints, table.concat(pieces, "\t"))
  end)

  return function()
    rawset(env, "print", nil)
    return prints
  end
end

-- Normalise multiline text into comment-prefixed lines that we can insert into
-- the scratch buffer. Evaluation output is always written through this helper.
local function extend_with_prefix(target, prefix, text)
  local lines = vim.split(tostring(text), "\n", { plain = true })
  for _, chunk in ipairs(lines) do
    table.insert(target, prefix .. chunk)
  end
end

-- Bundle return values and captured prints into a single list of comment lines.
local function render_result_lines(results, prints)
  local lines = {}

  for _, line in ipairs(prints) do
    extend_with_prefix(lines, config.print_prefix, line)
  end

  if #results > 0 then
    for index, value in ipairs(results) do
      local prefix = index == 1 and config.result_prefix or config.result_continuation_prefix
      extend_with_prefix(lines, prefix, vim.inspect(value))
    end
  elseif config.show_nil_results and #prints == 0 then
    table.insert(lines, config.result_prefix .. "nil")
  end

  return lines
end

-- Convert an error into a list of diagnostic comment lines.
local function render_error_lines(err)
  local lines = {}
  extend_with_prefix(lines, config.error_prefix, err)
  return lines
end

-- Utility helpers for detecting previously inserted result blocks so they can
-- be replaced on re-evaluation.
local function starts_with(str, prefix)
  if not str or not prefix or prefix == "" then
    return false
  end
  return str:sub(1, #prefix) == prefix
end

local function is_result_line(line)
  return starts_with(line, config.print_prefix)
    or starts_with(line, config.result_prefix)
    or starts_with(line, config.result_continuation_prefix)
    or starts_with(line, config.error_prefix)
end

-- Remove the prior output block (if any) that follows the evaluated range.
-- This keeps the scratch buffer tidy when lines or blocks are re-run.
local function remove_existing_result(bufnr, start_line, end_line)
  local first = end_line + 1
  local total = vim.api.nvim_buf_line_count(bufnr)
  if first >= total then
    return
  end

  local last = first
  local found = false

  while last < total do
    local text = vim.api.nvim_buf_get_lines(bufnr, last, last + 1, false)[1]
    if not text or text == "" then
      if found and text == "" then
        last = last + 1
      end
      break
    end
    if is_result_line(text) then
      found = true
      last = last + 1
    else
      break
    end
  end

  if not found then
    if config.newline_after_result then
      local text = vim.api.nvim_buf_get_lines(bufnr, first, first + 1, false)[1]
      if text == "" then
        vim.api.nvim_buf_set_lines(bufnr, first, first + 1, false, {})
      end
    end
    return
  end

  vim.api.nvim_buf_set_lines(bufnr, first, last, false, {})
end

-- Identifier validation used when rewriting assignments. We only rewrite
-- simple comma-separated names to avoid surprising behaviour.
local function is_identifier(name)
  if not name or name == "" then
    return false
  end
  if lua_keywords[name] then
    return false
  end
  return name:match("^[%a_][%w_]*$") ~= nil
end

local function split_identifiers(text)
  local names = {}
  for part in text:gmatch("[^,%s]+") do
    if not is_identifier(part) then
      return nil
    end
    table.insert(names, part)
  end
  if #names == 0 then
    return nil
  end
  return names
end

-- Mirror assigned locals into `_ENV` so subsequent snippets can observe them.
-- We also return the values to emulate traditional REPL feedback.
local function append_env_updates(lines, names)
  for _, name in ipairs(names) do
    table.insert(lines, string.format("_ENV[%q] = %s", name, name))
  end
  table.insert(lines, "return " .. table.concat(names, ", "))
end

-- Try to rewrite assignments so that top-level locals persist across
-- evaluations and display their values automatically. Complex statements we do
-- not recognise fall through unchanged.
local function transform_assignment(code)
  local trimmed = vim.trim(code)
  if trimmed == "" then
    return code
  end

  local function rhs_starts_with_equals(rhs)
    if not rhs then
      return false
    end
    return rhs:match("^%s*=") ~= nil
  end

  local function build_lines(base, names)
    local lines = { base }
    append_env_updates(lines, names)
    return table.concat(lines, "\n")
  end

  local func_name = trimmed:match("^local%s+function%s+([%a_][%w_]*)%s*%(")
  if func_name then
    local lines = { code }
    append_env_updates(lines, { func_name })
    return table.concat(lines, "\n")
  end

  local local_names, local_rhs = trimmed:match("^local%s+([%a_][%w_%s,]*)%s*=%s*(.+)$")
  if local_names and not rhs_starts_with_equals(local_rhs) then
    local names = split_identifiers(local_names)
    if names then
      return build_lines(code, names)
    end
  end

  local local_only = trimmed:match("^local%s+([%a_][%w_%s,]*)%s*$")
  if local_only then
    local names = split_identifiers(local_only)
    if names then
      return build_lines(code, names)
    end
  end

  local global_names, global_rhs = trimmed:match("^([%a_][%w_%s,]*)%s*=%s*(.+)$")
  if global_names and not rhs_starts_with_equals(global_rhs) then
    local names = split_identifiers(global_names)
    if names then
      return build_lines(code, names)
    end
  end

  return code
end

-- Compile and execute the snippet associated with a buffer. We first attempt
-- to wrap the code in `return` so standalone expressions produce values; if
-- compilation fails we retry with the raw text (after possible assignment
-- rewriting).
local function eval(bufnr, code)
  local env = build_env(bufnr)
  local chunk, err = load("return " .. code, "replua", "t", env)
  if not chunk then
    code = transform_assignment(code)
    chunk, err = load(code, "replua", "t", env)
  end
  if not chunk then
    return false, render_error_lines(err)
  end

  local release_print = capture_print(env)
  local packed = { pcall(chunk) }
  local prints = release_print()

  local ok = table.remove(packed, 1)
  if not ok then
    local message = packed[1]
    return false, render_error_lines(message)
  end

  return true, render_result_lines(packed, prints)
end

-- Insert the rendered result block immediately after the evaluated range.
-- Returns the number of inserted lines so cursor placement can be adjusted.
local function insert_result(bufnr, line, lines)
  local payload = {}
  vim.list_extend(payload, lines)

  local appended_blank = false
  if config.newline_after_result then
    local existing = vim.api.nvim_buf_get_lines(bufnr, line, line + 1, false)[1]
    if not existing or not existing:match("^%s*$") then
      table.insert(payload, "")
      appended_blank = true
    end
  end

  vim.api.nvim_buf_set_lines(bufnr, line, line, false, payload)
  return #payload, appended_blank
end

-- Locate the contiguous block surrounding the cursor so we can emulate the
-- classic "evaluate current form" behaviour from Lispy REPLs.
local function find_block_edges(bufnr, line)
  local total = vim.api.nvim_buf_line_count(bufnr)
  local current = vim.api.nvim_buf_get_lines(bufnr, line, line + 1, false)[1]
  if not current or current:match("^%s*$") then
    return nil, nil
  end

  local start_line = line
  while start_line > 0 do
    local previous = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, start_line, false)[1]
    if not previous or previous:match("^%s*$") then
      break
    end
    start_line = start_line - 1
  end

  local end_line = line
  while end_line < total - 1 do
    local next_line = vim.api.nvim_buf_get_lines(bufnr, end_line + 1, end_line + 2, false)[1]
    if not next_line or next_line:match("^%s*$") then
      break
    end
    end_line = end_line + 1
  end

  return start_line, end_line
end

-- Shared implementation for line / block / buffer evaluation. It extracts the
-- selected text, executes it, and records the resulting comment block.
local function eval_range(bufnr, start_line, end_line)
  remove_existing_result(bufnr, start_line, end_line)

  local lines = vim.api.nvim_buf_get_lines(bufnr, start_line, end_line + 1, false)
  if #lines == 0 then
    return 0, false
  end

  local code = table.concat(lines, "\n")
  local ok, result_lines = eval(bufnr, code)

  if not ok then
    return insert_result(bufnr, end_line + 1, result_lines)
  end

  return insert_result(bufnr, end_line + 1, result_lines)
end

-- Entry point for the line keymap.
local function eval_line(bufnr, line)
  local inserted = eval_range(bufnr, line, line)
  local inserted_count = inserted or 0
  local target = line + inserted_count
  vim.api.nvim_win_set_cursor(0, { target + 1, 0 })
end

-- Entry point for the block evaluation keymap.
local function eval_block(bufnr, line)
  local start_line, end_line = find_block_edges(bufnr, line)
  if not start_line then
    return
  end

  local inserted = eval_range(bufnr, start_line, end_line)
  local inserted_count = inserted or 0
  local target = end_line + inserted_count
  vim.api.nvim_win_set_cursor(0, { target + 1, 0 })
end

-- Prepare a brand-new scratch buffer. The buffer is `nofile`, modifiable, and
-- receives an optional introductory banner for first-time users.
local function configure_buffer(bufnr, buf_name)
  local opts = {
    buftype = "nofile",
    bufhidden = "hide",
    swapfile = false,
    modifiable = true,
    filetype = "lua",
  }

  for option, value in pairs(opts) do
    vim.api.nvim_set_option_value(option, value, { buf = bufnr })
  end

  vim.api.nvim_buf_set_name(bufnr, buf_name or "replua://scratch")

  local intro = config.intro_lines
  if type(intro) == "string" then
    intro = vim.split(intro, "\n", { plain = true })
  elseif type(intro) == "table" then
    intro = vim.deepcopy(intro)
  else
    intro = {}
  end

  if #intro == 0 then
    intro = { "" }
  end

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, intro)
end

-- Install buffer-local mappings so the scratch buffer behaves consistently
-- regardless of user-wide normal-mode bindings.
local function setup_keymaps(bufnr)
  local options = { buffer = bufnr, silent = true }
  local km = config.keymaps or {}

  if km.eval_line then
    vim.keymap.set("n", km.eval_line, function()
      local line = vim.api.nvim_win_get_cursor(0)[1] - 1
      eval_line(bufnr, line)
    end, vim.tbl_extend("force", {}, options, { desc = "replua: evaluate current line" }))
  end

  if km.eval_block then
    vim.keymap.set("n", km.eval_block, function()
      local line = vim.api.nvim_win_get_cursor(0)[1] - 1
      eval_block(bufnr, line)
    end, vim.tbl_extend("force", {}, options, { desc = "replua: evaluate current block" }))
  end

  if km.eval_buffer then
    vim.keymap.set("n", km.eval_buffer, function()
      local end_line = vim.api.nvim_buf_line_count(bufnr) - 1
      local inserted = eval_range(bufnr, 0, end_line)
      local inserted_count = inserted or 0
      local target = end_line + inserted_count
      vim.api.nvim_win_set_cursor(0, { target + 1, 0 })
    end, vim.tbl_extend("force", {}, options, { desc = "replua: evaluate entire buffer" }))
  end
end

-- Detect anonymous, empty buffers created as temporary placeholders by some
-- window commands (e.g. `:enew`). We reuse these windows instead of leaving
-- `[No Name]` buffers behind.
local function is_placeholder_buffer(bufnr)
  if not bufnr or bufnr == 0 or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  if vim.api.nvim_buf_get_name(bufnr) ~= "" then
    return false
  end
  if vim.api.nvim_buf_get_option(bufnr, "modified") then
    return false
  end
  if vim.api.nvim_buf_get_option(bufnr, "buftype") ~= "" then
    return false
  end
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  if line_count > 1 then
    return false
  end
  local line = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)[1]
  return not line or line == ""
end

-- Execute the configured `open_command`, capturing both the resulting window
-- and any buffer it left behind so we can clean up placeholder buffers later.
local function apply_open_command(win)
  local command = config.open_command
  if type(command) == "function" then
    command()
    local new_win = vim.api.nvim_get_current_win()
    return new_win, vim.api.nvim_win_get_buf(new_win)
  elseif type(command) == "string" and command ~= "" then
    local ok, err = pcall(vim.cmd, "keepalt " .. command)
    if not ok then
      vim.notify(string.format("replua.nvim: failed to run open_command %q: %s", command, err), vim.log.levels.WARN)
      return win, vim.api.nvim_win_get_buf(win)
    end
    local new_win = vim.api.nvim_get_current_win()
    return new_win, vim.api.nvim_win_get_buf(new_win)
  end
  return win, vim.api.nvim_win_get_buf(win)
end

-- Ensure the target window contains something meaningful before we replace its
-- buffer with the repl. Falling back to the alternate buffer keeps window
-- navigation intuitive when the repl buffer is closed.
local function prepare_window_for_repl(win)
  local current_win = win or vim.api.nvim_get_current_win()
  if not vim.api.nvim_win_is_valid(current_win) then
    return vim.api.nvim_get_current_win()
  end
  local current_buf = vim.api.nvim_win_get_buf(current_win)
  if not is_placeholder_buffer(current_buf) then
    return current_win
  end

  local alt = vim.fn.bufnr("#")
  if alt ~= -1 and vim.api.nvim_buf_is_valid(alt) then
    vim.api.nvim_win_set_buf(current_win, alt)
    return current_win
  end

  local listed = vim.fn.getbufinfo({ buflisted = 1 })
  if listed and #listed > 0 then
    vim.api.nvim_win_set_buf(current_win, listed[1].bufnr)
    return current_win
  end

  return current_win
end

-- Track lifecycle events so we can drop per-buffer state when a scratch buffer
-- is wiped by the user.
local function attach_buffer(bufnr)
  vim.api.nvim_buf_attach(bufnr, false, {
    on_detach = function()
      state.buffers[bufnr] = nil
      state.env_by_buf[bufnr] = nil
      if state.buf == bufnr then
        state.buf = nil
        pick_active_buffer()
      end
    end,
  })
end

-- Create a fresh scratch buffer, register keymaps, and remember its name so
-- tools like Telescope can surface it. Buffer names increment for clarity
-- (`replua://scratch/2`, `/3`, ...).
local function create_repl_buffer()
  state.counter = state.counter + 1
  local bufnr = vim.api.nvim_create_buf(true, true)
  local name = state.counter == 1 and "replua://scratch" or string.format("replua://scratch/%d", state.counter)
  configure_buffer(bufnr, name)
  setup_keymaps(bufnr)
  attach_buffer(bufnr)
  state.buffers[bufnr] = name
  return bufnr
end

-- Pick an existing scratch buffer to focus, preferring the most recently used
-- one tracked in `state.buf`.
pick_active_buffer = function()
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    return state.buf
  end
  for bufnr in pairs(state.buffers) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      state.buf = bufnr
      return bufnr
    end
  end
end

-- Public entry point: open an existing scratch buffer or create a new one.
-- Passing `force_new = true` (triggered via `:RepluaOpen!`) always starts a
-- fresh buffer with an isolated environment.
function M.open(opts)
  opts = opts or {}
  ensure_commands()

  local bufnr = nil
  local created = false

  if not opts.force_new then
    bufnr = pick_active_buffer()
  end

  if not bufnr then
    bufnr = create_repl_buffer()
    created = true
  end

  state.buf = bufnr

  if not config.persist_env then
    -- Allow users to disable environment persistence globally; the buffer still
    -- retains text, but evaluation restarts from a clean slate.
    state.env_by_buf[bufnr] = nil
  end

  local wins = vim.fn.win_findbuf(bufnr)
  if #wins > 0 then
    vim.api.nvim_set_current_win(wins[1])
  else
    local target_win = vim.api.nvim_get_current_win()
    target_win = prepare_window_for_repl(target_win)
    local new_win, placeholder = apply_open_command(target_win)
    target_win = prepare_window_for_repl(new_win)
    vim.api.nvim_win_set_buf(target_win, bufnr)
    if placeholder and placeholder ~= bufnr and is_placeholder_buffer(placeholder) then
      -- Window commands like `enew` often leave an empty buffer behind. Clean
      -- it up quietly so buffer lists stay tidy.
      pcall(vim.api.nvim_buf_delete, placeholder, { force = false })
    end
  end

  if created then
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    if line_count > 0 then
      local last_line = vim.api.nvim_buf_get_lines(bufnr, line_count - 1, line_count, false)[1]
      if last_line ~= "" then
        vim.api.nvim_buf_set_lines(bufnr, line_count, line_count, false, { "" })
        line_count = line_count + 1
      end
      vim.api.nvim_win_set_cursor(0, { line_count, 0 })
    end
  end

  return bufnr
end

-- Evaluate the entire scratch buffer. This mirrors the original `:RepluaEval`
-- behaviour but shares the cursor-placement niceties from other entry points.
function M.eval_current_buffer()
  local bufnr = M.open()
  if not bufnr then
    return
  end

  local end_line = vim.api.nvim_buf_line_count(bufnr) - 1
  local inserted = eval_range(bufnr, 0, end_line)
  local inserted_count = inserted or 0
  local target = end_line + inserted_count
  vim.api.nvim_win_set_cursor(0, { target + 1, 0 })
end

-- Drop the evaluation environment for a specific scratch buffer. Handy when a
-- user wants to clear definitions without wiping buffer contents.
function M.reset_environment(bufnr)
  local target = bufnr or state.buf or vim.api.nvim_get_current_buf()
  if not target then
    return
  end
  if not state.buffers[target] then
    return
  end
  state.env_by_buf[target] = nil
end

-- Public configuration hook.
function M.setup(opts)
  extend_config(opts)
  ensure_commands()
end

ensure_commands()

return M
