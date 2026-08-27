-- ---@diagnostic disable: undefined-field
-- kvcomplete.lua
-- Neovim 0.12+ unified command completion.
--
-- Grammar of one command:
--   [sub] [pos1 pos2 ...] [key=value ...]
--
-- sub  : first bare token, only if spec.subs exists
-- pos  : ordered bare tokens on the active leaf (root or sub)
-- keys : order-independent key=value after positionals

local M           = {}

local MAX         = 50

----------------------------------------------------------------------
-- Types
----------------------------------------------------------------------

---@alias KvKind
---| 'enum'
---| 'file'
---| 'dir'
---| 'buffer'
---| 'command'
---| 'help'
---| 'highlight'
---| 'option'
---| 'color'
---| 'bool'
---| 'flag'
---| 'number'
---| 'string'
---| 'custom'

---@class KvCtx
---@field key string
---@field lead string
---@field raw string
---@field kv table<string, string|string[]|boolean>
---@field used table<string, boolean>
---@field sub string|nil

---@class KvKeySpec
---@field kind KvKind|nil
---@field values string[]|nil
---@field values_fn fun(ctx: KvCtx): string[]|nil
---@field unique boolean|nil
---@field required boolean|nil
---@field pri integer|nil
---@field hint string[]|nil

---@class KvPosSpec
---@field name string
---@field kind KvKind|nil
---@field values string[]|nil
---@field values_fn? fun(ctx: KvCtx): string[]|nil
---@field required boolean|nil   -- default true
---@field hint string[]|nil

---@class KvCompiledKey
---@field name string
---@field kind KvKind
---@field values string[]|nil
---@field values_fn? fun(ctx: KvCtx): string[]|nil
---@field unique boolean
---@field required boolean
---@field pri integer
---@field hint string[]|nil

---@class KvCompiledPos
---@field name string
---@field kind KvKind
---@field values string[]|nil
---@field values_fn? fun(ctx: KvCtx): string[]|nil
---@field required boolean
---@field hint string[]|nil

---@class KvSubSpec
---@field keys table<string, KvKeySpec|string|string[]|boolean|KvKind>|nil
---@field pos (KvPosSpec|string)[]|nil
---@field pri integer|nil

---@class KvSpec
---@field keys table<string, KvKeySpec|string|string[]|boolean|KvKind>|nil
---@field pos (KvPosSpec|string)[]|nil
---@field subs table<string, KvSubSpec|table>|nil
---@field strict boolean|nil
---@field max integer|nil
---@field desc string|nil
---@field bang boolean|nil
---@field range boolean|string|nil
---@field force boolean|nil
---@field nargs string|nil

---@class KvCompiled
---@field list KvCompiledKey[]
---@field by_name table<string, KvCompiledKey>
---@field pos KvCompiledPos[]
---@field strict boolean
---@field max integer
---@field has_subs boolean
---@field subs table<string, KvCompiled>|nil
---@field sub_names string[]|nil
---@field pri integer|nil

---@class KvParsed
---@field kv table<string, string|string[]|boolean>
---@field sub string|nil
---@field unknown string[]
---@field missing string[]
---@field errors string[]

----------------------------------------------------------------------
-- Builtin value sources
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

---@param pos (KvPosSpec|string)[]|nil
---@return KvCompiledPos[]
local function compile_pos(pos)
  if type(pos) ~= "table" or pos[1] == nil then
    return {}
  end
  ---@type KvCompiledPos[]
  local out = {}
  for i = 1, #pos do
    local p = pos[i]
    if type(p) == "string" then
      out[i] = { name = p, kind = "string", required = true }
    elseif type(p) == "table" and type(p.name) == "string" then
      out[i] = {
        name = p.name,
        kind = p.kind or (p.values or p.values_fn) and "enum" or "string",
        values = p.values,
        values_fn = p.values_fn,
        required = p.required ~= false,
        hint = p.hint,
      }
    else
      error("kvcomplete: pos[" .. i .. "] must be a name string or { name = ... }")
    end
  end
  return out
end

---@param keys table<string, KvKeySpec|string|string[]|boolean|KvKind>|nil
---@param pos (KvPosSpec|string)[]|nil
---@param strict boolean
---@param max integer
---@return KvCompiled
local function compile_keys(keys, pos, strict, max)
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
    pos = compile_pos(pos),
    strict = strict,
    max = max,
    has_subs = false,
  }
end

---Long form if the table uses reserved fields; otherwise the whole table is keys.
---@param raw KvSubSpec|table
---@return table|nil keys
---@return (KvPosSpec|string)[]|nil pos
---@return integer pri
local function sub_fields(raw)
  if type(raw) ~= "table" then
    return {}, nil, 0
  end
  if raw.keys ~= nil or raw.pos ~= nil or raw.pri ~= nil then
    return raw.keys or {}, raw.pos, raw.pri or 0
  end
  return raw, nil, 0
end

