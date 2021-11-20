const s:EMPTY_HASH = '4b825dc642cb6eb9a060e54bf8d69288fbee4904'

function! s:Catch(exception, throwpoint) abort
  let l:level = get(g:, 'gitdify_error_message', 'INFO')
  echohl WarningMsg
  if l:level ==# 'DEBUG'
    echomsg a:exception
    echomsg a:throwpoint
  else
    echomsg printf('%s', a:exception)
  endif
  echohl None
endfunction

function! s:System(cmd, cwd) abort
  let l:info = { 'exited': 0, 'output': [] }
  let l:opts = {
  \ 'callback': { ch, msg -> add(l:info.output, msg) },
  \ 'exit_cb': { job, status -> extend(l:info, { 'exited': 1, 'status': status })}
  \}

  if !empty(a:cwd) && isdirectory(a:cwd)
    let l:opts.cwd = a:cwd
  endif

  " TODO: asynchronous
  let l:job = job_start(a:cmd, l:opts)
  while !l:info.exited
    sleep 10ms
  endwhile

  if l:info.status != 0
    throw printf('GitError(%d) %s', l:info.status, join(l:info.output, "\n"))
  endif

  return l:info.output
endfunction

function! s:NormalizePath(filepath) abort
  if has('win32')
    return substitute(a:filepath, '\V\\\%( \)\@!', '/', 'g')
  else
    return a:filepath
  endif
endfunction

function! s:ToRelativePath(base, path) abort
  let l:base = s:NormalizePath(fnamemodify(a:base, ':p'))
  let l:path = s:NormalizePath(fnamemodify(a:path, ':p'))
  if stridx(l:path, l:base) == 0
    return l:path[len(l:base):]
  endif
  return l:path
endfunction

function! s:GetGitDir(filepath) abort
  let l:cwd = fnamemodify(a:filepath, ':p:h')
  let l:output = s:System(['git', 'rev-parse', '--show-toplevel'], l:cwd)
  return s:NormalizePath(l:output[0])
endfunction

function! s:GetGitFileLog(filepath) abort
  let l:gitdir = s:GetGitDir(a:filepath)
  let l:command = ['git', 'log', '--oneline']
  if !empty(a:filepath)
    if filereadable(a:filepath) || isdirectory(a:filepath)
      let l:gitpath = s:ToRelativePath(l:gitdir, a:filepath)
      call extend(l:command, ['--', l:gitpath])
    endif
  endif
  return s:System(l:command, l:gitdir)
endfunction

function! s:GetGitLsFiles(filepath, revision) abort
  let l:gitdir = s:GetGitDir(a:filepath)
  let l:revision = a:revision
  if empty(l:revision)
    let l:revision = 'HEAD'
  endif
  let l:gitfiles = s:System(['git', 'ls-tree', '-r', '--name-only', '--', l:revision], l:gitdir)
  return map(l:gitfiles, { _, f -> ({ 'name': f, 'path': simplify(l:gitdir . '/' . f )}) })
endfunction

function! s:IsGitFile(filepath, revision) abort
  let l:files = map(s:GetGitLsFiles(a:filepath, a:revision),
  \ { _, v -> s:NormalizePath(fnamemodify(v.path, ':p')) })
  let l:path = s:NormalizePath(fnamemodify(simplify(a:filepath), ':p'))
  return index(l:files, l:path) != -1
endfunction

function! s:GetGitDiffFiles(filepath, before, after) abort
  let l:gitdir = s:GetGitDir(a:filepath)
  let l:gitfiles = s:System(['git', 'diff', '--name-only', a:before, a:after], l:gitdir)
  return map(l:gitfiles, { _, f -> ({ 'name': f, 'path': simplify(l:gitdir . '/' . f )}) })
endfunction

function! s:GetGitRevFileInfo(filepath, revision) abort
  let l:gitdir = s:GetGitDir(a:filepath)
  let l:gitpath = s:ToRelativePath(l:gitdir, a:filepath)
  if s:IsGitFile(a:filepath, a:revision)
    let l:param = printf('%s:%s', a:revision, l:gitpath)
    let l:lines = s:System(['git', 'show', l:param], l:gitdir)
  else
    let l:lines = []
  endif
  return {
  \ 'revision': a:revision,
  \ 'filepath': fnamemodify(a:filepath, ':p'),
  \ 'gitdir': l:gitdir,
  \ 'gitpath': l:gitpath,
  \ 'lines': l:lines,
  \ 'bufname': printf('gitdify://%s/%s:%s', l:gitdir, a:revision, l:gitpath)
  \}
