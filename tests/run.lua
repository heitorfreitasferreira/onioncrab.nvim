local M = {}

local function fail(msg)
    error(msg or "test failed", 2)
end

local function eq(a, b, msg)
    if a ~= b then
        fail((msg or "not equal") .. ": expected " .. tostring(b) .. ", got " .. tostring(a))
    end
end

local function ok(cond, msg)
    if not cond then
        fail(msg or "assertion failed")
    end
end

local function test(name, fn)
    local ok_run, err = pcall(fn)
    if not ok_run then
        return false, name .. ": " .. tostring(err)
    end
    return true
end

local function make_scratch_buf_without_name()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    -- Ensure no name
    vim.api.nvim_buf_set_name(bufnr, "")
    return bufnr
end

local function unload_onioncrab_modules()
    for name, _ in pairs(package.loaded) do
        if name == "onioncrab" or name:match("^onioncrab%.") then
            package.loaded[name] = nil
        end
    end
end

local function safe_close_ui()
    pcall(function()
        require("onioncrab.ui").close()
    end)
end

local function before_each()
    safe_close_ui()
    unload_onioncrab_modules()

    -- Reset Harpoon mock state between tests.
    if package.loaded["harpoon"] and package.loaded["harpoon"]._lists then
        package.loaded["harpoon"]._lists = {}
        package.loaded["harpoon"].sync_count = 0
    end

    -- start from a clean buffer
    make_scratch_buf_without_name()
end

