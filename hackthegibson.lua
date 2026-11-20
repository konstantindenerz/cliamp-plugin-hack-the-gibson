-- Hack the Gibson: a flight through a city of glass towers, after the film
-- Hackers (1995). Edges and code are Braille dots, and the glass is a color
-- behind them or a grid of dots. Kick, snare and hi-hat each set off an effect.

local p = plugin.register({
    name = "Hack the Gibson",
    type = "visualizer",
    version = "0.1.0",
    description = "Flight through a city of glass towers",
})

local abs, floor, ceil, max, min = math.abs, math.floor, math.ceil, math.max, math.min
local sin, cos, exp, sqrt, atan2 = math.sin, math.cos, math.exp, math.sqrt, math.atan2
local pi, huge = math.pi, math.huge

local BANDS = 10

-- The city moves in steps of TICK seconds, however often cliamp draws.
local TICK = 0.025

local QUIET = 0.5 -- s of silence before the flight stops
local PACE = 240 -- ticks of music that the tempo is read from

-- The city is a grid of towers, one per BLOCK. The streets run between them.
local BLOCK = 2.9
local HALF = 0.5 -- half the width of a tower
local TALL = 2.5
local TURN = BLOCK / 2 -- the radius of a turn at a crossing

-- The four ways to fly, as steps in x and z: north, east, south, west.
local DX = { [0] = 0, 1, 0, -1 }
local DZ = { [0] = 1, 0, -1, 0 }

local PULSES = 6

-- Cell tiers, low to high; a cell shows the highest one drawn into it.
local GRID, T1, T4, LIT, BEAT, HOT = 1, 2, 5, 6, 7, 8

-- Colors ----------------------------------------------------------------

local RESET = "\27[0m"

-- conf reads a key of [plugins.hackthegibson] in config.toml.
local function conf(key)
    local value = p:config(key)
    return type(value) == "string" and value or nil
end

-- COLOR has the code of each tier. The glass of a cell has GLOWS shades, and
-- GAIN times its amount picks one. The glass is a color behind the dots, with
-- the codes in GLOW from thin to dense and in WARM for a drop; dotted glass
-- is a grid of dots instead.
local COLOR, GLOW, WARM = {}, {}, {}
local glowing, dotted = false, false
local GLOWS, GAIN = 16, 1

do
    -- The shades of an RGB color from far to near, and the densest glass.
    local SHADES = { 0.22, 0.42, 0.68, 1 }
    local GLASS = 0.5

    -- The themes: the colors of the towers, the ground, the frames of light
    -- and the heads of the pulses, and the background of the terminal that
    -- they are made for. hackers has the colors of the film, as in the CSS
    -- demo; terminal has those of the terminal itself, by palette index.
    local THEMES = {
        mechanoonna = { tower = "e7c07c", floor = "c5564a", beat = "d94e38", hot = "fff8e8", back = "1c1b19" },
        tokyonight = { tower = "7dcfff", floor = "bb9af7", beat = "f7768e", hot = "e0af68", back = "1a1b26" },
        catppuccin = { tower = "cba6f7", floor = "89b4fa", beat = "f38ba8", hot = "f9e2af", back = "1e1e2e" },
        gruvbox = { tower = "8ec07c", floor = "83a598", beat = "fe8019", hot = "fabd2f", back = "282828" },
        hackers = { tower = "58c6a2", floor = "9375ee", beat = "ee75d2", hot = "deee75", back = "000000" },
        terminal = { tower = 6, floor = 4, beat = 9, hot = 11, back = "000000" },
    }
    local DEFAULT = "mechanoonna"

    -- The name of a theme, as the config has it: "Tokyo Night", "tokyo-night"
    -- and "tokyonight" are one theme, and so is a longer name that starts
    -- with one, as "catppuccin-mocha".
    local theme = THEMES[DEFAULT]
    do
        local name = (conf("theme") or ""):match("^[%s\"']*([%w _%-]*)"):lower():gsub("[^%w]", "")
        local found = THEMES[name]
        for known, colors in pairs(THEMES) do
            if not found and #known < #name and name:sub(1, #known) == known then
                found = colors
            end
        end
        if found then
            theme = found
        elseif name ~= "" then
            print("hackthegibson: no theme " .. name .. ", so it is " .. DEFAULT)
        end
    end

    local function parts(hex)
        return { tonumber(hex:sub(1, 2), 16), tonumber(hex:sub(3, 4), 16), tonumber(hex:sub(5, 6), 16) }
    end

    -- A color is "#rrggbb" or a palette index (0-255). The first has shades,
    -- the second follows the theme of the terminal. A key of the config that
    -- names no color has the color of the theme.
    local function ink(key)
        local value = conf(key)
        local hex = value and value:match("^%s*#(%x%x%x%x%x%x)")
        local index = not hex and tonumber(value and value:match("^%s*(%d+)") or "")
        if not hex and not index then
            local color = theme[key]
            if type(color) == "number" then
                index = color
            else
                hex = color
            end
        end
        if index then
            return { index = min(index, 255) }
        end
        return hex and parts(hex)
    end

    -- The ground of the terminal. A shade of a color is that far from here
    -- to the color, so the towers far away fade into the ground. A palette
    -- index will not do here.
    local back = ink("back")
    if back.index then
        back = parts(theme.back)
    end

    -- indexed gives the code of a palette color, for the dots or the ground
    -- behind them.
    local function indexed(n, ground)
        if n < 8 then
            return (ground and 40 or 30) + n
        elseif n < 16 then
            return (ground and 92 or 82) + n
        end
        return (ground and "48;5;" or "38;5;") .. n
    end

    local function rgb(color, shade, white, ground)
        local part = {}
        for i = 1, 3 do
            local v = back[i] + (color[i] - back[i]) * shade
            part[i] = floor(v + (255 - v) * white + 0.5)
        end
        return string.format("%d;2;%d;%d;%d", ground and 48 or 38, part[1], part[2], part[3])
    end

    -- paint gives the code for the dots: step 1 to 4 from far to near, 5 lit.
    -- A palette color is faint far away and bright near; every code sets the
    -- weight too, as the one before may have changed it.
    local function paint(color, step)
        local n = color.index
        if not n then
            return "\27[22;" .. rgb(color, SHADES[min(step, 4)], step == 5 and 0.55 or 0) .. "m"
        end
        local weight = "22;"
        if step <= 2 then
            weight = "22;2;"
        elseif step == 5 then
            weight = "22;1;"
        end
        if step >= 4 and n < 8 then
            n = n + 8
        end
        return "\27[" .. weight .. indexed(n) .. "m"
    end

    local tower, floor_, beat = ink("tower"), ink("floor"), ink("beat")
    COLOR[GRID] = floor_.index and paint(floor_, 1) or "\27[22;" .. rgb(floor_, 0.6, 0) .. "m"
    for step = 1, 4 do
        COLOR[T1 + step - 1] = paint(tower, step)
    end
    COLOR[LIT] = paint(tower, 5)
    COLOR[BEAT] = paint(beat, 4)
    COLOR[HOT] = paint(ink("hot"), 4)

    -- The glass has the color of the towers, unless the config names one.
    -- An RGB color gives shades of it. A palette color has none: as the glass
    -- it is one flat shade where the glass is dense enough, and towers of a
    -- palette color get dotted glass.
    local wanted = conf("glass") or ""
    if not wanted:match("^%s*off") then
        glowing = true
        local glass = ink("glass")
        if not glass and not tower.index and not wanted:match("^%s*dots") then
            glass = tower
        end
        if not glass then
            dotted = true
            GLOWS, GAIN = 4, 1.3
        elseif glass.index then
            GLOWS, GAIN = 1, 2
            GLOW[1] = "\27[" .. indexed(glass.index, true) .. "m"
            WARM = GLOW
        else
            for level = 1, GLOWS do
                GLOW[level] = "\27[" .. rgb(glass, GLASS * level / GLOWS, 0, true) .. "m"
                WARM[level] = beat.index and GLOW[level]
                    or "\27[" .. rgb(beat, GLASS * level / GLOWS, 0, true) .. "m"
            end
        end
    end
