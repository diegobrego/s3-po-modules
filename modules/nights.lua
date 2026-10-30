-- Game nights: watches the calendar of a Board Game Night site (the BoardGameNight web app)
-- and pushes when a day reaches "Game on" (enough players, like the site), when one is
-- off again, and optionally when time or place change and the day before.
--
-- The site keeps its data in Firestore; its rules let anyone read the calendar and the
-- players, so the public project id and web API key from the site's js/config.js are enough.

local M = {
  key = "nights",
  name = "Game nights",
  version = "1.0.0",
  about = "A push when a day on your Board Game Night calendar reaches \"Game on\", when it's off again, and a reminder the day before.",
  order = 10,
  every = 15,
  minEvery = 5,
  settings = {
    { "minPlayers", "Players for game on", 3, range = { 1, 50 }, hint = "the site uses 3" },
    { "onlyPlayer", "Only days with this player", "", hint = "your name on the site; empty = every game night" },
    { "pushNew", "Push when a day reaches game on", true },
    { "pushOff", "Push when a game night is off again", true },
    { "pushChange", "Push when time or place changes", false },
    { "remind", "Reminder the day before (from 12:00)", false },
    { "days", "Look ahead (days)", 21, range = { 1, 90 } },
    { "site", "Calendar page", "", hint = "the site's address, for the Open button" },
    { "project", "Firebase project id", "", hint = "projectId in the site's js/config.js" },
    { "apiKey", "Firebase web API key", "", hint = "apiKey in the site's js/config.js (public)" },
    { "place", "Usual place", "", hint = "shown when a night has no place saved" },
    { "time", "Usual start time", "17:00", hint = "the site's default" },
  },
}

local players = nil     -- id -> { name = }
local namesAt = 0
local upcoming = {}     -- game-on days from the last check

-- --- Reading the site (same as in the Game Night Oracle) ---------------------------
local function fs(collection, fields, from, to)
  local args = { project = cfg.project, key = cfg.apiKey, collection = collection, fields = fields, from = from, to = to }
  if from then return firestore.range(args) end
  return firestore.list(args)
end

local function loadPlayers()
  local docs, err = fs("players", { "name" })
  if not docs then return nil, err end
  local list = {}
  for _, d in ipairs(docs) do
    list[d._id] = { name = (d.name and d.name ~= "") and d.name or "?" }
  end
  return list
end

-- The site's vote key for a game: "g<BGG id>", or "n_<name as a slug>".
local function voteKey(id, name)
  if id and tostring(id) ~= "" and tostring(id) ~= "0" then return "g" .. tostring(id) end
  local slug, gap = "", false
  for i = 1, #name do
    local c = name:sub(i, i):lower()
    if c:match("%w") then
      if gap and slug ~= "" then slug = slug .. "_" end
      slug, gap = slug .. c, false
    else
      gap = true
    end
  end
  return "n_" .. (slug ~= "" and slug:sub(1, 60) or "unnamed")
end