function M.run()
    -- Mock plenary.path before requiring onioncrab.
    -- For tests we assume it always works; we only need make_relative().
    local sep = package.config:sub(1, 1)
    local function pesc(s)
        if vim.pesc then
            return vim.pesc(s)
        end
        return (tostring(s):gsub("([^%w])", "%%%1"))
    end
    local Path = {}
    Path.__index = Path

    function Path:new(p)
        return setmetatable({ _p = p or "" }, self)
    end

    function Path:make_relative(root)
        local abs = tostring(self._p or "")
        local r = tostring(root or "")
        if r == "" then
            return abs
        end

        -- Normalize slashes so prefix checks behave.
        abs = abs:gsub("\\\\", sep)
        r = r:gsub("\\\\", sep)

        if abs:sub(1, #r) == r then
            local rest = abs:sub(#r + 1)
            rest = rest:gsub("^" .. pesc(sep), "")
            if rest == "" then
                return "."
            end
            return rest
        end
        return abs
    end

    local plenary_path = { new = function(_, p) return Path:new(p) end }
    package.loaded["plenary.path"] = plenary_path
    package.preload["plenary.path"] = function()
        return plenary_path
    end

    -- Inject Harpoon mock before requiring onioncrab.
    local harpoon = require("tests.harpoon_mock").new()
    package.loaded["harpoon"] = harpoon
    package.preload["harpoon"] = function()
        return harpoon
    end

    local function new_onioncrab(opts)
        unload_onioncrab_modules()
        local onioncrab = require("onioncrab")
        onioncrab.setup(opts or { notify = false })
        return onioncrab
    end

    local results = {}

    do
        local pass, err = test("reset_then_menu_on_nameless_buffer", function()
            before_each()
            local onioncrab = new_onioncrab({ notify = false })
            onioncrab.reset()
            -- Must not error even with no current file.
            onioncrab.menu()
            ok(vim.bo.filetype == "onioncrab", "expected onioncrab UI buffer")
            -- Close to avoid interference with other tests.
            require("onioncrab.ui").close()
        end)
        table.insert(results, { pass = pass, err = err })
    end

    do
        local pass, err = test("ui_move_vertical_changes_layer_horizontal_changes_concept", function()
            before_each()
            local onioncrab = new_onioncrab({ notify = false })

            -- Seed mock state: 2 concepts in index list and a fixed layer set.
            onioncrab.delete_concepts()

            local idx = harpoon:list("__onioncrab_concepts")
            idx:clear()
            idx:add({ value = "User", context = {} })
            idx:add({ value = "Order", context = {} })
            harpoon:sync()

            -- Provide deterministic layers via setup.
            onioncrab.setup({
                notify = false,
                frameworks = {
                    ["django-rest"] = { layers = { "model", "serializer", "view" } },
                },
            })

            -- Open menu and move around.
            onioncrab.menu()

            local State = require("onioncrab.state")
            State.nav.concept_idx = 1
            State.nav.layer_idx = 1

            onioncrab._ui_move(1, 0) -- down: next layer
            eq(State.nav.layer_idx, 2, "expected layer_idx to change on vertical move")
            eq(State.nav.concept_idx, 1)

            onioncrab._ui_move(0, 1) -- right: next concept
            eq(State.nav.concept_idx, 2, "expected concept_idx to change on horizontal move")
            eq(State.nav.layer_idx, 2)

            require("onioncrab.ui").close()
        end)
        table.insert(results, { pass = pass, err = err })
    end

    do
        local pass, err = test("add_smoke_updates_lists", function()
            before_each()
            local onioncrab = new_onioncrab({
                notify = false,
                frameworks = {
                    ["django-rest"] = { layers = { "model", "serializer", "view" } },
                },
            })

            -- No real file needed; onioncrab only relies on current buffer name.
            local root = vim.loop.cwd()
            local file = root .. "/tmp/user_serializer.py"
            vim.api.nvim_buf_set_name(0, file)
            vim.api.nvim_buf_set_lines(0, 0, -1, false, {
                "from rest_framework import serializers",
                "class UserSerializer(serializers.Serializer):",
                "  pass",
            })
            onioncrab.add()

            local idx = harpoon:list("__onioncrab_concepts")
            ok(idx:length() >= 1, "expected at least one concept in index")

            local item = idx:get(1)
            ok(item and item.value and item.value ~= "", "expected concept name stored")

            local clist = harpoon:list("__onioncrab_concept::" .. item.value)
            -- onioncrab uses fixed slot positions; it may populate slot 2/3/etc.
            ok(clist:length() >= 1 or clist:get(1) ~= nil or clist:get(2) ~= nil or clist:get(3) ~= nil, "expected concept list to be populated")
        end)
        table.insert(results, { pass = pass, err = err })
    end

    do
        local pass, err = test("remove_clears_current_cell_and_syncs", function()
            before_each()
            local onioncrab = new_onioncrab({
                notify = false,
                frameworks = {
                    ["django-rest"] = { layers = { "model", "serializer", "view" } },
                },
            })

            onioncrab.delete_concepts()

            local idx = harpoon:list("__onioncrab_concepts")
            idx:clear()
            idx:add({ value = "User", context = {} })
            harpoon:sync()

            local clist = harpoon:list("__onioncrab_concept::User")
            -- Keep concept alive after removing layer 2.
            clist:replace_at(1, { value = "app/user_model.py", context = {} })
            clist:replace_at(2, { value = "app/user_serializer.py", context = {} })

            local State = require("onioncrab.state")
            State.nav.concept_idx = 1
            State.nav.layer_idx = 2

            local before_sync = harpoon.sync_count
            onioncrab.remove()

            eq(harpoon.sync_count, before_sync + 1, "expected harpoon:sync() after removal")
            ok(clist:get(2) ~= nil, "expected cell to exist after replace_at")
            ok(clist:get(2).value == "", "expected removed cell to be blank")
        end)
        table.insert(results, { pass = pass, err = err })
    end

    do
        local pass, err = test("remove_is_noop_on_empty_cell", function()
            before_each()
            local onioncrab = new_onioncrab({
                notify = false,
                frameworks = {
                    ["django-rest"] = { layers = { "model", "serializer", "view" } },
                },
            })

            onioncrab.delete_concepts()

            local idx = harpoon:list("__onioncrab_concepts")
            idx:clear()
            idx:add({ value = "User", context = {} })
            harpoon:sync()

            -- No cell set at layer 2.
            local clist = harpoon:list("__onioncrab_concept::User")

            local State = require("onioncrab.state")
            State.nav.concept_idx = 1
            State.nav.layer_idx = 2

            local before_sync = harpoon.sync_count
            onioncrab.remove()

            eq(harpoon.sync_count, before_sync, "expected no sync on noop removal")
            ok(clist:get(2) == nil or clist:get(2).value == "", "expected cell to stay empty")
        end)
        table.insert(results, { pass = pass, err = err })
    end

    do
        local pass, err = test("menu_x_removes_current_cell", function()
            before_each()
            local onioncrab = new_onioncrab({
                notify = false,
                frameworks = {
                    ["django-rest"] = { layers = { "model", "serializer", "view" } },
                },
            })

            onioncrab.delete_concepts()

            local idx = harpoon:list("__onioncrab_concepts")
            idx:clear()
            idx:add({ value = "User", context = {} })
            harpoon:sync()

            local clist = harpoon:list("__onioncrab_concept::User")
            -- Keep concept alive after removing layer 2.
            clist:replace_at(1, { value = "app/user_model.py", context = {} })
            clist:replace_at(2, { value = "app/user_serializer.py", context = {} })

            local State = require("onioncrab.state")
            State.nav.concept_idx = 1
            State.nav.layer_idx = 2

            onioncrab.menu()
            ok(vim.bo.filetype == "onioncrab", "expected onioncrab UI buffer")

            local before_sync = harpoon.sync_count

            -- Feed key through mappings (buffer-local map in UI).
            local keys = vim.api.nvim_replace_termcodes("x", true, false, true)
            vim.api.nvim_feedkeys(keys, "mx", false)
            vim.wait(50)

            eq(harpoon.sync_count, before_sync + 1, "expected sync after x removal")
            ok(clist:get(2) ~= nil, "expected cell to exist after replace_at")
            ok(clist:get(2).value == "", "expected removed cell to be blank")

            require("onioncrab.ui").close()
        end)
        table.insert(results, { pass = pass, err = err })
    end

    do
        local pass, err = test("remove_deletes_concept_when_last_cell_removed", function()
            before_each()
            local onioncrab = new_onioncrab({
                notify = false,
                frameworks = {
                    ["django-rest"] = { layers = { "model", "serializer", "view" } },
                },
            })

            onioncrab.delete_concepts()

            local idx = harpoon:list("__onioncrab_concepts")
            idx:clear()
            idx:add({ value = "User", context = {} })
            harpoon:sync()

            local clist = harpoon:list("__onioncrab_concept::User")
            -- Only one cell set in the whole concept.
            clist:replace_at(2, { value = "app/user_serializer.py", context = {} })

            local State = require("onioncrab.state")
            State.nav.concept_idx = 1
            State.nav.layer_idx = 2

            local before_sync = harpoon.sync_count
            onioncrab.remove()

            eq(harpoon.sync_count, before_sync + 1, "expected single sync after removal")
            eq(idx:length(), 0, "expected concept to be removed from index")
        end)
        table.insert(results, { pass = pass, err = err })
    end

    do
        local pass, err = test("remove_keeps_concept_when_other_cells_exist", function()
            before_each()
            local onioncrab = new_onioncrab({
                notify = false,
                frameworks = {
                    ["django-rest"] = { layers = { "model", "serializer", "view" } },
                },
            })

            onioncrab.delete_concepts()

            local idx = harpoon:list("__onioncrab_concepts")
            idx:clear()
            idx:add({ value = "User", context = {} })
            harpoon:sync()

            local clist = harpoon:list("__onioncrab_concept::User")
            clist:replace_at(1, { value = "app/user_model.py", context = {} })
            clist:replace_at(2, { value = "app/user_serializer.py", context = {} })

            local State = require("onioncrab.state")
            State.nav.concept_idx = 1
            State.nav.layer_idx = 2

            onioncrab.remove()
            eq(idx:length(), 1, "expected concept to remain in index")
            ok(idx:get(1).value == "User", "expected concept name preserved")
            ok(clist:get(1) and clist:get(1).value ~= "", "expected other cell to remain")
        end)
        table.insert(results, { pass = pass, err = err })
    end

    local failed = {}
    for _, r in ipairs(results) do
        if not r.pass then
            table.insert(failed, r.err)
        end
    end

    if #failed > 0 then
        for _, msg in ipairs(failed) do
            vim.api.nvim_err_writeln(msg)
        end
        vim.cmd("cquit 1")
        return
    end

    vim.cmd("quitall!")
end

return M