endfunction

function! s:OpenDiffWindow(info, winid) abort
  let l:bfexists = bufexists(a:info.bufname)

  call win_execute(a:winid, printf('vsplit %s', fnameescape(a:info.bufname)))
  let l:diffbufid = bufnr(a:info.bufname)
  let l:diffwinid = bufwinid(l:diffbufid)

  if !l:bfexists
    call win_execute(l:diffwinid, printf('setlocal syntax=%s fileformat=%s undolevels=-1',
    \ getwinvar(a:winid, '&l:syntax'), getwinvar(a:winid, '&l:fileformat')))
    call setbufline(l:diffbufid, 1, a:info.lines)
  endif

  call win_execute(l:diffwinid, 'diffthis')
  call win_execute(l:diffwinid, 'setlocal buftype=nofile bufhidden=wipe noswapfile nobuflisted nomodifiable')
  call setbufvar(l:diffbufid, 'gitdify', { 'filepath': a:info.filepath })

  call win_execute(a:winid, 'diffthis')
  call win_execute(a:winid, 'redraw')

  return l:diffwinid
endfunction

function! s:OpenGitRevCurrentFileDiff(revision, filepath, winid) abort
  let l:info = s:GetGitRevFileInfo(a:filepath, a:revision)
  let l:bufid = bufnr(a:filepath)
  let l:winid = a:winid

  if l:bufid == -1 || !win_id2win(bufwinid(l:bufid))
    tabnew
    silent execute printf('edit %s', fnameescape(a:filepath))
    let l:winid = win_getid()
  endif

  call s:OpenDiffWindow(l:info, l:winid)
  call win_gotoid(l:winid)
endfunction

function! s:OpenGitRevFileDiff(before, after, filepath) abort
  let l:afinfo = s:GetGitRevFileInfo(a:filepath, a:after)
  let l:bfinfo = s:GetGitRevFileInfo(a:filepath, a:before)
  let l:bfexists = bufexists(l:bfinfo.bufname)

  silent execute printf('tabedit %s', fnameescape(l:bfinfo.bufname))

  let l:bufid = bufnr(l:bfinfo.bufname)
  let l:winid = bufwinid(l:bufid)

  if !l:bfexists
    call win_execute(l:winid, 'setlocal undolevels=-1')
    call setbufline(l:bufid, 1, l:bfinfo.lines)
    call win_execute(l:winid, 'setlocal buftype=nofile bufhidden=wipe noswapfile nobuflisted nomodifiable')
    call setbufvar(l:bufid, 'gitdify', { 'filepath': l:bfinfo.filepath })
  endif

  let l:diffwinid = s:OpenDiffWindow(l:afinfo, l:winid)
  call win_execute(l:diffwinid, 'silent! foldclose!')
  call win_gotoid(l:winid)
endfunction

