-- kvcomplete.lua
-- Neovim 0.12+ unified key=value command completion.
-- Declare a spec per command; complete / parse / validate share one compiled form.

local M           = {}

local MAX         = 50

----------------------------------------------------------------------
-- Types
----------------------------------------------------------------------

---@alias KvKind
---| 'enum'      # fixed string list (or values/values_fn)
---| 'file'      # vim file completion
---| 'dir'       # directory completion
---| 'buffer'    # buffer name
---| 'command'   # Ex command
---| 'help'      # help tag
---| 'highlight' # hl group
---| 'option'    # option name
---| 'color'     # colorscheme
---| 'bool'      # true/false
---| 'flag'      # presence; completes as key=true
---| 'number'
---| 'string'
---| 'custom'    # values_fn required

---@class KvCtx
---@field key string
---@field lead string              -- value side only (after '=')
---@field raw string               -- whole ArgLead token
---@field kv table<string, string|string[]|boolean>
---@field used table<string, boolean>

---@class KvKeySpec
---@field kind KvKind|nil
---@field values string[]|nil
---@field values_fn fun(ctx: KvCtx): string[]|nil
---@field unique boolean|nil       -- default true
---@field required boolean|nil
---@field pri integer|nil
---@field hint string[]|nil        -- shown when value is empty (number/string)

---@class KvCompiledKey
---@field name string
---@field kind KvKind
---@field values string[]|nil
---@field values_fn? fun(ctx: KvCtx): string[]|nil
---@field unique boolean
---@field required boolean
---@field pri integer
---@field hint string[]|nil

---@class KvSpec
---@field keys table<string, KvKeySpec|string|string[]|boolean|KvKind>
---@field strict boolean|nil       -- reject unknown keys at run time (default true)
---@field max integer|nil          -- complete cap (default 50)
---@field desc string|nil
---@field bang boolean|nil
---@field range boolean|string|nil
---@field force boolean|nil
---@field nargs string|nil

---@class KvCompiled
---@field list KvCompiledKey[]     -- pri desc, then name
---@field by_name table<string, KvCompiledKey>
---@field strict boolean
---@field max integer

---@class KvParsed
---@field kv table<string, string|string[]|boolean>
---@field unknown string[]
---@field missing string[]
---@field errors string[]

----------------------------------------------------------------------
-- Builtin value sources (kind → getcompletion type)
----------------------------------------------------------------------

local KIND_COMPL  = {
  file = "file",
  dir = "dir",
  buffer = "buffer",
  command = "command",
  help = "help",
  highlight = "highlight",
  option = "option",
  color = "color",
}

local BOOL_VALUES = { "true", "false" }

----------------------------------------------------------------------
-- Compile
----------------------------------------------------------------------

---Normalize one key entry from the short or long form.
---@param name string
---@param raw KvKeySpec|string|string[]|boolean|KvKind
---@return KvCompiledKey
local function compile_key(name, raw)
  ---@type KvCompiledKey
  local k = {
    name = name,
    kind = "string",
    unique = true,
    required = false,
    pri = 0,
  }

  local t = type(raw)
  if raw == true then
    k.kind = "string"
  elseif t == "string" then
    k.kind = raw -- kind shorthand: file / bool / buffer / ...
  elseif t == "table" and raw[1] ~= nil and raw.kind == nil and raw.values == nil then
    -- { 'en', 'zh' } → enum
    k.kind = "enum"
    k.values = raw
  elseif t == "table" then
    ---@cast raw KvKeySpec
    k.kind = raw.kind or (raw.values or raw.values_fn) and "enum" or "string"
    k.values = raw.values
    k.values_fn = raw.values_fn
    if raw.unique ~= nil then k.unique = raw.unique end
    k.required = raw.required == true
    k.pri = raw.pri or 0
    k.hint = raw.hint
  else
    error("kvcomplete: bad spec for key '" .. name .. "'")
  end

  if k.kind == "bool" or k.kind == "flag" then
    k.values = k.values or BOOL_VALUES
  end
  return k
end

