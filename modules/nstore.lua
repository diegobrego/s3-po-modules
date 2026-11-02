-- Nintendo Store stock: watches a product page on store.nintendo.com and pushes as soon
-- as it can be bought. Set up for the Nintendo Switch 2 Pro Controller, The Legend of
-- Zelda Edition (40th anniversary), but any product page of the store works.
--
-- How it tells whether the product can be bought, most reliable first:
--   1. The page's product data (schema.org JSON-LD): "availability": ".../InStock",
--      ".../PreOrder" or ".../LimitedAvailability" = available; ".../OutOfStock",
--      ".../SoldOut" or ".../Discontinued" = not available. The price comes from there too.
--   2. Words on the page, from the settings: "sold out" words win over "buy" words,
--      because buy-button texts are often in the page even when it's sold out.
-- The Nintendo Store sometimes puts everyone in a Queue-it waiting room (it does during
-- big releases). Then S3-PO can't see the product, says so, and can tell you: a waiting
-- room often means a drop is happening.

local M = {
  key = "nstore",
  name = "Nintendo Store stock",
  version = "1.0.0",
  about = "Watches a product on the Nintendo Store and pushes the moment it can be bought (and when the store opens a waiting room).",
  order = 45,
  every = 5,                -- how often to look; change it on the settings page
  minEvery = 2,             -- be nice to the store
  settings = {
    { "url", "Product page",
      "https://store.nintendo.com/de-de/nintendo-switch-2-pro-controller-the-legend-of-zelda-edition-zum-40-jubilum-aufsteller-000000000010019437",
      hint = "any product page on store.nintendo.com" },
    { "product", "Product name", "Pro Controller (Zelda Edition)", hint = "used in the messages" },
    { "soldWords", "Sold-out words", "Ausverkauft, Nicht verfügbar, Derzeit nicht verfügbar, Bald erhältlich, Nicht vorrätig",
      hint = "comma separated, as written on the page (upper/lower case matters)" },
    { "buyWords", "Buy words", "In den Warenkorb, Jetzt kaufen, Vorbestellen", hint = "comma separated" },
    { "loud", "Loud push when it's available (also in quiet hours)", true },
    { "pushGone", "Push when it's sold out again", true },
    { "pushQueue", "Push when the store opens a waiting room", true },
  },
}

local last = nil        -- what the last check saw: "available", "soldout", "queue", "unknown"
local lastPrice = ""
local lastCheck = ""

-- --- Reading the page --------------------------------------------------------------
local AVAILABLE = { InStock = true, PreOrder = true, LimitedAvailability = true, OnlineOnly = true }
local GONE = { OutOfStock = true, SoldOut = true, Discontinued = true, BackOrder = true }

local function anyOf(page, words)
  for _, w in ipairs(split(words, ",")) do
    if page:find(w, 1, true) then return w end
  end
end

-- Price like "79,99 €" from the product data, or "" if there is none.
local function priceOf(page)
  local p = page:match('"price"%s*:%s*"?([%d%.]+)')
  if not p then return "" end
  local cur = page:match('"priceCurrency"%s*:%s*"(%a+)"') or "EUR"
  local euros = tonumber(p)
  if not euros then return "" end
  local text = string.format("%.2f", euros):gsub("%.", ",")
  return text .. (cur == "EUR" and " €" or (" " .. cur))
end

-- "available", "soldout", "queue" or nil (can't tell), and why.
local function read(page)
  if page:find("queue-it", 1, true) or page:find("queue%-it%.net") then
    return "queue", "the store has a waiting room (Queue-it) right now"
  end
  for value in page:gmatch('"availability"%s*:%s*"([^"]+)"') do
    local kind = value:match("([%a]+)$")
    if AVAILABLE[kind] then return "available", "product data: " .. kind end
    if GONE[kind] then return "soldout", "product data: " .. kind end
  end
  local w = anyOf(page, cfg.soldWords)
  if w then return "soldout", "\"" .. w .. "\" on the page" end
  w = anyOf(page, cfg.buyWords)
  if w then return "available", "\"" .. w .. "\" on the page" end
  return nil, "no availability on the page (layout changed?)"
end
-- -----------------------------------------------------------------------------------

local function buttons()
  return { { "Open the store", url = cfg.url }, { "Check again", cmd = "nintendo" } }
end

local function describe()
  if not last then return "No check yet." end
  local s = cfg.product .. ": " .. ({ available = "AVAILABLE", soldout = "not available",
                                      queue = "unknown, the store has a waiting room",
                                      unknown = "can't tell" })[last]
  if lastPrice ~= "" then s = s .. " (" .. lastPrice .. ")" end
  return s .. "\nLast check: " .. lastCheck
end

M.commands = {
  { "nintendo", "controller, stock, lager, verfügbar", "is the Nintendo Store product available?", function()
      M.check()
      return describe()
    end },
}

function M.notReady()
  if not startsWith(cfg.url, "https://") then return "no product page set" end
end

function M.check()
  local page, err = http.get(cfg.url)
  lastCheck = nowText()
  if not page then
    last = "unknown"
    return false, err
  end
  local state, why = read(page)
  local price = state == "available" and priceOf(page) or ""
  page = nil

  local before = (recall() or {}).state   -- survives restarts, so a restart doesn't repeat pushes
  if not state then
    last = "unknown"
    return false, why
  end
  last, lastPrice = state, price

  if state ~= before then
    if state == "available" then
      notify{
        title = cfg.product .. " is available!",
        message = (price ~= "" and ("Price: " .. price .. "\n") or "") .. "Nintendo Store, " .. nowText() ..
                  ". Be quick." .. "\n(" .. why .. ")",
        tag = "video_game",
        buttons = buttons(),
        priority = cfg.loud and 5 or 4,
      }
      blink(5)
    elseif state == "soldout" and before == "available" and cfg.pushGone then
      notify(cfg.product .. ": sold out again", "Gone at " .. nowText() .. ". I keep watching.", "x", buttons())
    elseif state == "queue" and cfg.pushQueue then
      notify("Nintendo Store waiting room is open",
             "The store is queueing visitors (Queue-it), which often means a drop. I can't see " .. cfg.product ..
             " until it's over; tap below to join the queue yourself.", "hourglass", buttons(), 4)
    end
    remember({ state = state, since = nowText() })
  end
  status(({ available = "AVAILABLE", soldout = "not available", queue = "waiting room active" })[state] ..
         (price ~= "" and (", " .. price) or "") .. " (" .. why .. ")")
end

return M
