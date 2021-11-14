if exists('g:loaded_gitdify')
  finish
endif
let g:loaded_gitdify = 1
let g:gitdify_error_message = 'INFO'

command! -nargs=* -complete=file -bang
\ Gitdify call gitdify#OpenCommitLogPopup(<q-args>, <bang>0)

