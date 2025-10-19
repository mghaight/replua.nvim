local M = {}

local defaults = {
  open_command = "enew",
  intro_lines = {
    "-- replua.nvim *scratch* buffer",
    "-- Evaluate Lua with <localleader>e (line / visual), <localleader><CR> (block), or <localleader>r (buffer).",
    "-- Results are appended as Lua comments with Neovim APIs available.",
    "",
  },
  keymaps = {
    eval_line = "<localleader>e",
    eval_visual = "<localleader>e",
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

local config = vim.deepcopy(defaults)

local state = {
  buf = nil,
  env = nil,
  commands_created = false,
}

local function extend_config(opts)
  if not opts then
    return
  end
  config = vim.tbl_deep_extend("force", vim.deepcopy(config), opts)
end

local function ensure_commands()
  if state.commands_created or not vim.api.nvim_create_user_command then
    return
  end

  vim.api.nvim_create_user_command("RepluaOpen", function()
    M.open()
  end, { desc = "Open the replua.nvim scratch buffer" })

  vim.api.nvim_create_user_command("RepluaEval", function()
    M.eval_current_buffer()
  end, { desc = "Evaluate the entire replua.nvim scratch buffer" })

  vim.api.nvim_create_user_command("RepluaReset", function()
    M.reset_environment()
  end, { desc = "Reset the replua.nvim Lua environment" })

  state.commands_created = true
end

local function build_env()
  if state.env then
    return state.env
  end

  local env = {}
  setmetatable(env, {
    __index = function(_, key)
      return rawget(_G, key)
    end,
    __newindex = function(_, key, value)
      rawset(_G, key, value)
    end,
  })

  state.env = env
  return env
end

local function capture_print(env)
  local prints = {}
  env.print = function(...)
    local pieces = {}
    for i = 1, select("#", ...) do
      local value = select(i, ...)
      pieces[i] = tostring(value)
    end
    table.insert(prints, table.concat(pieces, "\t"))
  end

  return function()
    env.print = nil
    return prints
  end
end

local function extend_with_prefix(target, prefix, text)
  local lines = vim.split(tostring(text), "\n", { plain = true })
  for _, chunk in ipairs(lines) do
    table.insert(target, prefix .. chunk)
  end
end

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

local function render_error_lines(err)
  local lines = {}
  extend_with_prefix(lines, config.error_prefix, err)
  return lines
end

local function eval(code)
  local env = build_env()
  local chunk, err = load(code, "replua", "t", env)
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

local function get_visual_selection_range()
  local mode = vim.fn.mode()
  if mode == "v" or mode == "V" or mode == "\22" then
    local start_pos = vim.fn.getpos("'<")
    local end_pos = vim.fn.getpos("'>")
    local start_line = math.min(start_pos[2], end_pos[2]) - 1
    local end_line = math.max(start_pos[2], end_pos[2]) - 1
    return start_line, end_line
  end
end

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

local function eval_range(bufnr, start_line, end_line)
  local lines = vim.api.nvim_buf_get_lines(bufnr, start_line, end_line + 1, false)
  if #lines == 0 then
    return 0, false
  end

  local code = table.concat(lines, "\n")
  local ok, result_lines = eval(code)

  if not ok then
    return insert_result(bufnr, end_line + 1, result_lines)
  end

  return insert_result(bufnr, end_line + 1, result_lines)
end

local function eval_line(bufnr, line)
  local inserted = eval_range(bufnr, line, line)
  local inserted_count = inserted or 0
  local target = line + inserted_count
  vim.api.nvim_win_set_cursor(0, { target + 1, 0 })
end

local function eval_visual(bufnr)
  local start_line, end_line = get_visual_selection_range()
  if not start_line then
    return
  end

  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
  local inserted = eval_range(bufnr, start_line, end_line)
  local inserted_count = inserted or 0
  local target = end_line + inserted_count
  vim.api.nvim_win_set_cursor(0, { target + 1, 0 })
end

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

local function configure_buffer(bufnr)
  local opts = {
    buftype = "nofile",
    bufhidden = "hide",
    buflisted = false,
    swapfile = false,
    modifiable = true,
    filetype = "lua",
  }

  for name, value in pairs(opts) do
    vim.api.nvim_set_option_value(name, value, { buf = bufnr })
  end

  vim.api.nvim_buf_set_name(bufnr, "replua://scratch")

  if type(config.intro_lines) == "table" then
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, config.intro_lines)
  else
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "" })
  end
end

local function setup_keymaps(bufnr)
  local options = { buffer = bufnr, silent = true }
  local km = config.keymaps or {}

  if km.eval_line then
    vim.keymap.set("n", km.eval_line, function()
      local line = vim.api.nvim_win_get_cursor(0)[1] - 1
      eval_line(bufnr, line)
    end, vim.tbl_extend("force", {}, options, { desc = "replua: evaluate current line" }))
  end

  if km.eval_visual then
    vim.keymap.set("v", km.eval_visual, function()
      eval_visual(bufnr)
    end, vim.tbl_extend("force", {}, options, { desc = "replua: evaluate selection" }))
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

local function open_target_buffer()
  local command = config.open_command
  if type(command) == "function" then
    command()
  elseif type(command) == "string" and command ~= "" then
    vim.cmd(command)
  else
    vim.cmd("enew")
  end
  return vim.api.nvim_get_current_buf()
end

local function attach_buffer(bufnr)
  vim.api.nvim_buf_attach(bufnr, false, {
    on_detach = function()
      if state.buf == bufnr then
        state.buf = nil
        if not config.persist_env then
          state.env = nil
        end
      end
    end,
  })
end

function M.open()
  ensure_commands()

  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    local wins = vim.fn.win_findbuf(state.buf)
    if #wins > 0 then
      vim.api.nvim_set_current_win(wins[1])
    else
      open_target_buffer()
      vim.api.nvim_win_set_buf(0, state.buf)
    end
    return state.buf
  end

  local bufnr = open_target_buffer()
  state.buf = bufnr
  if not config.persist_env then
    state.env = nil
  end

  configure_buffer(bufnr)
  setup_keymaps(bufnr)
  attach_buffer(bufnr)

  return bufnr
end

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

function M.reset_environment()
  state.env = nil
end

function M.setup(opts)
  extend_config(opts)
  ensure_commands()
end

ensure_commands()

return M
