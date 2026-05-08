# onioncrab.nvim

##### Concept x Layer navigation on top of Harpoon

`onioncrab.nvim` is a thin layer on top of [Harpoon 2](https://github.com/ThePrimeagen/harpoon/tree/harpoon2) that lets you navigate your codebase as a matrix:

- **Concept** (User, Order, Auth, ...)
- **Layer** (controller/service/repository/dto, or Django REST layers)

No new UI is introduced: you keep using Harpoon's quick menu, but each concept becomes a Harpoon list where each slot is a layer.

## ⇁ TOC

- [The Problems](#-the-problems)
- [The Solutions](#-the-solutions)
- [Installation](#-installation)
- [Getting Started](#-getting-started)
- [API](#-api)
  - [Setup](#setup)
  - [Commands](#commands)
  - [Configuration](#configuration)
  - [Extending Detection](#extending-detection)

## ⇁ The Problems

1. In layered architectures, you don't think in a single list. You think in at least two axes: concept and layer.
2. You don't want to memorize "which number is which file". You want to move through layers and concepts with consistent keys.

## ⇁ The Solutions

1. onioncrab stores one Harpoon list per **concept**.
2. Each list uses fixed positions as **layer slots** (e.g. `1=model`, `2=serializer`, `3=view`, ...).
3. When you `:OnioncrabAdd`, onioncrab infers concept and layer from the current file name (and falls back to simple regexes on file contents).

## ⇁ Installation

Requirements:

- Neovim 0.8+
- Harpoon 2 (`ThePrimeagen/harpoon`, `branch = "harpoon2"`)

### lazy.nvim

```lua
{
  "heitorfreitasferreira/onioncrab.nvim",
  dependencies = {
    { "ThePrimeagen/harpoon", branch = "harpoon2" },
  },
  config = function()
    require("harpoon"):setup()
    require("onioncrab").setup()
  end,
}
```

### packer.nvim

```lua
use {
  "heitorfreitasferreira/onioncrab.nvim",
  requires = {
    { "ThePrimeagen/harpoon", branch = "harpoon2" },
  },
  config = function()
    require("harpoon"):setup()
    require("onioncrab").setup()
  end,
}
```

## ⇁ Getting Started

Suggested mappings (pick your own):

```lua
vim.keymap.set("n", "<leader>oa", function() require("onioncrab").add() end)
vim.keymap.set("n", "<leader>om", function() require("onioncrab").menu() end)
vim.keymap.set("n", "<leader>oo", function() require("onioncrab").open() end)

vim.keymap.set("n", "<leader>oh", function() require("onioncrab").left() end)
vim.keymap.set("n", "<leader>ol", function() require("onioncrab").right() end)
vim.keymap.set("n", "<leader>ok", function() require("onioncrab").up() end)
vim.keymap.set("n", "<leader>oj", function() require("onioncrab").down() end)
```

Workflow:

1. Open a file (e.g. `user_serializer.py`, `UserController.java`).
2. Hit your `add` mapping (`:OnioncrabAdd`).
3. Navigate concept/layer and `open` (`:OnioncrabOpen`).
4. Use `menu` (`:OnioncrabMenu`) to see the current concept list (layer slots).

## ⇁ API

### Setup

```lua
require("onioncrab").setup({
  notify = true,
  -- frameworks = { ... },
})
```

Important:

- You must call `require("harpoon"):setup()` yourself. onioncrab will not call it for you.

### Commands

- `:OnioncrabAdd` infer concept/layer and store current file in the matrix
- `:OnioncrabOpen` open current (concept, layer) cell
- `:OnioncrabMenu` open Harpoon quick menu for the current concept
- `:OnioncrabLeft` / `:OnioncrabRight` navigate concepts
- `:OnioncrabUp` / `:OnioncrabDown` navigate layers
- `:OnioncrabReset` clear all onioncrab lists/state for current project

### Configuration

`setup()` accepts:

```lua
{
  concept_list_name = "__onioncrab_concepts",
  list_prefix = "__onioncrab_concept::",
  notify = true,
  frameworks = {
    ["django-rest"] = {
      layers = { "model", "serializer", "view", "service", "repository", "url", "test" },
      -- layer_rules = { ... },
      -- concept_suffixes = { ... },
    },
    spring = {
      layers = { "controller", "service", "repository", "entity", "dto", "mapper", "test" },
    },
  },
}
```

### Extending Detection

You can extend detection by overriding/adding entries in `frameworks[...].layer_rules` and `frameworks[...].concept_suffixes`.

`layer_rules` fields:

- `layer`: the layer name this rule assigns
- `path`: list of plain substrings matched against relative path
- `filename`: list of plain substrings matched against filename
- `content`: list of Lua patterns matched against current buffer contents

## Notes

This plugin is intentionally pragmatic:

- detection is heuristic
- you can always correct by overwriting a layer slot (add again)

## Development

### Tests

This repo includes a small headless Neovim test runner that uses a mocked Harpoon implementation.
It also mocks `plenary.path` for tests, so no vendored dependencies are required.

Run:

```sh
./scripts/test
```

### Pre-commit

If you use the `pre-commit` framework, you can run the test suite on every commit:

```sh
pre-commit install
```
