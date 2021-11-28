const s:EMPTY_HASH = '4b825dc642cb6eb9a060e54bf8d69288fbee4904'

function! s:IsLogLevelDebug() abort
  let l:level = get(g:, 'gitdify_log_level', 'INFO')
  return l:level ==# 'DEBUG'
endfunction

function! s:Catch(exception, throwpoint) abort
  echohl WarningMsg
  if s:IsLogLevelDebug()
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

  if s:IsLogLevelDebug()
    echom printf('%s %s', a:cmd, a:cwd)
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

function! s:GetGitFileLog(filepath, gitdir, all) abort
  let l:command = ['git', 'log', '--oneline']
  if a:all
    call extend(l:command, ['--all', '--decorate=full'])
  endif
  if !empty(a:filepath)
    if filereadable(a:filepath) || isdirectory(a:filepath)
      let l:gitpath = s:ToRelativePath(a:gitdir, a:filepath)
      if !empty(l:gitpath)
        call extend(l:command, ['--', l:gitpath])
      endif
    endif
  endif
  return s:System(l:command, a:gitdir)
endfunction

function! s:GetGitLsFiles(gitdir, revision) abort
  let l:revision = a:revision
  if empty(l:revision)
    let l:revision = 'HEAD'
  endif
  let l:gitfiles = s:System(['git', 'ls-tree', '-r', '--name-only', '--', l:revision], a:gitdir)
  return map(l:gitfiles, { _, f -> ({ 'name': f, 'path': simplify(a:gitdir . '/' . f ) }) })
endfunction

function! s:IsGitFile(filepath, gitdir, revision) abort
  let l:files = map(s:GetGitLsFiles(a:gitdir, a:revision),
  \ { _, v -> s:NormalizePath(fnamemodify(v.path, ':p')) })
  let l:path = s:NormalizePath(fnamemodify(simplify(a:filepath), ':p'))
  return index(l:files, l:path) != -1
endfunction

function! s:GetGitDiffFiles(filepath, gitdir, before, after) abort
  let l:command = ['git', 'diff', '--name-only', a:before, a:after]
  if !empty(a:filepath)
    if isdirectory(a:filepath)
      let l:gitpath = s:ToRelativePath(a:gitdir, a:filepath)
      if !empty(l:gitpath)
        call extend(l:command, ['--', l:gitpath])
      endif
    endif
  endif
  let l:gitfiles = s:System(l:command, a:gitdir)
  return map(l:gitfiles, { _, f -> ({ 'name': f, 'path': simplify(a:gitdir . '/' . f ) }) })
endfunction

function! s:GetInfoFromBufname(bufname) abort
  if a:bufname !~# '^gitdify://'
    return
  endif
  let l:filepath = split(a:bufname, ':')[-1]
  let l:revinfo = split(split(a:bufname, ':')[-2], '/', 1)[-3:-1]
  return {
  \ 'filepath': l:filepath,
  \ 'revision': {
  \   'cur': l:revinfo[0],
  \   'before': l:revinfo[1],
  \   'after': l:revinfo[2]
  \ }
  \}
endfunction

function! s:GetGitRevFileInfo(gitdir, filepath, revision, before, after) abort
  let l:gitpath = s:ToRelativePath(a:gitdir, a:filepath)
  let l:bufname = printf('gitdify://%s/%s/%s/%s:%s', a:gitdir, a:revision, a:before, a:after, l:gitpath)
  if s:IsGitFile(a:filepath, a:gitdir, a:revision)
    let l:param = printf('%s:%s', a:revision, l:gitpath)
    let l:lines = s:System(['git', 'show', l:param], a:gitdir)
  else
    let l:lines = []
  endif
  return {
  \ 'revision': a:revision,
  \ 'filepath': fnamemodify(a:filepath, ':p'),
  \ 'gitdir': a:gitdir,
  \ 'gitpath': l:gitpath,
  \ 'lines': l:lines,
  \ 'bufname': l:bufname
  \}
endfunction

