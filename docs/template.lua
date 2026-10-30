-- TEMPLATE for a new S3-PO module.
-- 1. Copy this file to modules/<key>.lua (the file name must be the key).
-- 2. Fill in the description and check().
-- 3. Try it: S3-PO's Modules page -> "Install from a file".
-- 4. Publish: commit it to modules/. GitHub Actions checks it and adds it to index.json;
--    then it shows up in every S3-PO's store.
-- Guide: docs/WRITING.md

local M = {
  key = "mymodule",            -- 1-12 lower-case letters and digits; also the file name
  name = "My module",          -- what people see
  version = "1.0.0",           -- raise it with every change, or nobody gets the update
  about = "One sentence for the store: what it tells you, and when.",
  every = 30,                  -- check every 30 minutes (people can change it)
  minEvery = 5,                -- but not more often than this
  settings = {
    { "city", "City", "", hint = "where to look" },
    { "limit", "Tell me from", 10, range = { 0, 100 } },
    { "loud", "Loud notifications", false },
  },
}

local items = {}   -- module state lives in plain Lua variables between checks

local function summary()
  if #items == 0 then return "Nothing yet." end
  return #items .. " items, the newest: " .. items[1].title
end

M.commands = {
  { "mything", "other, words", "what this module knows right now", function() return summary() end },
}

-- Why it can't run yet (shown on the status page), or nothing when it can.
function M.notReady()
  if cfg.city == "" then return "no city set" end
end

function M.check()
  local body, err = http.get("https://example.com/api?city=" .. urlEncode(cfg.city))
  if not body then return false, err end          -- 3 failed checks in a row -> one error push
  local data = json.decode(body)
  if type(data) ~= "table" then return false, "bad answer" end

  items = data.items or {}
  for _, item in ipairs(items) do
    -- isNew() remembers ids in flash; firstCheck() is true until the first successful check,
    -- so switching the module on doesn't announce everything that already exists.
    if isNew(item.id) and not firstCheck() and item.count >= cfg.limit then
      notify{
        title = "New: " .. item.title,
        message = item.text or "",
        tag = "sparkles",
        buttons = { { "Open", url = item.url }, { "All", cmd = "mything" } },
        priority = cfg.loud and 4 or 3,
      }
    end
  end
  status(#items .. " items")
end

return M
