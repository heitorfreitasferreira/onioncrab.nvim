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
