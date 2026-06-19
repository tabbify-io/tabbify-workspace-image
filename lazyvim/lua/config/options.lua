-- LazyVim loads this automatically on startup (before lazy). Workspace-tuned
-- editor options.
vim.g.mapleader = " "
vim.g.maplocalleader = "\\"

local opt = vim.opt
opt.number = true
opt.relativenumber = true
opt.expandtab = true
opt.shiftwidth = 4
opt.tabstop = 4
opt.smartindent = true
opt.wrap = false
opt.scrolloff = 4
opt.clipboard = "" -- no system clipboard inside the headless FC
opt.swapfile = false
opt.undofile = true
