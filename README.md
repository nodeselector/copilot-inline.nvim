# copilot-inline.nvim

> ⚠️ **Heads up** — this plugin was built almost entirely by a robot (Claude, via
> GitHub Copilot). It works, but it's rough around the edges. Use at your own risk,
> expect sharp corners, and PRs welcome if you find something busted.

Send inline review comments to the [GitHub Copilot App](https://github.com/githubnext/copilot-app)
from Neovim. Comments show up in the app's diff view and trigger the agent to
respond — replies stream back as virtual text in your buffer.

Think of it as code review from your editor, with an AI on the other end.

## Requirements

- Node.js 22+ (for native `WebSocket`)
- GitHub Copilot App running locally

## Install

```lua
-- lazy.nvim
{
  "nodeselector/copilot-inline.nvim",
  keys = {
    { "<leader>ic", function() require("copilot-inline").comment({ range = 0 }) end, desc = "Inline comment" },
    { "<leader>ic", function()
        local s, e = vim.fn.line("v"), vim.fn.line(".")
        if s > e then s, e = e, s end
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
        require("copilot-inline").comment({ range = 2, line1 = s, line2 = e })
      end, mode = "x", desc = "Inline comment (range)" },
    { "<leader>ix", function() require("copilot-inline").connect() end, desc = "Connect" },
    { "<leader>is", function() require("copilot-inline").status() end, desc = "Status" },
    { "<leader>ir", function() require("copilot-inline").toggle_replies() end, desc = "Toggle replies" },
    { "<leader>it", function() require("copilot-inline").view_thread() end, desc = "View thread" },
    { "<leader>il", function() require("copilot-inline").list_comments() end, desc = "List comments" },
  },
  config = function()
    require("copilot-inline").setup({ auto_connect = true })
  end,
}
```

## Usage

1. Open a file in a repo with an active Copilot App session
2. `<leader>ix` to connect (or `auto_connect = true` to skip this)
3. `<leader>ic` on a line — opens a floating markdown editor
4. `<C-s>` to send, `<Esc>`/`q` to cancel
5. Comment appears in the app UI → agent responds → reply shows as virtual text

Other keymaps: `<leader>ir` toggle replies, `<leader>it` view thread, `<leader>il` list all comments.

## How it works

```
nvim (lua)  ──stdin──▶  bridge.mjs  ──WebSocket──▶  Copilot App
            ◀─stdout──             ◀──────────────
```

The bridge connects to the app's local WebSocket (reads port/token from
`~/.copilot/run/`). The plugin matches your cwd against the app's workspace
list to figure out which session to talk to.

Each comment does two things: persists to the app's DB (`save_inline_review_comment`)
and triggers the agent (`send_message`). Replies come back via `inline_review_reply_saved`.

## Config

```lua
require("copilot-inline").setup({
  node = "node",        -- path to node binary
  auto_connect = false, -- connect on first keymap use
  reply_hl = "Comment", -- highlight group for virtual text replies
})
```

## Commands

| Command | What it does |
|---------|-------------|
| `:CopilotConnect` | Connect to the running app |
| `:CopilotComment [text]` | Comment on current line / visual selection |
| `:CopilotStatus` | Connection + workspace info |
| `:CopilotReplies` | Toggle reply virtual text |
| `:CopilotThread` | View comment + reply in a float |
| `:CopilotComments` | List all comments in quickfix |
| `:CopilotDisconnect` | Disconnect |

## License

MIT
