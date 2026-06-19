-- Bootstrap lazy.nvim + import the LazyVim distro and our local plugin specs.
-- On first nvim launch this clones lazy.nvim (the only network dependency); the
-- workspace already has git + ca-certificates baked.
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not (vim.uv or vim.loop).fs_stat(lazypath) then
  local out = vim.fn.system({
    "git", "clone", "--filter=blob:none",
    "https://github.com/folke/lazy.nvim.git", "--branch=stable", lazypath,
  })
  if vim.v.shell_error ~= 0 then
    vim.api.nvim_echo({
      { "Failed to clone lazy.nvim:\n", "ErrorMsg" },
      { out, "WarningMsg" },
    }, true, {})
    vim.fn.getchar()
    os.exit(1)
  end
end
vim.opt.rtp:prepend(lazypath)

require("lazy").setup({
  spec = {
    -- The LazyVim distro (sane defaults: telescope, treesitter, lsp, cmp…).
    { "LazyVim/LazyVim", import = "lazyvim.plugins" },
    -- The Rust language extra (rust-analyzer wired below in plugins/rust.lua).
    { import = "lazyvim.plugins.extras.lang.rust" },
    -- Our local overrides.
    { import = "plugins" },
  },
  defaults = { lazy = false, version = false },
  install = { colorscheme = { "tokyonight", "habamax" } },
  checker = { enabled = false }, -- no auto-update inside the FC
  performance = {
    rtp = {
      disabled_plugins = { "gzip", "tarPlugin", "tohtml", "tutor", "zipPlugin" },
    },
  },
})
