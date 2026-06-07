--- copilot-inline.nvim — send inline review comments to the GitHub Copilot App.
--- Comments appear in the app's diff view and trigger the agent to respond.
--- Agent replies stream back and are shown as virtual text in nvim.

local M = {}

-- ──────────────────────────── state ────────────────────────────

local bridge_job = nil
local connected = false
local workspaces = {} -- { id, path, name, branch, session? }[]
local resolved_ws = nil -- workspace matched to cwd
local session_id = nil -- active session for resolved workspace
local ns = vim.api.nvim_create_namespace("copilot_inline")
local show_replies = true
local stdout_buf = "" -- incremental line buffer for partial reads
local comment_lines = {} -- comment_id → { bufnr, line }
local stored_replies = {} -- comment_id → display string
local stored_comments = {} -- comment_id → { file, line, text, reply }
local last_sent_comment_id = nil -- for error correlation

-- ──────────────────────────── config ────────────────────────────

local config = {
  node = "node",
  auto_connect = false,
  reply_hl = "Comment",
}

function M.setup(opts)
  config = vim.tbl_deep_extend("force", config, opts or {})
  if config.auto_connect then
    M.connect()
  end
end

-- ──────────────────────────── bridge ────────────────────────────

local function bridge_path()
  local info = debug.getinfo(1, "S")
  local src = info.source:sub(2)
  local plugin_root = vim.fn.fnamemodify(src, ":h:h:h")
  return plugin_root .. "/bridge.mjs"
end

local function send(msg)
  if not bridge_job then
    vim.notify("[copilot-inline] not connected", vim.log.levels.WARN)
    return false
  end
  local json = vim.json.encode(msg)
  local ok = vim.fn.chansend(bridge_job, json .. "\n")
  if ok == 0 then
    vim.notify("[copilot-inline] bridge dead, reconnecting…", vim.log.levels.WARN)
    bridge_job = nil
    connected = false
    vim.schedule(function() M.connect() end)
    return false
  end
  return true
end

local function on_stdout(_, data, _)
  if not data or #data == 0 then return end
  -- Neovim splits on newlines: data = { "partial", "line2", "line3", "" }
  -- data[1] completes the previous incomplete line in stdout_buf.
  -- data[2..n] are new line starts. An empty trailing element means the
  -- prior element ended with a newline (complete line).
  stdout_buf = stdout_buf .. data[1]
  for i = 2, #data do
    if stdout_buf ~= "" then
      local ok, msg = pcall(vim.json.decode, stdout_buf)
      if ok then
        M._handle_message(msg)
      end
    end
    stdout_buf = data[i]
  end
end

local function on_stderr(_, data, _)
  for _, line in ipairs(data) do
    if line ~= "" then
      vim.schedule(function()
        vim.notify("[copilot-inline] " .. line, vim.log.levels.DEBUG)
      end)
    end
  end
end

local function on_exit(_, code, _)
  bridge_job = nil
  connected = false
  stdout_buf = ""
  vim.schedule(function()
    if code ~= 0 then
      vim.notify("[copilot-inline] bridge exited (" .. code .. ")", vim.log.levels.WARN)
    end
  end)
end

function M.connect()
  if bridge_job then
    vim.notify("[copilot-inline] already connected", vim.log.levels.INFO)
    return
  end
  local script = bridge_path()
  bridge_job = vim.fn.jobstart({ config.node, script }, {
    on_stdout = on_stdout,
    on_stderr = on_stderr,
    on_exit = on_exit,
    stdout_buffered = false,
    stderr_buffered = false,
  })
  if bridge_job <= 0 then
    bridge_job = nil
    vim.notify("[copilot-inline] failed to start bridge", vim.log.levels.ERROR)
  end
end

function M.disconnect()
  if bridge_job then
    vim.fn.jobstop(bridge_job)
    bridge_job = nil
    connected = false
    session_id = nil
    vim.notify("[copilot-inline] disconnected", vim.log.levels.INFO)
  end
end

