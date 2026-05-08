local M = {}

local UI = { win_id = nil, bufnr = nil, closing = false, ns = nil }

---@type table?
local Ctx = nil

---@param idx number
---@param n number
---@return number
local function wrap_idx(idx, n)
    if n <= 0 then
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

---@param s string
---@param w number
---@return string
local function fit_cell(s, w)
    s = s or ""
    if w <= 0 then
        return ""
    end

    local function dispwidth(x)
        return vim.fn.strdisplaywidth(x)
    end

    if dispwidth(s) > w then
        local total = vim.fn.strchars(s)
        local lo, hi = 0, total
        while lo < hi do
            local mid = math.floor((lo + hi + 1) / 2)
            local part = vim.fn.strcharpart(s, 0, mid)
            if dispwidth(part) <= w then
                lo = mid
            else
                hi = mid - 1
            end
        end
        s = vim.fn.strcharpart(s, 0, lo)
    end

    local pad = w - dispwidth(s)
    if pad > 0 then
        s = s .. string.rep(" ", pad)
    end
    return s
end

---@param rel_path? string
---@return string
local function short_path(rel_path)
    if Ctx.is_blank(rel_path) then
        return ""
    end
    local p = rel_path
    local base = p:gsub("^.*/", "")
    if base ~= "" then
        return base
    end
    return p
end

