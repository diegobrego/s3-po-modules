-- Checks modules the way S3-PO loads them, before any device downloads them.
--   lua5.4 tools/validate.lua modules/*.lua
-- Each file is run with stand-ins for S3-PO's API; the module table it returns must be a
-- valid description (key, name, version, settings, commands, check), and notReady() must
-- work with the default settings. Exit code 1 if anything is wrong.

local failures = 0
local function fail(file, msg)
  print(("error: %s: %s"):format(file, msg))
  failures = failures + 1
end

-- The helpers S3-PO gives every module (same as the firmware's prelude).
local prelude = [[
function trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end
function split(s, sep)
  local out, pos = {}, 1
  s, sep = tostring(s or ""), sep or ","
  while true do
    local a, b = s:find(sep, pos, true)
    local part = trim(s:sub(pos, a and a - 1 or #s))
    if part ~= "" then out[#out + 1] = part end
    if not a then return out end
    pos = b + 1
  end
end
function startsWith(s, prefix) return s:sub(1, #prefix) == prefix end
function contains(list, x)
  for _, v in ipairs(list) do if v == x then return true end end
  return false
end
function sortedKeys(t)
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  return keys
end
]]

local function sandbox(file, values)
  local env = {
    assert = assert, error = error, ipairs = ipairs, next = next, pairs = pairs, pcall = pcall, print = function() end,
    rawequal = rawequal, rawget = rawget, rawlen = rawlen, rawset = rawset, select = select, setmetatable = setmetatable,
    getmetatable = getmetatable, tonumber = tonumber, tostring = tostring, type = type, xpcall = xpcall,
    string = string, table = table, math = math, utf8 = utf8, coroutine = coroutine,
    s3po = { version = "validator", api = 1, url = "http://s3po.local" },
  }
  local function onlyInCheck(name)
    return function() error(name .. "() works only inside check() or a command", 2) end
  end
  for _, name in ipairs({ "notify", "isNew", "remember", "blink" }) do env[name] = onlyInCheck(name) end
  env.status, env.log, env._log = function() end, function() end, function() end
  env.firstCheck = function() return true end
  env.recall = function() return nil end
  env.fileText = function() return nil end
  env.today = function(n) return os.date("%Y-%m-%d", os.time() + (n or 0) * 86400) end
  env.hour = function() return tonumber(os.date("%H")) end
  env.dateLabel = function(iso) return iso end
  env.addDays = function(iso) return iso end
  env.daysBetween = function() return 0 end
  env.nowText = function() return os.date("%d.%m. %H:%M") end
  env.millis = function() return 0 end
  env.urlEncode = function(s) return s end
  env.http = { get = onlyInCheck("http.get"), post = onlyInCheck("http.post") }
  env.firestore = { list = onlyInCheck("firestore.list"), range = onlyInCheck("firestore.range") }
  env.json = { decode = function() return nil, "not in the validator" end, encode = function() return "{}" end }
  env.cfg = setmetatable({}, {
    __index = function(_, k)
      if values[k] == nil then error("cfg." .. tostring(k) .. ": this module has no setting \"" .. tostring(k) .. "\"", 2) end
      return values[k]
    end,
    __newindex = function() error("settings are read-only", 2) end,
  })
  env._G = env
  assert(load(prelude, "=prelude", "t", env))()
  return env
end

local function validKey(k, max)
  return type(k) == "string" and #k >= 1 and #k <= max and k:match("^%a%w*$") ~= nil
end

for _, path in ipairs(arg) do
  local file = path:match("([^/\\]+)$")
  local before = failures
  local source = assert(io.open(path, "rb")):read("a")
  local values = {}
  local env = sandbox(file, values)
  local chunk, err = load(source, "=" .. file, "t", env)
  if not chunk then
    fail(file, err)
    goto continue
  end
  do
    local ok, M = pcall(chunk)
    if not ok then fail(file, M) goto continue end
    if type(M) ~= "table" then fail(file, "the script must end with `return M` (the module table)") goto continue end

    if not validKey(M.key, 12) or M.key ~= M.key:lower() then fail(file, "`key` must be 1-12 lower-case letters and digits") end
    if file ~= tostring(M.key) .. ".lua" then fail(file, "the file must be named " .. tostring(M.key) .. ".lua") end
    if type(M.name) ~= "string" or M.name == "" then fail(file, "`name` is missing") end
    if type(M.version) ~= "string" or not M.version:match("^%d+%.%d+") then fail(file, "`version` must look like \"1.0.0\"") end
    if type(M.about) ~= "string" or M.about == "" then fail(file, "`about` is missing (one sentence for the store)") end
    if (M.api or 1) > 1 then fail(file, "`api` is newer than this validator knows") end
    if type(M.check) ~= "function" then fail(file, "there is no check function") end
    for _, f in ipairs({ "every", "minEvery", "order" }) do
      if M[f] ~= nil and math.type(M[f]) ~= "integer" then fail(file, "`" .. f .. "` must be a whole number") end
    end
    if (M.minEvery or 1) > (M.every or 15) then fail(file, "`minEvery` is larger than `every`") end
    if M.sendTo and M.sendTo ~= "main" and M.sendTo ~= "second" and M.sendTo ~= "both" then
      fail(file, "`sendTo` must be \"main\", \"second\" or \"both\"")
    end

    local seen = {}
    for i, s in ipairs(M.settings or {}) do
      local key, label, default = s.key or s[1], s.label or s[2], s.default
      if default == nil then default = s[3] end
      local where = "settings[" .. i .. "] (" .. tostring(key) .. ")"
      if not validKey(key, 15) then fail(file, where .. ": key must be 1-15 letters and digits, starting with a letter") end
      if seen[key] then fail(file, where .. ": appears twice") end
      seen[key] = true
      if type(label) ~= "string" then fail(file, where .. ": label is missing") end
      if s.options then
        local found = false
        for _, o in ipairs(s.options) do
          if type(o) ~= "string" then fail(file, where .. ": options must be texts") end
          found = found or (tostring(o):match("^[^|]*") == default)
        end
        if not found then fail(file, where .. ": the default is not one of the options") end
      end
      if s.range then
        local lo, hi = s.range[1], s.range[2]
        if math.type(lo) ~= "integer" or math.type(hi) ~= "integer" or lo > hi then
          fail(file, where .. ": range must be {low, high} whole numbers")
        elseif math.type(default) ~= "integer" or default < lo or default > hi then
          fail(file, where .. ": the default is outside the range")
        end
      end
      if s.file then values[key] = false
      elseif default == nil then values[key] = ""
      else values[key] = default end
    end

    seen = {}
    for i, c in ipairs(M.commands or {}) do
      local name, words, help, run = c.name or c[1], c.words or c[2], c.help or c[3], c.run or c[4]
      local where = "commands[" .. i .. "]"
      if type(name) ~= "string" or name == "" then fail(file, where .. ": name is missing") end
      if words ~= nil and type(words) ~= "string" then fail(file, where .. ": other words must be one comma-separated text") end
      if type(help) ~= "string" or help == "" then fail(file, where .. ": help line is missing") end
      if type(run) ~= "function" then fail(file, where .. ": function is missing") end
      if seen[name] then fail(file, where .. ": " .. tostring(name) .. " appears twice") end
      seen[name] = true
    end

    if M.notReady then
      local ok2, why = pcall(M.notReady)
      if not ok2 then fail(file, "notReady() fails with the default settings: " .. tostring(why))
      elseif why ~= nil and type(why) ~= "string" then fail(file, "notReady() must return a text or nothing") end
    end
    if failures == before then
      print(("ok    %s: %s %s, %d settings, %d commands"):format(file, M.name, M.version, #(M.settings or {}), #(M.commands or {})))
    end
  end
  ::continue::
end

if failures > 0 then
  print(failures .. " problem(s)")
  os.exit(1)
end