function M.status()
  local parts = {}
  if connected then
    table.insert(parts, "connected")
  else
    vim.notify("[copilot-inline] disconnected", vim.log.levels.INFO)
    return
  end
  if resolved_ws then
    table.insert(parts, "workspace: " .. (resolved_ws.name or resolved_ws.id))
  else
    table.insert(parts, "no workspace matched")
  end
  if session_id then
    table.insert(parts, "session: " .. session_id:sub(1, 8) .. "…")
  else
    table.insert(parts, "no active session")
  end
  vim.notify("[copilot-inline] " .. table.concat(parts, " | "), vim.log.levels.INFO)
end

-- ──────────────────────────── message handling ────────────────────────────

function M._handle_message(msg)
  local t = msg.type

  if t == "__connected" then
    connected = true
    vim.schedule(function()
      vim.notify("[copilot-inline] connected", vim.log.levels.INFO)
    end)
    send({ type = "list_workspaces" })
    return
  end

  if t == "__error" then
    vim.schedule(function()
      vim.notify("[copilot-inline] " .. (msg.message or "bridge error"), vim.log.levels.ERROR)
    end)
    return
  end

  -- App-side error (e.g. send_message failed because session is dead)
  if t == "error" then
    local err_msg = msg.message or "unknown error"
    local err_sid = msg.session_id
    vim.schedule(function()
      vim.notify("[copilot-inline] ❌ " .. err_msg, vim.log.levels.ERROR)
      -- If error references our session, mark pending comments as failed
      if err_sid and err_sid == session_id then
        M._mark_last_comment_failed()
      end
    end)
    return
  end

  if t == "workspace_list" then
    workspaces = msg.workspaces or {}
    vim.schedule(function() M._resolve_workspace() end)
    return
  end

  -- Response to get_workspace_session
  if t == "workspace_session" then
    local s = msg.session
    if s then
      session_id = s.sessionId or s.session_id
      vim.schedule(function()
        vim.notify("[copilot-inline] session: " .. (session_id or "?"):sub(1, 8) .. "…", vim.log.levels.INFO)
      end)
    end
    return
  end

  if t == "inline_review_reply_saved" then
    vim.schedule(function() M._show_reply(msg.reply) end)
    return
  end

  if t == "inline_review_comments" then
    vim.schedule(function() M._hydrate_from_ws(msg.comments or {}) end)
    return
  end

  -- Session lifecycle — re-resolve when sessions start/stop so session_id stays fresh
  if t == "session_started" or t == "session_stopped" or t == "session_removed" then
    local sid = msg.session_id or msg.sessionId
    if t == "session_started" then
      -- A new session started — re-resolve to pick up resumed/new sessions for our workspace
      vim.schedule(function()
        local old_sid = session_id
        send({ type = "list_workspaces" })
        -- After re-resolve completes (async), _resolve_workspace will update session_id.
        -- If it changed, we'll log it there.
      end)
    elseif sid and sid == session_id then
      -- Our session died — clear stale id and re-resolve
      vim.schedule(function()
        vim.notify("[copilot-inline] session ended, re-resolving…", vim.log.levels.WARN)
        session_id = nil
        send({ type = "list_workspaces" })
      end)
    end
    return
  end
end

-- ──────────────────────────── workspace resolution ────────────────────────────

function M._resolve_workspace()
  local cwd = vim.fn.resolve(vim.fn.getcwd())
  local git_root = vim.fn.resolve(vim.fn.systemlist("git rev-parse --show-toplevel")[1] or cwd)

  local best, best_len = nil, 0
  for _, ws in ipairs(workspaces) do
    local p = vim.fn.resolve(ws.path or "")
    if p ~= "" then
      -- Longest prefix match with path boundary
      if vim.startswith(cwd, p) or vim.startswith(p, cwd)
          or vim.startswith(git_root, p) or vim.startswith(p, git_root) then
        if #p > best_len then
          best = ws
          best_len = #p
        end
      end
    end
  end

  resolved_ws = best
  if not best then return end

  vim.notify("[copilot-inline] workspace: " .. (best.name or best.id), vim.log.levels.INFO)

  local old_session_id = session_id

  -- Extract session_id from workspace_list payload (nested Option<Option<>>)
  local s = best.session
  if s then
    session_id = s.sessionId or s.session_id
  else
    -- Fetch it explicitly
    send({ type = "get_workspace_session", workspace_id = best.id })
  end

  -- Hydrate existing comments from the DB
  M._hydrate_comments()

  -- Detect session change (resume scenario) and warn about orphaned comments
  if old_session_id and session_id and old_session_id ~= session_id then
    vim.notify(
      "[copilot-inline] session changed (resume?). Use :CopilotResend to re-deliver unreplied comments.",
      vim.log.levels.WARN
    )
  end