---Compile a user spec once. Call at command-definition time, not in complete().
---@param spec KvSpec
---@return KvCompiled
function M.compile(spec)
  assert(type(spec) == "table" and type(spec.keys) == "table", "kvcomplete: spec.keys required")
  ---@type KvCompiledKey[]
  local list = {}
  ---@type table<string, KvCompiledKey>
  local by_name = {}
  for name, raw in pairs(spec.keys) do
    local k = compile_key(name, raw)
    list[#list + 1] = k
    by_name[name] = k
  end
  table.sort(list, function(a, b)
    if a.pri ~= b.pri then return a.pri > b.pri end
    return a.name < b.name
  end)
  return {
    list = list,
    by_name = by_name,
    strict = spec.strict ~= false,
    max = spec.max or MAX,
  }
end

----------------------------------------------------------------------
-- Tokenize / parse  (quote-aware, single pass)
----------------------------------------------------------------------

---@class KvToken
---@field text string
---@field done boolean             -- true if closed by whitespace

---Scan [i, stop] of s into tokens. Quotes keep spaces inside one token.
---@param s string
---@param i integer
---@param stop integer
---@return KvToken[]
local function tokenize(s, i, stop)
  ---@type KvToken[]
  local out, acc = {}, {}
  local q = nil -- current quote char
  local function flush(done)
    if #acc == 0 then return end
    out[#out + 1] = { text = table.concat(acc), done = done }
    acc = {}
  end
  while i <= stop do
    local c = s:sub(i, i)
    if q then
      acc[#acc + 1] = c
      if c == q then q = nil end
    elseif c == "'" or c == '"' then
      q = c
      acc[#acc + 1] = c
    elseif c:find("%s") then
      flush(true)
    else
      acc[#acc + 1] = c
    end
    i = i + 1
  end
  if #acc > 0 then
    flush(false)
  end
  return out
end

---Strip one layer of matching quotes.
---@param s string
---@return string
local function unquote(s)
  local a, b = s:sub(1, 1), s:sub(-1)
  if #s >= 2 and (a == '"' or a == "'") and a == b then
    return s:sub(2, -2)
  end
  return s
end

---Split one token into key, value. value=nil means no '=' yet.
---@param tok string
---@return string key, string|nil val
local function split_kv(tok)
  local eq = tok:find("=", 1, true)
  if not eq then return tok, nil end
  return tok:sub(1, eq - 1), tok:sub(eq + 1)
end

---Parse a full args string (not fargs) into kv map.
---@param compiled KvCompiled
---@param args string
---@return KvParsed
function M.parse(compiled, args)
  ---@type table<string, string|string[]|boolean>
  local kv = {}
  ---@type string[]
  local unknown, errors = {}, {}
  args = args or ""
  local tokens = tokenize(args, 1, #args)
  for i = 1, #tokens do
    local key, val = split_kv(tokens[i].text)
    if key == "" then
      errors[#errors + 1] = "empty key in '" .. tokens[i].text .. "'"
    else
      local spec = compiled.by_name[key]
      if not spec then
        unknown[#unknown + 1] = key
        if compiled.strict then
          errors[#errors + 1] = "unknown key: " .. key
        end
      elseif val == nil then
        if spec.kind == "flag" then
          kv[key] = true
        else
          errors[#errors + 1] = "missing '=' for key: " .. key
        end
      else
        val = unquote(val)
        if spec.kind == "bool" or spec.kind == "flag" then
          kv[key] = (val == "true" or val == "1" or val == "yes")
        elseif spec.unique == false then
          local cur = kv[key]
          if type(cur) ~= "table" then
            kv[key] = { val }
          else
            cur[#cur + 1] = val
          end
        else
          kv[key] = val
        end
      end
    end
  end
  ---@type string[]
  local missing = {}
  for i = 1, #compiled.list do
    local k = compiled.list[i]
    if k.required and kv[k.name] == nil then
      missing[#missing + 1] = k.name
      errors[#errors + 1] = "missing required key: " .. k.name
    end
  end
  return { kv = kv, unknown = unknown, missing = missing, errors = errors }
end

----------------------------------------------------------------------
-- Complete
----------------------------------------------------------------------

---@param items string[]
---@param needle string
---@param cap integer
---@return string[]
local function fuzzy_take(items, needle, cap)
  if #items == 0 then return {} end
  local src = items
  if needle ~= "" then
    src = vim.fn.matchfuzzy(items, needle)
  end
  local n = math.min(cap, #src)
  local out = {}
  for i = 1, n do out[i] = src[i] end
  return out
end

---@param spec KvCompiledKey
---@param ctx KvCtx
---@return string[]
local function values_of(spec, ctx)
  if spec.values_fn then
    local ok, res = pcall(spec.values_fn, ctx)
    if ok and type(res) == "table" then return res end
    return {}
  end
  local ctype = KIND_COMPL[spec.kind]
  if ctype then
    return vim.fn.getcompletion(ctx.lead, ctype)
  end
  if spec.values then return spec.values end
  if spec.hint and ctx.lead == "" then return spec.hint end
  return spec.hint or {}
end

---Build already-finished keys from cmdline left of cursor.
---@param cmd_line string
---@param cursor_pos integer
---@return table<string, boolean> used
---@return table<string, string> kv_so_far
local function context_left(cmd_line, cursor_pos)
  local stop = math.min(cursor_pos, #cmd_line)
  -- skip command name
  local sp = cmd_line:find("%s") or (stop + 1)
  local tokens = tokenize(cmd_line, sp + 1, stop)
  ---@type table<string, boolean>
  local used = {}
  ---@type table<string, string>
  local kv = {}
  for i = 1, #tokens do
    local tok = tokens[i]
    if tok.done then
      local key, val = split_kv(tok.text)
      if key ~= "" then
        used[key] = true
        if val ~= nil then kv[key] = unquote(val) end
      end
    end
  end
  return used, kv
end

---customlist complete. Return order = Tab order.
---@param compiled KvCompiled
---@param arg_lead string
---@param cmd_line string
---@param cursor_pos integer
---@return string[]
function M.complete(compiled, arg_lead, cmd_line, cursor_pos)
  local cap = compiled.max
  local used, kv_so_far = context_left(cmd_line, cursor_pos)
  local key, val = split_kv(arg_lead)

  -- no '=' yet → suggest key=
  if val == nil then
    ---@type string[]
    local names = {}
    for i = 1, #compiled.list do
      local k = compiled.list[i]
      if not (k.unique and used[k.name]) then
        names[#names + 1] = k.name
      end
    end
    local hit = fuzzy_take(names, key, cap)
    for i = 1, #hit do
      hit[i] = hit[i] .. "="
    end
    return hit
  end

  local spec = compiled.by_name[key]
  if not spec then return {} end

  ---@type KvCtx
  local ctx = {
    key = key,
    lead = unquote(val),
    raw = arg_lead,
    kv = kv_so_far,
    used = used,
  }
  local vals = values_of(spec, ctx)
  local hit = fuzzy_take(vals, ctx.lead, cap)
  local prefix = key .. "="
  for i = 1, #hit do
    local w = hit[i]
    if w:find("%s") then
      w = '"' .. w:gsub('"', '\\"') .. '"'
    end
    hit[i] = prefix .. w
  end
  return hit
end

----------------------------------------------------------------------
-- Command factory
----------------------------------------------------------------------

---@class KvCommandOpts
---@field kv table<string, string|string[]|boolean>
---@field parsed KvParsed
---@field args string
---@field fargs string[]
---@field bang boolean
---@field name string
---@field line1 integer
---@field line2 integer
---@field range integer
---@field count integer
---@field reg string
---@field smods table

---Create a user command whose args are key=value tokens.
---@param name string
---@param fn fun(opts: KvCommandOpts)
---@param spec KvSpec
function M.create(name, fn, spec)
  local compiled = M.compile(spec)
  vim.api.nvim_create_user_command(name, function(opts)
    local parsed = M.parse(compiled, opts.args)
    ---@type KvCommandOpts
    local wrap = {
      kv = parsed.kv,
      parsed = parsed,
      args = opts.args,
      fargs = opts.fargs,
      bang = opts.bang,
      name = opts.name,
      line1 = opts.line1,
      line2 = opts.line2,
      range = opts.range,
      count = opts.count,
      reg = opts.reg,
      smods = opts.smods,
    }
    if compiled.strict and #parsed.errors > 0 then
      vim.notify(name .. ": " .. parsed.errors[1], vim.log.levels.ERROR)
      return
    end
    fn(wrap)
  end, {
    nargs = spec.nargs or "*",
    desc = spec.desc,
    bang = spec.bang,
    range = spec.range,
    force = spec.force ~= false,
    complete = function(arg_lead, cmd_line, cursor_pos)
      return M.complete(compiled, arg_lead, cmd_line, cursor_pos)
    end,
  })
  return compiled
end

return M
