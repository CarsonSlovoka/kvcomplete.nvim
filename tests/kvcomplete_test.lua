vim.cmd.packadd("kvcomplete")
local kv = require("kvcomplete")

kv.create("Hello", function(opts)
  -- opts.kv.name / opts.kv.lang / opts.kv.file
  vim.print(opts.kv)
end, {
  desc = "demo",
  keys = {
    name = true,                 -- 自由字串
    lang = { "en", "zh", "ja" }, -- enum
    file = "file",               -- 內建 kind
    force = "bool",              -- true/false
  },
})

kv.create("Build", function(opts)
  local t = opts.kv.target
  local jobs = tonumber(opts.kv.jobs) or 4
  print(vim.inspect(opts))
end, {
  keys = {
    cmd = {
      kind = "enum",
      values = { "build", "test", "clean" },
      required = true,
      pri = 100, -- 數值大擺放的順序就優先
    },
    target = {
      pri = 90,
      values_fn = function(ctx)
        if ctx.kv.cmd == "test" then
          return { "unit", "e2e" }
        end
        return { "debug", "release" }
      end,
    },
    jobs = { kind = "number", hint = { "1", "4", "8" } },
    tag = { unique = false }, -- tag=a tag=b → kv.tag = { "a", "b" } -- 用unique使得可以放array
  },
})

return {}
