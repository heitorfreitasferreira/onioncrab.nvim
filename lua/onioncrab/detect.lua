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

        -- Prefer semantic signals from file content (imports/usages) over
        -- location/name heuristics, to avoid false positives like `previews.py`.
        if rule.content and any_match(rule.content, text) then
            ok = true
        end
        if not ok and rule.path and any_find_plain(rule.path, rp) then
            ok = true
        end
        if not ok and rule.filename and any_find_plain(rule.filename, fn) then
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

    local function norm(s)
        s = tostring(s or ""):lower()
        return s:gsub("[^%w]", "")
    end

    local function common_prefix_len(a, b)
        local n = math.min(#a, #b)
        local i = 0
        while i < n do
            if a:sub(i + 1, i + 1) ~= b:sub(i + 1, i + 1) then
                break
            end
            i = i + 1
        end
        return i
    end

    local function levenshtein(a, b)
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

        local prev = {}
        local cur = {}
        for j = 0, lb do
            prev[j] = j
        end
        for i = 1, la do
            cur[0] = i
            local ai = a:sub(i, i)
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
            end
            prev, cur = cur, prev
        end
        return prev[lb]
    end

    local function clean_candidate(name)
        name = strip_suffixes(name, suf)
        -- For common DRF naming (`UserView`, `UserViews`), strip View(s) only when
        -- it is a case-sensitive CamelCase suffix. This avoids truncating words like
        -- `Review` (lowercase `view`).
        if name:sub(-4) == "View" then
            name = name:sub(1, #name - 4)
        elseif name:sub(-5) == "Views" then
            name = name:sub(1, #name - 5)
        end
        if name:sub(1, 4) == "Test" and #name > 4 then
            name = name:sub(5)
        end
        return name
    end

    -- filename-driven baseline: user_serializer -> User
    local base = trim_ext(filename(rel_path))
    base = base:gsub("^test[_%-]", "")
    -- `views.py` is a generic container file; don't let it become a concept.
    if base == "views" then
        base = ""
    end
    local file_concept = base
    file_concept = strip_suffixes(file_concept, suf)
    file_concept = file_concept:gsub("[_%-]+$", "")
    if file_concept:find("_") or file_concept:find("-") then
        file_concept = snake_to_title(file_concept)
    end

    -- Prefer a class name, but pick the best match (not just the first).
    -- This avoids helpers like Parsed* winning over the actual service class.
    local text = read_current_buffer_text()
    local best = nil
    local best_dist = nil
    local best_pfx = nil
    local want = norm(file_concept)

    for cls in text:gmatch("\n%s*class%s+(%w+)") do
        local cand = clean_candidate(cls)
        if cand ~= "" then
            if want == "" then
                return cand
            end
            local n_cand = norm(cand)
            if want ~= "" and n_cand == want then
                return cand
            end
            local pfx = common_prefix_len(n_cand, want)
            local dist = (want == "") and nil or levenshtein(n_cand, want)
            if dist ~= nil then
                if best == nil or dist < best_dist or (dist == best_dist and pfx > best_pfx) then
                    best = cand
                    best_dist = dist
                    best_pfx = pfx
                end
            end
        end
    end

    -- Also consider class at start-of-file (no leading newline)
    do
        local first = text:match("^%s*class%s+(%w+)")
        if first then
            local cand = clean_candidate(first)
            if cand ~= "" then
                if want == "" then
                    return cand
                end
                local n_cand = norm(cand)
                if want ~= "" and n_cand == want then
                    return cand
                end
                local pfx = common_prefix_len(n_cand, want)
                local dist = (want == "") and nil or levenshtein(n_cand, want)
                if dist ~= nil then
                    if best == nil or dist < best_dist or (dist == best_dist and pfx > best_pfx) then
                        best = cand
                        best_dist = dist
                        best_pfx = pfx
                    end
                end
            end
        end
    end

    if best and want ~= "" then
        -- Only trust the class-derived best if it's reasonably close.
        local ratio = best_dist / math.max(#want, #norm(best))
        if (best_pfx or 0) >= 4 and ratio <= 0.34 then
            return best
        end
    end

    if file_concept ~= "" then
        return file_concept
    end

    -- last resort: record name (non-python)
    local record_name = text:match("^%s*record%s+(%w+)")
        or text:match("\n%s*record%s+(%w+)")
    if record_name then
        record_name = clean_candidate(record_name)
        if record_name ~= "" then
            return record_name
        end
    end

    return "Concept"
end

return M