-- Days between two dates (ids like "2026-11-07"), with time and place like the site
-- shows them: saved details win; otherwise the usual place and the latest start time.
local function loadDays(from, to)
  local docs, err = fs("days", { "players", "times", "details", "games", "votes" }, from, to)
  if not docs then return nil, err end
  local days = {}
  for _, d in ipairs(docs) do
    local day = { date = d._id, players = d.players or {}, topGame = "", topVotes = 0 }
    local details, times = d.details or {}, d.times or {}
    if details.time and details.time ~= "" then
      day.time = details.time
    else
      local latest = cfg.time
      for _, p in ipairs(day.players) do
        if times[p] and times[p] > latest then latest = times[p] end   -- "HH:MM" compares as text
      end
      day.time = latest
    end
    day.place = details.place ~= nil and tostring(details.place) or cfg.place
    local votes = d.votes or {}
    for _, g in ipairs(d.games or {}) do
      local n = #(votes[voteKey(g.id, g.name or "")] or {})
      if n > day.topVotes then day.topVotes, day.topGame = n, g.name or "" end
    end
    days[#days + 1] = day
  end
  return days
end

local function nameOf(id) return players and players[id] and players[id].name or "?" end
local function namesOf(ids)
  local names = {}
  for _, id in ipairs(ids) do names[#names + 1] = nameOf(id) end
  return table.concat(names, ", ")
end
-- -----------------------------------------------------------------------------------

local function whereWhen(d) return d.place ~= "" and (d.time .. " at " .. d.place) or d.time end
local function buttons() return { { "Open calendar", url = cfg.site }, { "Game nights", cmd = "nights" } } end

local function includesMe(d)
  local me = cfg.onlyPlayer:lower()
  if me == "" then return true end
  for _, id in ipairs(d.players) do
    if nameOf(id):lower() == me then return true end
  end
  return false
end

local function list()
  if #upcoming == 0 then return "No game night in the next " .. cfg.days .. " days." end
  local lines = {}
  for _, d in ipairs(upcoming) do
    lines[#lines + 1] = dateLabel(d.date) .. ", " .. whereWhen(d) .. "\n  " .. namesOf(d.players)
  end
  return table.concat(lines, "\n")
end

M.commands = {
  { "nights", "night, game, spiel", "upcoming game nights", function() return list() end },
}

function M.notReady()
  if cfg.project == "" or cfg.apiKey == "" then return "no Board Game Night project set" end
end

function M.check()
  if not players or millis() - namesAt > 3600000 then   -- names hourly
    local p, err = loadPlayers()
    if p then players, namesAt = p, millis()
    elseif not players then return false, err end
  end
  local days, err = loadDays(today(), today(cfg.days))
  if not days then return false, err end

  -- What was announced before: date -> { t = time, p = place, r = reminder sent }
  local state = recall()
  local known = type(state) == "table" and state.days or {}
  local minPlayers, now, tomorrow = cfg.minPlayers, today(), today(1)
  local seen, pushes = {}, 0
  upcoming = {}

  for _, d in ipairs(days) do
    local on = #d.players >= minPlayers
    if on then upcoming[#upcoming + 1] = d end
    if on and includesMe(d) then
      seen[d.date] = true
      local label = dateLabel(d.date)
      local k = known[d.date]
      if k == nil then
        if not firstCheck() and cfg.pushNew then
          notify("Game on: " .. label, whereWhen(d) .. "\n" .. namesOf(d.players) .. " (" .. #d.players .. " players)",
                 "game_die", buttons())
          pushes = pushes + 1
        end
        known[d.date] = { t = d.time, p = d.place, r = false }
      else
        if cfg.pushChange and (k.t ~= d.time or k.p ~= d.place) then
          notify("Game night changed: " .. label, "Now " .. whereWhen(d), "game_die", buttons())
          pushes = pushes + 1
        end
        k.t, k.p = d.time, d.place
        if cfg.remind and d.date == tomorrow and not k.r and hour() >= 12 then
          notify("Tomorrow: game night", label .. ", " .. whereWhen(d) .. "\n" .. namesOf(d.players), "game_die", buttons())
          k.r = true
          pushes = pushes + 1
        end
      end
    end
  end

  -- Announced days that are no longer game on (or are over now).
  for _, date in ipairs(sortedKeys(known)) do
    if not seen[date] then
      known[date] = nil
      if date >= now then
        local count = 0
        for _, d in ipairs(days) do
          if d.date == date then count = #d.players end
        end
        if count < minPlayers and cfg.pushOff then
          notify("Game night off: " .. dateLabel(date),
                 count == 0 and "Nobody is in any more." or ("Only " .. count .. (count == 1 and " player" or " players") .. " left."),
                 "x", buttons())
          pushes = pushes + 1
        end
      end
    end
  end

  if firstCheck() then
    notify("S3-PO watches your game nights",
           #upcoming == 0 and ("No game night planned yet. I'll tell you when a day reaches " .. minPlayers .. " players.")
                          or list(), "game_die", buttons())
  end

  remember({ days = known })
  if pushes > 0 then blink(3) end
  status(#upcoming .. " game night" .. (#upcoming == 1 and "" or "s") .. " ahead" ..
         (pushes > 0 and (", " .. pushes .. " push" .. (pushes == 1 and "" or "es") .. " sent") or ""))
end

return M
