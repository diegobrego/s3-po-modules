-- Waste collection reminder, from an iCal (.ics) calendar: the format most German waste
-- providers offer as "Kalender abonnieren" / "iCal-Export". Either from a link (read
-- twice a day) or from a file uploaded on the settings page.
--
-- When it reminds you:
--   - Events without an alarm (normal pickups): the evening before, from the reminder
--     hour. Several pickups on the same day become one push.
--   - Events with a VALARM trigger get their own time, like in a phone calendar:
--       TRIGGER:-P7D  -> 7 days before, from the reminder hour
--       TRIGGER:PT8H  -> on the day itself at 08:00
--     Good for notices such as "Wertstoffhof closed".

local M = {
  key = "waste",
  name = "Waste collection",
  version = "1.0.0",
  about = "A reminder the evening before a waste pickup, plus notices like recycling centre closures, from an iCal calendar.",
  order = 20,
  every = 15,
  settings = {
    { "url", "Calendar link (iCal)", "",
      hint = "your provider's \"subscribe\" / iCal link (https:// or webcal://). Empty = use the uploaded file" },
    { "ics", "Calendar file (.ics)", file = true },
    { "hour", "Remind from (hour)", 18, range = { 0, 23 }, hint = "the evening before a pickup, e.g. 18 = 18:00" },
    { "bins", "Only these bins", "", hint = "comma separated, e.g. Rest, Papier; empty = all" },
  },
}

local RELOAD_MS = 12 * 3600000
local DAYS_KEPT = 60
local entries = {}      -- upcoming, sorted by date
local loadedAt = 0
local loadedFor = ""    -- the day the list was built

local function wanted(what, list)
  if trim(list) == "" then return true end
  what = what:lower()
  for _, item in ipairs(split(list:lower(), ",")) do
    if what:find(item, 1, true) then return true end
  end
  return false
end

-- iCal duration like "-P7D", "PT8H", "-P1DT6H" -> minutes (signed), and whether it
-- only has days (and weeks).
local function durationMinutes(d)
  d = trim(d)
  local sign = 1
  if d:sub(1, 1) == "-" then sign, d = -1, d:sub(2)
  elseif d:sub(1, 1) == "+" then d = d:sub(2) end
  if d:sub(1, 1) ~= "P" then return 0, true end
  local total, num, inTime, onlyDays = 0, 0, false, true
  for i = 2, #d do
    local c = d:sub(i, i)
    if c:match("%d") then
      num = num * 10 + tonumber(c)
    else
      if c == "T" then inTime = true
      elseif c == "W" then total = total + num * 7 * 1440
      elseif c == "D" then total = total + num * 1440
      elseif c == "H" and inTime then total, onlyDays = total + num * 60, false
      elseif c == "M" and inTime then total, onlyDays = total + num, false
      end
      num = 0
    end
  end
  return sign * total, onlyDays
end

local function unescape(s)
  s = s:gsub("\\,", ","):gsub("\\;", ";"):gsub("\\n", "\n"):gsub("\\N", "\n")
  return trim(s)
end

local function afterColon(l)
  local c = l:find(":", 1, true)
  return c and l:sub(c + 1) or ""
end