function! s:CreatePopupObject(selects, scope) abort
  let l:search = ''
  let l:meta = {'pos': {}, 'result': 1}
  let l:selects = map(a:selects, { i, v -> extend({ 'id': i + 1}, v) })
  let l:popup = extend(extend({}, l:), a:scope)

  function! l:popup.Items() dict abort
    let l:items = copy(self.selects)
    if len(self.search) > 0
      call filter(l:items, { _, v -> stridx(v.text, self.search) != -1 })
    endif
    return extend([{ 'text': self.search }], l:items)
  endfunction

  function! l:popup.Filter(id, key) dict abort
    let l:ignore_keys = [
    \ "\<Down>", "\<C-N>",
    \ "\<Up>", "\<C-P>",
    \ "\<Space>", "\<Enter>",
    \ "\<Esc>", "\<C-C>"
    \ ]

    let l:key = a:key
    let l:result = line('.', a:id)
    let self.meta.pos = popup_getpos(a:id)
    let self.meta.result = l:result

    if strtrans(l:key) ==# l:key
      let self.search = self.search . l:key
    elseif l:key ==# "\<BS>" || l:key ==# "\<C-H>"
      let l:strlen = strchars(self.search)
      if l:strlen > 0
        let self.search = strcharpart(self.search, 0, l:strlen - 1)
      endif
    elseif l:key ==# "\<C-W>" || l:key ==# "\<DEL>"
      let self.search = ''
    elseif l:key ==# "\<Space>" || l:key ==# "\<Enter>"
      if l:result == 1
        return 1
      endif
    elseif l:key ==# "\<C-J>"
      let l:key = "\<Down>"
    elseif l:key ==# "\<C-K>"
      let l:key = "\<Up>"
    elseif l:key ==# "\<C-X>"
      let l:key = "\<Esc>"
    endif

    if index(l:ignore_keys, l:key) != -1
      return popup_filter_menu(a:id, l:key)
    endif

    call popup_settext(a:id, map(self.Items(), { _, v -> v.text }))

    return 1
  endfunction

  function! l:popup._Open() dict abort
    let l:winid = popup_menu(map(self.Items(), { _, v -> v.text }), extend({
    \ 'callback': self.Callback,
    \ 'filter': self.Filter,
    \ 'pos': 'topleft',
    \ 'maxheight': &lines * 6 / 10,
    \ 'minheight': &lines * 6 / 10,
    \ 'maxwidth': &columns * 6 / 10,
    \ 'minwidth': &columns * 6 / 10,
    \ 'resize': 1,
    \}, self.meta.pos))
    call win_execute(l:winid, printf(':%d', self.meta.result))
    return l:winid
  endfunction

  function! l:popup.Open() dict abort
    call self._Open()
  endfunction

  return l:popup
endfunction

function! s:OpenCommitFilesPopup(filepath, before, after, winid, bang, opener) abort
  let l:popup = s:CreatePopupObject(
  \ map(s:GetGitDiffFiles(a:filepath, a:before, a:after), { _,v -> ({ 'text': v.name, 'val': v.path }) }),
  \ extend(extend({}, a:), l:))

  function! l:popup.Callback(id, result) dict abort
    try
      let l:selects = self.Items()
      if a:result > 0 && !empty(l:selects)
        let l:selected = l:selects[a:result - 1]
        if self.bang
          call s:OpenGitRevCurrentFileDiff(self.after, l:selected.val, self.winid)
        else
          call s:OpenGitRevFileDiff(self.before, self.after, l:selected.val)
        endif
      else
        call self.opener.Open()
      endif
    catch /.*/
      call s:Catch(v:exception, v:throwpoint)
    endtry
  endfunction

  call l:popup.Open()
endfunction

function! s:OpenCommitLogPopup(filepath, winid, bang) abort
  let l:popup = s:CreatePopupObject(
  \ map(s:GetGitFileLog(a:filepath), { _, v -> ({ 'text': v, 'val': v }) }),
  \ extend(extend({}, a:), l:))

  function! l:popup.Callback(id, result) dict abort
    try
      let l:selects = self.Items()
      if a:result > 0 && !empty(l:selects)
        let l:selected = l:selects[a:result - 1]
        let l:revision = split(l:selected.val, ' ')[0]
        let l:after = l:revision
        let l:before = len(self.selects) == l:selected.id ? s:EMPTY_HASH : l:revision . '~1'
        if !empty(self.filepath) && filereadable(self.filepath)
          if self.bang
            call s:OpenGitRevCurrentFileDiff(l:revision, self.filepath, self.winid)
          else
            call s:OpenGitRevFileDiff(l:before, l:after, self.filepath)
          endif
        else
          call s:OpenCommitFilesPopup(self.filepath, l:before, l:after, self.winid, self.bang, self)
        endif
      endif
    catch /.*/
      call s:Catch(v:exception, v:throwpoint)
    endtry
  endfunction

  function! l:popup.Open() dict abort
    let l:winid = self._Open()
    call win_execute(l:winid, 'setlocal syntax=gitrebase')
  endfunction

  call l:popup.Open()
endfunction

function! gitdify#OpenCommitLogPopup(filepath, bang) abort
  try
    if !empty(a:filepath)
      let l:filepath = expand(a:filepath)
    else
      let l:filepath = ''
    endif

    call s:OpenCommitLogPopup(l:filepath, win_getid(), a:bang)
  catch /.*/
    call s:Catch(v:exception, v:throwpoint)
  endtry
endfunction

