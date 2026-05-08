local M = {}

M.did_setup = false

M.config = {
    concept_list_name = "__onioncrab_concepts",
    list_prefix = "__onioncrab_concept::",
    frameworks = {},
    notify = true,
}

M.project = {
    framework = nil,
}

M.nav = {
    concept_idx = 1,
    layer_idx = 1,
}

return M