---@param spec KvSpec
---@return KvCompiled
function M.compile(spec)
  assert(type(spec) == "table", "kvcomplete: spec table required")
  assert(
    spec.keys ~= nil or spec.subs ~= nil or spec.pos ~= nil,
    "kvcomplete: spec.keys, spec.subs or spec.pos required"
  )

  local strict = spec.strict ~= false
  local max = spec.max or MAX
  local root_keys = spec.keys or {}
  local root = compile_keys(root_keys, spec.pos, strict, max)

  if not spec.subs then
    return root
  end

  ---@type table<string, KvCompiled>
  local subs = {}
  ---@type string[]
  local names = {}
  for name, raw in pairs(spec.subs) do
    local extra, extra_pos, pri = sub_fields(raw)
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
    -- sub.pos replaces root.pos; omitted pos inherits root
    local leaf = compile_keys(merged, extra_pos or spec.pos, strict, max)
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
-- Tokenize / parse
----------------------------------------------------------------------

---@class KvToken
---@field text string
---@field done boolean

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

---@param s string
---@return string
local function unquote(s)
  local a, b = s:sub(1, 1), s:sub(-1)
  if #s >= 2 and (a == '"' or a == "'") and a == b then
    return s:sub(2, -2)
  end
  return s
end

---@param tok string
---@return string key, string|nil val
local function split_kv(tok)
  local eq = tok:find("=", 1, true)
  if not eq then return tok, nil end
  return tok:sub(1, eq - 1), tok:sub(eq + 1)
end

---Consume leading bare tokens as positionals. Stops at first '=' token.
---@param leaf KvCompiled
---@param tokens KvToken[]
---@param start integer
---@param kv table<string, string|string[]|boolean>
---@param missing string[]
---@param errors string[]
---@return integer next_index
local function take_pos(leaf, tokens, start, kv, missing, errors)
  local pos = leaf.pos
  local npos = #pos
  if npos == 0 then
    return start
  end
  local filled = 0
  local i = start
  while i <= #tokens and filled < npos do
    local text, val = split_kv(tokens[i].text)
    if val ~= nil then
      break
    end
    filled = filled + 1
    kv[pos[filled].name] = unquote(text)
    i = i + 1
  end
  for p = filled + 1, npos do
    if pos[p].required then
      missing[#missing + 1] = pos[p].name
      errors[#errors + 1] = "missing positional: " .. pos[p].name
    end
  end
  return i
end

---@param leaf KvCompiled
---@param tokens KvToken[]
---@param start integer
---@return KvParsed
local function parse_tokens(leaf, tokens, start)
  ---@type table<string, string|string[]|boolean>
  local kv = {}
  ---@type string[]
  local unknown, missing, errors = {}, {}, {}

  start = take_pos(leaf, tokens, start, kv, missing, errors)

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

  for i = 1, #leaf.list do
    local k = leaf.list[i]
    if k.required and kv[k.name] == nil then
      missing[#missing + 1] = k.name
      errors[#errors + 1] = "missing required key: " .. k.name
    end
  end
  return { kv = kv, unknown = unknown, missing = missing, errors = errors }
end

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
    elseif #compiled.list == 0 and #compiled.pos == 0 then
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

---@param spec KvCompiledKey|KvCompiledPos
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

---Finished key=value tokens from `start`, skipping leading positionals.
---@param tokens KvToken[]
---@param start integer
---@param pos KvCompiledPos[]
---@return table<string, boolean> used
---@return table<string, string> kv
---@return integer filled_pos
local function context_from(tokens, start, pos)
  ---@type table<string, boolean>
  local used = {}
  ---@type table<string, string>
  local kv = {}
  local npos = #pos
  local filled = 0
  for i = start, #tokens do
    local tok = tokens[i]
    if not tok.done then
      break
    end
    local key, val = split_kv(tok.text)
    if val == nil and filled < npos then
      filled = filled + 1
      kv[pos[filled].name] = unquote(key)
      used[pos[filled].name] = true
    else
      if key ~= "" then
        used[key] = true
        if val ~= nil then kv[key] = unquote(val) end
      end
    end
  end
  return used, kv, filled
end

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
  local hit = fuzzy_take(values_of(spec, ctx), ctx.lead, cap)
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

---@param leaf KvCompiled
---@param arg_lead string
---@param tokens KvToken[]
---@param start integer
---@param sub string|nil
---@return string[]
local function complete_leaf(leaf, arg_lead, tokens, start, sub)
  local used, kv, filled = context_from(tokens, start, leaf.pos)
  local _, val = split_kv(arg_lead)

  -- still filling positionals: suggest values, no 'key=' prefix
  if val == nil and filled < #leaf.pos then
    local p = leaf.pos[filled + 1]
    ---@type KvCtx
    local ctx = {
      key = p.name,
      lead = unquote(arg_lead),
      raw = arg_lead,
      kv = kv,
      used = used,
      sub = sub,
    }
    return fuzzy_take(values_of(p, ctx), ctx.lead, leaf.max)
  end

  return complete_kv(leaf, arg_lead, used, kv, sub)
end

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
      return complete_leaf(compiled, arg_lead, tokens, 1, nil)
    end

    local name, val = split_kv(first_done.text)
    if val == nil then
      local leaf = compiled.subs and compiled.subs[name]
      if leaf then
        return complete_leaf(leaf, arg_lead, tokens, 2, name)
      end
      return fuzzy_take(compiled.sub_names or {}, arg_lead, compiled.max)
    end
  end

  return complete_leaf(compiled, arg_lead, tokens, 1, nil)
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
