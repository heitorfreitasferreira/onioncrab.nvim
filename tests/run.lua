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

local function contains(list, item)
    for _, v in ipairs(list or {}) do
        if v == item then
            return true
        end
    end
    return false
end

local function any_contains(list, items)
    for _, it in ipairs(items or {}) do
        if contains(list, it) then
            return true
        end
    end
    return false
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

    -- Ensure no leftover named buffers interfere between tests.
    local cur = vim.api.nvim_get_current_buf()
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if b ~= cur then
            pcall(vim.api.nvim_buf_delete, b, { force = true })
        end
    end
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
        local pass, err = test("django_rest_defaults_follow_styleguide_boxes", function()
            before_each()
            new_onioncrab({ notify = false })

            local State = require("onioncrab.state")
            local layers = State.config.frameworks["django-rest"].layers

            ok(contains(layers, "model"), "expected model layer")
            ok(contains(layers, "service"), "expected service layer")
            ok(contains(layers, "selector"), "expected selector layer")
            ok(contains(layers, "api"), "expected api layer")
            ok(contains(layers, "url"), "expected url layer")
            ok(contains(layers, "test"), "expected test layer")

            ok(not contains(layers, "view"), "expected to not use view layer by default")
            ok(not contains(layers, "repository"), "expected to not use repository layer by default")
        end)
        table.insert(results, { pass = pass, err = err })
    end

    do
        local pass, err = test("django_concept_prefers_python_class_name_over_filename", function()
            before_each()
            new_onioncrab({ notify = false })

            local Detect = require("onioncrab.detect")
            local State = require("onioncrab.state")
            local spec = State.config.frameworks["django-rest"]

            vim.api.nvim_buf_set_name(0, vim.loop.cwd() .. "/pricing/models/external_price.py")
            vim.api.nvim_buf_set_lines(0, 0, -1, false, {
                "from django.db import models",
                "",
                "class ExternalPricing(models.Model):",
                "    pass",
            })

            local concept = Detect.detect_concept("pricing/models/external_price.py", spec)
            eq(concept, "ExternalPricing", "expected class name to drive concept")
        end)
        table.insert(results, { pass = pass, err = err })
    end

    do
        local pass, err = test("django_concept_fuzzy_aliases_close_names_within_same_app", function()
            before_each()
            local onioncrab = new_onioncrab({ notify = true })

            onioncrab.delete_concepts()

            -- Seed an existing concept in the pricing app.
            local harpoon = require("harpoon")
            local idx = harpoon:list("__onioncrab_concepts")
            idx:clear()
            idx:add({ value = "ExternalPricing", context = {} })
            harpoon:sync()

            -- Now add a file that would normally infer "ExternalPrice".
            local root = vim.loop.cwd()
            vim.api.nvim_buf_set_name(0, root .. "/pricing/models/external_price.py")
            vim.api.nvim_buf_set_lines(0, 0, -1, false, {
                "from django.db import models",
                "",
                "# no class here on purpose",
            })

            onioncrab.add()

            local concept_list = harpoon:list("__onioncrab_concept::ExternalPricing")
            ok(
                (concept_list:get(1) and concept_list:get(1).value) == "pricing/models/external_price.py",
                "expected file to be stored in model layer (slot 1) under aliased concept"
            )

            -- Must not create a new concept for ExternalPrice.
            ok(idx:get_by_value("ExternalPrice") == nil, "expected no ExternalPrice concept after alias")
        end)
        table.insert(results, { pass = pass, err = err })
    end

    do
        local pass, err = test("django_views_files_map_to_api_layer_and_share_concept", function()
            before_each()
            new_onioncrab({ notify = false })

            local Detect = require("onioncrab.detect")
            local State = require("onioncrab.state")
            local spec = State.config.frameworks["django-rest"]

            vim.api.nvim_buf_set_name(0, vim.loop.cwd() .. "/pricing/views/external_pricing_views.py")
            vim.api.nvim_buf_set_lines(0, 0, -1, false, {
                "from rest_framework.decorators import api_view",
                "",
                "@api_view(['GET'])",
                "def list_external_pricing(request):",
                "    pass",
            })

            local concept = Detect.detect_concept("pricing/views/external_pricing_views.py", spec)
            eq(concept, "ExternalPricing", "expected _views suffix to be stripped")

            local layer = Detect.detect_layer("pricing/views/external_pricing_views.py", spec)
            eq(layer, "api", "expected views/ to map to api layer")
        end)
        table.insert(results, { pass = pass, err = err })
    end

    do
        local pass, err = test("django_views_py_at_app_root_maps_to_api_layer_via_import", function()
            before_each()
            new_onioncrab({ notify = false })

            local Detect = require("onioncrab.detect")
            local State = require("onioncrab.state")
            local spec = State.config.frameworks["django-rest"]

            vim.api.nvim_buf_set_name(0, vim.loop.cwd() .. "/pricing/views.py")
            vim.api.nvim_buf_set_lines(0, 0, -1, false, {
                "from rest_framework.decorators import api_view",
                "",
                "@api_view(['GET'])",
                "def list_pricing(request):",
                "    pass",
            })

            local layer = Detect.detect_layer("pricing/views.py", spec)
            eq(layer, "api", "expected views.py to map to api via DRF import")
        end)
        table.insert(results, { pass = pass, err = err })
    end

    do
        local pass, err = test("django_review_word_is_not_truncated_by_view_suffix", function()
            before_each()
            new_onioncrab({ notify = false })

            local Detect = require("onioncrab.detect")
            local State = require("onioncrab.state")
            local spec = State.config.frameworks["django-rest"]

            vim.api.nvim_buf_set_name(0, vim.loop.cwd() .. "/pricing/review.py")
            vim.api.nvim_buf_set_lines(0, 0, -1, false, {
                "class Review:",
                "    pass",
            })

            local concept = Detect.detect_concept("pricing/review.py", spec)
            eq(concept, "Review", "expected Review not to be truncated by view suffix stripping")
        end)
        table.insert(results, { pass = pass, err = err })
    end

    do
        local pass, err = test("django_class_UserView_strips_view_suffix_without_breaking_review", function()
            before_each()
            new_onioncrab({ notify = false })

            local Detect = require("onioncrab.detect")
            local State = require("onioncrab.state")
            local spec = State.config.frameworks["django-rest"]

            vim.api.nvim_buf_set_name(0, vim.loop.cwd() .. "/accounts/views.py")
            vim.api.nvim_buf_set_lines(0, 0, -1, false, {
                "from rest_framework.views import APIView",
                "",
                "class UserView(APIView):",
                "    pass",
                "",
                "class Review(APIView):",
                "    pass",
            })

            -- Filename is `views.py` (generic container); should prefer class name.
            local concept = Detect.detect_concept("accounts/views.py", spec)
            eq(concept, "User", "expected UserView to map to User concept")
        end)
        table.insert(results, { pass = pass, err = err })
    end

    do
        local pass, err = test("django_previews_py_keeps_concept_name", function()
            before_each()
            new_onioncrab({ notify = false })

            local Detect = require("onioncrab.detect")
            local State = require("onioncrab.state")
            local spec = State.config.frameworks["django-rest"]

            vim.api.nvim_buf_set_name(0, vim.loop.cwd() .. "/pricing/previews.py")
            vim.api.nvim_buf_set_lines(0, 0, -1, false, {
                "class Previews:",
                "    pass",
            })

            local concept = Detect.detect_concept("pricing/previews.py", spec)
            eq(concept, "Previews", "expected previews not to be truncated")
        end)
        table.insert(results, { pass = pass, err = err })
    end

    do
        local pass, err = test("django_previews_py_does_not_match_api_layer", function()
            before_each()
            new_onioncrab({ notify = false })

            local Detect = require("onioncrab.detect")
            local State = require("onioncrab.state")
            local spec = State.config.frameworks["django-rest"]

            vim.api.nvim_buf_set_name(0, vim.loop.cwd() .. "/pricing/previews.py")
            vim.api.nvim_buf_set_lines(0, 0, -1, false, {
                "# should not be treated as views.py",
                "def preview(request):",
                "    pass",
            })

            local layer = Detect.detect_layer("pricing/previews.py", spec)
            ok(layer ~= "api", "expected previews.py not to match api layer")
        end)
        table.insert(results, { pass = pass, err = err })
    end

    do
        local pass, err = test("django_concept_fuzzy_aliases_case_only_differences", function()
            before_each()
            local onioncrab = new_onioncrab({ notify = true })

            onioncrab.delete_concepts()

            local harpoon = require("harpoon")
            local idx = harpoon:list("__onioncrab_concepts")
            idx:clear()
            idx:add({ value = "Role", context = {} })
            harpoon:sync()

            local root = vim.loop.cwd()
            vim.api.nvim_buf_set_name(0, root .. "/accounts/models/role.py")
            vim.api.nvim_buf_set_lines(0, 0, -1, false, {
                "# no class here; filename would infer role",
            })

            onioncrab.add()

            ok(idx:get_by_value("role") == nil, "expected no lowercase role concept")
            ok(idx:get_by_value("Role") ~= nil, "expected Role concept to remain")
        end)
        table.insert(results, { pass = pass, err = err })
    end

    do
        local pass, err = test("django_concept_picks_best_matching_class_not_first", function()
            before_each()
            new_onioncrab({ notify = false })

            local Detect = require("onioncrab.detect")
            local State = require("onioncrab.state")
            local spec = State.config.frameworks["django-rest"]

            vim.api.nvim_buf_set_name(0, vim.loop.cwd() .. "/pricing/services/external_pricing_service.py")
            vim.api.nvim_buf_set_lines(0, 0, -1, false, {
                "from dataclasses import dataclass",
                "",
                "@dataclass",
                "class ParsedExternalPricingRow:",
                "    pass",
                "",
                "class ExternalPricingService:",
                "    pass",
            })

            local concept = Detect.detect_concept("pricing/services/external_pricing_service.py", spec)
            eq(concept, "ExternalPricing", "expected to prefer best class match")
        end)
        table.insert(results, { pass = pass, err = err })
    end

    do
        local pass, err = test("django_concept_strips_test_prefix_from_filename_and_class", function()
            before_each()
            new_onioncrab({ notify = false })

            local Detect = require("onioncrab.detect")
            local State = require("onioncrab.state")
            local spec = State.config.frameworks["django-rest"]

            vim.api.nvim_buf_set_name(0, vim.loop.cwd() .. "/pricing/tests/services/test_external_pricing_service.py")
            vim.api.nvim_buf_set_lines(0, 0, -1, false, {
                "from django.test import TestCase",
                "",
                "class TestExternalPricingService(TestCase):",
                "    pass",
            })

            local concept = Detect.detect_concept("pricing/tests/services/test_external_pricing_service.py", spec)
            eq(concept, "ExternalPricing", "expected test prefix to be ignored")
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

    do
        local pass, err = test("delete_concept_removes_from_index_and_clears_list", function()
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

            local before_sync = harpoon.sync_count
            onioncrab.delete_concept()

            eq(harpoon.sync_count, before_sync + 1, "expected sync after concept deletion")
            eq(idx:length(), 0, "expected concept removed from index")
            eq(clist:length(), 0, "expected concept list cleared")
        end)
        table.insert(results, { pass = pass, err = err })
    end

    do
        local pass, err = test("menu_d_deletes_current_concept", function()
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

            local State = require("onioncrab.state")
            State.nav.concept_idx = 1
            State.nav.layer_idx = 1

            onioncrab.menu()
            ok(vim.bo.filetype == "onioncrab", "expected onioncrab UI buffer")

            local before_sync = harpoon.sync_count
            local keys = vim.api.nvim_replace_termcodes("d", true, false, true)
            vim.api.nvim_feedkeys(keys, "mx", false)
            vim.wait(50)

            eq(harpoon.sync_count, before_sync + 1, "expected sync after d deletion")
            eq(idx:length(), 0, "expected concept removed from index")
            eq(clist:length(), 0, "expected concept list cleared")

            require("onioncrab.ui").close()
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