end

-- cliamp hands a plugin the sound a little before it is heard. The city
-- waits this long, in ticks, so a kick shows when it sounds.
local DELAY = tonumber((conf("delay_ms") or ""):match("^%s*(%d+)") or "") or 0
DELAY = min(40, floor(DELAY / (TICK * 1000) + 0.5))

-- State -----------------------------------------------------------------

local s

local function filled(n, v)
    local t = {}
    for i = 1, n do
        t[i] = v
    end
    return t
end

-- A fixed pseudo-random value in [0, 1) for item i, a different one per slot.
local function hash(i, slot)
    local x = sin(i * 12.9898 + slot * 78.233) * 43758.5453
    return x - floor(x)
end

local function round(x)
    if x < 0 then
        return -floor(0.5 - x)
    end
    return floor(x + 0.5)
end

-- turn picks the way of a leg from the way of the leg before: left, right
-- or, most often, straight on.
local function turn(leg, dir)
    local pick = hash(leg, 1)
    if pick < 0.15 then
        return (dir + 1) % 4
    elseif pick < 0.3 then
        return (dir + 3) % 4
    end
    return dir
end

local function reset()
    s = {
        travel = 0, -- blocks
        speed = 0, -- blocks/s
        loud = 0,
        clock = 0, -- playback seconds, frozen while paused
        playing = false,
        deaf = 0, -- s left without hits
        hasPrev = false,
        lastKick = -huge,
        -- Tempo: how much the bands rose in each of the last PACE ticks, the
        -- newest at fluxAt; the beat period in s (0 = none yet), the time of a
        -- beat, and the confidence, 0..1. rival is a period that may take over.
        flux = filled(PACE, 0),
        fluxAt = PACE,
        paced = 0, -- ticks since the tempo was read
        beat = 0,
        beatAt = 0,
        sure = 0,
        rival = 0,
        rivals = 0,
        fastE = 0,
        slowE = 0,
        warpAt = -huge,
        warp = 0,
        lift = 0, -- 0 in the streets, 1 above the roofs
        heard = 0, -- s of music since the last silence
        quiet = QUIET, -- s of silence
        rock = 0,
        rockTo = 0,
        rockSide = 1,
        -- The route: leg number leg starts at the crossing (nx, nz) and runs
        -- one block the way dir. from and to are the ways of the legs around it.
        leg = 0,
        nx = 0,
        nz = 0,
        from = 0,
        dir = 0,
        to = 0,
        turnedAt = -huge, -- when the eye last chose to turn
        turnedLeg = 0, -- and the first leg after that turn
        pulsed = 0, -- pulses so far
        scanAt = -huge,
        scanUp = false,
        struck = 0, -- hi-hats so far
        strikeAt = -huge,
        strike = 0,
        lo = filled(BANDS, 1), -- start wide open
        hi = filled(BANDS, 0),
        glow = filled(BANDS, 0), -- live band levels
        prev = filled(BANDS, 0),
        typical = { 0, 0, 0 }, -- recent hit ratios
        pulses = {},
        heldBands = {}, -- the bands of the last DELAY ticks
        held = 0,
        lateBands = filled(BANDS, 0),
        lastBands = filled(BANDS, 0), -- the bands of the frame before
        midBands = filled(BANDS, 0),
        -- Kick, snare, hi-hat: a sudden rise across a share of the bands,
        -- judged against how much they usually rise. Gaps in ticks: at most
        -- 240 kicks a minute.
        onsets = {
            { from = 1, to = 3, k = 2.0, floor = 0.05, gap = 10 },
            { from = 4, to = 6, k = 2.0, floor = 0.04, gap = 8 },
            { from = 7, to = 10, k = 1.8, floor = 0.025, gap = 6 },
        },
    }
    for _, o in ipairs(s.onsets) do
        o.mean, o.dev, o.since, o.over = 0.03, 0.02, o.gap, 0
    end
    for i = 1, PULSES do
        s.pulses[i] = { x = 0, z = 0, dx = 0, dz = 0, at = -huge, strength = 0 } -- strength 0 = unused
    end
    for i = 1, DELAY do
        s.heldBands[i] = filled(BANDS, 0)
    end
end

reset()

-- camera gives the eye: x, y and z, then yaw, pitch and roll in rad. A turn
-- is a quarter circle around the corner of a crossing, from the middle of
-- one block to the middle of the next.
local camera

do
    local EYE = 0.9
    local BOB = 0.35 -- the eye rises with the loudness
    local CLIMB = 6
    local TILT = 0.04 -- the eye looks down a little
    local DIVE = 0.42 -- and more from above the roofs
    local BANK = 0.16

    function camera()
        local t = (s.travel - s.leg) * BLOCK
        local dir = s.dir
        local ax, az = DX[dir], DZ[dir]
        local x, z = (s.nx + 0.5) * BLOCK, (s.nz + 0.5) * BLOCK
        local bx, bz, angle
        if t < TURN and s.from ~= dir then
            bx, bz, ax, az = ax, az, DX[s.from], DZ[s.from]
            angle = (1 + t / TURN) * pi / 4
        elseif t > BLOCK - TURN and s.to ~= dir then
            bx, bz = DX[s.to], DZ[s.to]
            x, z = x + ax * BLOCK, z + az * BLOCK
            angle = (t - BLOCK + TURN) / TURN * pi / 4
        end
        local yaw, bank = dir * pi / 2, 0
        if angle then
            local sine, cosine = sin(angle), cos(angle)
            x = x + TURN * (ax * (sine - 1) + bx * (1 - cosine))
            z = z + TURN * (az * (sine - 1) + bz * (1 - cosine))
            yaw = atan2(ax * cosine + bx * sine, az * cosine + bz * sine)
            bank = (ax * bz - az * bx) * BANK * sin(2 * angle)
        else
            x, z = x + ax * t, z + az * t
        end
        return x, EYE + BOB * s.loud + CLIMB * s.lift, z, yaw, TILT + DIVE * s.lift, bank + s.rock
    end
end

-- Music ------------------------------------------------------------------

-- play runs the ticks of a frame of playback, rest one tick of a pause.
local play, rest

