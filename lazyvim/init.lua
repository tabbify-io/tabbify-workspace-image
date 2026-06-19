-- Tabbify Workspace — LazyVim bootstrap. A human SSHing in lands in a real
-- editor (not a bare shell). The LSP layer points rust-analyzer at the SAME
-- baked binary the codeservice fronts, so `gd`/`gr` in neovim and the agent's
-- find_references share ONE warm index (spec §3.A "common warm index").
require("config.lazy")
