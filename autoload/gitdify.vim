const s:EMPTY_HASH = '4b825dc642cb6eb9a060e54bf8d69288fbee4904'

function! s:Catch(exception, throwpoint) abort
  echomsg printf('%s - (%s)', a:exception, a:throwpoint)
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
  return mapnew(l:gitfiles,
  \ { _, f -> ({ 'name': f, 'path': simplify(l:gitdir . '/' . f )}) })
endfunction

function! s:IsGitFile(filepath, revision) abort
  let l:files = s:GetGitLsFiles(a:filepath, a:revision)
  let l:paths = mapnew(l:files,
  \ { _, v -> s:NormalizePath(fnamemodify(v.path, ':p')) })
  let l:path = s:NormalizePath(fnamemodify(simplify(a:filepath), ':p'))
  return index(l:paths, l:path) != -1
endfunction

function! s:GetGitDiffFiles(filepath, before, after) abort
  let l:gitdir = s:GetGitDir(a:filepath)
  let l:gitfiles = s:System(['git', 'diff', '--name-only', a:before, a:after], l:gitdir)
  return mapnew(l:gitfiles,
  \ { _, f -> ({ 'name': f, 'path': simplify(l:gitdir . '/' . f )}) })
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
    call win_execute(l:diffwinid, printf('setlocal syntax=%s fileformat=%s',
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
    execute printf('edit %s', fnameescape(a:filepath))
    let l:winid = win_getid()
  endif

  call s:OpenDiffWindow(l:info, l:winid)
  call win_gotoid(l:winid)
endfunction

function! s:OpenGitRevFileDiff(before, after, filepath) abort
  let l:afinfo = s:GetGitRevFileInfo(a:filepath, a:after)
  let l:bfinfo = s:GetGitRevFileInfo(a:filepath, a:before)
  let l:bfexists = bufexists(l:bfinfo.bufname)

  execute printf('tabedit %s', fnameescape(l:bfinfo.bufname))

  let l:bufid = bufnr(l:bfinfo.bufname)
  let l:winid = bufwinid(l:bufid)

  if !l:bfexists
    call setbufline(l:bufid, 1, l:bfinfo.lines)
    call win_execute(l:winid, 'setlocal buftype=nofile bufhidden=wipe noswapfile nobuflisted nomodifiable')
    call setbufvar(l:bufid, 'gitdify', { 'filepath': l:bfinfo.filepath })
  endif

  let l:diffwinid = s:OpenDiffWindow(l:afinfo, l:winid)
  call win_execute(l:diffwinid, 'foldclose')
  call win_gotoid(l:winid)
endfunction

function! s:OpenCommitFilesPopup(filepath, before, after, winid, bang, ppopup) abort
  let l:selects = s:GetGitDiffFiles(a:filepath, a:before, a:after)
  let l:popup = extend(extend({}, a:), l:)

  function! l:popup.Callback(id, result) dict abort
    try
      if a:result != -1 && !empty(self.selects)
        let l:selected = self.selects[a:result - 1]
        if self.bang
          call s:OpenGitRevCurrentFileDiff(self.after, l:selected.path, self.winid)
        else
          call s:OpenGitRevFileDiff(self.before, self.after, l:selected.path)
        endif
      else
        call self.ppopup.Open()
      endif
    catch /.*/
      call s:Catch(v:exception, v:throwpoint)
    endtry
  endfunction

  function! l:popup.Open() dict abort
    let l:selects = mapnew(self.selects, { _, v -> v.name })
    call popup_menu(l:selects, {
    \ 'callback': self.Callback,
    \ 'maxheight': &lines * 6 / 10,
    \ 'maxwidth': &columns * 6 / 10,
    \ 'minwidth': &columns * 6 / 10,
    \ 'resize': 1,
    \})
  endfunction

  call l:popup.Open()
endfunction

function! s:OpenCommitLogPopup(filepath, winid, bang) abort
  let l:selects = s:GetGitFileLog(a:filepath)
  let l:popup = extend(extend({ '_pos': {}, '_res': 1 }, a:), l:)

  function! l:popup.Callback(id, result) dict abort
    try
      if a:result != -1 && !empty(self.selects)
        let self._pos = popup_getpos(a:id)
        let self._res = a:result
        let l:selected = self.selects[a:result - 1]
        let l:revision = split(l:selected, ' ')[0]
        let l:after = l:revision
        let l:before = len(self.selects) == a:result ? s:EMPTY_HASH : l:revision . '~1'
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
    let l:winid = popup_menu(self.selects, extend({
    \ 'callback': self.Callback,
    \ 'maxheight': &lines * 6 / 10,
    \ 'maxwidth': &columns * 6 / 10,
    \ 'minwidth': &columns * 6 / 10,
    \ 'resize': 1,
    \}, self._pos))
    call win_execute(l:winid, printf(':%d', self._res))
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

