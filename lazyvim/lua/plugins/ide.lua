-- Curated Linux-as-IDE extras (spec §3.A "minimal but effective", not the
-- kitchen sink). The heavy lifting is LazyVim's defaults; these are the few
-- additions that make ssh-in feel like an IDE.
return {
  -- tmux <-> nvim seamless pane navigation (the human lives in tmux + nvim).
  { "christoomey/vim-tmux-navigator", lazy = false },
  -- lazygit from inside nvim (the binary is baked in the image).
  {
    "kdheepak/lazygit.nvim",
    cmd = { "LazyGit" },
    dependencies = { "nvim-lua/plenary.nvim" },
    keys = { { "<leader>gg", "<cmd>LazyGit<cr>", desc = "LazyGit" } },
  },
}
