local ts_utils = require("nvim-treesitter.ts_utils")
local api = vim.api

M = {}

M.term = {
    opened = 0,
    winid = nil,
    bufid = nil,
    chanid = nil,
}

-- HELPERS
local visual_selection_range = function()
    local _, start_row, start_col, _ = unpack(vim.fn.getpos("'<"))
    local _, end_row, end_col, _ = unpack(vim.fn.getpos("'>"))
    if start_row < end_row or (start_row == end_row and start_col <= end_col) then
        return start_row - 1, start_col - 1, end_row - 1, end_col
    else
        return end_row - 1, end_col - 1, start_row - 1, start_col
    end
end

local get_statement_definition = function(filetype)
    local node = ts_utils.get_node_at_cursor()
    if (node:named() == false) then
        error("Node not recognized. Check to ensure treesitter parser is installed.")
    end
    if filetype == "python" or filetype == "scala" then
        while (
                string.match(node:sexpr(), "import") == nil and
                string.match(node:sexpr(), "statement") == nil and
                string.match(node:sexpr(), "definition") == nil and
                string.match(node:sexpr(), "call_expression") == nil) do
            node = node:parent()
        end
    elseif filetype == "lua" then
        while (
                string.match(node:sexpr(), "for_statement") == nil and
                string.match(node:sexpr(), "if_statement") == nil and
                string.match(node:sexpr(), "while_statement") == nil and
                string.match(node:sexpr(), "assignment_statement") == nil and
                string.match(node:sexpr(), "function_definition") == nil and
                string.match(node:sexpr(), "function_call") == nil and
                string.match(node:sexpr(), "local_declaration") == nil
            ) do
            node = node:parent()
        end
    end
    return node
end

local term_open = function(filetype, config, force)
    -- Ensure we have a clean state before opening a new terminal
    if force then
        -- If we're forcing a new terminal, make sure any existing state is cleared
        M.term.opened = 0
        M.term.winid = nil
        M.term.bufid = nil
        M.term.chanid = nil
    end

    local orig_win = vim.api.nvim_get_current_win()
    
    -- Skip opening if there's already a valid REPL open (and we're not forcing)
    if not force and 
       M.term.chanid ~= nil and 
       M.term.bufid ~= nil and vim.api.nvim_buf_is_valid(M.term.bufid) and
       M.term.winid ~= nil and vim.api.nvim_win_is_valid(M.term.winid) then
        return
    end
    
    -- Create a new split
    if config.vsplit then
        api.nvim_command('vsplit')
    else
        api.nvim_command('split')
    end
    
    local buf = vim.api.nvim_create_buf(true, true)
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    
    -- Set up the REPL command
    local choice = ''
    if config.prompt_spawn then
        choice = vim.fn.input("REPL spawn command: ")
    else
        if filetype == 'scala' then
            choice = config.spawn_command.scala
        elseif filetype == 'python' then
            choice = config.spawn_command.python
        elseif filetype == 'lua' then
            choice = config.spawn_command.lua
        end
    end
    
    -- Open the terminal
    local chan = vim.fn.termopen(choice, {
        on_exit = function()
            M.term.chanid = nil
            M.term.opened = 0
            M.term.winid = nil
            M.term.bufid = nil
        end
    })
    
    -- Update the terminal state
    M.term.chanid = chan
    vim.bo.filetype = 'term'

    -- Block until terminal is ready - extend timeout for certain REPL types
    local timeout = 5000 -- 5 seconds timeout by default
    if just_restarted or force then
        timeout = 10000 -- 10 seconds timeout for restart scenarios
    end
    
    local interval = 100 -- Check every 100ms
    local success = vim.wait(timeout, function()
        -- Check if terminal buffer has content
        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        return #lines > 0 and lines[1] ~= ""
    end, interval)

    if not success then
        vim.notify("Terminal initialization timed out", vim.log.levels.WARN)
    end

    -- Additional wait for safety, extended for restart cases
    if just_restarted or force then
        vim.wait(200)  -- Longer wait after restart
    else
        vim.wait(50)   -- Normal wait
    end

    -- Update the rest of the terminal state
    M.term.opened = 1
    M.term.winid = win
    M.term.bufid = buf
    
    -- Return to original window
    if orig_win and vim.api.nvim_win_is_valid(orig_win) then
        api.nvim_set_current_win(orig_win)
    end