function! s:OpenDiffWindow(info, winid) abort
  call win_execute(a:winid, printf('vsplit %s', fnameescape(a:info.bufname)))
  let l:diffbufid = bufnr(a:info.bufname)
  let l:diffwinid = sort(win_findbuf(l:diffbufid))[-1]

  call win_execute(a:winid, 'setlocal foldlevel=0')
  call win_execute(l:diffwinid, 'setlocal undolevels=-1 foldlevel=0 modifiable')
  call win_execute(l:diffwinid, ':%d_')
  call setbufline(l:diffbufid, 1, a:info.lines)
  call win_execute(l:diffwinid, 'setlocal buftype=nofile bufhidden=wipe noswapfile nobuflisted nomodifiable')

  call win_execute(l:diffwinid, 'diffthis')
  call win_execute(a:winid, 'diffthis')

  return l:diffwinid
endfunction

function! s:SetupDiffWondow(winid) abort
  call win_execute(a:winid, 'command! -nargs=0 -buffer'
  \ . ' GitdifyFiles call gitdify#OpenCommitFilesPopup()')
endfunction

function! s:OpenGitRevCurrentFileDiff(revision, filepath, gitdir, winid) abort
  let l:info = s:GetGitRevFileInfo(a:gitdir, a:filepath, a:revision, a:revision, '')
  let l:bufid = bufnr(a:filepath)
  let l:winid = a:winid

  call win_execute(l:winid, printf('tabedit %s', fnameescape(a:filepath)))
  let l:bufid = bufnr(a:filepath)
  let l:winid = sort(win_findbuf(l:bufid))[-1]

  let l:diffwinid = s:OpenDiffWindow(l:info, l:winid)
  call s:SetupDiffWondow(l:diffwinid)

  return l:winid
endfunction

function! s:OpenGitRevFileDiff(before, after, filepath, gitdir) abort
  let l:afinfo = s:GetGitRevFileInfo(a:gitdir, a:filepath, a:after, a:before, a:after)
  let l:bfinfo = s:GetGitRevFileInfo(a:gitdir, a:filepath, a:before, a:before, a:after)

  call win_execute(win_getid() ,printf('tabedit %s', fnameescape(l:bfinfo.bufname)))
  let l:bfbufnr = bufnr(l:bfinfo.bufname)
  let l:bfwinid = sort(win_findbuf(l:bfbufnr))[-1]
  call s:SetupDiffWondow(l:bfwinid)

  call win_execute(l:bfwinid, 'setlocal undolevels=-1 modifiable')
  call win_execute(l:bfwinid, ':%d_')
  call setbufline(l:bfbufnr, 1, l:bfinfo.lines)
  call win_execute(l:bfwinid, 'setlocal buftype=nofile bufhidden=wipe noswapfile nobuflisted nomodifiable')

  let l:diffwinid = s:OpenDiffWindow(l:afinfo, l:bfwinid)
  call s:SetupDiffWondow(l:diffwinid)

  return l:bfwinid
endfunction