do
    -- Speed in blocks/s.
    local CRUISE = 0.5
    local LOUD_GAIN = 0.4
    local WARP_GAIN = 0.6 -- the share a drop adds

    -- Between two turns: at least this many seconds and this many blocks.
    local CALM = 2.5
    local STRAIGHT = 2

    -- Tempo: read every PACE_EVERY ticks, as a beat of LAG_MIN to LAG_MAX
    -- ticks: 60 to 185 BPM. A hi-hat counts less than a drum, or the eighths
    -- pass for the beat.
    local PACE_EVERY = 20
    local LAG_MIN, LAG_MAX = 13, 40
    local PART_WEIGHT = { 1, 1, 0.5 }
    local PRIOR_WIDTH = 1.0 -- in octaves
    local FOLD = 0.5 * 2 ^ 0.5 -- s; a longer period is two beats
    local SALIENT = 1.5 -- a beat stands out this much from the other periods
    local SAME = 0.06 -- two periods this close are one tempo
    local MARGIN = 1.3 -- another tempo must fit this much better
    local RIVALS = 3 -- for this many looks in a row, to take over
    local SURE_STEP = 0.25
    local PHASES = 16
    local LOCK = 0.3 -- speed change per block of phase error
    local LOCK_MAX = 0.15

    -- A drop: the short energy average jumps above the long one.
    local DROP_RATIO = 1.5
    local DROP_FLOOR = 0.12
    local DROP_GAP = 8.0 -- s between drops
    local DROP_WARM = 4.0 -- s of music before a drop counts
    local SILENCE = 0.02
    local DEAF = 0.3 -- s without hits while the bands rise again after a break
    local WARP_RISE = 0.15
    local WARP_FADE = 0.6
    local WARP_LIFE = 2.5
    local HOVER = 2.2 -- s above the roofs

    -- A hit as strong as the recent ones gets this strength.
    local HIT_TYPICAL = 0.6
    -- Snare: rock the eye, alternating sides.
    local ROCK = 0.035
    -- Hi-hat: none within this many ticks of a snare.
    local HAT_WAIT = 2
    -- Kick: a pulse of light. One that crosses the way starts this far aside.
    local PULSE_FROM = 2.5 * BLOCK

    -- Per-band min/max tracking.
    local BAND_RELAX = 0.08
    local BAND_SPAN = 0.12

    -- Share of the way to the target that one tick covers at rate r per second.
    local function per_tick(r)
        return 1 - exp(-r * TICK)
    end

    local K_SPEED, K_FALL, K_LOUD = per_tick(2.0), per_tick(2.5), per_tick(1.5)
    local K_GLOW_UP, K_GLOW_DOWN = per_tick(12), per_tick(6)
    local K_ROCK, K_LIFT = per_tick(14), per_tick(2.5)
    local K_FAST, K_SLOW = per_tick(4.0), per_tick(0.15)

    -- levels tracks each band against its own recent range and returns the
    -- overall loudness, 0..1.
    local function levels(bands)
        local lo, hi, glow = s.lo, s.hi, s.glow
        local loud = 0
        for i = 1, BANDS do
            local b = bands[i]
            hi[i] = max(b, hi[i] - BAND_RELAX * TICK)
            lo[i] = min(b, lo[i] + BAND_RELAX * TICK)
            local level = (b - lo[i]) / max(hi[i] - lo[i], BAND_SPAN)
            local g = glow[i]
            glow[i] = g + (level - g) * (level > g and K_GLOW_UP or K_GLOW_DOWN)
            loud = loud + level / BANDS
        end
        return loud
    end

    -- pulse sends a light along the ground: down a street beside the eye or
    -- under it, or across the way ahead.
    local function pulse(strength)
        local n = s.pulsed
        s.pulsed = n + 1
        local one = s.pulses[n % PULSES + 1]
        local ax, az = DX[s.dir], DZ[s.dir]
        local x, z = (s.nx + 0.5) * BLOCK, (s.nz + 0.5) * BLOCK
        if n % 2 == 0 then
            local lane = (floor(hash(n, 2) * 3) - 1) * BLOCK
            local back = (s.travel - s.leg) * BLOCK - 1
            one.x, one.z = x + az * lane + ax * back, z - ax * lane + az * back
            one.dx, one.dz = ax, az
        else
            local ahead = (1 + floor(hash(n, 2) * 3)) * BLOCK
            local side = hash(n, 3) < 0.5 and -1 or 1
            one.x, one.z = x + ax * ahead - az * side * PULSE_FROM, z + az * ahead + ax * side * PULSE_FROM
            one.dx, one.dz = az * side, -ax * side
        end
        one.at, one.strength = s.clock, strength
    end

    -- A beat repeats at its multiples too, so half and twice the tempo fit
    -- the music as well. Of those, the period nearest to half a second wins:
    -- PRIOR weighs each period, in quarters of a tick from LAG_MIN.
    local PRIOR = {}
    for i = 0, (LAG_MAX - LAG_MIN) * 4 do
        local octaves = math.log((LAG_MIN + i / 4) * TICK / 0.5) / math.log(2)
        PRIOR[i] = exp(-0.5 * (octaves / PRIOR_WIDTH) ^ 2)
    end

    -- The rises of the last PACE ticks, oldest first; the same spread out
    -- and less their mean; how alike they are to those some ticks before, by
    -- the number of ticks; how well each period fits, in quarters of a tick
    -- from LAG_MIN; and how much of the rises falls on each part of a beat.
    local raw, wave, echoes, scores, phases = {}, {}, {}, {}, {}
    local LAGS = 4 * LAG_MAX + 3 -- the refinement looks 3 ticks past 4 beats

    -- echo tells how alike the rises are to those lag ticks before. The lag
    -- need not be whole.
    local function echo(lag)
        local whole = floor(lag)
        return echoes[whole] + (echoes[whole + 1] - echoes[whole]) * (lag - whole)
    end

    -- crest tells where the top of a peak is between its samples: from half
    -- a sample before the middle one to half a sample after it.
    local function crest(before, top, after)
        local bend = before - 2 * top + after
        if not (bend < 0) then
            return 0
        end
        return max(-0.5, min(0.5, 0.5 * (before - after) / bend))
    end

    -- held tells how well the beat that the eye flies to fits the music now:
    -- the best score of the periods near it, near half of it and twice it.
    local function held()
        local most = 0
        for times = -1, 1 do
            local ticks = s.beat * 2 ^ times / TICK
            local from = ceil((ticks * (1 - SAME) - LAG_MIN) * 4)
            local to = floor((ticks * (1 + SAME) - LAG_MIN) * 4)
            for i = max(0, from), min((LAG_MAX - LAG_MIN) * 4, to) do
                most = max(most, scores[i])
            end
        end
        return most
    end

    -- tempo reads the beat from the rises of all bands, not from the kicks
    -- alone: a break has its kicks off the beat, and the snare on it. The
    -- beat is the period at which the rises repeat, and at its multiples too.
    local function tempo()
        -- cliamp hears the music every other tick, so a rise is a tick early
        -- or late. Spread each rise over the ticks around it, or beats that
        -- fall between two ticks do not look alike.
        local flux, newest = s.flux, s.fluxAt
        local mean = 0
        for i = 1, PACE do
            raw[i] = flux[(newest + i - 1) % PACE + 1]
            mean = mean + raw[i] / PACE
        end
        raw[-1], raw[0], raw[PACE + 1], raw[PACE + 2] = 0, 0, 0, 0
        local power = 0
        for i = 1, PACE do
            local v = (raw[i - 2] + 2 * raw[i - 1] + 3 * raw[i] + 2 * raw[i + 1] + raw[i + 2]) / 9
            v = max(0, v - mean)
            wave[i] = v
            power = power + v * v
        end
        local best, lag, total = 0, 0, 0
        if power > 1e-6 then
            for l = LAG_MIN - 1, LAGS do
                local sum = 0
                for t = l + 1, PACE do
                    sum = sum + wave[t] * wave[t - l]
                end
                echoes[l] = sum / (PACE - l)
            end
            for i = 0, (LAG_MAX - LAG_MIN) * 4 do
                local l = LAG_MIN + i / 4
                local score = (echo(l) + echo(2 * l) + echo(3 * l) + echo(4 * l)) * PRIOR[i]
                scores[i] = score
                total = total + score
                if score > best then
                    best, lag = score, l
                end
            end
        end
        if best <= 0 or best * ((LAG_MAX - LAG_MIN) * 4 + 1) < SALIENT * total then
            -- No beat to hear.
            s.sure = max(0, s.sure - SURE_STEP / 2)
            return
        end

        -- Four beats tell the period four times as well as one.
        local at = floor(4 * lag + 0.5)
        local peak = echoes[at]
        for l = at - 2, at + 2 do
            if echoes[l] > peak then
                peak, at = echoes[l], l
            end
        end
        local period = (at + crest(echoes[at - 1], peak, echoes[at + 1])) / 4 * TICK
        -- Music repeats every two beats more than every one, so the period
        -- may be twice the beat, or half of it. Take the one nearest to half
        -- a second: the eye then flies at a like speed to any track.
        if period > FOLD and period / 2 >= LAG_MIN * TICK then
            period = period / 2
        elseif period < FOLD / 2 and period * 2 <= LAG_MAX * TICK then
            period = period * 2
        end

        if s.beat == 0 or abs(period - s.beat) < SAME * s.beat then
            s.beat = s.beat == 0 and period or s.beat + (period - s.beat) * 0.4
            s.sure = min(1, s.sure + SURE_STEP)
            s.rivals = 0
        elseif best > MARGIN * held() then
            -- Another tempo fits better by far: it takes over when it stays.
            s.sure = max(0, s.sure - SURE_STEP / 2)
            if abs(period - s.rival) < SAME * s.rival then
                s.rivals = s.rivals + 1
            else
                s.rival, s.rivals = period, 1
            end
            if s.rivals >= RIVALS then
                s.beat, s.rivals = period, 0
            end
        else
            -- The beat of before fits about as well: dense music has many
            -- periods that do, and the eye must not hop between them.
            s.sure = min(1, s.sure + SURE_STEP)
            s.rivals = 0
        end

        -- Where in the beat the rises fall: the part that has most is the beat.
        local ticks = s.beat / TICK
        for i = 1, PHASES do
            phases[i] = 0
        end
        for t = 1, PACE do
            local part = floor((PACE - t) % ticks / ticks * PHASES) % PHASES + 1
            phases[part] = phases[part] + wave[t]
        end
        local most, part = 0, 1
        for i = 1, PHASES do
            if phases[i] > most then
                most, part = phases[i], i
            end
        end
        local shift = crest(phases[(part - 2) % PHASES + 1], most, phases[part % PHASES + 1])
        local ago = (part - 0.5 + shift) / PHASES * ticks
        s.beatAt = s.clock - ago * TICK
    end

    local function kick(strength)
        pulse(strength)
        s.lastKick = s.clock
    end

    -- hits finds kick, snare and hi-hat as rises, not levels: a louder bass
    -- floor must not hide the kicks. A snare is noise from the mids up, so a
    -- rise in the highs right before or after a snare is no hi-hat.
    local function hits(bands)
        local prev = s.prev
        local flux = 0
        if s.hasPrev then
            local onsets = s.onsets
            for part, o in ipairs(onsets) do
                local rise = 0
                for i = o.from, o.to do
                    rise = rise + max(0, bands[i] - prev[i])
                end
                flux = flux + rise * PART_WEIGHT[part]
                local threshold = max(o.mean + o.k * o.dev, o.floor)
                o.over = rise / threshold
                o.mean = o.mean * 0.92 + rise * 0.08
                o.dev = o.dev * 0.92 + abs(rise - o.mean) * 0.08
            end
            local low, mid, high = onsets[1], onsets[2], onsets[3]
            for part, o in ipairs(onsets) do
                local hit = o.over > 1 and o.since + 1 >= o.gap
                if o == high then
                    hit = hit and mid.since > HAT_WAIT
                end
                o.since = hit and 0 or o.since + 1
                if hit and s.deaf <= 0 then
                    -- Judge the hit against the recent ones, or every kick looks hard.
                    local usual = s.typical[part]
                    local strength = HIT_TYPICAL
                    if usual > 0 then
                        strength = min(1, HIT_TYPICAL * o.over / usual)
                        s.typical[part] = usual + (o.over - usual) * 0.2
                    else
                        s.typical[part] = o.over
                    end
                    if o == low then
                        kick(strength)
                    elseif o == mid then
                        -- A frame of light runs up the towers, then down them.
                        s.rockTo, s.rockSide = s.rockSide * ROCK, -s.rockSide
                        s.scanAt, s.scanUp = s.clock, not s.scanUp
                        -- The highs of a snare rise a tick before its mids
                        -- at times: that was no hi-hat.
                        if s.clock - s.strikeAt < (HAT_WAIT + 0.5) * TICK then
                            s.struck, s.strikeAt = s.struck - 1, -huge
                        end
                    else
                        -- Lines of code flash.
                        s.struck, s.strikeAt, s.strike = s.struck + 1, s.clock, strength
                    end
                end
            end
        end
        s.hasPrev = true
        for i = 1, BANDS do
            prev[i] = bands[i]
        end
        s.fluxAt = s.fluxAt % PACE + 1
        s.flux[s.fluxAt] = flux
    end

    -- dive finds drops in the raw energy. A drop lifts the eye above the roofs.
    local function dive(energy)
        if energy < SILENCE then
            s.heard = 0
            s.quiet = s.quiet + TICK
        else
            s.quiet = 0
            if s.heard == 0 then
                -- A track rising out of silence is no drop.
                s.fastE, s.slowE = energy, energy
            end
            s.heard = s.heard + TICK
        end
        s.fastE = s.fastE + (energy - s.fastE) * K_FAST
        -- While warming up the long average learns the level as fast as the short one.
        s.slowE = s.slowE + (energy - s.slowE) * (s.heard < DROP_WARM and K_FAST or K_SLOW)
        local drop = s.fastE > DROP_RATIO * s.slowE and s.fastE > DROP_FLOOR
        if drop and s.heard >= DROP_WARM and s.clock - s.warpAt > DROP_GAP then
            s.warpAt = s.clock
        end
        local age = s.clock - s.warpAt
        if age < 0 or age > WARP_LIFE then
            s.warp = 0
        elseif age < WARP_RISE then
            s.warp = age / WARP_RISE
        else
            s.warp = exp(-(age - WARP_RISE) / WARP_FADE)
        end
        s.lift = s.lift + ((age >= 0 and age < HOVER and 1 or 0) - s.lift) * K_LIFT
        if s.lift < 1e-4 then
            s.lift = 0
        end
    end

    -- target_speed is one block per beat when the tempo is sure, else the
    -- cruise. The flight stops when there is nothing to hear.
    local function target_speed()
        if s.quiet >= QUIET then
            return 0
        end
        local target = CRUISE + LOUD_GAIN * s.loud
        if s.beat > 0 then
            -- Phase error in blocks: 0 when the eye is at a crossing on the beat.
            local err = s.travel - (s.clock - s.beatAt) / s.beat
            err = err - round(err)
            local lock = max(-LOCK_MAX, min(LOCK_MAX, -LOCK * err)) * (1 - s.warp)
            target = target + ((1 + lock) / s.beat - target) * s.sure
        end
        return target * (1 + WARP_GAIN * s.warp)
    end

    -- fly moves the eye on by a tick and picks the way of the leg after each
    -- new one. After a turn the eye flies straight on for a while.
    local function fly()
        s.travel = s.travel + s.speed * TICK
        while s.travel - s.leg >= 1 do
            s.leg = s.leg + 1
            s.nx, s.nz = s.nx + DX[s.dir], s.nz + DZ[s.dir]
            local to = s.to
            if s.clock - s.turnedAt >= CALM and s.leg + 1 - s.turnedLeg >= STRAIGHT then
                to = turn(s.leg + 1, to)
                if to ~= s.to then
                    s.turnedAt, s.turnedLeg = s.clock, s.leg + 1
                end
            end
            s.from, s.dir, s.to = s.dir, s.to, to
        end
    end

    -- delayed swaps the bands for the ones from DELAY ticks ago.
    local function delayed(bands)
        if DELAY == 0 then
            return bands
        end
        s.held = s.held % DELAY + 1
        local slot, late = s.heldBands[s.held], s.lateBands
        for i = 1, BANDS do
            late[i], slot[i] = slot[i], bands[i]
        end
        return late
    end

    -- cliamp eases the bands and hands over where they are at the end of a
    -- frame. between gives them part of the way through it: the ease is faster
    -- up than down. after is the share of the frame gone by, span its length in s.
    local EASE_UP, EASE_DOWN = 34, 10

    local function between(bands, after, span)
        local up = (1 - exp(-EASE_UP * after * span)) / (1 - exp(-EASE_UP * span))
        local down = (1 - exp(-EASE_DOWN * after * span)) / (1 - exp(-EASE_DOWN * span))
        local from, mid = s.lastBands, s.midBands
        for i = 1, BANDS do
            local change = bands[i] - from[i]
            mid[i] = from[i] + change * (change > 0 and up or down)
        end
        return mid
    end

    -- step is one tick of playback.
    local function step(bands)
        bands = delayed(bands)
        s.loud = s.loud + (levels(bands) - s.loud) * K_LOUD
        s.clock = s.clock + TICK
        if not s.playing then
            -- The bands rise out of the break. That is no drum.
            s.hasPrev, s.deaf, s.playing = false, DEAF, true
        end
        s.deaf = max(0, s.deaf - TICK)
        hits(bands)
        s.rock = s.rock + (s.rockTo - s.rock) * K_ROCK
        s.paced = s.paced + 1
        if s.paced >= PACE_EVERY then
            s.paced = 0
            tempo()
        end
        local sum = 0
        for i = 1, BANDS do
            sum = sum + bands[i]
        end
        dive(sum / BANDS)

        s.speed = s.speed + (target_speed() - s.speed) * K_SPEED
        fly()
    end

    -- The last tick of a frame gets its bands, the ticks before it the bands
    -- on the way there.
    function play(bands, steps)
        local last = s.lastBands
        if not s.playing then
            -- Nothing to ease from after a break.
            for i = 1, BANDS do
                last[i] = bands[i]
            end
        end
        for i = 1, steps - 1 do
            step(between(bands, i / steps, steps * TICK))
        end
        step(bands)
        for i = 1, BANDS do
            last[i] = bands[i]
        end
    end

    -- rest is one tick of a pause: the eye eases to a stop.
    function rest()
        s.playing = false
        s.speed = s.speed - s.speed * K_FALL
        if s.speed < 0.01 then
            s.speed = 0
        end
        fly()
    end
