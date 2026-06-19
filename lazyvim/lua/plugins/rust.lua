-- Point neovim's rust-analyzer at the SAME baked binary the codeservice fronts,
-- so the human IDE (gd/gr/rename) and the agent (find_references) share ONE warm
-- index (spec §3.A). Build scripts + proc-macros are DISABLED to match the
-- codeservice's §4 RCE-safe config (a malicious build.rs must never run as agent).
return {
  {
    "mrcjkb/rustaceanvim",
    opts = {
      server = {
        cmd = { "/usr/local/bin/rust-analyzer" },
        default_settings = {
          ["rust-analyzer"] = {
            cargo = { buildScripts = { enable = false } },
            procMacro = { enable = false },
          },
        },
      },
    },
  },
}
