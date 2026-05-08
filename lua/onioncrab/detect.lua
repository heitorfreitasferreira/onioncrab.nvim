local M = {}

local State = require("onioncrab.state")

---@param s string
local function lower(s)
    return (s or ""):lower()
end

---@param s string
local function trim_ext(s)
    return (s or ""):gsub("%.[^%.]+$", "")
end

---@param rel_path string
---@return string filename
local function filename(rel_path)
    return rel_path:gsub("^.*/", "")
end

---@return string
local function read_current_buffer_text()
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    return table.concat(lines, "\n")
end

---@param patterns string[]
---@param text string
---@return boolean
local function any_match(patterns, text)
    for _, p in ipairs(patterns or {}) do
        if text:match(p) then
            return true
        end
    end
    return false
end

---@param needles string[]
---@param text string
---@return boolean
local function any_find_plain(needles, text)
    local t = text or ""
    for _, n in ipairs(needles or {}) do
        if t:find(n, 1, true) then
            return true
        end
    end
    return false
end

---@return string
function M.detect_framework()
    -- cheap project-level heuristics
    local cwd = vim.loop.cwd()
    local uv = vim.loop
    local function exists(path)
        local st = uv.fs_stat(path)
        return st ~= nil
    end

    if exists(cwd .. "/manage.py") or exists(cwd .. "/pyproject.toml") then
        return "django-rest"
    end
    if
        exists(cwd .. "/pom.xml")
        or exists(cwd .. "/build.gradle")
        or exists(cwd .. "/build.gradle.kts")
    then
        return "spring"
    end

    -- fallback: sniff current buffer content
    local text = read_current_buffer_text()
    if
        text:find("from django", 1, true)
        or text:find("rest_framework", 1, true)
    then
        return "django-rest"
    end
    if
        text:find("@RestController", 1, true)
        or text:find("org.springframework", 1, true)
    then
        return "spring"
    end

    -- default to django-rest since it's your MVP
    return "django-rest"
end

---@param rel_path string
---@param spec OnioncrabFrameworkSpec
---@return string? layer
function M.detect_layer(rel_path, spec)
    spec = spec or {}
    local text = read_current_buffer_text()

    local rp = rel_path or ""
    local fn = filename(rp)

    for _, rule in ipairs(spec.layer_rules or {}) do
        local ok = false
        if rule.path and any_find_plain(rule.path, rp) then
            ok = true
        end
        if not ok and rule.filename and any_find_plain(rule.filename, fn) then
            ok = true
        end
        if not ok and rule.content and any_match(rule.content, text) then
            ok = true
        end
        if ok then
            return rule.layer
        end
    end

    return nil
end

---@param s string
---@return string
local function snake_to_title(s)
    local out = {}
    for part in s:gmatch("[^_%-]+") do
        table.insert(out, part:sub(1, 1):upper() .. part:sub(2))
    end
    return table.concat(out, "")
end

---@param name string
---@param suffixes string[]
---@return string
local function strip_suffixes(name, suffixes)
    local n = name
    local ln = lower(n)
    local changed = true
    while changed do
        changed = false
        for _, suf in ipairs(suffixes or {}) do
            local s = lower(suf)
            if ln:sub(-#s) == s then
                n = n:sub(1, #n - #s)
                ln = lower(n)
                changed = true
            end
        end
    end
    return n
end

---@param rel_path string
---@param spec OnioncrabFrameworkSpec
---@return string
function M.detect_concept(rel_path, spec)
    spec = spec or {}
    local suf = spec.concept_suffixes or {}

    local base = trim_ext(filename(rel_path))
    local b = base

    -- python-ish: user_serializer -> User
    b = strip_suffixes(b, suf)
    b = b:gsub("[_%-]+$", "")
    if b:find("_") or b:find("-") then
        b = snake_to_title(b)
    end
    if b ~= "" then
        return b
    end

    -- fallback: first class/record name
    local text = read_current_buffer_text()
    local class_name = text:match("class%s+(%w+)")
        or text:match("record%s+(%w+)")
    if class_name then
        class_name = strip_suffixes(class_name, suf)
        if class_name ~= "" then
            return class_name
        end
    end

    return "Concept"
end

return M