end

-- CONSTRUCTING MESSAGE
local construct_message_from_selection = function(start_row, start_col, end_row, end_col)
    local bufnr = api.nvim_get_current_buf()
    if start_row ~= end_row then
        local lines = api.nvim_buf_get_lines(bufnr, start_row, end_row + 1, false)
        lines[1] = string.sub(lines[1], start_col + 1)
        -- end_row might be just after the last line. In this case the last line is not truncated.
        if #lines == end_row - start_row then
            lines[#lines] = string.sub(lines[#lines], 1, end_col)
        end
        return lines
    else
        local line = api.nvim_buf_get_lines(bufnr, start_row, start_row + 1, false)[1]
        -- If line is nil then the line is empty
        return line and { string.sub(line, start_col + 1, end_col) } or {}
    end
end

local construct_message_from_buffer = function()
    local bufnr = api.nvim_get_current_buf()
    local lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
    return lines
end

local construct_message_from_node = function(filetype)
    local node = get_statement_definition(filetype)
    local bufnr = api.nvim_get_current_buf()
    local message = vim.treesitter.get_node_text(node, bufnr)
    if filetype == "python" then
        -- For Python, we need to preserve the original indentation
        local start_row, start_column, end_row, _ = node:range()
        if vim.fn.has('win32') == 1 then
            local lines = api.nvim_buf_get_lines(bufnr, start_row, end_row + 1, false)
            message = table.concat(lines, api.nvim_replace_termcodes("<C-m>", true, false, true))
        end
        -- For Linux, remove superfluous indentation so nested code is not indented
        while start_column ~= 0 do
            -- For empty blank lines
            message = string.gsub(message, "\n\n+", "\n")
            -- For nested indents in classes/functions
            message = string.gsub(message, "\n%s%s%s%s", "\n")
            start_column = start_column - 4
        end
        -- end
    end
    return message
end

-- We're tracking when a restart has occurred to handle the next send_message call specially
local just_restarted = false

local send_message = function(filetype, message, config)
    -- Handle recently restarted terminal
    if just_restarted then
        -- Reset flag immediately to avoid cascading errors
        just_restarted = false
        
        -- Additional wait to ensure terminal is ready after restart
        vim.wait(500)
        
        -- If terminal state is invalid after restart + wait, try to recover
        if not (M.term.chanid ~= nil and 
               M.term.bufid ~= nil and vim.api.nvim_buf_is_valid(M.term.bufid) and
               M.term.winid ~= nil and vim.api.nvim_win_is_valid(M.term.winid)) then
            vim.notify("Warning: REPL state appears invalid after restart. Attempting to recreate...", vim.log.levels.WARN)
            term_open(filetype, config, true)
        end
    end
    
    -- If we haven't opened a REPL yet, open one
    if M.term.opened == 0 then
        term_open(filetype, config)
    end
    
    -- Check terminal state after any initialization attempts
    local valid_terminal = M.term.chanid ~= nil and 
                          M.term.bufid ~= nil and vim.api.nvim_buf_is_valid(M.term.bufid) and
                          M.term.winid ~= nil and vim.api.nvim_win_is_valid(M.term.winid)
    
    -- If terminal is still invalid, try one last recovery attempt
    if not valid_terminal then
        vim.notify("REPL state invalid. Recreating REPL...", vim.log.levels.WARN)
        -- Force reset the terminal state
        M.term.opened = 0
        M.term.winid = nil
        M.term.bufid = nil
        M.term.chanid = nil
        -- Try to open a new terminal
        term_open(filetype, config, true)
        
        -- Verify it worked
        if not (M.term.chanid ~= nil and 
               M.term.bufid ~= nil and vim.api.nvim_buf_is_valid(M.term.bufid) and
               M.term.winid ~= nil and vim.api.nvim_win_is_valid(M.term.winid)) then
            vim.notify("Failed to create REPL terminal.", vim.log.levels.ERROR)
            return
        end
    end
    
    local line_count = vim.api.nvim_buf_line_count(M.term.bufid)
    vim.api.nvim_win_set_cursor(M.term.winid, { line_count, 0 })
    vim.wait(50)
    
    -- Trim trailing empty lines from message
    if filetype == "python" then
        -- Remove trailing newlines to avoid extra empty lines in output
        message = message:gsub("\n+$", "")
    end

    if filetype == "python" or filetype == "lua" then
        -- Use bracketed paste mode to send the text properly
        message = api.nvim_replace_termcodes("<esc>[200~" .. message .. "<esc>[201~", true, false, true)
        api.nvim_chan_send(M.term.chanid, message)
    elseif filetype == "scala" then
        if config.spawn_command.scala == "sbt console" then
            message = api.nvim_replace_termcodes(":paste<cr>" .. message .. "<cr><C-d>", true, false, true)
        else
            message = api.nvim_replace_termcodes("{<cr>" .. message .. "<cr>}", true, false, true)
        end
        api.nvim_chan_send(M.term.chanid, message)
    end
    
    if config.execute_on_send then
        vim.wait(20)
        if vim.fn.has('win32') == 1 then
            vim.wait(20)
            -- For Windows, simulate pressing Enter
            api.nvim_chan_send(M.term.chanid, api.nvim_replace_termcodes("<C-m>", true, false, true))
        else
            -- Check if this is a Python code block that needs an extra newline
            if filetype == "python" and 
               (message:match("for%s+.*:%s*\n") or 
                message:match("if%s+.*:%s*\n") or 
                message:match("while%s+.*:%s*\n") or 
                message:match("def%s+.*:%s*\n") or
                message:match("class%s+.*:%s*\n")) then
                -- Send two carriage returns for code blocks
                api.nvim_chan_send(M.term.chanid, "\r\r")
            else
                -- Only send one carriage return to avoid extra blank lines
                api.nvim_chan_send(M.term.chanid, "\r")
            end
        end
    end
end

-- Function to find all cell boundaries in the buffer
local get_all_cell_boundaries = function()
    local bufnr = vim.api.nvim_get_current_buf()
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local boundaries = {}
    
    -- Always consider line 0 as a start boundary (implicit cell start)
    table.insert(boundaries, 0)
    
    -- Find all explicit cell markers
    for i = 0, #lines - 1 do
        if string.match(lines[i + 1], "^# %%%%") then
            table.insert(boundaries, i)
        end
    end
    
    -- Always consider end of file as a boundary
    if boundaries[#boundaries] ~= #lines then
        table.insert(boundaries, #lines)
    end
    
    return boundaries
end

-- Function to identify cell boundaries
local get_current_cell_range = function()
    local bufnr = vim.api.nvim_get_current_buf()
    local cursor_row = vim.api.nvim_win_get_cursor(0)[1] - 1

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local start_row = 0
    local end_row = #lines - 1

    for i = cursor_row, 0, -1 do
        if string.match(lines[i + 1], "^# %%%%") then
            start_row = i + 1
            break
        end
    end

    for i = cursor_row + 1, #lines - 1 do
        if string.match(lines[i + 1], "^# %%%%") then
            end_row = i - 1
            break
        end
    end

    return start_row, end_row
end

-- Function to extract cell content
local construct_message_from_cell = function()
    local start_row, end_row = get_current_cell_range()
    local bufnr = vim.api.nvim_get_current_buf()
    local lines = vim.api.nvim_buf_get_lines(bufnr, start_row, end_row + 1, false)
    return lines
end

-- Helper function to find the current cell index
local get_current_cell_index = function()
    local bufnr = vim.api.nvim_get_current_buf()
    local cursor_row = vim.api.nvim_win_get_cursor(0)[1] - 1
    local boundaries = get_all_cell_boundaries()
    
    local current_cell_index = 1
    for i = 1, #boundaries do
        if boundaries[i] > cursor_row then
            current_cell_index = i - 1
            break
        elseif i == #boundaries then
            current_cell_index = i
        end
    end
    
    return current_cell_index, boundaries
end

-- Function to send current cell to REPL
M.send_current_cell_to_repl = function(config)
    local filetype = vim.bo.filetype
    local message_lines = construct_message_from_cell()
    local message = table.concat(message_lines, "\n")
    
    -- Remove any unnecessary trailing newlines for Python
    if filetype == "python" then
        message = message:gsub("\n+$", "")
    end
    
    send_message(filetype, message, config)
end

-- Function to send current cell to REPL and jump to the next cell
M.send_cell_and_jump_to_next = function(config)
    -- First, execute the current cell
    local filetype = vim.bo.filetype
    local message_lines = construct_message_from_cell()
    local message = table.concat(message_lines, "\n")
    
    -- Remove any unnecessary trailing newlines for Python
    if filetype == "python" then
        message = message:gsub("\n+$", "")
    end
    
    send_message(filetype, message, config)
    
    -- Now find the current cell index and boundaries
    local current_cell_index, boundaries = get_current_cell_index()
    
    -- If we're already at the last cell, nothing more to do
    if current_cell_index >= #boundaries then
        vim.notify("Already at the last cell", vim.log.levels.INFO)
        return
    end
    
    -- Jump to the start of the next cell
    local target_row = boundaries[current_cell_index + 1]
    
    -- If target is a cell marker, move to the line after it
    local bufnr = vim.api.nvim_get_current_buf()
    if string.match(vim.api.nvim_buf_get_lines(bufnr, target_row, target_row + 1, false)[1] or "", "^# %%%%") then
        target_row = target_row + 1
    end
    
    -- Move cursor to the target row
    vim.api.nvim_win_set_cursor(0, {target_row + 1, 0})
    
    -- Visual feedback
    vim.api.nvim_exec("normal! zz", false)
end

-- Function to send all cells above the current cursor position to REPL
M.send_above_cells_to_repl = function(config)
    local filetype = vim.bo.filetype
    local bufnr = vim.api.nvim_get_current_buf()
    local current_cell_index, boundaries = get_current_cell_index()
    
    -- If we're already at the first cell, nothing to do
    if current_cell_index <= 1 then
        vim.notify("No cells above current position", vim.log.levels.INFO)
        return
    end
    
    -- Process all cells above the current one
    for i = 1, current_cell_index - 1 do
        local start_row = boundaries[i] + (string.match(vim.api.nvim_buf_get_lines(bufnr, boundaries[i], boundaries[i] + 1, false)[1] or "", "^# %%%%") and 1 or 0)
        local end_row = boundaries[i + 1] - 1
        
        -- Skip empty cells
        if end_row >= start_row then
            local cell_lines = vim.api.nvim_buf_get_lines(bufnr, start_row, end_row + 1, false)
            local message = table.concat(cell_lines, "\n")
            
            -- Remove any unnecessary trailing newlines for Python
            if filetype == "python" then
                message = message:gsub("\n+$", "")
            end
            
            -- Send each cell to the REPL
            send_message(filetype, message, config)
            
            -- Add a small delay between cells to ensure proper execution order
            vim.wait(100)
        end
    end
    
    vim.notify("Executed " .. (current_cell_index - 1) .. " cells above current position", vim.log.levels.INFO)
end

-- Function to jump to the previous cell
M.jump_to_previous_cell = function()
    local current_cell_index, boundaries = get_current_cell_index()
    
    -- If we're already at the first cell, nothing to do
    if current_cell_index <= 1 then
        vim.notify("Already at the first cell", vim.log.levels.INFO)
        return
    end
    
    -- Jump to the start of the previous cell
    local target_row = boundaries[current_cell_index - 1]
    
    -- If target is a cell marker, move to the line after it
    local bufnr = vim.api.nvim_get_current_buf()
    if string.match(vim.api.nvim_buf_get_lines(bufnr, target_row, target_row + 1, false)[1] or "", "^# %%%%") then
        target_row = target_row + 1
    end
    
    -- Move cursor to the target row
    vim.api.nvim_win_set_cursor(0, {target_row + 1, 0})
    
    -- Visual feedback
    vim.api.nvim_exec("normal! zz", false)
    vim.notify("Jumped to previous cell", vim.log.levels.INFO)
end

-- Function to jump to the next cell
M.jump_to_next_cell = function()
    local current_cell_index, boundaries = get_current_cell_index()
    
    -- If we're already at the last cell, nothing to do
    if current_cell_index >= #boundaries then
        vim.notify("Already at the last cell", vim.log.levels.INFO)
        return
    end
    
    -- Jump to the start of the next cell
    local target_row = boundaries[current_cell_index + 1]
    
    -- If target is a cell marker, move to the line after it
    local bufnr = vim.api.nvim_get_current_buf()
    if string.match(vim.api.nvim_buf_get_lines(bufnr, target_row, target_row + 1, false)[1] or "", "^# %%%%") then
        target_row = target_row + 1
    end
    
    -- Move cursor to the target row
    vim.api.nvim_win_set_cursor(0, {target_row + 1, 0})
    
    -- Visual feedback
    vim.api.nvim_exec("normal! zz", false)
    vim.notify("Jumped to next cell", vim.log.levels.INFO)
end

M.send_statement_definition = function(config)
    local filetype = vim.bo.filetype
    local message = construct_message_from_node(filetype)
    send_message(filetype, message, config)
end

M.send_visual_to_repl = function(config)
    local filetype = vim.bo.filetype
    local start_row, start_col, end_row, end_col = visual_selection_range()
    local message = construct_message_from_selection(start_row, start_col, end_row, end_col)
    local concat_message = ""
    if vim.fn.has('win32') == 1 then
        concat_message = table.concat(message, "<C-m>")
    else
        concat_message = table.concat(message, "\n")
        -- Remove any unnecessary trailing newlines
        if filetype == "python" then
            concat_message = concat_message:gsub("\n+$", "")
        end
    end
    send_message(filetype, concat_message, config)
end

M.send_buffer_to_repl = function(config)
    local filetype = vim.bo.filetype
    local message = construct_message_from_buffer()
    local concat_message = ""
    if vim.fn.has('win32') == 1 then
        concat_message = table.concat(message, "<C-m>")
    else
        concat_message = table.concat(message, "\n")
        -- Remove any unnecessary trailing newlines
        if filetype == "python" then
            concat_message = concat_message:gsub("\n+$", "")
        end
    end
    send_message(filetype, concat_message, config)
end

M.open_repl = function(config)
    local filetype = vim.bo.filetype
    term_open(filetype, config)
end

-- Function to close the current REPL and open a new one
M.restart_repl = function(config)
    local filetype = vim.bo.filetype
    -- Store the original window
    local orig_win = vim.api.nvim_get_current_win()
    
    -- Close any existing REPL
    if M.term.opened == 1 then
        -- Focus the REPL window if it exists
        if M.term.winid and vim.api.nvim_win_is_valid(M.term.winid) then
            vim.api.nvim_set_current_win(M.term.winid)
            
            -- Close the current terminal buffer
            if M.term.bufid and vim.api.nvim_buf_is_valid(M.term.bufid) then
                vim.api.nvim_buf_delete(M.term.bufid, {force = true})
            end
        end
    end
    
    -- Wait briefly to allow cleanup
    vim.wait(100)
    
    -- Always reset terminal state completely, even if we couldn't close properly
    M.term.opened = 0
    M.term.winid = nil
    M.term.bufid = nil
    M.term.chanid = nil
    
    -- Set the just_restarted flag before opening a new REPL
    just_restarted = true
    
    -- Now open a new REPL with force=true to bypass the chanid check
    term_open(filetype, config, true)
    
    -- Verify the terminal was created successfully
    local valid_terminal = M.term.chanid ~= nil and 
                          M.term.bufid ~= nil and vim.api.nvim_buf_is_valid(M.term.bufid) and
                          M.term.winid ~= nil and vim.api.nvim_win_is_valid(M.term.winid)
                          
    if not valid_terminal then
        vim.notify("Failed to restart REPL terminal. Please try again.", vim.log.levels.ERROR)
        just_restarted = false
        return
    end
    
    -- Return to the original window
    if orig_win and vim.api.nvim_win_is_valid(orig_win) then
        vim.api.nvim_set_current_win(orig_win)
    end
    
    -- Notify the user
    vim.notify("REPL restarted successfully", vim.log.levels.INFO)
end

return M
