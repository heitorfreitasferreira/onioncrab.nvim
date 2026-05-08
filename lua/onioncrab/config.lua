local M = {}

---@class OnioncrabFrameworkSpec
---@field layers string[]
---@field concept_suffixes? string[]
---@field layer_rules? OnioncrabRule[]
---@field root_dir? fun(): string

---@class OnioncrabRule
---@field layer string
---@field path? string[] plain substrings
---@field filename? string[] plain substrings
---@field content? string[] lua patterns

local function default_frameworks()
    return {
        ["django-rest"] = {
            layers = {
                "model",
                "serializer",
                "view",
                "service",
                "repository",
                "url",
                "test",
            },
            concept_suffixes = {
                "model",
                "models",
                "serializer",
                "serializers",
                "view",
                "views",
                "viewset",
                "service",
                "repository",
                "urls",
                "tests",
            },
            layer_rules = {
                {
                    layer = "model",
                    filename = { "models.py" },
                    content = { "from%s+django%.db%s+import%s+models" },
                },
                {
                    layer = "serializer",
                    filename = { "serializers.py" },
                    content = {
                        "class%s+%w+Serializer%s*%(",
                        "from%s+rest_framework",
                    },
                },
                {
                    layer = "view",
                    filename = { "views.py" },
                    content = {
                        "class%s+%w+ViewSet%s*%(",
                        "from%s+rest_framework%.views",
                    },
                },
                {
                    layer = "url",
                    filename = { "urls.py" },
                    content = { "urlpatterns%s*=" },
                },
                {
                    layer = "test",
                    path = { "/tests/" },
                    filename = { "test_" },
                },
                {
                    layer = "service",
                    path = { "/services/" },
                    filename = { "service" },
                },
                {
                    layer = "repository",
                    path = { "/repositories/", "/repos/" },
                    filename = { "repo", "repository" },
                },
            },
        },
        spring = {
            layers = {
                "controller",
                "service",
                "repository",
                "entity",
                "dto",
                "mapper",
                "test",
            },
            concept_suffixes = {
                "controller",
                "service",
                "repository",
                "entity",
                "dto",
                "mapper",
                "test",
            },
            layer_rules = {
                {
                    layer = "controller",
                    content = { "@RestController", "@Controller" },
                },
                {
                    layer = "service",
                    content = { "@Service" },
                    filename = { "Service" },
                },
                {
                    layer = "repository",
                    content = { "@Repository" },
                    filename = { "Repository" },
                },
                {
                    layer = "entity",
                    content = { "@Entity" },
                    path = { "/entity/", "/entities/" },
                },
                {
                    layer = "dto",
                    filename = { "Dto", "DTO" },
                    path = { "/dto/", "/dtos/" },
                },
                {
                    layer = "mapper",
                    filename = { "Mapper" },
                    path = { "/mapper/", "/mappers/" },
                },
                {
                    layer = "test",
                    path = { "/src/test/" },
                    filename = { "Test" },
                },
            },
        },
    }
end

---@param user any
---@return any
local function deep_merge(user, base)
    if user == nil then
        return base
    end
    if type(user) ~= "table" or type(base) ~= "table" then
        return user
    end
    local out = vim.tbl_deep_extend("force", {}, base, user)
    return out
end

function M.merge(user_config)
    user_config = user_config or {}
    local base = {
        concept_list_name = "__onioncrab_concepts",
        list_prefix = "__onioncrab_concept::",
        frameworks = default_frameworks(),
        notify = true,
    }
    return deep_merge(user_config, base)
end

return M
