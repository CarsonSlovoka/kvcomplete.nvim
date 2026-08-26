-- ln -siv $(realpath kvcomplete_test.lua) ~/.config/nvim/plugin/
vim.cmd.packadd("kvcomplete.nvim")
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
    -- 子命令範例
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
    tag2 = { unique = false },
  },
})

kv.create("Tool", function(opts)
  print(vim.inspect(opts))
  -- opts.sub  = "build" | "test" | nil
  -- opts.kv   = { target = "release", jobs = "4" }
end, {
  subs = { -- sub command, 首參數不需要=
    build = {
      pri = 20,
      keys = { target = { "debug", "release" } }, -- 會為keys增加此target選項
    },
    test = {
      file = "file",
      filter = true
    },          -- 短寫: 當省略keys時，這些數值都會加入到keys之中
    clean = {}, -- 不額外新增keys的參數
  },
  keys = {
    -- root keys 共用的keys內容
    jobs = { kind = "number", hint = { "1", "4", "8" } },
    verbose = "bool",
    debug = {
      pri = -10,
      values_fn = function(ctx)
        -- print(vim.inspect(ctx))
        if ctx.kv.jobs == "4" then
          return { "unit", "e2e" }
        elseif ctx.sub == "build" then
          -- 當有subs時ctx提供sub, 使得可以依sub來決定參數
          return { "b1", "b2" }
        end
        return { "debug", "release" }
      end,
    }
  },
})


local test_cmd_spec = kv.compile({
  keys = {
    foo = { "a", "b" },
    path = "file"
  }
})
-- 也能用原始的nvim指令，只套用補全就好
vim.api.nvim_create_user_command("Testcmd", function(opts)
  print(vim.inspect(opts))
end, {
  nargs = "*",
  complete = function(a, c, p)
    return kv.complete(test_cmd_spec, a, c, p)
  end,
})