function! s:CreatePopupObject(scope) abort
  let l:search = ''
  let l:meta = { 'pos': {}, 'result': 2 }
  let l:popup = extend(extend({}, l:), a:scope)

  function! l:popup.ItemList() dict abort
    return []
  endfunction

  function! l:popup.UpdateItems() dict abort
    let self.selects = map(self.ItemList(), { i, v -> extend({ 'id': i + 1 }, v) })
  endfunction

  function! l:popup.Items() dict abort
    let l:items = copy(self.selects)
    if len(self.search) > 0
      if get(g:, 'gitdify_filter_use_fuzzy', 0) == 1
        let l:items = matchfuzzy(l:items, self.search, { 'key': 'text' })
      else
        call filter(l:items, { _, v -> stridx(v.text, self.search) != -1 })
      endif
    endif
    return extend([{ 'text': self.search }], l:items)
  endfunction

  function! l:popup.KeyMap(id, key, enter) dict abort
    return 0
  endfunction

  function! l:popup.Filter(id, key) dict abort
    let l:key = a:key
    let l:result = line('.', a:id)
    let l:enter = 0
    let self.meta.pos = popup_getpos(a:id)
    let self.meta.result = l:result

    if strtrans(l:key) ==# l:key
      if l:key ==# "\<Space>"
        let self.search = self.search . l:key
        let l:key = ''
      else
        let self.search = self.search . l:key
      endif
    elseif l:key ==# "\<C-C>"
      call popup_close(a:id)
      return 1
    elseif l:key ==# "\<BS>" || l:key ==# "\<C-H>"
      let l:strlen = strchars(self.search)
      if l:strlen > 0
        let self.search = strcharpart(self.search, 0, l:strlen - 1)
      endif
    elseif l:key ==# "\<C-W>" || l:key ==# "\<DEL>"
      let self.search = ''
    elseif l:key ==# "\<Enter>"
      if l:result == 1
        return 1
      else
        let l:enter = 1
      endif
    elseif l:key ==# "\<C-J>"
      let l:key = "\<Down>"
    elseif l:key ==# "\<C-K>"
      let l:key = "\<Up>"
    elseif l:key ==# "\<C-X>"
      let l:key = "\<Esc>"
    endif

    if self.KeyMap(a:id, l:key, l:enter)
      return 1
    endif

    call popup_settext(a:id, map(self.Items(), { _, v -> v.text }))

    return popup_filter_menu(a:id, l:key)
  endfunction

  function! l:popup._Open() dict abort
    if !has_key(self, 'selects')
      call self.UpdateItems()
    endif

    let l:winid = popup_menu(map(self.Items(), { _, v -> v.text }), extend({
    \ 'callback': self.Callback,
    \ 'filter': self.Filter,
    \ 'pos': 'topleft',
    \ 'maxheight': &lines * 6 / 10,
    \ 'minheight': &lines * 6 / 10,
    \ 'maxwidth': &columns * 6 / 10,
    \ 'minwidth': &columns * 6 / 10,
    \ 'resize': 1,
    \ 'title': get(self.meta, 'title', '')
    \}, self.meta.pos))

    call win_execute(l:winid, printf(':%d', self.meta.result))
    return l:winid
  endfunction

  function! l:popup.Open() dict abort
    call self._Open()
  endfunction

  return l:popup
endfunction

function! s:CreateCommitFilesPopup(filepath, before, after, winid, bang, opener) abort
  let l:popup = s:CreatePopupObject(extend(extend({}, a:), l:))

  function! l:popup.ItemList() dict abort
    if !has_key(self, '_selects')
      if !has_key(self, 'gitdir')
        if has_key(self.opener, 'gitdir')
          let self.gitdir = self.opener.gitdir
        else
          let self.gitdir = s:GetGitDir(self.filepath)
        endif
      endif
      let self._selects = map(s:GetGitDiffFiles(
      \ self.filepath, self.gitdir, self.before, self.after),
      \ { _, v -> ({ 'text': v.name, 'val': v.path }) })
    endif
    return self._selects
  endfunction

  function! l:popup.OpenDiff(selected) dict abort
    try
      if self.bang
        return s:OpenGitRevCurrentFileDiff(self.after, a:selected.val, self.gitdir, self.winid)
      else
        return s:OpenGitRevFileDiff(self.before, self.after, a:selected.val, self.gitdir)
      endif
    catch /.*/
      call s:Catch(v:exception, v:throwpoint)
    endtry
  endfunction

  function! l:popup.Callback(id, result) dict abort
    try
      let l:selects = self.Items()
      if a:result > 1 && !empty(l:selects)
        let l:selected = l:selects[a:result - 1]
        call win_gotoid(self.OpenDiff(l:selected))
      elseif a:result != 0
        if type(get(self.opener, 'Open', '')) == type(function('tr'))
          call self.opener.Open()
        endif
      endif
    catch /.*/
      call s:Catch(v:exception, v:throwpoint)
    endtry
  endfunction

  function! l:popup.KeyMap(id, key, enter) dict abort
    if a:key ==# "\<Tab>"
      let l:result = self.meta.result
      if l:result > 1
        let l:selected = self.Items()[l:result - 1]
        call timer_start(1, { -> self.OpenDiff(l:selected) })
        call filter(self._selects, { _, v -> !(v.val is l:selected.val) })
        call self.UpdateItems()
      endif
    endif

    return 0
  endfunction

  return l:popup