end

-- ──────────────────────────── helpers (declared early for hydration) ────

local function git_relative_path(filepath)
  local root = vim.fn.systemlist("git rev-parse --show-toplevel")[1]
  if not root or root == "" then return filepath end
  if vim.startswith(filepath, root) then
    return filepath:sub(#root + 2):gsub("\\", "/")
  end
  return filepath:gsub("\\", "/")
end

-- ──────────────────────────── DB hydration ────────────────────────────

--- Fetch existing comments from the app's SQLite DB via WS on connect.
function M._hydrate_comments()
  if not resolved_ws then return end
  send({ type = "get_inline_review_comments", workspace_id = resolved_ws.id })
end

--- Process hydrated comments from the app DB.
function M._hydrate_from_ws(comments)
  local count = 0
  for _, c in ipairs(comments) do
    local cid = c.id
    if not stored_comments[cid] then
      -- Skip agent-originated comments
      if not c.isAgentComment and not c.is_agent_comment then
        stored_comments[cid] = {
          file = c.filePath or c.file_path or "",
          line_start = c.lineStart or c.line_start or c.line or 0,
          line_end = c.lineEnd or c.line_end or c.lineStart or c.line_start or 0,
          text = c.text or "",
          reply = nil,
        }

        -- Hydrate replies
        local replies = c.replies or {}
        for _, r in ipairs(replies) do
          local content = r.content or ""
          stored_comments[cid].reply = content
          -- Store display string for virtual text
          local lines = vim.split(content, "\n")
          local display = lines[1] or ""
          if #lines > 1 then display = display .. " [+" .. (#lines - 1) .. " lines]" end
          if #display > 120 then display = display:sub(1, 117) .. "..." end
          stored_replies[cid] = display
        end

        -- Place extmarks on matching open buffers
        local ls = stored_comments[cid].line_start
        if ls and ls > 0 then
          local file = stored_comments[cid].file
          for _, buf in ipairs(vim.api.nvim_list_bufs()) do
            if vim.api.nvim_buf_is_loaded(buf) then
              local name = vim.api.nvim_buf_get_name(buf)
              local rel = git_relative_path(name)
              if rel == file then
                comment_lines[cid] = { bufnr = buf, line = ls - 1 }
                local vt
                if stored_replies[cid] then
                  vt = { { " 🤖 " .. stored_replies[cid], config.reply_hl } }
                else
                  vt = { { " 💬 sent", "DiagnosticInfo" } }
                end
                vim.api.nvim_buf_set_extmark(buf, ns, ls - 1, 0, {
                  virt_text = vt,
                  virt_text_pos = "eol",
                })
                break
              end
            end
          end
        end

        count = count + 1
      end
    end
  end
  if count > 0 then
    vim.notify(string.format("[copilot-inline] hydrated %d comment(s) from DB", count), vim.log.levels.INFO)
  end
end

-- ──────────────────────────── helpers ────────────────────────────

local function uuid()
  local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
  return (template:gsub("[xy]", function(c)
    local v = (c == "x") and math.random(0, 0xf) or math.random(8, 0xb)
    return string.format("%x", v)
  end))
end

--- Get unified diff context around specific lines
local function get_diff_context(filepath, line_start, line_end)
  local diff = vim.fn.systemlist(
    string.format("git diff HEAD -- %s 2>/dev/null", vim.fn.shellescape(filepath))
  )
  if diff and #diff > 0 then
    return table.concat(diff, "\n")
  end
  local buf_lines = vim.api.nvim_buf_get_lines(0, math.max(0, line_start - 4), line_end + 3, false)
  local result = {}
  for i, l in ipairs(buf_lines) do
    local actual_line = line_start - 3 + i
    local prefix = (actual_line >= line_start and actual_line <= line_end) and ">" or " "
    table.insert(result, string.format("%s %4d | %s", prefix, actual_line, l))
  end
  return table.concat(result, "\n")
end

--- Build a review prompt similar to the app's buildInlineReviewPrompt
local function build_review_prompt(comment_id, thread_id, thread_token, reply_to_id,
                                    file_path, line_start, line_end, user_comment, diff_context, ws_id)
  local line_label
  if line_start == line_end then
    line_label = string.format("Line: %d", line_start)
  else
    line_label = string.format("Lines: %d-%d", line_start, line_end)
  end

  return string.format([[
[INLINE CODE REVIEW]

Address the user's comment about selected lines in a diff.

	Comment ID: %s
	Thread ID: %s
	Thread token: %s
	Replying to message: %s
	File: %s
	%s
	- Workspace ID: %s

User comment:
"%s"

Selected diff:
%s

ACTION-FIRST WORKFLOW (this is your own code — you are the author):
	- If the user requests a change, fix, or improvement: make the code change FIRST using your editing tools, then call reply_to_comment to summarize what you changed and why.
	- If the user is asking a question or requesting clarification: answer it directly via reply_to_comment.
	- If you cannot safely make the requested change, explain the blocker in your reply_to_comment response — but default to action when the request is clear and safe.

INSTRUCTIONS:
	1. Use the exact Thread ID above; include Comment ID for compatibility.
	2. Always finish by calling reply_to_comment with:
	   - threadId: "%s"
	   - commentId: "%s"
	   - threadToken: "%s"
	   - workspaceId: "%s"
	   - replyToMessageId: "%s"
	   - response: a summary of what you did, or your answer

Do not reply directly in chat. Always call reply_to_comment as the final step.
Pass replyToMessageId through verbatim.
After reply_to_comment returns, immediately end your turn.]],
    comment_id, thread_id, thread_token or "(not provided)", reply_to_id,
    file_path, line_label, ws_id or "(not provided)",
    user_comment, diff_context,
    thread_id, comment_id, thread_token or "", ws_id or "", reply_to_id
  )
end

-- ──────────────────────────── comment editor ────────────────────────────

--- Open a floating scratch buffer for writing multi-line comments.
--- On submit (<C-CR> or :w), sends the comment and closes the float.
function M._open_comment_editor(line_start, line_end)
  local parent_buf = vim.api.nvim_get_current_buf()
  local filepath = vim.api.nvim_buf_get_name(parent_buf)
  local rel_path = git_relative_path(filepath)

  local width = math.min(math.max(64, math.floor(vim.o.columns * 0.54)), math.max(64, vim.o.columns - 8))
  local height = math.max(8, math.floor(vim.o.lines * 0.24))
  local row = math.max(1, math.floor((vim.o.lines - height) / 2 - 1))
  local col = math.max(0, math.floor((vim.o.columns - width) / 2))

  local float_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[float_buf].buftype = "nofile"
  vim.bo[float_buf].bufhidden = "wipe"
  vim.bo[float_buf].swapfile = false
  vim.bo[float_buf].filetype = "markdown"

  local line_label = line_start == line_end
    and string.format("L%d", line_start)
    or string.format("L%d-L%d", line_start, line_end)
  local title = string.format(" %s · %s ", vim.fn.fnamemodify(rel_path, ":t"), line_label)

  local win = vim.api.nvim_open_win(float_buf, true, {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = title,
    title_pos = "center",
    footer = " Type freely · <C-s> send · <Esc>/q cancel ",
    footer_pos = "center",
  })
  vim.wo[win].wrap = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].cursorline = false
  vim.wo[win].signcolumn = "no"

  local done = false
  local function finish(text)
    if done then return end
    done = true
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
    if text then
      M._send_comment(parent_buf, filepath, rel_path, line_start, line_end, text)
    end
  end

  local function save()
    if not vim.api.nvim_buf_is_valid(float_buf) then
      finish(nil)
      return
    end
    local lines = vim.api.nvim_buf_get_lines(float_buf, 0, -1, false)
    local text = vim.trim(table.concat(lines, "\n"))
    if text == "" then
      vim.notify("[copilot-inline] empty comment, cancelled", vim.log.levels.INFO)
      return
    end
    finish(text)
  end

  local function cancel()
    finish(nil)
  end

  vim.keymap.set({ "n", "i" }, "<C-s>", save, { buffer = float_buf, silent = true, desc = "Send comment" })
  vim.keymap.set("n", "<CR>", save, { buffer = float_buf, silent = true, desc = "Send comment" })
  vim.keymap.set("n", "<Esc>", cancel, { buffer = float_buf, silent = true, desc = "Cancel comment" })
  vim.keymap.set("n", "q", cancel, { buffer = float_buf, silent = true, desc = "Cancel comment" })
  vim.keymap.set("n", "<C-c>", cancel, { buffer = float_buf, silent = true, desc = "Cancel comment" })

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = float_buf,
    once = true,
    callback = save,
  })

  vim.cmd("startinsert")
