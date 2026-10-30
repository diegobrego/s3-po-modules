-- Fuel prices for Germany and Austria, with a push when a station drops to your limit.
--
-- Germany: Tankerkönig API (data from the Markttransparenzstelle für Kraftstoffe).
--   Your chosen stations by id, all in one call. Needs a free personal key; no more than
--   one call per 5 minutes. Prices: Tankerkönig / MTS-K, CC BY 4.0.
-- Austria: E-Control Spritpreisrechner API, no key needed. Searches around a point and
--   returns the nearest stations; only the cheapest ones publish a price, the others are
--   left out. Diesel = DIE, Super 95 = SUP (Austria has no E10).
-- Since April 2026 both countries allow price increases only once a day, at 12:00.

local M = {
  key = "fuel",
  name = "Fuel prices",
  version = "1.0.0",
  about = "Fuel prices for Germany (Tankerkönig) and Austria (E-Control), with a push when a station drops to your limit.",
  order = 40,
  every = 10,
  minEvery = 5,   -- Tankerkönig: no more than one call per 5 minutes
  settings = {
    { "type", "Fuel", "e10", options = { "e5|Super E5", "e10|Super E10", "diesel|Diesel" },
      hint = "Austria: E5 and E10 both use Super 95" },
    { "limit", "Push at or below (EUR)", 1.65 },
    { "apikey", "Tankerkönig API key", "", secret = true,
      hint = "for German stations; free at onboarding.tankerkoenig.de" },
    { "stations", "German stations", "", long = true,
      hint = "one per line: Tankerkönig station id, a space, a short name. Up to 10. "
          .. "Ids: Tankstellenfinder on creativecommons.tankerkoenig.de" },
    { "atOn", "Also check Austrian stations (E-Control, no key needed)", false },
    { "atLat", "Austria: latitude", "", hint = "point to search around, e.g. 47.5830 (right-click in Google Maps)" },
    { "atLng", "Austria: longitude", "", hint = "e.g. 12.1700" },
    { "atKm", "Austria: max. distance (km)", 25, range = { 0, 200 }, hint = "0 = no limit" },
  },
}

local REARM = 0.02       -- alert again only after the price rose this much
local MAX_STATIONS = 10
local stations = {}      -- from the last successful check
local armed = {}         -- station id -> may alert again
local lastCheck = ""

local function num(v)
  if type(v) == "number" then return v end
  return tonumber((tostring(v or ""):gsub(",", "."))) or 0
end

local function euro(v) return string.format("%.3f €", v) end

local function fuelName()
  local t = cfg.type
  return t == "e5" and "Super E5" or t == "e10" and "Super E10" or "Diesel"
end