endfunction

function! s:CreateCommitLogPopup(filepath, winid, bang, opener) abort
  let l:_all = 0
  let l:popup = s:CreatePopupObject(extend(extend({}, a:), l:))

  function! l:popup.ItemList() dict abort
    if !has_key(self, 'gitdir')
      let self.gitdir = s:GetGitDir(self.filepath)
    endif
    return map(s:GetGitFileLog(
    \ self.filepath, self.gitdir, self._all), { _, v -> ({ 'text': v, 'val': v }) })
  endfunction

  function! l:popup.Callback(id, result) dict abort
    try
      let l:selects = self.Items()
      if a:result > 1 && !empty(l:selects)
        let l:selected = l:selects[a:result - 1]
        let l:revision = split(l:selected.val, ' ')[0]
        let l:message = l:selected.val[len(l:revision) + 1:]
        let l:after = l:revision
        let l:before = len(self.selects) == l:selected.id ? s:EMPTY_HASH : l:revision . '~1'
        if !empty(self.filepath) && filereadable(self.filepath)
          if self.bang
            let l:winid = s:OpenGitRevCurrentFileDiff(l:revision, self.filepath, self.gitdir, self.winid)
            call win_gotoid(l:winid)
          else
            let l:winid = s:OpenGitRevFileDiff(l:before, l:after, self.filepath, self.gitdir)
            call win_gotoid(l:winid)
          endif
        else
          let l:files_popup = s:CreateCommitFilesPopup(
          \ self.filepath, l:before, l:after, self.winid, self.bang, self)
          let l:files_popup.meta.title = printf('[%s] %s', l:revision, l:message)
          call l:files_popup.Open()
        endif
      elseif a:result != 0
        if type(get(self.opener, 'Open', '')) == type(function('tr'))
          call self.opener.Open()
        endif
      endif
    catch /.*/
      call s:Catch(v:exception, v:throwpoint)
    endtry
  endfunction

  function! l:popup.KeyMap(id, key, enter) dict abort
    if a:key ==# "\<C-A>"
      let self._all = !self._all
      call self.UpdateItems()
    endif

    return 0
  endfunction

  function! l:popup.Open() dict abort
    let l:winid = self._Open()
    call win_execute(l:winid, 'setlocal syntax=gitrebase')
  endfunction

  return l:popup
endfunction

function! gitdify#OpenCommitFilesPopup() abort
  try
    let l:bufname = bufname()
    if l:bufname !~# '^gitdify://'
      return
    endif
    let l:info = s:GetInfoFromBufname(l:bufname)
    let l:popup = s:CreateCommitFilesPopup(
    \ l:info.filepath,
    \ l:info.revision.before,
    \ l:info.revision.after,
    \ win_getid(), empty(l:info.revision.after), {})
    call l:popup.Open()
  catch /.*/
    call s:Catch(v:exception, v:throwpoint)
  endtry
endfunction

function! gitdify#OpenCommitLogPopup(filepath, bang) abort
  try
    if !empty(a:filepath)
      let l:filepath = expand(a:filepath)
      if l:filepath =~# '^gitdify://'
        let l:info = s:GetInfoFromBufname(l:bufname)
        let l:filepath = l:info.filepath
      endif
    else
      let l:filepath = ''
    endif

    let l:logs_popup = s:CreateCommitLogPopup(l:filepath, win_getid(), a:bang, {})
    call l:logs_popup.Open()
  catch /.*/
    call s:Catch(v:exception, v:throwpoint)
  endtry
endfunction