end

--- Update the last sent comment's extmark to show a failure indicator.
function M._mark_last_comment_failed()
  local cid = last_sent_comment_id
  if not cid then return end
  local cl = comment_lines[cid]
  if not cl or not vim.api.nvim_buf_is_valid(cl.bufnr) then return end
  vim.api.nvim_buf_set_extmark(cl.bufnr, ns, cl.line, 0, {
    virt_text = { { " ❌ send failed", "DiagnosticError" } },
    virt_text_pos = "eol",
  })
end

--- Internal: send a comment (shared by both inline text and editor paths).
function M._send_comment(bufnr, filepath, rel_path, line_start, line_end, text)
  local comment_id = "nvim-" .. uuid()
  local thread_id = "thread:" .. comment_id
  local thread_token = "nvim:" .. resolved_ws.id .. ":" .. uuid()
  local now = os.date("!%Y-%m-%dT%H:%M:%S.000Z")

  local ok1 = send({
    type = "save_inline_review_comment",
    comment = {
      id = comment_id,
      workspaceId = resolved_ws.id,
      filePath = rel_path,
      lineStart = line_start,
      lineEnd = line_end,
      text = text,
      createdAt = now,
      status = "investigating",
      replies = {},
      isAgentComment = false,
      severity = "info",
      threadToken = thread_token,
    },
  })

  if not ok1 then
    vim.notify("[copilot-inline] ❌ failed to save comment (bridge dead)", vim.log.levels.ERROR)
    return
  end

  local diff_context = get_diff_context(filepath, line_start, line_end)
  local prompt = build_review_prompt(
    comment_id, thread_id, thread_token, comment_id,
    rel_path, line_start, line_end, text, diff_context, resolved_ws.id
  )

  local ok2 = send({
    type = "send_message",
    session_id = session_id,
    prompt = prompt,
    mode = "enqueue",
  })

  local mark_text = ok2
    and { { " 💬 sent", "DiagnosticInfo" } }
    or { { " ⚠️ saved but send failed", "DiagnosticWarn" } }

  vim.api.nvim_buf_set_extmark(bufnr, ns, line_start - 1, 0, {
    virt_text = mark_text,
    virt_text_pos = "eol",
  })

  last_sent_comment_id = comment_id
  comment_lines[comment_id] = { bufnr = bufnr, line = line_start - 1 }
  stored_comments[comment_id] = {
    file = rel_path,
    line_start = line_start,
    line_end = line_end,
    text = text,
    reply = nil,
  }

  vim.notify(
    string.format("[copilot-inline] comment sent on %s:%d", rel_path, line_start),
    vim.log.levels.INFO
  )