local function germanStations()
  local list = {}
  for _, row in ipairs(split((cfg.stations:gsub("\r", "")), "\n")) do
    if #list >= MAX_STATIONS then break end
    if #row >= 36 then   -- a station id is a 36-character UUID
      local space = row:find(" ", 1, true)
      local id = space and row:sub(1, space - 1) or row
      local name = space and trim(row:sub(space + 1)) or id:sub(1, 8)
      list[#list + 1] = { id = "de-" .. id, uuid = id, country = "DE", name = name, open = false, price = 0, lat = 0, lng = 0 }
    end
  end
  return list
end

local function germany() return cfg.apikey ~= "" and #germanStations() > 0 end
local function austria() return cfg.atOn and num(cfg.atLat) ~= 0 and num(cfg.atLng) ~= 0 end

local function mapsUrl(s)
  if s.lat ~= 0 and s.lng ~= 0 then
    return string.format("https://www.google.com/maps/search/?api=1&query=%.6f,%.6f", s.lat, s.lng)
  end
  return "https://www.google.com/maps/search/?api=1&query=" .. urlEncode(s.name .. " Tankstelle")
end

local function fetchGermany(out)
  local list = germanStations()
  local ids = {}
  for _, s in ipairs(list) do ids[#ids + 1] = s.uuid end
  local body, err = http.get("https://creativecommons.tankerkoenig.de/json/prices.php?ids=" ..
                             table.concat(ids, ",") .. "&apikey=" .. cfg.apikey)
  if not body then return false, err end
  local doc = json.decode(body)
  if type(doc) ~= "table" or not doc.ok then return false, (type(doc) == "table" and doc.message) or "bad answer" end
  local t = cfg.type
  for _, s in ipairs(list) do
    local p = (doc.prices or {})[s.uuid] or {}
    s.open = p.status == "open"
    s.price = type(p[t]) == "number" and p[t] or 0   -- `false` when the station has no such fuel
    out[#out + 1] = s
  end
  return true
end

local function fetchAustria(out)
  local t = cfg.type == "diesel" and "DIE" or "SUP"
  local lat, lng = cfg.atLat:gsub(",", "."), cfg.atLng:gsub(",", ".")
  local body, err = http.get("https://api.e-control.at/sprit/1.0/search/gas-stations/by-address?latitude=" .. lat ..
                             "&longitude=" .. lng .. "&fuelType=" .. t .. "&includeClosed=false")
  if not body then return false, err end
  local doc = json.decode(body)
  if type(doc) ~= "table" then return false, "bad answer" end
  local maxKm = cfg.atKm
  for _, st in ipairs(doc) do
    if not (maxKm > 0 and num(st.distance) > maxKm) then
      local loc = st.location or {}
      local name, city = tostring(st.name or "?"), tostring(loc.city or "")
      local s = { id = "at-" .. tostring(st.id or 0), country = "AT", name = city ~= "" and (name .. ", " .. city) or name,
                  open = st.open == true, price = 0, lat = num(loc.latitude), lng = num(loc.longitude) }
      for _, p in ipairs(st.prices or {}) do
        if p.fuelType == t then s.price = num(p.amount) end
      end
      if s.price > 0 then out[#out + 1] = s end   -- stations without a published price are left out
    end
  end
  return true
end

local function report()
  if #stations == 0 then return "No prices yet." end
  local sorted = {}
  for i, s in ipairs(stations) do sorted[i] = s end
  table.sort(sorted, function(a, b)
    if a.open ~= b.open then return a.open end   -- open stations first
    if (a.price > 0) ~= (b.price > 0) then return a.price > 0 end
    return a.price < b.price
  end)
  local lines = { fuelName() .. ", limit " .. euro(cfg.limit) .. " (" .. lastCheck .. ")" }
  local de, at = false, false
  for _, s in ipairs(sorted) do
    lines[#lines + 1] = (s.price > 0 and euro(s.price) or "-") .. "  " .. s.country .. " " .. s.name ..
                        (s.open and "" or " (closed)")
    de = de or s.country == "DE"
    at = at or s.country == "AT"
  end
  if de then lines[#lines + 1] = "DE prices: Tankerkönig / MTS-K (CC BY 4.0)" end
  if at then lines[#lines + 1] = "AT prices: E-Control Spritpreisrechner" end
  return table.concat(lines, "\n")
end

function M.notReady()
  if germany() or austria() then return nil end
  if cfg.apikey == "" and not cfg.atOn then return "no Tankerkönig key and Austria is off" end
  return "no German stations and no Austrian location"
end

function M.check()
  local list, errors, anyOk = {}, {}, false
  if germany() then
    local ok, err = fetchGermany(list)
    if ok then anyOk = true else errors[#errors + 1] = "Tankerkönig: " .. err end
  end
  if austria() then
    local ok, err = fetchAustria(list)
    if ok then anyOk = true else errors[#errors + 1] = "E-Control: " .. err end
  end
  if not anyOk then return false, table.concat(errors, "; ") end
  stations, lastCheck = list, nowText()

  -- Alert once per drop to the limit; again only after the price rose by REARM.
  local limit, alerts = cfg.limit, 0
  for _, s in ipairs(stations) do
    if armed[s.id] == nil then armed[s.id] = true end
    if s.price > 0 then
      if s.open and s.price <= limit and armed[s.id] then
        notify(fuelName() .. " " .. euro(s.price) .. " at " .. s.name .. " (" .. s.country .. ")",
               "At or below your limit of " .. euro(limit) .. ".", "fuelpump",
               { { "Navigate", url = mapsUrl(s) }, { "All prices", cmd = "fuel" } })
        armed[s.id] = false
        alerts = alerts + 1
      elseif s.price >= limit + REARM then
        armed[s.id] = true
      end
    end
  end
  if alerts > 0 then blink(2) end

  local best
  for _, s in ipairs(stations) do
    if s.open and s.price > 0 and (not best or s.price < best.price) then best = s end
  end
  local line = best and ("cheapest " .. euro(best.price) .. " at " .. best.name .. " (" .. best.country .. ")")
                    or "no open station"
  if alerts > 0 then line = line .. ", " .. alerts .. " alert" .. (alerts == 1 and "" or "s") end
  if #errors > 0 then line = line .. " [" .. table.concat(errors, "; ") .. "]" end   -- one country failed
  status(line)
end

M.commands = {
  { "fuel", "sprit, tank, preis, price, diesel, benzin", "current fuel prices, cheapest first", function()
      M.check()   -- fresh prices
      return report()
    end },
}

return M
