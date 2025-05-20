if !has('nvim')
  echohl Error
  echom 'This plugin only works with Neovim'
  echohl clear
  finish
endif

" The send statement/definition command.
command! SendPyObject              lua require("nvim-python-repl").send_statement_definition()
command! SendPySelection           lua require("nvim-python-repl").send_visual_to_repl()
command! SendPyBuffer              lua require("nvim-python-repl").send_buffer_to_repl()
command! ToggleExecuteOnSend       lua require("nvim-python-repl").toggle_execute()
command! ReplToggleVertical        lua require("nvim-python-repl").toggle_vertical()
command! ReplTogglePrompt          lua require("nvim-python-repl").toggle_prompt()
command! ReplOpen                  lua require("nvim-python-repl").open_repl()
command! ReplRestart               lua require("nvim-python-repl").restart_repl()
command! SendCell                  lua require("nvim-python-repl").send_current_cell_to_repl()
command! SendAboveCells            lua require("nvim-python-repl").send_above_cells_to_repl()
command! SendCellAndJump           lua require("nvim-python-repl").send_cell_and_jump_to_next()
" Remove default mappings
" nnoremap <silent> <leader>n :SendPyObject<CR>
" nnoremap <silent> <leader>e :ToggleExecuteOnSend<CR>
" nnoremap <silent> <leader>nr :SendPyBuffer<CR>
" vnoremap <silent> <leader>n :<C-U>SendPySelection<CR>
