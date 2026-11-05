-- Crypto price: watches one coin and pushes when its price reaches your thresholds,
-- above or below, and optionally when it moves a lot within 24 hours.
--
-- Data: CoinGecko (https://www.coingecko.com), public API, no account needed:
--   https://api.coingecko.com/api/v3/simple/price?ids=bitcoin&vs_currencies=eur
--     &include_24hr_change=true  ->  {"bitcoin":{"eur":90512.4,"eur_24h_change":-1.23}}
-- Without a key the API allows a few calls a minute; a free "Demo" key from
-- coingecko.com raises that (enter it in the settings). Prices are updated about once
-- a minute, so checking more often than that gains nothing.
--
-- Each threshold alerts once when the price reaches it, and again only after the price
-- has moved back by the re-arm margin, so a price wobbling around it doesn't spam you.

local M = {
  key = "crypto",
  name = "Crypto price",
  version = "1.0.0",
  about = "Watches a cryptocurrency (CoinGecko) and pushes when its price rises above or falls below your thresholds, or moves a lot in 24 hours.",
  order = 42,
  every = 5,
  minEvery = 1,
  settings = {
    { "coin", "Coin", "bitcoin",
      hint = "CoinGecko id (the name in the coin's coingecko.com address), e.g. bitcoin, ethereum, solana; BTC, ETH, SOL work too" },
    { "currency", "Currency", "eur", options = { "eur|Euro (€)", "usd|US dollar ($)", "chf|Swiss franc (CHF)", "gbp|Pound (£)" } },
    { "above", "Tell me when it rises to", 0.0, hint = "price; 0 = off" },
    { "below", "Tell me when it falls to", 0.0, hint = "price; 0 = off" },
    { "move", "Tell me when it moves more than (% in 24 h)", 0.0, hint = "e.g. 10; 0 = off" },
    { "rearm", "Re-arm margin (%)", 2.0, hint = "how far it must move back before the same alert comes again" },
    { "loud", "Loud threshold alerts (also in quiet hours)", false },
    { "apikey", "CoinGecko Demo API key", "", secret = true, hint = "optional, free at coingecko.com/en/api" },
  },
}

-- Ticker symbols people type, and the CoinGecko ids they mean.
local SYMBOLS = {
  btc = "bitcoin", eth = "ethereum", sol = "solana", xrp = "ripple", ada = "cardano", doge = "dogecoin",
  ltc = "litecoin", dot = "polkadot", bnb = "binancecoin", trx = "tron", link = "chainlink", avax = "avalanche-2",
  xlm = "stellar", xmr = "monero", usdt = "tether", usdc = "usd-coin", matic = "matic-network", pol = "polygon-ecosystem-token",
}
local SIGNS = { eur = " €", usd = " $", chf = " CHF", gbp = " £" }

local last = nil     -- { price =, change =, at = } from the last check

local function coinId()
  local c = trim(cfg.coin):lower()
  return SYMBOLS[c] or c
end

local function coinName()
  local id = coinId()
  return (id:gsub("%-%d+$", ""):gsub("%-", " "):gsub("^%l", string.upper))
end

-- 90512.4 -> "90,512 €", 2.4567 -> "2.46 €", 0.00001234 -> "0.00001234 €"
local function money(v)
  local s
  if v >= 1000 then s = string.format("%.0f", v)
  elseif v >= 1 then s = string.format("%.2f", v)
  else s = string.format("%.8f", v):gsub("0+$", ""):gsub("%.$", "") end
  local int, frac = s:match("^(%d+)(.*)$")
  int = int:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
  return int .. frac .. (SIGNS[cfg.currency] or (" " .. cfg.currency:upper()))
end

local function pct(v) return string.format("%+.1f %%", v) end

local function fetch()
  local cur = cfg.currency
  local url = "https://api.coingecko.com/api/v3/simple/price?ids=" .. urlEncode(coinId()) ..
              "&vs_currencies=" .. cur .. "&include_24hr_change=true"
  if cfg.apikey ~= "" then url = url .. "&x_cg_demo_api_key=" .. urlEncode(cfg.apikey) end
  local body, err, code = http.get(url)
  if not body then
    if code == 429 then return nil, "CoinGecko: too many requests (check less often, or add a free API key)" end
    return nil, "CoinGecko: " .. err
  end
  local doc = json.decode(body)
  local data = type(doc) == "table" and doc[coinId()]
  if type(data) ~= "table" or type(data[cur]) ~= "number" then
    return nil, "CoinGecko doesn't know the coin \"" .. cfg.coin .. "\" (use its CoinGecko id, e.g. bitcoin)"
  end
  return { price = data[cur], change = tonumber(data[cur .. "_24h_change"]), at = nowText() }
end

local function describe()
  if not last then return "No price yet." end
  local s = coinName() .. ": " .. money(last.price)
  if last.change then s = s .. " (" .. pct(last.change) .. " in 24 h)" end
  local watch = {}
  if cfg.above > 0 then watch[#watch + 1] = "above " .. money(cfg.above) end
  if cfg.below > 0 then watch[#watch + 1] = "below " .. money(cfg.below) end
  if cfg.move > 0 then watch[#watch + 1] = "moves over " .. cfg.move .. " % in 24 h" end
  s = s .. "\nWatching: " .. (#watch > 0 and table.concat(watch, ", ") or "nothing (set a threshold)")
  return s .. "\nPrice from CoinGecko, " .. last.at
end

local function buttons()
  return { { "Chart", url = "https://www.coingecko.com/en/coins/" .. coinId() }, { "Price now", cmd = "crypto" } }
end

M.commands = {
  { "crypto", "krypto, coin, bitcoin, btc, kurs", "the price of your coin and what I watch", function()
      local p = fetch()
      if p then last = p end
      return describe()
    end },
}

function M.notReady()
  if trim(cfg.coin) == "" then return "no coin set" end
end

function M.settingsChanged()
  remember(nil)   -- new coin or thresholds: start fresh, so a reached threshold is told again
  last = nil
end

function M.check()
  local p, err = fetch()
  if not p then return false, err end
  last = p

  -- Which alerts are armed. Kept in flash, so a restart doesn't repeat them.
  local st = recall() or {}
  local margin = math.max(0, cfg.rearm) / 100
  local pushes = 0
  local priority = cfg.loud and 5 or 4

  if cfg.above > 0 then
    if p.price >= cfg.above and not st.aboveSent then
      notify(coinName() .. " is above " .. money(cfg.above),
             "Now " .. money(p.price) .. (p.change and (", " .. pct(p.change) .. " in 24 h") or "") .. ".",
             "chart_with_upwards_trend", buttons(), priority)
      st.aboveSent, pushes = true, pushes + 1
    elseif st.aboveSent and p.price < cfg.above * (1 - margin) then
      st.aboveSent = false   -- back below: the next rise alerts again
    end
  end

  if cfg.below > 0 then
    if p.price <= cfg.below and not st.belowSent then
      notify(coinName() .. " is below " .. money(cfg.below),
             "Now " .. money(p.price) .. (p.change and (", " .. pct(p.change) .. " in 24 h") or "") .. ".",
             "chart_with_downwards_trend", buttons(), priority)
      st.belowSent, pushes = true, pushes + 1
    elseif st.belowSent and p.price > cfg.below * (1 + margin) then
      st.belowSent = false
    end
  end

  -- Big 24 h move: once a day at most.
  if cfg.move > 0 and p.change and math.abs(p.change) >= cfg.move and st.movedOn ~= today() then
    notify(coinName() .. (p.change > 0 and " jumped " or " dropped ") .. pct(p.change) .. " in 24 h",
           "Now " .. money(p.price) .. ".", p.change > 0 and "rocket" or "warning", buttons())
    st.movedOn, pushes = today(), pushes + 1
  end

  remember(st)
  if pushes > 0 then blink(3) end
  status(money(p.price) .. (p.change and (", " .. pct(p.change) .. " in 24 h") or "") ..
         (pushes > 0 and (", " .. pushes .. " alert" .. (pushes == 1 and "" or "s")) or ""))
end

return M
