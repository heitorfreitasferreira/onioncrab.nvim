local M = {}

local harpoon = require("harpoon")
local Config = require("onioncrab.config")
local Detect = require("onioncrab.detect")
local State = require("onioncrab.state")

---@class OnioncrabSetup
---@field frameworks? table<string, OnioncrabFrameworkSpec>
---@field concept_list_name? string
---@field list_prefix? string
---@field notify? boolean

---@param msg string
local function note(msg)
    if State.config.notify then
        vim.notify(msg)
    end
end

local function ensure_setup_called()
    if not State.did_setup then
        error("onioncrab: call require('onioncrab').setup(...) first")
    end
end

---@return HarpoonList
local function concept_index_list()
    return harpoon:list(State.config.concept_list_name)
end

---@param concept string
---@return string
local function concept_list_name(concept)
    return State.config.list_prefix .. concept
end

---@return string
local function current_framework()
    local fw = State.project.framework
    if fw then
        return fw
    end
    fw = Detect.detect_framework()
    State.project.framework = fw
    return fw
end

---@return OnioncrabFrameworkSpec
local function framework_spec()
    local fw = current_framework()
    local spec = State.config.frameworks[fw]
    if not spec then
        -- fallback to a minimal spec if user removed presets
        spec = {
            layers = { "layer1", "layer2", "layer3" },
        }
    end
    return spec
end

---@return string[], table<string, number>
local function layers_and_index()
    local spec = framework_spec()
    local layers = spec.layers
    local idx = {}
    for i, name in ipairs(layers) do
        idx[name] = i
    end
    return layers, idx
end

---@param s string
local function is_blank(s)
    return s == nil or s:gsub("%s", "") == ""
end

---@return string? abs_path
local function current_abs_path()
    local abs = vim.api.nvim_buf_get_name(0)
    if is_blank(abs) then
        return nil
    end
    return abs
end

---@return string? rel_path, string? root
local function current_rel_path()
    local abs = current_abs_path()
    if not abs then
        return nil, nil
    end
    local root = framework_spec().root_dir and framework_spec().root_dir()
        or vim.loop.cwd()
    local Path = require("plenary.path")
    local rel = Path:new(abs):make_relative(root)
    return rel, root
end

---@param rel_path string
---@return string
local function infer_concept(rel_path)
    local fw = current_framework()
    local spec = State.config.frameworks[fw]
    local concept = Detect.detect_concept(rel_path, spec)
    return concept
end

---@param rel_path string
---@return string? layer
local function infer_layer(rel_path)
    local fw = current_framework()
    local spec = State.config.frameworks[fw]
    return Detect.detect_layer(rel_path, spec)
end

---@param concept string
local function ensure_concept_in_index(concept)
    local list = concept_index_list()
    local item, idx = list:get_by_value(concept)
    if item == nil then
        list:add({ value = concept, context = {} })
        State.nav.concept_idx = list:length()
        return
    end
    State.nav.concept_idx = idx
end

---@return string concept
local function ensure_current_concept()
    local list = concept_index_list()
    local idx = State.nav.concept_idx
    if idx < 1 or idx > list:length() then
        idx = 1
    end
    local item = list:get(idx)
    if item and item.value then
        State.nav.concept_idx = idx
        return item.value
    end
    -- no concept yet: infer from current file
    local rel = current_rel_path()
    if not rel then
        error("onioncrab: current buffer has no file path")
    end
    local concept = infer_concept(rel)
    ensure_concept_in_index(concept)
    return concept
end

---@return number
local function clamp_layer_idx(idx)
    local layers = framework_spec().layers
    if idx < 1 then
        return 1
    end
    if idx > #layers then
        return #layers
    end
    return idx
end

---@return string
local function current_layer_name()
    local layers = framework_spec().layers
    return layers[State.nav.layer_idx]
end

---@param concept string
---@return HarpoonList
local function get_concept_list(concept)
    return harpoon:list(concept_list_name(concept))
end

---@param layer string
---@param layers_idx table<string, number>
---@return number
local function layer_to_index(layer, layers_idx)
    local idx = layers_idx[layer]
    if idx then
        return idx
    end
    return State.nav.layer_idx
end