end

-- Drawing ----------------------------------------------------------------

local draw, resize
local coarse = 1 -- 1 draws all of the city, a higher number less of it

do
    local NEAR = 0.12 -- nothing shows nearer to the eye than this

    -- The lens: the focal length as a share of half the panel. A flat panel
    -- gets a wider one, or it shows a strip of the towers only.
    local LENS, TELE, WIDE = 1.19, 2.75, 0.6

    -- How far the eye sees, in blocks, by coarse.
    local SIGHT = { 6, 5, 4, 3 }
    local FLOOR_SIGHT = { 3.6, 3, 2.4, 1.8 }
    local CODE_SIGHT = { 3.2, 2.6, 2, 1.5 }
    local SCAN_SIGHT = 3.5
    local BACK_SIGHT = 2 -- the edges behind the glass show up to here

    local EMPTY = 0.1 -- share of the lots without a tower
    local BREATH = 0.25 -- a tower grows this much with its band

    -- The glass: how much one face adds, and how much less at its top.
    local FACE = 0.85
    local FADE = 0.5
    local PAD = 0.8 -- half the width of the glow under a tower

    -- Code: line height, the space at the sides, the indent step, the share of
    -- blank lines, the share of a face the code starts with, and the least
    -- distance between two lines in dots.
    local LINE = 0.14
    local EDGE = 0.1
    local INDENT = 0.1
    local BLANK = 0.25
    local REVEAL = 0.4
    local LINE_GAP = 4
    local FLASH = 0.12 -- s a hi-hat lights its lines

    local STEP = BLOCK / 4 -- between two lines of the ground
    local SCAN_TIME = 0.45
    local SCAN_TOP = 1.7 * TALL -- the frame of light rises this high
    local PULSE_LIFE = 0.9
    local PULSE_SPEED = 16
    local PULSE_TAIL = 2.2
    local PULSE_WIDTH = 0.05 -- between two of its lines
    local PULSE_SHINE = 0.35 -- half the width of its shine

    -- The dots of a cell as Braille bits, row by row.
    local DOT = { 1, 8, 2, 16, 4, 32, 64, 128 }

    local GLYPH = {}
    -- HAS[mask * 8 + k] tells whether a cell with these dots has dot k.
    local HAS = {}
    for mask = 0, 255 do
        GLYPH[mask] = string.char(0xE2, 0xA0 + floor(mask / 64), 0x80 + mask % 64)
        for k, bit in ipairs(DOT) do
            HAS[mask * 8 + k] = mask % (2 * bit) >= bit
        end
    end

    -- Dotted glass: the dots of a cell by shade, thin to dense. The two thin
    -- ones alternate from cell to cell, so the dots do not line up.
    local STIPPLE = { 0x02, 0x20, 0x21, 0x0C, 0x15, 0x15, 0x95, 0x95 }

    -- The corners of a tower, around it.
    local CX = { -HALF, HALF, HALF, -HALF }
    local CZ = { -HALF, -HALF, HALF, HALF }

    -- One entry per character cell: its dots and its tier. haze holds the
    -- glass of each row as changes from cell to cell, one more than cells.
    local bits, tiers, haze = {}, {}, {}
    -- Where dot column x and dot row y fall: the cell, and the dot in it.
    local COL, SIDE, ROW, LINE_OF = {}, {}, {}, {}
    local out, joined = {}, {}
    local PIECE = 1000

    -- The frame that draw works on.
    local w, h, cols, rows
    local halfW, halfH, focal
    local ex, ey, ez -- the eye
    local m11, m12, m13, m21, m22, m23, m31, m32, m33 -- world to view
    local aheadX, aheadZ, spread, sight
    local clock, warp, glow
    local scan -- the height of the frame of light, or nil

    -- The corners of a tower in view space, at the ground and at the roof,
    -- and the corners of a face to fill.
    local gx, gy, gz, rx, ry, rz = {}, {}, {}, {}, {}, {}
    local qx, qy, qz, px, py = {}, {}, {}, {}, {}

    function resize(lines, columns)
        cols, rows, w, h = columns, lines, columns * 2, lines * 4
        for x = 0, w - 1 do
            COL[x], SIDE[x] = floor(x / 2), x % 2
        end
        for y = 0, h - 1 do
            ROW[y], LINE_OF[y] = floor(y / 4) * cols + 1, y % 4 * 2 + 1
        end
    end

    -- seg draws the line between two points in view space: x to the right, y
    -- up, z away from the eye. It cuts the line at the eye and at the edges of
    -- the panel first, so a long line costs no more than the part that shows.
    local function seg(ax, ay, az, bx, by, bz, tier)
        if az < NEAR then
            if bz < NEAR then
                return
            end
            local t = (NEAR - az) / (bz - az)
            ax, ay, az = ax + (bx - ax) * t, ay + (by - ay) * t, NEAR
        elseif bz < NEAR then
            local t = (NEAR - bz) / (az - bz)
            bx, by, bz = bx + (ax - bx) * t, by + (ay - by) * t, NEAR
        end
        local x0, y0 = halfW + focal * ax / az, halfH - focal * ay / az
        local dx, dy = halfW + focal * bx / bz - x0, halfH - focal * by / bz - y0
        local t0, t1 = 0, 1
        if dx > 0 then
            t0, t1 = max(t0, -x0 / dx), min(t1, (w - 0.001 - x0) / dx)
        elseif dx < 0 then
            t0, t1 = max(t0, (w - 0.001 - x0) / dx), min(t1, -x0 / dx)
        elseif not (x0 >= 0 and x0 < w) then
            return
        end
        if dy > 0 then
            t0, t1 = max(t0, -y0 / dy), min(t1, (h - 0.001 - y0) / dy)
        elseif dy < 0 then
            t0, t1 = max(t0, (h - 0.001 - y0) / dy), min(t1, -y0 / dy)
        elseif not (y0 >= 0 and y0 < h) then
            return
        end
        if not (t0 <= t1) then
            return
        end
        x0, y0 = x0 + dx * t0, y0 + dy * t0
        dx, dy = dx * (t1 - t0), dy * (t1 - t0)
        local steps = floor(max(abs(dx), abs(dy))) + 1
        dx, dy = dx / steps, dy / steps
        for i = 0, steps do
            -- The dot that holds the point. A rounding error can leave the point
            -- just off the panel.
            local x, y = x0 + dx * i, y0 + dy * i
            if x >= 0 and x < w and y >= 0 and y < h then
                local xi, yi = floor(x), floor(y)
                local c, k = ROW[yi] + COL[xi], LINE_OF[yi] + SIDE[xi]
                local mask = bits[c]
                if not HAS[mask * 8 + k] then
                    bits[c] = mask + DOT[k]
                end
                if tier > tiers[c] then
                    tiers[c] = tier
                end
            end
        end
    end

    -- line draws from one point to another. Both are given from the eye, along
    -- the axes of the city.
    local function line(x0, y0, z0, x1, y1, z1, tier)
        seg(m11 * x0 + m12 * y0 + m13 * z0, m21 * x0 + m22 * y0 + m23 * z0, m31 * x0 + m32 * y0 + m33 * z0,
            m11 * x1 + m12 * y1 + m13 * z1, m21 * x1 + m22 * y1 + m23 * z1, m31 * x1 + m32 * y1 + m33 * z1,
            tier)
    end

    -- fill adds glass to the cells of the face with the four corners in qx, qy
    -- and qz. It cuts the face at the eye, then notes for each row of cells
    -- where the glass starts and where it ends. The face is denser at its foot.
    local function fill(amount)
        local n = 0
        local ux, uy, uz = qx[4], qy[4], qz[4]
        for k = 1, 4 do
            local x, y, z = qx[k], qy[k], qz[k]
            if (z >= NEAR) ~= (uz >= NEAR) then
                local t = (NEAR - uz) / (z - uz)
                n = n + 1
                px[n] = (halfW + focal * (ux + (x - ux) * t) / NEAR) / 2
                py[n] = (halfH - focal * (uy + (y - uy) * t) / NEAR) / 4
            end
            if z >= NEAR then
                n = n + 1
                px[n], py[n] = (halfW + focal * x / z) / 2, (halfH - focal * y / z) / 4
            end
            ux, uy, uz = x, y, z
        end
        if n < 3 then
            return
        end
        local top, foot = huge, -huge
        for k = 1, n do
            top, foot = min(top, py[k]), max(foot, py[k])
        end
        local height = max(foot - top, 1e-6)
        for row = max(0, floor(top + 0.5)), min(rows - 1, floor(foot - 0.5)) do
            local y = row + 0.5
            local left, right = huge, -huge
            local fromX, fromY = px[n], py[n]
            for k = 1, n do
                local toX, toY = px[k], py[k]
                if (fromY <= y) ~= (toY <= y) then
                    local x = fromX + (toX - fromX) * (y - fromY) / (toY - fromY)
                    left, right = min(left, x), max(right, x)
                end
                fromX, fromY = toX, toY
            end
            local first, last = max(0, floor(left + 0.5)), min(cols - 1, floor(right - 0.5))
            if first <= last then
                local share = amount * (1 - FADE * (foot - y) / height)
                local at = row * (cols + 1) + first + 1
                haze[at] = haze[at] + share
                at = at + last - first + 1
                haze[at] = haze[at] - share
            end
        end
    end

    -- code writes lines on the face from one corner to the other. The corners
    -- are given from the eye. A line is a run of dots, as long as its hash
    -- says; the face shows its lines from the top down and starts over then.
    local function code(x0, z0, x1, z1, tall, id, tier, dist)
        local every = max(1, ceil(LINE_GAP * dist / (focal * LINE)))
        local turns = clock / (2 + 3 * hash(id, 4)) + hash(id, 5)
        local cycle = floor(turns)
        local shown = floor(tall / LINE * (REVEAL + (1 - REVEAL) * (turns - cycle))) - 1
        local flash = clock - s.strikeAt < FLASH and 0.15 + 0.5 * s.strike or 0
        local slot = 10 + s.struck % 7
        for k = 0, shown - 1, every do
            local key = id + k * 7.31 + cycle * 3.17
            if hash(key, 6) > BLANK then
                local from = EDGE + INDENT * floor(hash(key, 7) * 4)
                local to = from + (1 - EDGE - from) * (0.2 + 0.6 * hash(key, 8))
                local y = tall - (k + 1) * LINE - ey
                line(x0 + (x1 - x0) * from, y, z0 + (z1 - z0) * from,
                    x0 + (x1 - x0) * to, y, z0 + (z1 - z0) * to,
                    hash(key, slot) < flash and LIT or tier)
            end
        end
    end

    -- roof draws the pattern on top of the tower at x and z: five rows of
    -- cells, each on or off.
    local function roof(x, z, y, id, tier)
        local size = 1.6 * HALF
        for r = 0, 4 do
            local row = z + ((r + 0.5) / 5 - 0.5) * size
            local start
            for c = 0, 5 do
                local on = c < 5 and hash(id + r * 5 + c, 9) < 0.5
                if on and not start then
                    start = c
                elseif start and not on then
                    line(x + (start / 5 - 0.5) * size, y, row, x + (c / 5 - 0.5) * size, y, row, tier)
                    start = nil
                end
            end
        end
    end

    -- skin gives the tower at x and z its faces: edges, glass, code and the
    -- frame of light. The corners are in gx to rz already. fog is 1 at the eye
    -- and 0 where the sight ends.
    local function skin(x, z, tall, id, dist, fog, level, tier)
        local amount = FACE * fog * (0.45 + 0.55 * level)
        local near = dist < CODE_SIGHT[coarse] * BLOCK
        local dim = max(T1, T1 + min(3, floor(fog * 4)) - 1)
        local lit = scan and scan < tall and dist < SCAN_SIGHT * BLOCK and scan / tall
        local above = ey > tall
        local a = 4
        for b = 1, 4 do
            -- Only the faces that look at the eye. The eye sees through them.
            local faces
            if b == 1 then
                faces = x > HALF
            elseif b == 2 then
                faces = z > HALF
            elseif b == 3 then
                faces = x < -HALF
            else
                faces = z < -HALF
            end
            if faces then
                seg(gx[a], gy[a], gz[a], rx[a], ry[a], rz[a], tier)
                seg(gx[b], gy[b], gz[b], rx[b], ry[b], rz[b], tier)
                seg(gx[a], gy[a], gz[a], gx[b], gy[b], gz[b], tier)
                if glowing then
                    qx[1], qy[1], qz[1] = gx[a], gy[a], gz[a]
                    qx[2], qy[2], qz[2] = gx[b], gy[b], gz[b]
                    qx[3], qy[3], qz[3] = rx[b], ry[b], rz[b]
                    qx[4], qy[4], qz[4] = rx[a], ry[a], rz[a]
                    fill(amount * (b % 2 == 1 and 1 or 0.6))
                end
                if near then
                    code(x + CX[a], z + CZ[a], x + CX[b], z + CZ[b], tall, id + b, dim, dist)
                end
            end
            if faces or above then
                seg(rx[a], ry[a], rz[a], rx[b], ry[b], rz[b], tier)
            end
            if lit and faces then
                seg(gx[a] + (rx[a] - gx[a]) * lit, gy[a] + (ry[a] - gy[a]) * lit, gz[a] + (rz[a] - gz[a]) * lit,
                    gx[b] + (rx[b] - gx[b]) * lit, gy[b] + (ry[b] - gy[b]) * lit, gz[b] + (rz[b] - gz[b]) * lit,
                    BEAT)
            end
            a = b
        end
        if above then
            if glowing then
                for c = 1, 4 do
                    qx[c], qy[c], qz[c] = rx[c], ry[c], rz[c]
                end
                fill(amount)
            end
            if near then
                roof(x, z, tall - ey, id, tier)
            end
        end
        if glowing and near then
            -- The light that a tower throws on the ground.
            for c = 1, 4 do
                local dx, dz = x + CX[c] * PAD / HALF, z + CZ[c] * PAD / HALF
                qx[c] = m11 * dx - m12 * ey + m13 * dz
                qy[c] = m21 * dx - m22 * ey + m23 * dz
                qz[c] = m31 * dx - m32 * ey + m33 * dz
            end
            fill(0.4 * amount)
        end
    end

    -- tower draws the tower of lot (i, j), unless the lot is empty or out of
    -- sight. A tower is as loud as its band.
    local function tower(i, j)
        local x, z = i * BLOCK - ex, j * BLOCK - ez
        local depth = x * aheadX + z * aheadZ
        if depth < -1 or abs(x * aheadZ - z * aheadX) > (depth + 1.5) * spread + 1 then
            return
        end
        local dist = sqrt(x * x + z * z)
        local id = i * 127.1 + j * 311.7
        if dist >= sight or hash(id, 12) < EMPTY then
            return
        end
        local level = glow[1 + floor(hash(id, 13) * BANDS)]
        local tall = TALL * (0.7 + 0.9 * hash(id, 14)) * (1 + BREATH * level)
        local fog = 1 - dist / sight
        local tier = T1 + min(3, floor(fog * 4))
        if fog > 0.5 then
            if warp > 0.5 then
                tier = BEAT
            elseif level > 0.8 then
                tier = LIT
            end
        end
        local low, high = -ey, tall - ey
        for c = 1, 4 do
            local dx, dz = x + CX[c], z + CZ[c]
            local vx, vy, vz = m11 * dx + m13 * dz, m21 * dx + m23 * dz, m31 * dx + m33 * dz
            gx[c], gy[c], gz[c] = vx + m12 * low, vy + m22 * low, vz + m32 * low
            rx[c], ry[c], rz[c] = vx + m12 * high, vy + m22 * high, vz + m32 * high
        end
        if dist < BACK_SIGHT * BLOCK then
            -- The edges behind the glass, before the ones in front of it.
            local a = 4
            for b = 1, 4 do
                seg(gx[b], gy[b], gz[b], rx[b], ry[b], rz[b], T1)
                seg(rx[a], ry[a], rz[a], rx[b], ry[b], rz[b], T1)
                seg(gx[a], gy[a], gz[a], gx[b], gy[b], gz[b], T1)
                a = b
            end
        end
        skin(x, z, tall, id, dist, fog, level, tier)
    end

    -- ground draws the grid of the ground. Every other line ends sooner, or
    -- the lines would run into each other far away.
    local function ground()
        local reach = min(sight, FLOOR_SIGHT[coarse] * BLOCK)
        local y = -ey
        for k = ceil((ex - reach) / STEP), floor((ex + reach) / STEP) do
            local x = k * STEP - ex
            local far = k % 2 == 0 and reach or 0.5 * reach
            if abs(x) < far then
                line(x, y, -far, x, y, far, GRID)
            end
        end
        for k = ceil((ez - reach) / STEP), floor((ez + reach) / STEP) do
            local z = k * STEP - ez
            local far = k % 2 == 0 and reach or 0.5 * reach
            if abs(z) < far then
                line(-far, y, z, far, y, z, GRID)
            end
        end
    end

    -- lights draws the pulses that the kicks sent along the ground: three
    -- lines side by side with a hot head, and their shine on the ground.
    local function lights()
        local y = 0.02 - ey
        for _, one in ipairs(s.pulses) do
            local age = clock - one.at
            if one.strength ~= 0 and age >= 0 and age <= PULSE_LIFE then
                local head = PULSE_SPEED * age
                local tail = max(0, head - PULSE_TAIL * (0.5 + one.strength))
                local mid = head - (head - tail) * 0.35
                local dx, dz = one.dx, one.dz
                for lane = -1, 1 do
                    local x, z = one.x - ex + dz * lane * PULSE_WIDTH, one.z - ez - dx * lane * PULSE_WIDTH
                    line(x + dx * tail, y, z + dz * tail, x + dx * mid, y, z + dz * mid, T4)
                    line(x + dx * mid, y, z + dz * mid, x + dx * head, y, z + dz * head, HOT)
                end
                if glowing then
                    for c = 1, 4 do
                        local along = c < 3 and tail or head
                        local aside = (c == 1 or c == 4) and -PULSE_SHINE or PULSE_SHINE
                        local x, z = one.x - ex + dx * along + dz * aside, one.z - ez + dz * along - dx * aside
                        qx[c] = m11 * x + m12 * y + m13 * z
                        qy[c] = m21 * x + m22 * y + m23 * z
                        qz[c] = m31 * x + m32 * y + m33 * z
                    end
                    fill((0.4 + 0.6 * one.strength) * (1 - age / PULSE_LIFE))
                end
            end
        end
    end

    -- aim sets up the projection of the frame.
    local function aim()
        local yaw, pitch, roll
        ex, ey, ez, yaw, pitch, roll = camera()
        local cy, sy, cp, sp, cr, sr = cos(yaw), sin(yaw), cos(pitch), sin(pitch), cos(roll), sin(roll)
        m11, m12, m13 = cr * cy + sr * sp * sy, sr * cp, sr * sp * cy - cr * sy
        m21, m22, m23 = cr * sp * sy - sr * cy, cr * cp, sr * sy + cr * sp * cy
        m31, m32, m33 = cp * sy, -sp, cp * cy
        aheadX, aheadZ = sy, cy
        halfW, halfH = w / 2, h / 2
        focal = max(WIDE * halfW, min(LENS * halfW, TELE * halfH))
        spread = 1.3 * halfW / focal + 0.3
        -- A low panel has no room for the towers far away.
        sight = min(SIGHT[coarse], 2 + rows / 7) * BLOCK
        clock, warp, glow = s.clock, s.warp, s.glow
        local age = (clock - s.scanAt) / SCAN_TIME
        scan = nil
        if age >= 0 and age <= 1 then
            scan = SCAN_TOP * (s.scanUp and age or 1 - age)
        end
    end

    -- text packs the cells into lines of colored Braille. A cell without dots
    -- keeps the color that runs: it paints nothing but its glass. Dotted glass
    -- gives such a cell a few dots of its own, more where it is denser. The Lua
    -- stack limits how many strings one concat can take, so the frame is
    -- joined in pieces.
    local function text()
        local ramp = warp > 0.5 and WARM or GLOW
        local n, c, d, pieces = 0, 0, 0, 0
        for row = 1, rows do
            local tier, lit, sum = 0, 0, 0
            for col = 1, cols do
                c, d = c + 1, d + 1
                sum = sum + haze[d]
                local level = floor(min(1, sum * GAIN) * GLOWS + 0.5)
                local t, mask = tiers[c], bits[c]
                if dotted then
                    if level > 0 and mask == 0 then
                        t, mask = T1, STIPPLE[2 * level - (col + row) % 2]
                    end
                elseif level ~= lit then
                    n = n + 1
                    out[n] = level > 0 and ramp[level] or "\27[49m"
                    lit = level
                end
                if t ~= 0 and t ~= tier then
                    n = n + 1
                    out[n] = COLOR[t]
                    tier = t
                end
                n = n + 1
                out[n] = GLYPH[mask]
                if n >= PIECE then
                    pieces = pieces + 1
                    joined[pieces] = table.concat(out, "", 1, n)
                    n = 0
                end
            end
            d = d + 1
            if tier ~= 0 or lit ~= 0 then
                n = n + 1
                out[n] = RESET
            end
            if row < rows then
                n = n + 1
                out[n] = "\n"
            end
        end
        pieces = pieces + 1
        joined[pieces] = table.concat(out, "", 1, n)
        return table.concat(joined, "", 1, pieces)
    end

    function draw()
        for i = 1, rows * cols do
            bits[i], tiers[i] = 0, 0
        end
        for i = 1, rows * (cols + 1) do
            haze[i] = 0
        end
        aim()
        ground()
        lights()
        for i = floor((ex - sight) / BLOCK), ceil((ex + sight) / BLOCK) do
            for j = floor((ez - sight) / BLOCK), ceil((ez + sight) / BLOCK) do
                tower(i, j)
            end
        end
        return text()
    end
