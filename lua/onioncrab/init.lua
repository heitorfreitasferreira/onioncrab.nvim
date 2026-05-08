local M = {}

local harpoon = require("harpoon")
local Config = require("onioncrab.config")
local Detect = require("onioncrab.detect")
local State = require("onioncrab.state")
local UI = require("onioncrab.ui")

-- Forward declaration (used by infer_concept)
local list_concepts

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

    -- Optional fuzzy aliasing: if the detected concept is "close" to an existing one,
    -- reuse the existing name to keep layers grouped (e.g. ExternalPrice -> ExternalPricing).
    local fuzzy = (spec or {}).concept_fuzzy or {}
    if fuzzy.enabled then
        local idx_list = concept_index_list()
        local existing_item = idx_list:get_by_value(concept)
        if existing_item == nil then
            local function norm(s)
                s = tostring(s or ""):lower()
                -- keep alnum only so snake/camel/paths compare well
                s = s:gsub("[^%w]", "")
                return s
            end

            local function common_prefix_len(a, b)
                local n = math.min(#a, #b)
                local i = 0
                while i < n do
                    local ia = a:sub(i + 1, i + 1)
                    local ib = b:sub(i + 1, i + 1)
                    if ia ~= ib then
                        break
                    end
                    i = i + 1
                end
                return i
            end

            local function levenshtein(a, b, max_dist)
                if a == b then
                    return 0
                end
                local la, lb = #a, #b
                if la == 0 then
                    return lb
                end
                if lb == 0 then
                    return la
                end
                if max_dist and math.abs(la - lb) > max_dist then
                    return max_dist + 1
                end

                -- DP with two rows to keep allocations small.
                local prev = {}
                local cur = {}
                for j = 0, lb do
                    prev[j] = j
                end

                for i = 1, la do
                    cur[0] = i
                    local ai = a:sub(i, i)
                    local row_min = cur[0]
                    for j = 1, lb do
                        local cost = (ai == b:sub(j, j)) and 0 or 1
                        local ins = cur[j - 1] + 1
                        local del = prev[j] + 1
                        local sub = prev[j - 1] + cost
                        local v = ins
                        if del < v then
                            v = del
                        end
                        if sub < v then
                            v = sub
                        end
                        cur[j] = v
                        if v < row_min then
                            row_min = v
                        end
                    end

                    if max_dist and row_min > max_dist then
                        return max_dist + 1
                    end

                    prev, cur = cur, prev
                end

                return prev[lb]
            end

            local function concept_has_app_evidence(c, app)
                if app == nil or app == "" then
                    return false
                end
                local list = harpoon:list(concept_list_name(c))
                local n = #(spec.layers or {})
                for i = 1, n do
                    local it = list:get(i)
                    if it and it.value and it.value:sub(1, #app + 1) == app .. "/" then
                        return true
                    end
                end
                return false
            end

            local app = rel_path:match("^([^/]+)/")
            local scope = fuzzy.scope or "project"
            local prefix_len = tonumber(fuzzy.prefix_len) or 6
            local max_dist = tonumber(fuzzy.max_dist) or 3
            local max_ratio = tonumber(fuzzy.max_ratio) or 0.2

            local existing = list_concepts()
            local candidates = existing
            if scope == "app" and app and app ~= "" then
                -- Memoize evidence checks so we don't keep reopening Harpoon lists
                -- for the same concept during this infer_concept call.
                local evidence_cache = {}
                local function has_evidence(c)
                    local v = evidence_cache[c]
                    if v ~= nil then
                        return v
                    end
                    local ok = concept_has_app_evidence(c, app)
                    evidence_cache[c] = ok
                    return ok
                end

                local filtered = {}
                for _, c in ipairs(existing) do
                    if has_evidence(c) then
                        table.insert(filtered, c)
                    end
                end
                if #filtered > 0 then
                    candidates = filtered
                end
            end

            local n_concept = norm(concept)
            local best = nil
            local best_dist = nil
            local best_prefix = nil
            for _, c in ipairs(candidates) do
                local n_c = norm(c)
                if n_c ~= "" then
                    -- Exact match after normalization (case/underscore/etc) should always alias.
                    if n_c == n_concept then
                        best = c
                        best_dist = 0
                        best_prefix = #n_concept
                        break
                    end

                    local required_prefix = math.min(prefix_len, math.min(#n_concept, #n_c))
                    local pfx = common_prefix_len(n_concept, n_c)
                    if pfx >= required_prefix then
                        local dist = levenshtein(n_concept, n_c, max_dist)
                        local ratio = dist / math.max(#n_concept, #n_c)
                        if dist <= max_dist and ratio <= max_ratio then
                            if best == nil
                                or dist < best_dist
                                or (dist == best_dist and pfx > best_prefix)
                            then
                                best = c
                                best_dist = dist
                                best_prefix = pfx
                            end
                        end
                    end
                end
            end

            if best and best ~= concept then
                if State.config.notify and (fuzzy.notify == nil or fuzzy.notify == true) then
                    note(
                        string.format(
                            "onioncrab: concept alias %s -> %s%s",
                            concept,
                            best,
                            (scope == "app" and app and app ~= "") and (" (" .. app .. ")") or ""
                        )
                    )
                end
                concept = best
            end
        end
    end

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

---@param idx number
---@return number
local function wrap_layer_idx(idx)
    local layers = framework_spec().layers
    local n = #layers
    if n == 0 then
        return 1
    end
    if idx < 1 then
        return n
    end
    if idx > n then
        return 1
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

---@return string[]
list_concepts = function()
    local list = concept_index_list()
    local out = {}
    for i = 1, list:length() do
        local item = list:get(i)
        if item and item.value then
            table.insert(out, item.value)
        end
    end
    return out
end

---@param list HarpoonList
---@param idx number
---@return boolean
local function cell_filled(list, idx)
    local item = list:get(idx)
    return item ~= nil and not is_blank(item.value)
end

---@param list HarpoonList
---@param start_idx number
---@return number? idx
local function find_nearest_filled_layer_idx(list, start_idx)
    local n = #framework_spec().layers
    if n == 0 then
        return nil
    end

    local base = wrap_layer_idx(start_idx)
    if cell_filled(list, base) then
        return base
    end

    for dist = 1, n - 1 do
        local fwd = wrap_layer_idx(base + dist)
        if cell_filled(list, fwd) then
            return fwd
        end
        local back = wrap_layer_idx(base - dist)
        if cell_filled(list, back) then
            return back
        end
    end

    return nil
end

---@param list HarpoonList
---@param start_idx number
---@param step number
---@return number? idx
local function find_next_filled_layer_idx(list, start_idx, step)
    local n = #framework_spec().layers
    if n == 0 then
        return nil
    end

    local idx = wrap_layer_idx(start_idx)
    for _ = 1, n do
        if cell_filled(list, idx) then
            return idx
        end
        idx = wrap_layer_idx(idx + step)
    end

    return nil
end

---@return boolean opened
local function open_current_cell()
    local concept = ensure_current_concept()
    local list = get_concept_list(concept)
    local idx = State.nav.layer_idx

    local item = list:get(idx)
    if item and not is_blank(item.value) then
        list:select(idx)
        return true
    end

    local nearest = find_nearest_filled_layer_idx(list, idx)
    if nearest then
        State.nav.layer_idx = nearest
        list:select(nearest)
        return true
    end

    note(
        string.format(
            "onioncrab: empty cell %s [%s] (%d/%d)",
            concept,
            current_layer_name(),
            idx,
            #framework_spec().layers
        )
    )
    return false
end

---@param list HarpoonList
---@param idx number
---@return boolean opened
local function select_layer_if_filled(list, idx)
    local item = list:get(idx)
    if not item or is_blank(item.value) then
        return false
    end
    State.nav.layer_idx = wrap_layer_idx(idx)
    list:select(State.nav.layer_idx)
    return true
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

    open_current_cell()
end

function M.menu()
    ensure_setup_called()

    UI.toggle()
end

---@param list HarpoonList
---@return boolean
local function concept_list_has_any_filled_cell(list)
    local n = #framework_spec().layers
    for i = 1, n do
        local it = list:get(i)
        if it and not is_blank(it.value) then
            return true
        end
    end
    return false
end

---@param concept string
local function remove_concept_from_index(concept)
    local idx_list = concept_index_list()
    if idx_list:length() == 0 then
        return
    end

    local kept = {}
    for i = 1, idx_list:length() do
        local it = idx_list:get(i)
        if it and it.value and it.value ~= concept then
            table.insert(kept, it.value)
        end
    end

    idx_list:clear()
    for _, v in ipairs(kept) do
        idx_list:add({ value = v, context = {} })
    end

    -- Keep nav index in bounds.
    if State.nav.concept_idx > idx_list:length() then
        State.nav.concept_idx = 1
    end
end

---Remove the current (concept, layer) cell from the matrix.
---No-op if there is no concept or the cell is already empty.
function M.remove()
    ensure_setup_called()

    -- No concepts yet: nothing to remove.
    if concept_index_list():length() == 0 then
        return
    end

    local concept = ensure_current_concept()
    local list = get_concept_list(concept)
    local idx = State.nav.layer_idx

    local item = list:get(idx)
    if not item or is_blank(item.value) then
        return
    end

    list:replace_at(idx, { value = "", context = {} })

    -- If this was the last filled cell for the concept, remove the concept itself.
    if not concept_list_has_any_filled_cell(list) then
        remove_concept_from_index(concept)
        list:clear()
    end

    harpoon:sync()

    -- If the menu is open, re-render so the cell updates to '.'.
    pcall(function()
        UI.render()
    end)
 end

---Delete the current concept entirely (removes it from the index and clears its list).
---No-op if there are no concepts yet.
function M.delete_concept()
    ensure_setup_called()

    if concept_index_list():length() == 0 then
        return
    end

    local concept = ensure_current_concept()
    local list = get_concept_list(concept)

    list:clear()
    remove_concept_from_index(concept)
    harpoon:sync()

    pcall(function()
        UI.render()
    end)
end

---Delete all onioncrab concepts (persisted Harpoon lists) for the current project key.
---This only touches lists created by onioncrab: the index list + per-concept lists.
function M.delete_concepts()
    ensure_setup_called()

    local idx_list = concept_index_list()
    local concepts = list_concepts()

    -- Clear per-concept lists first.
    for _, concept in ipairs(concepts) do
        get_concept_list(concept):clear()
    end

    -- Clear the index list.
    idx_list:clear()

    harpoon:sync()
end

---Fully reset onioncrab state for the current project key.
---Clears all saved onioncrab lists and resets in-memory navigation/framework state.
function M.reset()
    ensure_setup_called()

    -- Close UI if it's currently open.
    pcall(function()
        require("onioncrab.ui").close()
    end)

    M.delete_concepts()

    State.nav.concept_idx = 1
    State.nav.layer_idx = 1
    State.project.framework = nil
end

-- internal: used by UI keymaps
---@param drow number
---@param dcol number
function M._ui_move(drow, dcol)
    ensure_setup_called()
    UI.move(drow, dcol)
end

function M.left()
    ensure_setup_called()
    local list = concept_index_list()
    if list:length() == 0 then
        -- create first concept from current file
        ensure_current_concept()
        return
    end

    local n = list:length()
    State.nav.concept_idx = State.nav.concept_idx - 1
    if State.nav.concept_idx < 1 then
        State.nav.concept_idx = n
    end

    local concept = ensure_current_concept()
    note("onioncrab: concept=" .. concept)

    local clist = get_concept_list(concept)
    local nearest = find_nearest_filled_layer_idx(clist, State.nav.layer_idx)
    if nearest then
        select_layer_if_filled(clist, nearest)
    else
        open_current_cell()
    end
end

function M.right()
    ensure_setup_called()
    local list = concept_index_list()
    if list:length() == 0 then
        ensure_current_concept()
        return
    end

    local n = list:length()
    State.nav.concept_idx = State.nav.concept_idx + 1
    if State.nav.concept_idx > n then
        State.nav.concept_idx = 1
    end

    local concept = ensure_current_concept()
    note("onioncrab: concept=" .. concept)

    local clist = get_concept_list(concept)
    local nearest = find_nearest_filled_layer_idx(clist, State.nav.layer_idx)
    if nearest then
        select_layer_if_filled(clist, nearest)
    else
        open_current_cell()
    end
end

function M.up()
    ensure_setup_called()

    local concept = ensure_current_concept()
    local clist = get_concept_list(concept)

    local start = wrap_layer_idx(State.nav.layer_idx - 1)
    local next_idx = find_next_filled_layer_idx(clist, start, -1)
    if next_idx then
        State.nav.layer_idx = next_idx
        note(
            string.format(
                "onioncrab: layer=%s (%d/%d)",
                current_layer_name(),
                State.nav.layer_idx,
                #framework_spec().layers
            )
        )
        clist:select(State.nav.layer_idx)
        return
    end

    State.nav.layer_idx = start
    note(
        string.format(
            "onioncrab: layer=%s (%d/%d)",
            current_layer_name(),
            State.nav.layer_idx,
            #framework_spec().layers
        )
    )
    open_current_cell()
end

function M.down()
    ensure_setup_called()

    local concept = ensure_current_concept()
    local clist = get_concept_list(concept)

    local start = wrap_layer_idx(State.nav.layer_idx + 1)
    local next_idx = find_next_filled_layer_idx(clist, start, 1)
    if next_idx then
        State.nav.layer_idx = next_idx
        note(
            string.format(
                "onioncrab: layer=%s (%d/%d)",
                current_layer_name(),
                State.nav.layer_idx,
                #framework_spec().layers
            )
        )
        clist:select(State.nav.layer_idx)
        return
    end

    State.nav.layer_idx = start
    note(
        string.format(
            "onioncrab: layer=%s (%d/%d)",
            current_layer_name(),
            State.nav.layer_idx,
            #framework_spec().layers
        )
    )
    open_current_cell()
end

---@param user_config? OnioncrabSetup
function M.setup(user_config)
    user_config = user_config or {}

    State.config = Config.merge(user_config)
    State.did_setup = true

    -- UI highlight defaults (users can override in their colorscheme).
    vim.api.nvim_set_hl(0, "OnioncrabHeader", { link = "Title", default = true })
    vim.api.nvim_set_hl(
        0,
        "OnioncrabHeaderCol",
        { link = "Directory", default = true }
    )
    vim.api.nvim_set_hl(
        0,
        "OnioncrabSeparator",
        { link = "Comment", default = true }
    )
    vim.api.nvim_set_hl(
        0,
        "OnioncrabActiveCell",
        { link = "Visual", default = true }
    )
    vim.api.nvim_set_hl(
        0,
        "OnioncrabActiveHeader",
        { link = "IncSearch", default = true }
    )
    vim.api.nvim_set_hl(
        0,
        "OnioncrabActiveHeaderCol",
        { link = "IncSearch", default = true }
    )

    UI.setup({
        state = State,
        is_blank = is_blank,
        get_concepts = list_concepts,
        get_layers = function()
            return framework_spec().layers
        end,
        get_concept_list = get_concept_list,
        ensure_current_concept = ensure_current_concept,
        current_framework = current_framework,
    })

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

    vim.api.nvim_create_user_command("OnioncrabReset", function()
        require("onioncrab").reset()
    end, {})
end

return M
