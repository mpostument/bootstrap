-- managed by the bootstrap - Catppuccin Mocha, the theme of every other tool
-- the bootstrap sets up. LazyVim ships the catppuccin plugin spec; this picks
-- the flavour and makes it the colour scheme in place of tokyonight.
return {
  { "catppuccin/nvim", name = "catppuccin", opts = { flavour = "mocha" } },
  { "LazyVim/LazyVim", opts = { colorscheme = "catppuccin" } },
}
