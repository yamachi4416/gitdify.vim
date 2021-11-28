if exists('g:loaded_gitdify')
  finish
endif
let g:loaded_gitdify = 1
let g:gitdify_log_level = get(g:, 'gitdify_log_level', 'INFO')
let g:gitdify_filter_use_fuzzy = get(g:, 'gitdify_filter_use_fuzzy', 1)

command! -nargs=* -complete=file -bang
\ Gitdify call gitdify#OpenCommitLogPopup(<q-args>, <bang>0)