---@param concepts string[]
---@param layers string[]
---@param max_width? number
---@return table
local function compute_matrix_layout(concepts, layers, max_width)
    local concept_w = 7
    for _, c in ipairs(concepts) do
        concept_w = math.max(concept_w, math.min(#c, 24))
    end

    local cell_w = 10
    for _, l in ipairs(layers) do
        cell_w = math.max(cell_w, math.min(#l, 18))
    end
    local min_cell_w = 16
    cell_w = math.min(math.max(cell_w, min_cell_w), 30)

    local sep = " | "

    if max_width and #layers > 0 then
        local avail = max_width - concept_w - (#sep * #layers)
        if avail > 0 then
            cell_w = math.min(cell_w, math.floor(avail / #layers))
        end
        cell_w = math.max(min_cell_w, math.min(cell_w, 30))
    end

    local first_col_w = concept_w
    local first_cell_col = first_col_w + #sep
    local stride = cell_w + #sep

    local table_w = concept_w + (#layers * cell_w) + (#layers * #sep)

    return {
        concept_w = concept_w,
        cell_w = cell_w,
        sep = sep,
        first_cell_col = first_cell_col,
        stride = stride,
        table_w = table_w,
    }
end

---@param concepts string[]
---@param layers string[]
---@param layout table
---@return string[]
local function render_matrix_lines(concepts, layers, layout)
    local lines = {}

    local header = fit_cell("Concept", layout.concept_w)
    for _, layer in ipairs(layers) do
        header = header .. layout.sep .. fit_cell(layer, layout.cell_w)
    end
    table.insert(lines, header)

    for _, concept in ipairs(concepts) do
        local row = fit_cell(concept, layout.concept_w)
        local clist = Ctx.get_concept_list(concept)
        for i = 1, #layers do
            local item = clist:get(i)
            local v = (item and item.value) and short_path(item.value) or ""
            if Ctx.is_blank(v) then
                v = "."
            end
            row = row .. layout.sep .. fit_cell(v, layout.cell_w)
        end
        table.insert(lines, row)
    end

    return lines
end

---@param concepts string[]
---@param layers string[]
---@param layout table
local function set_ui_cursor(concepts, layers, layout)
    if not UI.win_id or not vim.api.nvim_win_is_valid(UI.win_id) then
        return
    end

    local r = wrap_idx(Ctx.state.nav.concept_idx, #concepts)
    local c = wrap_idx(Ctx.state.nav.layer_idx, #layers)
    Ctx.state.nav.concept_idx = r
    Ctx.state.nav.layer_idx = c

    local line = 1 + r
    local col = layout.first_cell_col + ((c - 1) * layout.stride)
    pcall(vim.api.nvim_win_set_cursor, UI.win_id, { line, col })
end

---@param concepts string[]
---@param layers string[]
---@param layout table
function UI:_apply_highlights(concepts, layers, layout)
    if not (self.bufnr and vim.api.nvim_buf_is_valid(self.bufnr)) then
        return
    end
    local ns = self.ns or vim.api.nvim_create_namespace("onioncrab-ui")
    self.ns = ns
    vim.api.nvim_buf_clear_namespace(self.bufnr, ns, 0, -1)

    -- Header row
    vim.api.nvim_buf_add_highlight(self.bufnr, ns, "OnioncrabHeader", 0, 0, -1)

    -- Column headers (layer names)
    local start = layout.first_cell_col
    for i = 1, #layers do
        local col = start + ((i - 1) * layout.stride)
        vim.api.nvim_buf_add_highlight(
            self.bufnr,
            ns,
            "OnioncrabHeaderCol",
            0,
            col,
            col + layout.cell_w
        )
    end

    -- Left header column (concept names)
    for i = 1, #concepts do
        local line = i
        vim.api.nvim_buf_add_highlight(
            self.bufnr,
            ns,
            "OnioncrabHeaderCol",
            line,
            0,
            layout.concept_w
        )
    end

    -- Separators
    local sep_start = layout.concept_w
    for i = 0, #concepts do
        local col = sep_start
        for _ = 1, #layers do
            vim.api.nvim_buf_add_highlight(
                self.bufnr,
                ns,
                "OnioncrabSeparator",
                i,
                col,
                col + #layout.sep
            )
            col = col + layout.stride
        end
    end

    -- Active row/col headers + active cell
    local r = wrap_idx(Ctx.state.nav.concept_idx, #concepts)
    local c = wrap_idx(Ctx.state.nav.layer_idx, #layers)
    vim.api.nvim_buf_add_highlight(
        self.bufnr,
        ns,
        "OnioncrabActiveHeaderCol",
        r,
        0,
        layout.concept_w
    )
    local header_cell_col = layout.first_cell_col + ((c - 1) * layout.stride)
    vim.api.nvim_buf_add_highlight(
        self.bufnr,
        ns,
        "OnioncrabActiveHeader",
        0,
        header_cell_col,
        header_cell_col + layout.cell_w
    )

    local cell_line = r
    local cell_col = layout.first_cell_col + ((c - 1) * layout.stride)
    vim.api.nvim_buf_add_highlight(
        self.bufnr,
        ns,
        "OnioncrabActiveCell",
        cell_line,
        cell_col,
        cell_col + layout.cell_w
    )
end

---@param opts? table
---@return number win_id, number bufnr
function UI:_create_window(opts)
    opts = opts or {}
    local ui = vim.api.nvim_list_uis()
    local width = opts.width_in_columns
    if not width then
        width = opts.ui_fallback_width or 90
        if #ui > 0 then
            width = math.floor(ui[1].width * (opts.ui_width_ratio or 0.8))
        end
        if opts.ui_max_width and width > opts.ui_max_width then
            width = opts.ui_max_width
        end
    end

    if #ui > 0 then
        width = math.min(width, math.max(10, ui[1].width - 6))
    end

    local height = opts.height_in_lines or 12
    local bufnr = vim.api.nvim_create_buf(false, true)
    local win_id = vim.api.nvim_open_win(bufnr, true, {
        relative = "editor",
        title = opts.title or "onioncrab",
        title_pos = opts.title_pos or "left",
        row = math.floor(((vim.o.lines - height) / 2) - 1),
        col = math.floor((vim.o.columns - width) / 2),
        width = width,
        height = height,
        style = "minimal",
        border = opts.border or "single",
    })

    if win_id == 0 then
        vim.api.nvim_buf_delete(bufnr, { force = true })
        error("onioncrab: failed to create UI window")
    end

    vim.api.nvim_set_option_value("filetype", "onioncrab", { buf = bufnr })
    vim.api.nvim_set_option_value("buftype", "nofile", { buf = bufnr })
    vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = bufnr })
    vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })
    vim.api.nvim_set_option_value("number", false, { win = win_id })
    vim.api.nvim_set_option_value("relativenumber", false, { win = win_id })
    vim.api.nvim_set_option_value("wrap", false, { win = win_id })
    vim.api.nvim_set_option_value("cursorline", true, { win = win_id })
    vim.api.nvim_set_option_value("signcolumn", "no", { win = win_id })
    vim.api.nvim_set_option_value("foldcolumn", "0", { win = win_id })

    self.win_id = win_id
    self.bufnr = bufnr
    self._layout = nil
    self.ns = self.ns or vim.api.nvim_create_namespace("onioncrab-ui")

    -- Keymaps: delegate back to onioncrab public API
    vim.keymap.set("n", "q", function()
        require("onioncrab").menu()
    end, { buffer = bufnr, silent = true })
    vim.keymap.set("n", "<Esc>", function()
        require("onioncrab").menu()
    end, { buffer = bufnr, silent = true })
    vim.keymap.set("n", "<CR>", function()
        require("onioncrab").open()
    end, { buffer = bufnr, silent = true })

    vim.keymap.set("n", "h", function()
        require("onioncrab")._ui_move(0, -1)
    end, { buffer = bufnr, silent = true })
    vim.keymap.set("n", "l", function()
        require("onioncrab")._ui_move(0, 1)
    end, { buffer = bufnr, silent = true })
    vim.keymap.set("n", "k", function()
        require("onioncrab")._ui_move(-1, 0)
    end, { buffer = bufnr, silent = true })
    vim.keymap.set("n", "j", function()
        require("onioncrab")._ui_move(1, 0)
    end, { buffer = bufnr, silent = true })

    vim.api.nvim_create_autocmd({ "BufLeave" }, {
        buffer = bufnr,
        callback = function()
            pcall(function()
                require("onioncrab").menu()
            end)
        end,
    })

    return win_id, bufnr
end

function UI:close()
    if self.closing then
        return
    end
    self.closing = true
    if self.bufnr and vim.api.nvim_buf_is_valid(self.bufnr) then
        vim.api.nvim_buf_delete(self.bufnr, { force = true })
    end
    if self.win_id and vim.api.nvim_win_is_valid(self.win_id) then
        vim.api.nvim_win_close(self.win_id, true)
    end
    self.win_id = nil
    self.bufnr = nil
    self._layout = nil
    self.closing = false
end

function UI:render()
    if not (self.bufnr and vim.api.nvim_buf_is_valid(self.bufnr)) then
        return
    end

    if #Ctx.get_concepts() == 0 then
        Ctx.ensure_current_concept()
    end

    local concepts = Ctx.get_concepts()
    local layers = Ctx.get_layers()
    local max_width = nil
    if self.win_id and vim.api.nvim_win_is_valid(self.win_id) then
        max_width = vim.api.nvim_win_get_width(self.win_id)
    end
    local layout = compute_matrix_layout(concepts, layers, max_width)
    self._layout = layout

    local lines = render_matrix_lines(concepts, layers, layout)
    vim.api.nvim_set_option_value("modifiable", true, { buf = self.bufnr })
    vim.api.nvim_buf_set_lines(self.bufnr, 0, -1, false, lines)
    vim.api.nvim_set_option_value("modifiable", false, { buf = self.bufnr })

    self:_apply_highlights(concepts, layers, layout)
    set_ui_cursor(concepts, layers, layout)
end

function UI:toggle()
    if self.win_id ~= nil then
        self:close()
        return
    end

    local concepts = Ctx.get_concepts()
    if #concepts == 0 then
        Ctx.ensure_current_concept()
        concepts = Ctx.get_concepts()
    end
    local layers = Ctx.get_layers()
    local height = math.min((#concepts + 1), math.max(6, vim.o.lines - 6))

    local layout = compute_matrix_layout(concepts, layers, nil)
    local width = math.max(20, layout.table_w)

    self:_create_window({
        title = string.format(
            "onioncrab: %s (%d concepts)",
            Ctx.current_framework(),
            #concepts
        ),
        height_in_lines = height,
        width_in_columns = width,
    })
    self:render()
end

function M.setup(ctx)
    Ctx = ctx
end

function M.toggle()
    if not Ctx then
        error("onioncrab.ui: setup(ctx) not called")
    end
    UI:toggle()
end

---@param drow number
---@param dcol number
function M.move(drow, dcol)
    if not Ctx then
        return
    end
    if not (UI.win_id and vim.api.nvim_win_is_valid(UI.win_id)) then
        return
    end

    local concepts = Ctx.get_concepts()
    local layers = Ctx.get_layers()
    if #concepts == 0 or #layers == 0 then
        return
    end

    Ctx.state.nav.concept_idx = wrap_idx(Ctx.state.nav.concept_idx + drow, #concepts)
    Ctx.state.nav.layer_idx = wrap_idx(Ctx.state.nav.layer_idx + dcol, #layers)
    UI:render()
end

return M