end

-- ──────────────────────────── comment creation ────────────────────────────

function M.comment(opts)
  if not connected then
    M.connect()
    -- Poll for connection (up to 5 seconds)
    local attempts = 0
    local timer = vim.uv.new_timer()
    timer:start(500, 500, vim.schedule_wrap(function()
      attempts = attempts + 1
      if connected then
        timer:stop()
        timer:close()
        M.comment(opts)
        return
      end
      if attempts >= 10 then
        timer:stop()
        timer:close()
        vim.notify("[copilot-inline] could not connect — is the Copilot App running?", vim.log.levels.ERROR)
      end
    end))
    return
  end

  if not resolved_ws then
    vim.notify("[copilot-inline] no workspace matched — is the Copilot App running with this repo?", vim.log.levels.ERROR)
    return
  end

  if not session_id then
    vim.notify("[copilot-inline] no active session for this workspace", vim.log.levels.ERROR)
    return
  end

  local line_start, line_end
  if opts.range == 2 then
    line_start = opts.line1
    line_end = opts.line2
  else
    line_start = vim.fn.line(".")
    line_end = line_start
  end

  local text = opts.args and opts.args ~= "" and opts.args or nil
  if not text then
    M._open_comment_editor(line_start, line_end)
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local filepath = vim.api.nvim_buf_get_name(bufnr)
  local rel_path = git_relative_path(filepath)
  M._send_comment(bufnr, filepath, rel_path, line_start, line_end, text)
