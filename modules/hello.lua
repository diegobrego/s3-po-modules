-- Hello world: an example module that shows how S3-PO modules work.
--
-- It doesn't watch anything real. It greets you once a day, counts its checks, rolls a
-- die on request, and uses every part of the module API once along the way: settings of
-- each kind, commands (with words after them), pushes with buttons and priority, the
-- status line, memory that survives a restart, isNew(), firstCheck() and notReady().
--
-- Copy it as a starting point for your own module (or start from docs/template.lua),
-- and read docs/WRITING.md for the full API.

-- 1. The description. S3-PO builds the settings page section, the help text and the
--    store entry from it.
local M = {
  key = "hello",                  -- short id; the file must be called hello.lua
  name = "Hello world (example)",
  version = "1.0.0",              -- raise it with every change
  about = "An example for module writers: a daily greeting, a check counter and a dice command. Sends nothing useful.",
  order = 90,                     -- near the bottom of the settings page
  every = 60,                     -- check once an hour...
  minEvery = 5,                   -- ...or as often as every 5 minutes, if you set it
  startOff = true,                -- installed switched off, so nobody gets surprise pushes
  settings = {
    { "name", "Your name", "", hint = "used in the greeting; empty = \"friend\"" },        -- text
    { "greeting", "Greeting", "Hello", hint = "the first word of the daily push" },          -- text
    { "hour", "Greet from (hour)", 9, range = { 0, 23 } },                                    -- whole number
    { "mood", "S3-PO's mood", "cheerful",                                                     -- drop-down
      options = { "cheerful|Cheerful", "grumpy|Grumpy", "poetic|Poetic" } },
    { "loud", "Loud greeting (priority 4)", false },                                          -- checkbox
  },
}

-- 2. Module state. Plain Lua variables keep their values between checks (until S3-PO
--    restarts or the module is updated). For things that must survive a restart, use
--    remember() / recall(), as below.
local checksSinceStart = 0

local QUIPS = {
  cheerful = "What a lovely day to be a droid!",
  grumpy = "Another day, another push. You're welcome.",
  poetic = "The router hums, the packets flow; a droid salutes you from below.",
}

local function who()
  return cfg.name ~= "" and cfg.name or "friend"   -- cfg.<key> reads a setting, typed by its default
end

-- What survives restarts: a table, stored as JSON in flash.
local function stats()
  local s = recall() or {}          -- nil the first time
  s.checks = s.checks or 0
  s.greetings = s.greetings or 0
  return s
end

-- 3. Commands. Each one: a name, other words that trigger it (comma separated), a help
--    line, and a function that gets the whole message and returns the reply.
--    Words match at the start of any word in the message, and modules higher up the
--    settings page are asked first. So pick words that don't start other commands:
--    "hallo" would go to the Oracle (it listens for "hall"), "hi" would catch "hilfe".
M.commands = {
  { "hello", "greet, servus", "say hello (try: hello Anna)", function(text)
      local name = trim(text:gsub("^%S+", "", 1))      -- the words after "hello", if any
      if name == "" then name = who() end
      local s = stats()
      return cfg.greeting .. ", " .. name .. "! " .. QUIPS[cfg.mood] ..
             "\nI've run " .. s.checks .. " checks and sent " .. s.greetings .. " greetings so far."
    end },

  { "dice", "roll, würfel, wuerfel", "roll a die", function()
      local n = math.random(6)
      if n == 6 then
        -- A command can also send a push of its own, with buttons:
        -- { "Label", cmd = "..." } runs a command, { "Label", url = "..." } opens a page.
        notify{
          title = "A six!",
          message = who() .. " rolled a six. Lucky day.",
          tag = "game_die",
          buttons = { { "Roll again", cmd = "dice" } },
        }
      end
      return "You rolled a " .. n .. "."
    end },
}

-- 4. notReady(): why the module can't run yet, or nothing when it can. While it returns
--    something, S3-PO doesn't call check() and shows the reason on the status page.
function M.notReady()
  if trim(cfg.greeting) == "" then return "no greeting set" end
end

-- 5. settingsChanged(): optional, called after the settings were saved.
function M.settingsChanged()
  log("settings saved, mood is now %s", cfg.mood)
end

-- 6. check(): runs on schedule (and on "check"). Send pushes with notify(), set one line
--    for the status page with status(). `return false, "why"` (or an error) means the
--    check failed; after 3 failures in a row S3-PO sends one error push.
function M.check()
  checksSinceStart = checksSinceStart + 1
  local s = stats()
  s.checks = s.checks + 1

  -- firstCheck() is true until the first successful check: a good moment for a welcome,
  -- and for staying quiet about things that already existed (see the other modules).
  if firstCheck() then
    notify("Hello from the example module",
           "This module shows how S3-PO modules work. You'll get one greeting a day from " ..
           cfg.hour .. ":00. Send \"hello\" or \"dice\" to try its commands.",
           "wave", { { "Say hello", cmd = "hello" }, { "Roll a die", cmd = "dice" } })
  end

  -- Once a day from the chosen hour. isNew(id) is true only the first time it sees an id,
  -- and remembers ids in flash, so a restart doesn't send the greeting twice.
  if hour() >= cfg.hour and isNew("greeting " .. today()) then
    s.greetings = s.greetings + 1
    notify{
      title = cfg.greeting .. ", " .. who() .. "!",
      message = QUIPS[cfg.mood] .. "\nToday is " .. dateLabel(today()) .. ".",
      tag = "wave",
      buttons = { { "Roll a die", cmd = "dice" }, { "How modules work", url = "https://github.com/diegobrego/s3-po-modules/blob/main/docs/WRITING.md" } },
      priority = cfg.loud and 4 or 3,   -- 4 and 5 are louder, and go out even in quiet hours
    }
  end

  remember(s)   -- back to flash
  status(s.checks .. " checks (" .. checksSinceStart .. " since start), " .. s.greetings .. " greetings")
end

return M   -- the last line: the module table
