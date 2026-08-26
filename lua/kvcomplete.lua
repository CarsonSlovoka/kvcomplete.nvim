-- ---@diagnostic disable: undefined-field
-- kvcomplete.lua
-- Neovim 0.12+ unified command completion.
-- Base form: key=value (order-independent).
-- Optional subs: first bare token selects a leaf spec; remaining tokens stay key=value.

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
---@field sub string|nil           -- selected subcommand, if any

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

---@class KvSubSpec
---@field keys table<string, KvKeySpec|string|string[]|boolean|KvKind>|nil
---@field pri integer|nil

---@class KvSpec
---@field keys table<string, KvKeySpec|string|string[]|boolean|KvKind>|nil
---@field subs table<string, KvSubSpec|table>|nil
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
---@field has_subs boolean
---@field subs table<string, KvCompiled>|nil
---@field sub_names string[]|nil
---@field pri integer|nil          -- only on sub leaves, for name sort

---@class KvParsed
---@field kv table<string, string|string[]|boolean>
---@field sub string|nil
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
    k.kind = raw
  elseif t == "table" and raw[1] ~= nil and raw.kind == nil and raw.values == nil then
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

---Compile a flat keys table into list + by_name.
---@param keys table<string, KvKeySpec|string|string[]|boolean|KvKind>|nil
---@param strict boolean
---@param max integer
---@return KvCompiled
local function compile_keys(keys, strict, max)
  ---@type KvCompiledKey[]
  local list = {}
  ---@type table<string, KvCompiledKey>
  local by_name = {}
  if keys then
    for name, raw in pairs(keys) do
      local k = compile_key(name, raw)
      list[#list + 1] = k
      by_name[name] = k
    end
    table.sort(list, function(a, b)
      if a.pri ~= b.pri then return a.pri > b.pri end
      return a.name < b.name
    end)
  end
  return {
    list = list,
    by_name = by_name,
    strict = strict,
    max = max,
    has_subs = false,
  }
end

---@param raw KvSubSpec|table
---@return table keys, integer pri
local function sub_keys_and_pri(raw)
  if type(raw) ~= "table" then
    return {}, 0
  end
  if raw.keys ~= nil then
    return raw.keys, raw.pri or 0
  end
  return raw, 0
end

---Compile a user spec once. Call at command-definition time, not in complete().
---No `subs` → identical to the original flat key=value spec.
---@param spec KvSpec
---@return KvCompiled
function M.compile(spec)
  assert(type(spec) == "table", "kvcomplete: spec table required")
  assert(spec.keys ~= nil or spec.subs ~= nil, "kvcomplete: spec.keys or spec.subs required")

  local strict = spec.strict ~= false
  local max = spec.max or MAX
  local root_keys = spec.keys or {}
  local root = compile_keys(root_keys, strict, max)

  if not spec.subs then
    return root
  end

  ---@type table<string, KvCompiled>
  local subs = {}
  ---@type string[]
  local names = {}
  for name, raw in pairs(spec.subs) do
    local extra, pri = sub_keys_and_pri(raw)
    ---@type table<string, KvKeySpec|string|string[]|boolean|KvKind>
    local merged = {}
    for k, v in pairs(root_keys) do
      merged[k] = v
    end
    if type(extra) == "table" then
      for k, v in pairs(extra) do
        merged[k] = v
      end
    end
    local leaf = compile_keys(merged, strict, max)
    leaf.pri = pri
    subs[name] = leaf
    names[#names + 1] = name
  end
  table.sort(names, function(a, b)
    local pa, pb = subs[a].pri or 0, subs[b].pri or 0
    if pa ~= pb then return pa > pb end
    return a < b
  end)

  root.has_subs = true
  root.subs = subs
  root.sub_names = names
  return root
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
  local q = nil
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

---@param cmd_line string
---@param cursor_pos integer
---@return KvToken[]
local function args_tokens(cmd_line, cursor_pos)
  local stop = math.min(cursor_pos, #cmd_line)
  local sp = cmd_line:find("%s") or (stop + 1)
  return tokenize(cmd_line, sp + 1, stop)
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

---@param leaf KvCompiled
---@param tokens KvToken[]
---@param start integer
---@return KvParsed
local function parse_tokens(leaf, tokens, start)
  ---@type table<string, string|string[]|boolean>
  local kv = {}
  ---@type string[]
  local unknown, errors = {}, {}

  for i = start, #tokens do
    local key, val = split_kv(tokens[i].text)
    if key == "" then
      errors[#errors + 1] = "empty key in '" .. tokens[i].text .. "'"
    else
      local spec = leaf.by_name[key]
      if not spec then
        unknown[#unknown + 1] = key
        if leaf.strict then
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
  for i = 1, #leaf.list do
    local k = leaf.list[i]
    if k.required and kv[k.name] == nil then
      missing[#missing + 1] = k.name
      errors[#errors + 1] = "missing required key: " .. k.name
    end
  end
  return { kv = kv, unknown = unknown, missing = missing, errors = errors }
end

---Parse a full args string (not fargs) into kv map.
---If compiled.has_subs and the first token has no '=', that token is the sub.
---@param compiled KvCompiled
---@param args string
---@return KvParsed
function M.parse(compiled, args)
  args = args or ""
  local tokens = tokenize(args, 1, #args)

  local leaf = compiled
  local sub = nil
  local start = 1

  if compiled.has_subs and tokens[1] then
    local name, val = split_kv(tokens[1].text)
    if val == nil then
      local found = compiled.subs and compiled.subs[name]
      if found then
        sub = name
        leaf = found
        start = 2
      else
        return {
          kv = {},
          sub = nil,
          unknown = { name },
          missing = {},
          errors = { "unknown subcommand: " .. name },
        }
      end
    elseif #compiled.list == 0 then
      return {
        kv = {},
        sub = nil,
        unknown = {},
        missing = {},
        errors = { "missing subcommand" },
      }
    end
  end

  local parsed = parse_tokens(leaf, tokens, start)
  parsed.sub = sub
  return parsed
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

---Collect finished key=value tokens starting at `start`.
---@param tokens KvToken[]
---@param start integer
---@return table<string, boolean> used
---@return table<string, string> kv
local function keys_from_tokens(tokens, start)
  ---@type table<string, boolean>
  local used = {}
  ---@type table<string, string>
  local kv = {}
  for i = start, #tokens do
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

---Complete against one compiled leaf (root or sub).
---@param leaf KvCompiled
---@param arg_lead string
---@param used table<string, boolean>
---@param kv_so_far table<string, string>
---@param sub string|nil
---@return string[]
local function complete_kv(leaf, arg_lead, used, kv_so_far, sub)
  local cap = leaf.max
  local key, val = split_kv(arg_lead)

  if val == nil then
    ---@type string[]
    local names = {}
    for i = 1, #leaf.list do
      local k = leaf.list[i]
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

  local spec = leaf.by_name[key]
  if not spec then return {} end

  ---@type KvCtx
  local ctx = {
    key = key,
    lead = unquote(val),
    raw = arg_lead,
    kv = kv_so_far,
    used = used,
    sub = sub,
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

---customlist complete. Return order = Tab order.
---With subs: first unfinished bare token completes sub names (no '=').
---@param compiled KvCompiled
---@param arg_lead string
---@param cmd_line string
---@param cursor_pos integer
---@return string[]
function M.complete(compiled, arg_lead, cmd_line, cursor_pos)
  local tokens = args_tokens(cmd_line, cursor_pos)

  if compiled.has_subs then
    local first_done = nil
    for i = 1, #tokens do
      if tokens[i].done then
        first_done = tokens[i]
        break
      end
    end

    if not first_done then
      local _, val = split_kv(arg_lead)
      if val == nil then
        return fuzzy_take(compiled.sub_names or {}, arg_lead, compiled.max)
      end
      return complete_kv(compiled, arg_lead, {}, {}, nil)
    end

    local name, val = split_kv(first_done.text)
    if val == nil then
      local leaf = compiled.subs and compiled.subs[name]
      if leaf then
        local used, kv = keys_from_tokens(tokens, 2)
        return complete_kv(leaf, arg_lead, used, kv, name)
      end
      return fuzzy_take(compiled.sub_names or {}, arg_lead, compiled.max)
    end
  end

  local used, kv = keys_from_tokens(tokens, 1)
  return complete_kv(compiled, arg_lead, used, kv, nil)
end

----------------------------------------------------------------------
-- Command factory
----------------------------------------------------------------------

---@class KvCommandOpts
---@field kv table<string, string|string[]|boolean>
---@field sub string|nil
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

---Create a user command. Args are `[sub] key=value...`.
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
      sub = parsed.sub,
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
