-- Minimal Neovim init for onioncrab tests.
-- Keeps runtime clean and ensures our plugin is on runtimepath.

vim.o.swapfile = false
vim.o.backup = false
vim.o.writebackup = false
vim.o.shadafile = "NONE"
vim.o.undofile = false

local root = vim.fn.fnamemodify(vim.fn.expand("<sfile>:p"), ":h:h")

-- Keep tests hermetic: only our plugin + $VIMRUNTIME.
-- `plenary.path` is mocked in the test runner, so we don't need plenary on rtp.

-- Reset rtp/packpath instead of prepending to user's environment.
vim.opt.runtimepath = { root, vim.env.VIMRUNTIME }
vim.o.packpath = vim.o.runtimepath

-- Make plugin available via runtimepath.
-- (Already included above)

-- Make tests folder require-able.
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. root .. "/tests/?.lua;" .. package.path