end

-- Plugin -----------------------------------------------------------------

local FRAME = 0.05 -- what a draw is worth when the clock is no help
local MAX_GAP = 0.25 -- a longer wait between draws is a break, not a slow frame
local MAX_STEPS = 4
local DRAW_GAP = 0.04 -- s between two draws while the music plays

-- cliamp gives a draw 50 ms and keeps the old frame when it takes longer.
-- Two draws in a row slower than SLOW seconds show less of the city from then
-- on, a swift one more again.
local SLOW, SWIFT = 0.03, 0.012
local MAX_COARSE = 4

local lastAt, lastFrame, owed = nil, nil, 0
local shown, shownRows, shownCols
local dirty, drawing, drawnAt, slow = true, false, 0, 0

function p:init()
    reset()
    lastAt, lastFrame, owed, dirty = nil, nil, 0, true
end

function p:render(bands, frame, rows, columns)
    rows, columns = floor(rows), floor(columns)
    if rows < 1 or columns < 1 then
        return ""
    end

    local now = os.clock()
    local status = cliamp.player.state()
    local flying = s.speed ~= 0
    if status == "stopped" then
        dirty = dirty or flying
        s.speed, s.playing, lastAt = 0, false, nil
    elseif status == "paused" or frame ~= lastFrame then
        -- cliamp also draws between its ticks, on a key press for one. The
        -- bands are new only when the frame is; a pause holds the frame.
        local dt = lastAt and now - lastAt or FRAME
        if dt <= 0 or dt > MAX_GAP then
            dt = FRAME
            if status == "paused" then
                s.speed = 0 -- the ticks of a pause thin out before the eye is at rest
            end
            s.playing = false
        end
        lastAt, lastFrame = now, frame
        owed = owed + dt
        local steps = min(MAX_STEPS, floor((owed + 1e-6) / TICK))
        owed = owed - steps * TICK
        if owed > TICK then
            owed = 0
        end
        if status == "paused" then
            for _ = 1, steps do
                rest()
            end
        elseif steps > 0 then
            play(bands, steps)
        end
        dirty = dirty or steps > 0 and (flying or status ~= "paused")
    end

    if rows ~= shownRows or columns ~= shownCols then
        resize(rows, columns)
        shown, shownRows, shownCols = nil, rows, columns
    end
    -- cliamp shows 20 frames a second, so a frame drawn sooner is wasted.
    if not shown or dirty and (now - drawnAt > DRAW_GAP or status ~= "playing") then
        if drawing then
            coarse = min(MAX_COARSE, coarse + 1) -- cliamp cut the last draw short
        end
        drawing = true
        shown = draw()
        drawing = false
        local took = os.clock() - now
        slow = took > SLOW and slow + 1 or 0
        if slow > 1 and coarse < MAX_COARSE then
            coarse, slow = coarse + 1, 0
        elseif took < SWIFT and coarse > 1 then
            coarse = coarse - 1
        end
        dirty, drawnAt = false, now
    end
    return shown
end
