if exists('g:autoloaded_dispatch_neovim')
	finish
endif

let g:autoloaded_dispatch_neovim = 1

function! s:UsesTerminal(request)
	return a:request.action ==# 'start' ||
				\(a:request.action ==# 'make' && !a:request.background)
endfunction

function! s:NeedsOutput(request)
	return a:request.action ==# 'make'
endfunction

function! s:IsBackgroundJob(request)
	return a:request.action ==# 'make' && a:request.background
endfunction

function! s:CommandOptions(request) abort
	let opts = {
				\ 'name': a:request.title,
				\ 'background': a:request.background,
				\ 'request': a:request,
				\}
	let terminal_opts = { 'pty': 1, 'width': 80, 'height': 25 }

	if s:UsesTerminal(a:request)
		call extend(opts, terminal_opts)
	endif

	if s:NeedsOutput(a:request)
		if s:IsBackgroundJob(a:request)
			call extend(opts, {
						\ 'on_stdout': function('s:BufferOutput'),
						\ 'on_stderr': function('s:BufferOutput'),
						\ 'on_exit': function('s:JobExit'),
						\ 'tempfile': a:request.file,
						\ 'output': ''
						\})
		else
			call extend(opts, {
						\ 'on_exit': function('s:JobExit'),
						\ 'tempfile': a:request.file,
						\})
		endif
	endif
	return opts
endfunction

function! s:SaveCurrentBufferPid(request)
	let pid = get(b:, 'terminal_job_pid', 0)
	call writefile([pid], a:request.file . '.pid')
	let a:request.pid = pid " This is used by Start! (see g:DISPATCH_STARTS)
endfunction

function! dispatch#neovim#handle(request) abort
	let action = a:request.action
	let cmd = a:request.expanded
	let bg = a:request.background
	let opts = s:CommandOptions(a:request)
	if s:UsesTerminal(a:request)
		if s:NeedsOutput(a:request)
			if exists("g:test_term_buf_id")
				if bufexists(g:test_term_buf_id)
					" close any terminals from previous test runs
					execute 'silent bd! ' . g:test_term_buf_id
				endif
			endif
			execute 'botright split | enew | resize 15'
			let opts.buf_id = bufnr('%')
			call termopen(cmd, opts)
			call s:SaveCurrentBufferPid(a:request)
			" scroll to end
			execute 'norm! G' 
			execute 'wincmd p'
		else
			execute 'tabnew'
			call termopen(cmd, opts)
			call s:SaveCurrentBufferPid(a:request)
			if bg
				execute 'tabprev'
			else
				execute 'startinsert'
			endif
		endif
	else
		let l:job_id = jobstart(cmd, opts)

		" Create empty file in case there is no output
		call writefile([], a:request.file)

		" There is currently no way to get the pid in neovim when using
		" jobstart. See: https://github.com/neovim/neovim/issues/557
		" Use job id as pid for now.
		call writefile([l:job_id], a:request.file.'.pid')
	endif
	return 1
endfunction

function! s:FindBufferByPID(pid) abort
	let bufcount = bufnr('$')
	for b in range(1, bufcount)
		if buflisted(b)
			if a:pid == getbufvar(b, 'terminal_job_pid', -1) + 0
				return b
			endif
		endif
	endfor
	return 0
endfunction

function! dispatch#neovim#activate(pid) abort
	let l:buf = s:FindBufferByPID(a:pid)
	if buf > 0
		for t in range(1, tabpagenr('$'))
			if index(tabpagebuflist(t), l:buf) != -1
				" When we find the buffer, switch to the right tab and window
				execute 'normal! '.t.'gt'
				execute bufwinnr(l:buf).'wincmd w'
				return 1
			endif
		endfor
	else
		" Program was not found among the buffers so nothing to activate
		return 0
	endif
endfunction

" Remove newlines and merge lines without newlines
function! s:FilterNewlines(lines, state) abort
	" commenting this code to fix Copen with background execution, see:
	" https://github.com/radenling/vim-dispatch-neovim/issues/8#issuecomment-360969208

	" let l:lines = []
	" for line in a:lines
	" 	let l:line_without_newline = substitute(line, '\n\|\r', '', 'g')
	" 	let a:state.output .= l:line_without_newline
	" 	if line =~ '\n\|\r'
	" 		call add(l:lines, a:state.output)
	" 		let a:state.output = ''
	" 	endif
	" endfor
	" return l:lines
	return a:lines
endfunction

function! s:RemoveANSI(lines)
	return map(a:lines, 'substitute(v:val, ''\e\[[0-9;]*[a-zA-Z]'', "", "g")')
endfunction

function! s:BufferOutput(job_id, data, event) dict abort
	let l:lines = a:data
	let l:lines = filter(l:lines, '!empty(v:val)')
	let l:lines = s:RemoveANSI(l:lines)
	let l:lines = s:FilterNewlines(l:lines, self)
	call writefile(l:lines, self.tempfile, "a")
endfunction

function! DispatchNeovimCleanup(buf_id, tempfile, data)
	let term_win = bufwinnr(a:buf_id)
	let cur_win = winnr()
	execute term_win . ' wincmd w'
	call feedkeys("\<C-\>\<C-n>", 'n')
	execute cur_win . ' wincmd w'
	let g:test_term_buf_id = a:buf_id
	" close the terminal window
	silent execute term_win 'wincmd c'

	call writefile([a:data], a:tempfile . '.complete')
	call dispatch#complete(a:tempfile)
endfunction

function! s:JobExit(job_id, data, event) dict abort
	if s:UsesTerminal(self.request) && s:NeedsOutput(self.request)
		call writefile(getbufline(self.buf_id, 1, '$'), self.tempfile)
	endif

	" Clean up terminal window if visible
	if !self.background
		let term_win = bufwinnr(self.buf_id)
		if term_win != -1
			if &filetype == 'TelescopePrompt'
				" yolo
				let g:neovim_dispatch_buf_id = self.buf_id
				let g:neovim_dispatch_tempfile = self.tempfile
				let g:neovim_dispatch_data = a:data
				autocmd User TelescopePickerClose ++once call DispatchNeovimCleanup(g:neovim_dispatch_buf_id, g:neovim_dispatch_tempfile, g:neovim_dispatch_data)
			else
				call DispatchNeovimCleanup(self.buf_id, self.tempfile, a:data)
			endif
		endif
	endif
endfunction