end

-- ──────────────────────────── reply display ────────────────────────────

function M._show_reply(reply)
  if not reply then return end

  local comment_id = reply.commentId or reply.comment_id
  if not comment_id then return end

  local content = reply.content or ""
  local lines = vim.split(content, "\n")
  local display = lines[1] or ""
  if #lines > 1 then
    display = display .. " [+" .. (#lines - 1) .. " lines]"
  end
  if #display > 120 then
    display = display:sub(1, 117) .. "..."
  end

  -- Store for toggle re-render
  stored_replies[comment_id] = display

  -- Store full reply for thread viewer
  if stored_comments[comment_id] then
    stored_comments[comment_id].reply = content
  end

  if not show_replies then return end

  M._render_reply(comment_id, display)
  vim.notify("[copilot-inline] reply received", vim.log.levels.INFO)
end

function M._render_reply(comment_id, display)
  local info = comment_lines[comment_id]
  if info and vim.api.nvim_buf_is_valid(info.bufnr) then
    local marks = vim.api.nvim_buf_get_extmarks(info.bufnr, ns, { info.line, 0 }, { info.line, -1 }, {})
    if #marks > 0 then
      for _, mark in ipairs(marks) do
        vim.api.nvim_buf_set_extmark(info.bufnr, ns, info.line, 0, {
          id = mark[1],
          virt_text = { { " 🤖 " .. display, config.reply_hl } },
          virt_text_pos = "eol",
        })
      end
    else
      vim.api.nvim_buf_set_extmark(info.bufnr, ns, info.line, 0, {
        virt_text = { { " 🤖 " .. display, config.reply_hl } },
        virt_text_pos = "eol",
      })
    end
  end
end

function M.toggle_replies()
  show_replies = not show_replies
  if not show_replies then
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(bufnr) then
        vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
      end
    end
    vim.notify("[copilot-inline] replies hidden", vim.log.levels.INFO)
  else
    -- Re-render all stored replies and sent markers
    for cid, display in pairs(stored_replies) do
      M._render_reply(cid, display)
    end
    -- Re-render "sent" markers for comments without replies
    for cid, info in pairs(comment_lines) do
      if not stored_replies[cid] and vim.api.nvim_buf_is_valid(info.bufnr) then
        vim.api.nvim_buf_set_extmark(info.bufnr, ns, info.line, 0, {
          virt_text = { { " 💬 sent", "DiagnosticInfo" } },
          virt_text_pos = "eol",
        })
      end
    end
    vim.notify("[copilot-inline] replies visible", vim.log.levels.INFO)
  end
end

-- ──────────────────────────── thread viewer ────────────────────────────

--- Show thread for comment on current line in a floating window.
function M.view_thread()
  local bufnr = vim.api.nvim_get_current_buf()
  local cursor_line = vim.fn.line(".") - 1

  -- Find comment on this line
  local found_id = nil
  for cid, info in pairs(comment_lines) do
    if info.bufnr == bufnr and info.line == cursor_line then
      found_id = cid
      break
    end
  end

  if not found_id then
    vim.notify("[copilot-inline] no comment on this line", vim.log.levels.INFO)
    return
  end

  local comment = stored_comments[found_id]
  if not comment then
    vim.notify("[copilot-inline] comment data not found", vim.log.levels.WARN)
    return
  end

  -- Build thread content with word wrapping
  local max_width = math.min(72, math.floor(vim.o.columns * 0.7))
  local text_width = max_width - 4

  local function wrap_text(text, width)
    local result = {}
    for _, raw_line in ipairs(vim.split(text, "\n")) do
      if #raw_line <= width then
        table.insert(result, raw_line)
      else
        local pos = 1
        while pos <= #raw_line do
          if pos + width - 1 >= #raw_line then
            table.insert(result, raw_line:sub(pos))
            break
          end
          local break_at = raw_line:sub(pos, pos + width - 1):match(".*()%s")
          if not break_at or break_at < width * 0.3 then
            break_at = width
          end
          table.insert(result, raw_line:sub(pos, pos + break_at - 1))
          pos = pos + break_at
          while pos <= #raw_line and raw_line:sub(pos, pos) == " " do pos = pos + 1 end
        end
      end
    end
    return result
  end

  local content = {}
  local hl_ranges = {}

  table.insert(content, "💬 You")
  table.insert(hl_ranges, { #content - 1, "Title" })
  table.insert(content, (comment.file or "?") .. ":" .. (comment.line_start or "?"))
  table.insert(hl_ranges, { #content - 1, "Comment" })
  table.insert(content, "")

  for _, line in ipairs(wrap_text(comment.text, text_width)) do
    table.insert(content, "  " .. line)
  end

  if comment.reply then
    table.insert(content, "")
    table.insert(content, string.rep("─", max_width - 2))
    table.insert(hl_ranges, { #content - 1, "Comment" })
    table.insert(content, "")
    table.insert(content, "🤖 Agent")
    table.insert(hl_ranges, { #content - 1, "Title" })
    table.insert(content, "")
    for _, line in ipairs(wrap_text(comment.reply, text_width)) do
      table.insert(content, "  " .. line)
    end
  else
    table.insert(content, "")
    table.insert(content, "⏳ Waiting for reply...")
    table.insert(hl_ranges, { #content - 1, "DiagnosticInfo" })
  end

  local float_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(float_buf, 0, -1, false, content)
  vim.bo[float_buf].modifiable = false
  vim.bo[float_buf].bufhidden = "wipe"
  vim.bo[float_buf].filetype = "markdown"

  local height = math.min(#content, math.floor(vim.o.lines * 0.6))

  local win = vim.api.nvim_open_win(float_buf, true, {
    relative = "editor",
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - max_width) / 2),
    width = max_width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " Thread ",
    title_pos = "center",
    footer = " q close ",
    footer_pos = "center",
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true

  local hl_ns = vim.api.nvim_create_namespace("copilot_inline_thread")
  for _, hl in ipairs(hl_ranges) do
    vim.api.nvim_buf_add_highlight(float_buf, hl_ns, hl[2], hl[1], 0, -1)
  end

  -- Close on q or Esc
  vim.keymap.set("n", "q", function()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
  end, { buffer = float_buf })
  vim.keymap.set("n", "<Esc>", function()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
  end, { buffer = float_buf })
end

--- List all comments in a picker / quickfix list.
function M.list_comments()
  local items = {}
  for cid, comment in pairs(stored_comments) do
    local status = stored_replies[cid] and "✅" or "⏳"
    table.insert(items, {
      filename = comment.file,
      lnum = comment.line_start,
      text = status .. " " .. comment.text,
      comment_id = cid,
    })
  end

  if #items == 0 then
    vim.notify("[copilot-inline] no comments in this session", vim.log.levels.INFO)
    return
  end

  table.sort(items, function(a, b)
    if a.filename ~= b.filename then return a.filename < b.filename end
    return a.lnum < b.lnum
  end)

  vim.fn.setqflist(items, "r")
  vim.fn.setqflist({}, "a", { title = "Copilot Inline Comments" })
  vim.cmd("copen")
end

--- Re-send unreplied plugin-authored comments to the current session.
--- Only resends comments with nvim-* IDs (plugin-authored, not App-UI comments).
function M.resend()
  if not resolved_ws then
    vim.notify("[copilot-inline] not connected to a workspace", vim.log.levels.ERROR)
    return
  end
  if not session_id then
    vim.notify("[copilot-inline] no active session", vim.log.levels.ERROR)
    return
  end

  local candidates = {}
  for cid, comment in pairs(stored_comments) do
    -- Only resend plugin-authored comments (nvim-* prefix) that have no reply
    if vim.startswith(cid, "nvim-") and not stored_replies[cid] then
      table.insert(candidates, { id = cid, comment = comment })
    end
  end

  if #candidates == 0 then
    vim.notify("[copilot-inline] no unreplied plugin comments to resend", vim.log.levels.INFO)
    return
  end

  table.sort(candidates, function(a, b)
    if a.comment.file ~= b.comment.file then return a.comment.file < b.comment.file end
    return a.comment.line_start < b.comment.line_start
  end)

  local descriptions = {}
  for _, c in ipairs(candidates) do
    table.insert(descriptions, string.format("  %s:%d — %s",
      c.comment.file, c.comment.line_start,
      c.comment.text:sub(1, 60) .. (#c.comment.text > 60 and "…" or "")
    ))
  end

  vim.ui.select(
    { "Resend all (" .. #candidates .. ")", "Cancel" },
    {
      prompt = "Re-deliver unreplied comments to current session?\n" .. table.concat(descriptions, "\n") .. "\n",
    },
    function(choice)
      if not choice or choice:match("^Cancel") then return end

      local sent = 0
      for _, c in ipairs(candidates) do
        local cid = c.id
        local comment = c.comment
        local thread_id = "thread:" .. cid
        -- Reuse original thread_token if available, otherwise generate new
        local thread_token = "nvim:" .. resolved_ws.id .. ":" .. uuid()

        -- Find the file on disk to get diff context
        local filepath = nil
        local git_root = vim.fn.systemlist("git rev-parse --show-toplevel")[1] or ""
        if git_root ~= "" then
          filepath = git_root .. "/" .. comment.file
        end

        local diff_context = filepath and get_diff_context(filepath, comment.line_start, comment.line_end) or ""
        local prompt = build_review_prompt(
          cid, thread_id, thread_token, cid,
          comment.file, comment.line_start, comment.line_end,
          comment.text, diff_context, resolved_ws.id
        )

        local ok = send({
          type = "send_message",
          session_id = session_id,
          prompt = prompt,
          mode = "enqueue",
        })

        if ok then
          sent = sent + 1
          -- Update extmark if we have one
          local cl = comment_lines[cid]
          if cl and vim.api.nvim_buf_is_valid(cl.bufnr) then
            vim.api.nvim_buf_set_extmark(cl.bufnr, ns, cl.line, 0, {
              virt_text = { { " 💬 resent", "DiagnosticInfo" } },
              virt_text_pos = "eol",
            })
          end
        end
      end

      vim.notify(
        string.format("[copilot-inline] resent %d/%d comment(s) to session %s",
          sent, #candidates, (session_id or "?"):sub(1, 8)),
        vim.log.levels.INFO
      )
    end
  )
end

function M.debug()
  return {
    bridge_job = bridge_job,
    connected = connected,
    resolved_ws = resolved_ws,
    session_id = session_id,
    workspaces_count = #workspaces,
    stdout_buf_len = #stdout_buf,
  }
end

return M