---@param concept string
---@param layer string
---@param rel_path string
local function set_cell(concept, layer, rel_path)
    local list = get_concept_list(concept)
    local layers, layers_idx = layers_and_index()
    local idx = layer_to_index(layer, layers_idx)

    local pos = vim.api.nvim_win_get_cursor(0)
    local item = {
        value = rel_path,
        context = {
            row = pos[1],
            col = pos[2],
            layer = layer,
            concept = concept,
            framework = current_framework(),
        },
    }

    list:replace_at(idx, item)
    State.nav.layer_idx = clamp_layer_idx(idx)

    if State.config.notify then
        note(
            string.format(
                "onioncrab: %s [%s] = %s",
                concept,
                layers[idx] or tostring(idx),
                rel_path
            )
        )
    end
end

function M.add()
    ensure_setup_called()

    local rel = current_rel_path()
    if not rel then
        error("onioncrab: current buffer has no file path")
    end

    local concept = infer_concept(rel)
    ensure_concept_in_index(concept)

    local layer = infer_layer(rel)
    if not layer then
        local layers = framework_spec().layers
        vim.ui.select(layers, {
            prompt = "onioncrab: layer for " .. rel,
        }, function(choice)
            if choice then
                set_cell(concept, choice, rel)
                harpoon:sync()
            end
        end)
        return
    end

    set_cell(concept, layer, rel)
    harpoon:sync()
end

function M.open()
    ensure_setup_called()

    local concept = ensure_current_concept()
    local list = get_concept_list(concept)
    local idx = State.nav.layer_idx
    list:select(idx)
end

function M.menu()
    ensure_setup_called()

    local concept = ensure_current_concept()
    local list = get_concept_list(concept)
    local layers = framework_spec().layers

    harpoon.ui:toggle_quick_menu(list, {
        title = string.format(
            "onioncrab: %s | layer=%s (%d/%d)",
            concept,
            layers[State.nav.layer_idx],
            State.nav.layer_idx,
            #layers
        ),
    })
end

function M.left()
    ensure_setup_called()
    local list = concept_index_list()
    if list:length() == 0 then
        -- create first concept from current file
        ensure_current_concept()
        return
    end
    State.nav.concept_idx = State.nav.concept_idx - 1
    if State.nav.concept_idx < 1 then
        State.nav.concept_idx = 1
    end
    note("onioncrab: concept=" .. ensure_current_concept())
end

function M.right()
    ensure_setup_called()
    local list = concept_index_list()
    if list:length() == 0 then
        ensure_current_concept()
        return
    end
    State.nav.concept_idx = State.nav.concept_idx + 1
    if State.nav.concept_idx > list:length() then
        State.nav.concept_idx = list:length()
    end
    note("onioncrab: concept=" .. ensure_current_concept())
end

function M.up()
    ensure_setup_called()
    State.nav.layer_idx = clamp_layer_idx(State.nav.layer_idx - 1)
    note(
        string.format(
            "onioncrab: layer=%s (%d/%d)",
            current_layer_name(),
            State.nav.layer_idx,
            #framework_spec().layers
        )
    )
end

function M.down()
    ensure_setup_called()
    State.nav.layer_idx = clamp_layer_idx(State.nav.layer_idx + 1)
    note(
        string.format(
            "onioncrab: layer=%s (%d/%d)",
            current_layer_name(),
            State.nav.layer_idx,
            #framework_spec().layers
        )
    )
end

---@param user_config? OnioncrabSetup
function M.setup(user_config)
    user_config = user_config or {}

    State.config = Config.merge(user_config)
    State.did_setup = true

    -- NOTE: We intentionally do not call `harpoon:setup()` here.
    -- Harpoon's setup currently reinitializes internal state; calling it from
    -- a dependent plugin can surprise users.

    vim.api.nvim_create_user_command("OnioncrabAdd", function()
        require("onioncrab").add()
    end, {})
    vim.api.nvim_create_user_command("OnioncrabOpen", function()
        require("onioncrab").open()
    end, {})
    vim.api.nvim_create_user_command("OnioncrabMenu", function()
        require("onioncrab").menu()
    end, {})
    vim.api.nvim_create_user_command("OnioncrabLeft", function()
        require("onioncrab").left()
    end, {})
    vim.api.nvim_create_user_command("OnioncrabRight", function()
        require("onioncrab").right()
    end, {})
    vim.api.nvim_create_user_command("OnioncrabUp", function()
        require("onioncrab").up()
    end, {})
    vim.api.nvim_create_user_command("OnioncrabDown", function()
        require("onioncrab").down()
    end, {})
end

return M
