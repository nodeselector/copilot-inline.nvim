if vim.g.loaded_copilot_inline then
  return
end
vim.g.loaded_copilot_inline = true

vim.api.nvim_create_user_command("CopilotComment", function(opts)
  require("copilot-inline").comment(opts)
end, { range = true, nargs = "*", desc = "Send inline comment to Copilot session" })

vim.api.nvim_create_user_command("CopilotConnect", function()
  require("copilot-inline").connect()
end, { desc = "Connect to Copilot App WebSocket" })

vim.api.nvim_create_user_command("CopilotDisconnect", function()
  require("copilot-inline").disconnect()
end, { desc = "Disconnect from Copilot App WebSocket" })

vim.api.nvim_create_user_command("CopilotStatus", function()
  require("copilot-inline").status()
end, { desc = "Show Copilot inline connection status" })

vim.api.nvim_create_user_command("CopilotReplies", function()
  require("copilot-inline").toggle_replies()
end, { desc = "Toggle inline reply virtual text" })

vim.api.nvim_create_user_command("CopilotThread", function()
  require("copilot-inline").view_thread()
end, { desc = "View comment thread on current line" })

vim.api.nvim_create_user_command("CopilotComments", function()
  require("copilot-inline").list_comments()
end, { desc = "List all inline comments in quickfix" })
