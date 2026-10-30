-- Weather: official DWD weather warnings for your place, and a short morning forecast.
--
-- Data: Bright Sky (https://brightsky.dev), a free JSON API for the open data of the
-- Deutscher Wetterdienst. No key needed. Germany only.
--   /alerts?lat=..&lon=..&tz=Europe/Berlin    active warnings for the municipality
--   /weather?lat=..&lon=..&date=..&last_date=..&tz=Europe/Berlin    hourly data and forecast
-- Units are the DWD defaults: °C, km/h, mm, minutes of sunshine, % rain probability.

local M = {
  key = "weather",
  name = "Weather",
  version = "1.0.0",
  about = "Official DWD weather warnings for your place (storms louder, even in quiet hours) and a morning forecast. Germany.",
  order = 30,
  every = 15,
  minEvery = 5,
  settings = {
    { "place", "Place name", "", hint = "only used in the messages" },
    { "lat", "Latitude", "", hint = "e.g. 48.1374 (right-click in Google Maps)" },
    { "lon", "Longitude", "", hint = "e.g. 11.5755" },
    { "level", "Warn me from", "moderate",
      options = { "minor|Yellow: weather warning", "moderate|Orange: notable weather",
                  "severe|Red: severe weather", "extreme|Dark red: extreme weather" } },
    { "lang", "Warning texts in", "en", options = { "en|English", "de|Deutsch" } },
    { "pushEnd", "Tell me when a warning is over", false },
    { "morning", "Morning forecast at (hour)", 7, range = { -1, 23 }, hint = "-1 = off" },
    { "onlyBad", "Morning forecast only when it rains, snows, storms or freezes", false },
  },
}

local active = {}   -- warnings from the last check, at or above the chosen level

local function round(x) return x >= 0 and math.floor(x + 0.5) or -math.floor(-x + 0.5) end
local function num(s) return tonumber((tostring(s or ""):gsub(",", "."))) or 0 end
local function place() return cfg.place ~= "" and cfg.place or "your place" end

local LEVELS = { minor = 1, moderate = 2, severe = 3, extreme = 4 }
local function levelOf(severity) return LEVELS[severity] or 0 end

local function base()
  return "lat=" .. cfg.lat:gsub(",", ".") .. "&lon=" .. cfg.lon:gsub(",", ".") .. "&tz=Europe/Berlin"
end

-- "2026-11-07T18:00:00+01:00" -> "Sat 7 Nov 18:00"
local function when(iso)
  if #iso < 16 then return iso end
  return dateLabel(iso:sub(1, 10)) .. " " .. iso:sub(12, 16)
end

local function span(w)
  if w.expires == "" then return "from " .. when(w.onset) end
  if w.onset:sub(1, 10) == w.expires:sub(1, 10) then return when(w.onset) .. " to " .. w.expires:sub(12, 16) end
  return when(w.onset) .. " to " .. when(w.expires)
end

local function fetchWarnings()
  local body, err = http.get("https://api.brightsky.dev/alerts?" .. base())
  if not body then return false, err end
  local doc = json.decode(body)
  if type(doc) ~= "table" then return false, "bad answer" end
  local de, minLevel = cfg.lang == "de", levelOf(cfg.level)
  local list = {}
  for _, a in ipairs(doc.alerts or {}) do
    local severity = a.severity or ""
    if (a.status or "actual") == "actual" and levelOf(severity) >= minLevel then   -- skip test messages
      local function text(field) return tostring(a[field .. (de and "_de" or "_en")] or "") end
      local w = { severity = severity, level = levelOf(severity), event = text("event"), headline = text("headline"),
                  text = text("description"), onset = a.onset or "", expires = a.expires or "" }
      local instruction = text("instruction")
      if instruction ~= "" then w.text = w.text .. "\n" .. instruction end
      if #w.text > 600 then w.text = w.text:sub(1, 597) .. "..." end
      -- An update with new times keeps the key: event|onset hour|severity
      w.key = tostring(a.event_code or 0) .. "|" .. w.onset:sub(1, 13) .. "|" .. severity
      list[#list + 1] = w
    end
  end
  active = list
  return true
end

local function pushWarnings()
  local known = recall("warned") or ""   -- warnings told about before, one key per line
  local now, pushes = {}, 0
  for _, w in ipairs(active) do
    now[#now + 1] = w.key .. "\n"
    if not known:find(w.key .. "\n", 1, true) then
      local priority = w.level >= 4 and 5 or w.level == 3 and 4 or 3
      notify(w.headline ~= "" and w.headline or w.event, span(w) .. "\n" .. w.text,
             w.level >= 3 and "rotating_light" or "warning", { { "All warnings", cmd = "weather" } }, priority)
      pushes = pushes + 1
    end
  end
  now = table.concat(now)
  if cfg.pushEnd then
    for _, k in ipairs(split(known, "\n")) do
      if not now:find(k .. "\n", 1, true) then
        notify("Weather warning over", place() .. ": a warning has ended or was lifted.", "white_check_mark")
        pushes = pushes + 1
      end
    end
  end
  if now ~= known then remember(now, "warned") end
  return pushes
end

local function warningList()
  if #active == 0 then return "No weather warnings for " .. place() .. "." end
  local lines = {}
  for _, w in ipairs(active) do lines[#lines + 1] = "- " .. (w.event ~= "" and w.event or w.headline) .. ", " .. span(w) end
  return table.concat(lines, "\n")
end

local function fetchDay(date)
  local body, err = http.get("https://api.brightsky.dev/weather?" .. base() .. "&date=" .. date ..
                             "&last_date=" .. addDays(date, 1))
  if not body then return nil, err end
  local doc = json.decode(body)
  if type(doc) ~= "table" then return nil, "bad answer" end
  local d = { tMin = 99, tMax = -99, rain = 0, gust = 0, rainProb = 0, sun = 0, hours = 0, rainFrom = "",
              snow = false, thunder = false, fog = false }
  for _, r in ipairs(doc.weather or {}) do
    local ts = r.timestamp or ""
    if ts:sub(1, 10) == date then   -- last_date is included; stay on this day
      local h = tonumber(ts:sub(12, 13)) or 0
      d.hours = d.hours + 1
      if type(r.temperature) == "number" then
        d.tMin, d.tMax = math.min(d.tMin, r.temperature), math.max(d.tMax, r.temperature)
      end
      d.rain = d.rain + (tonumber(r.precipitation) or 0)
      d.sun = d.sun + (tonumber(r.sunshine) or 0)
      d.gust = math.max(d.gust, tonumber(r.wind_gust_speed) or 0)
      local prob, cond = math.floor(tonumber(r.precipitation_probability) or 0), r.condition or ""
      local daytime = h >= 7 and h <= 21
      if daytime and prob > d.rainProb then d.rainProb = prob end
      if daytime and prob >= 50 and d.rainFrom == "" then d.rainFrom = ts:sub(12, 16) end
      d.snow = d.snow or cond == "snow" or cond == "sleet"
      d.thunder = d.thunder or cond == "thunderstorm"
      d.fog = d.fog or (daytime and cond == "fog")
    end
  end
  if d.hours == 0 then return nil, "no forecast data" end
  return d
end

local function bad(d) return d.rainProb >= 50 or d.snow or d.thunder or d.tMin <= 0 or d.gust >= 60 end

local function tag(d)
  if d.thunder then return "zap" end
  if d.snow then return "snowflake" end
  if d.rainProb >= 50 then return "umbrella" end
  if d.sun >= 360 then return "sunny" end
  if d.tMin <= 0 then return "cold_face" end
  return "partly_sunny"
end

local function headline(d)
  local what = d.thunder and "thunderstorms" or d.snow and "snow" or d.rainProb >= 50 and "take an umbrella"
               or d.sun >= 360 and "sunny" or d.fog and "foggy" or "dry"
  return "Today in " .. place() .. ": " .. what .. ", " .. round(d.tMin) .. " to " .. round(d.tMax) .. " °C"
end

local function describe(d, withTitle)
  local lines = {}
  if withTitle then lines[#lines + 1] = headline(d) end
  if d.rainProb >= 50 then
    lines[#lines + 1] = string.format("Rain likely from %s (up to %d %%), %.1f mm", d.rainFrom, d.rainProb, d.rain)
  elseif d.rainProb > 0 then
    lines[#lines + 1] = "Rain chance up to " .. d.rainProb .. " %"
  end
  if d.snow then lines[#lines + 1] = "Snow or sleet expected" end
  if d.thunder then lines[#lines + 1] = "Thunderstorms possible" end
  if d.gust >= 40 then lines[#lines + 1] = "Gusts up to " .. round(d.gust) .. " km/h" end
  if d.tMin <= 0 then lines[#lines + 1] = "Frost: watch for ice" end
  if d.sun >= 60 then lines[#lines + 1] = math.floor(d.sun / 60) .. " h of sunshine" end
  lines[#lines + 1] = "Data: DWD via Bright Sky"
  return table.concat(lines, "\n")
end

M.commands = {
  { "weather", "wetter, warnung, warning, forecast, umbrella, regen", "warnings and today's forecast", function()
      local ok, err = fetchWarnings()
      local warnings = ok and warningList() or ("Warnings: " .. err)
      local d, err2 = fetchDay(today())
      return warnings .. "\n\n" .. (d and describe(d, true) or ("Forecast: " .. err2))
    end },
}

function M.notReady()
  if num(cfg.lat) == 0 or num(cfg.lon) == 0 then return "no location set" end
end

function M.check()
  local ok, err = fetchWarnings()
  if not ok then return false, "warnings: " .. err end
  local pushes = pushWarnings()

  -- Morning forecast, once a day.
  local now = today()
  if cfg.morning >= 0 and hour() >= cfg.morning and trim(recall("morning") or "") ~= now then
    local d = fetchDay(now)
    if d then
      if not cfg.onlyBad or bad(d) then
        notify(headline(d), describe(d, false), tag(d), { { "Warnings & forecast", cmd = "weather" } })
        pushes = pushes + 1
      end
      remember(now, "morning")
    end
  end

  local line = #active == 0 and "no warnings" or (#active .. " warning" .. (#active == 1 and "" or "s"))
  if pushes > 0 then line = line .. ", " .. pushes .. " push" .. (pushes == 1 and "" or "es") end
  status(line)
end

return M