-- Minimal iCal reader: VEVENT blocks with DTSTART, SUMMARY, DESCRIPTION and the first
-- VALARM TRIGGER. Handles folded lines, all-day dates and date-times.
local function parseIcs(ics, filter)
  local first, last = today(), today(DAYS_KEPT)
  local out, events = {}, 0
  local e, trigger, inEvent, inAlarm = nil, "", false, false

  local function handle(l)
    if startsWith(l, "BEGIN:VEVENT") then
      inEvent, inAlarm = true, false
      e, trigger = { date = "", what = "", info = "", alarm = false, notifyDate = "", notifyHour = -1 }, ""
    elseif startsWith(l, "END:VEVENT") then
      inEvent = false
      events = events + 1
      if #e.date ~= 10 or e.what == "" or not wanted(e.what, filter) then return end
      if trigger ~= "" then
        local minutes, onlyDays = durationMinutes(trigger)
        e.alarm = true
        if onlyDays then
          e.notifyDate = addDays(e.date, minutes // 1440)
        else
          local shift = minutes >= 0 and minutes // 1440 or -((-minutes + 1439) // 1440)
          e.notifyDate = addDays(e.date, shift)
          e.notifyHour = (minutes - shift * 1440) // 60
        end
      end
      local upTo = (e.alarm and e.notifyDate > e.date) and e.notifyDate or e.date
      if upTo >= first and e.date <= last then out[#out + 1] = e end
    elseif not inEvent then
      return
    elseif startsWith(l, "BEGIN:VALARM") then
      inAlarm = true
    elseif startsWith(l, "END:VALARM") then
      inAlarm = false
    elseif inAlarm then   -- only the alarm's TRIGGER counts, not its SUMMARY/DESCRIPTION
      if startsWith(l, "TRIGGER") and trigger == "" then trigger = afterColon(l) end
    elseif startsWith(l, "DTSTART") then
      local c = l:find(":", 1, true)
      if c and #l >= c + 8 then
        local d = l:sub(c + 1, c + 8)
        e.date = d:sub(1, 4) .. "-" .. d:sub(5, 6) .. "-" .. d:sub(7, 8)
      end
    elseif startsWith(l, "SUMMARY") then
      e.what = unescape(afterColon(l))
    elseif startsWith(l, "DESCRIPTION") then
      e.info = unescape(afterColon(l))
    end
  end

  local line = ""
  for raw in (ics .. "\n"):gmatch("(.-)\n") do
    raw = raw:gsub("\r$", "")
    local c = raw:sub(1, 1)
    if c == " " or c == "\t" then   -- folded continuation line
      line = line .. raw:sub(2)
    else
      if line ~= "" then handle(line) end
      line = raw
    end
  end
  if line ~= "" then handle(line) end

  table.sort(out, function(a, b)
    if a.date ~= b.date then return a.date < b.date end
    return a.what < b.what
  end)
  return out, events
end

local function loadCalendar()
  local ics
  local url = trim(cfg.url)
  if url ~= "" then
    if startsWith(url, "webcal://") then url = "https://" .. url:sub(10) end
    local body, err = http.get(url)
    if not body then return false, "calendar download: " .. err end
    ics = body
  else
    ics = fileText("ics")
    if not ics then return false, "no calendar file uploaded" end
  end
  if not ics:find("BEGIN:VCALENDAR", 1, true) then return false, "that is not an iCal calendar" end
  local list, events = parseIcs(ics, cfg.bins)
  if events == 0 then return false, "calendar has no events" end
  entries, loadedAt, loadedFor = list, millis(), today()
  log("calendar: %d events, %d upcoming", events, #list)
  return true
end

-- Pickups (events without their own alarm) on a date, comma separated.
local function pickupsOn(date)
  local what = {}
  for _, e in ipairs(entries) do
    if not e.alarm and e.date == date then what[#what + 1] = e.what end
  end
  return table.concat(what, ", ")
end

local function list()
  local now, lines, lastDate = today(), {}, nil
  for _, e in ipairs(entries) do
    if e.date >= now then
      if e.alarm then
        -- Notices usually name their date already ("Wertstoffhof closed: Thu 24 Dec ...").
        if e.what:find(dateLabel(e.date), 1, true) then lines[#lines + 1] = e.what
        else lines[#lines + 1] = dateLabel(e.date) .. ": " .. e.what end
      elseif e.date ~= lastDate then
        lastDate = e.date
        lines[#lines + 1] = dateLabel(e.date) .. ": " .. pickupsOn(e.date)
      end
      if #lines >= 10 then break end
    end
  end
  if #lines == 0 then return "Nothing in the next " .. DAYS_KEPT .. " days." end
  return table.concat(lines, "\n")
end

M.commands = {
  { "waste", "müll, muell, abfall, tonne, bin, trash, wertstoff", "next waste pickups", function()
      if #entries == 0 then
        local ok, err = loadCalendar()
        if not ok then return "Calendar: " .. err end
      end
      return list()
    end },
}

function M.notReady()
  local url = cfg.url
  if startsWith(url, "http") or startsWith(url, "webcal") then return nil end
  if not cfg.ics then return "no calendar link and no uploaded file" end
end

function M.settingsChanged()
  entries, loadedAt = {}, 0
end

function M.check()
  local stale = #entries == 0 or millis() - loadedAt > RELOAD_MS or loadedFor ~= today()
  if stale then
    local ok, err = loadCalendar()
    if not ok then
      if #entries == 0 then return false, err end
      log("%s, keeping the old list", err)
    end
  end

  local now, tomorrow, h, remindHour = today(), today(1), hour(), cfg.hour
  -- Reminders already sent, one key per line.
  local sent, keys = {}, {}
  for _, k in ipairs(split(recall("sent") or "", "\n")) do
    sent[k] = true
    keys[#keys + 1] = k
  end
  local pushes = 0
  local function mark(k)
    sent[k] = true
    keys[#keys + 1] = k
    pushes = pushes + 1
  end

  -- 1. Pickups tomorrow, from the reminder hour, one combined push.
  local what = pickupsOn(tomorrow)
  if what ~= "" and h >= remindHour and not sent[tomorrow .. "|pickup"] then
    notify("Tomorrow: " .. what, "Put it out tonight (pickup from 06:00). " .. dateLabel(tomorrow) .. ".",
           "wastebasket", { { "Next pickups", cmd = "waste" } })
    mark(tomorrow .. "|pickup")
  end

  -- 2. Events with their own alarm (e.g. recycling centre closures).
  for _, e in ipairs(entries) do
    if e.alarm and e.notifyDate == now then
      local at = e.notifyHour < 0 and remindHour or e.notifyHour
      local k = now .. "|" .. e.date .. "|" .. e.what
      if h >= at and not sent[k] then
        notify(e.what, e.info ~= "" and e.info or dateLabel(e.date), "recycle", { { "Next dates", cmd = "waste" } })
        mark(k)
      end
    end
  end

  if pushes > 0 then
    local cutoff, out = today(-10), {}   -- keep the keys of the last 10 days
    for _, k in ipairs(keys) do
      if k:sub(1, 10) >= cutoff then out[#out + 1] = k end
    end
    remember(table.concat(out, "\n") .. "\n", "sent")
    blink(2)
  end

  -- Drop what is past (alarm events stay until their notify day has passed too).
  local keep = {}
  for _, e in ipairs(entries) do
    local upTo = (e.alarm and e.notifyDate > e.date) and e.notifyDate or e.date
    if upTo >= now then keep[#keep + 1] = e end
  end
  entries = keep

  local nextDate
  for _, e in ipairs(entries) do
    if not e.alarm and e.date >= now then nextDate = e.date break end
  end
  local line = nextDate and ("next: " .. pickupsOn(nextDate) .. " on " .. dateLabel(nextDate))
                         or ("no pickups in the next " .. DAYS_KEPT .. " days")
  if pushes > 0 then line = line .. ", " .. pushes .. " reminder" .. (pushes == 1 and "" or "s") .. " sent" end
  status(line)
end

return M
