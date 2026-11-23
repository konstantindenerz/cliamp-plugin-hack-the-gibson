-- Hack the Gibson: a flight through a city of glass towers, like the Gibson
-- in Hackers (1995). Everything is drawn with Braille dots. The glass is a
-- background tint, or a dot pattern when the colors can't be shaded.
-- Kick, snare and hi-hat each trigger their own effect.

local p = plugin.register({
	name = "Hack the Gibson",
	type = "visualizer",
	version = "0.1.1",
	description = "Flight through a city of glass towers",
	permissions = { "keymap" }, -- for the theme key
})

local abs, floor, ceil, max, min = math.abs, math.floor, math.ceil, math.max, math.min
local sin, cos, exp, sqrt, atan2 = math.sin, math.cos, math.exp, math.sqrt, math.atan2
local pi, huge = math.pi, math.huge

local BANDS = 10

-- Simulation step in seconds. Independent of how often cliamp calls render.
local TICK = 0.025

local SILENCE_STOP = 0.5 -- s of silence before the camera stops
local FLUX_LEN = 240 -- ticks of onset history the tempo is read from (6 s)

-- City layout: one tower per block, streets in between.
local BLOCK = 2.9
local HALF = 0.5 -- half the width of a tower
local TALL = 2.5
local TURN = BLOCK / 2 -- turn radius at a crossing

-- Directions 0..3: north, east, south, west.
local DX = { [0] = 0, 1, 0, -1 }
local DZ = { [0] = 1, 0, -1, 0 }

local PULSES = 6 -- ground pulses alive at once

-- Color tiers. A cell gets the color of the highest tier drawn into it.
-- FAR..NEAR are the four distance shades of the tower color.
local GRID, FAR, NEAR, LIT, BEAT, DROP, HOT = 1, 2, 5, 6, 7, 8, 9

-- cliamp only strips a trailing "# comment" from quoted values, so config
-- values are parsed by their leading part and the rest is ignored.
local function conf_num(key, default, lo, hi)
	local n = tonumber((p:config(key) or ""):match("^%s*([%d.]+)") or "")
	return max(lo, min(hi, n or default))
end

-- Themes and colors ------------------------------------------------------

local RESET = "\27[0m"

local COLOR = {} -- escape sequence per tier

-- The glass is a background color per cell: GLASS[level] from thin to dense,
-- GLASS_DROP the same in the drop color. With glass_dots it's a dot pattern
-- instead.
local GLASS, GLASS_DROP = {}, {}
local glass_on, glass_dots = false, false
local GLASS_LEVELS, GLASS_GAIN = 16, 1

local THEMES, THEME_ORDER, find_theme, apply_theme

do
	-- Shades from far to near, as the share of the way from the background
	-- to the color, and the same for the densest glass.
	local SHADES = { 0.22, 0.42, 0.68, 1 }
	local GLASS_MAX = 0.5

	-- back is the terminal background the theme is made for. glass defaults
	-- to tower and drop to beat. Colors are hex, or palette indexes for
	-- "terminal". hackers is sampled from stills of the film; kode is the
	-- palette of the CSS demo.
	THEMES = {
		hackers = {
			title = "Hackers",
			tower = "81e3e8",
			glass = "50c3bc",
			floor = "6a66b7",
			beat = "a054e2",
			drop = "b75049",
			hot = "e6fdff",
			back = "00020f",
		},
		mechanoonna = {
			title = "Mechanoonna",
			tower = "e7c07c",
			floor = "c5564a",
			beat = "d94e38",
			hot = "fff8e8",
			back = "1c1b19",
		},
		tokyonight = {
			title = "Tokyo Night",
			tower = "7dcfff",
			floor = "bb9af7",
			beat = "f7768e",
			hot = "e0af68",
			back = "1a1b26",
		},
		catppuccin = {
			title = "Catppuccin",
			tower = "cba6f7",
			floor = "89b4fa",
			beat = "f38ba8",
			hot = "f9e2af",
			back = "1e1e2e",
		},
		gruvbox = {
			title = "Gruvbox",
			tower = "8ec07c",
			floor = "83a598",
			beat = "fe8019",
			hot = "fabd2f",
			back = "282828",
		},
		kode = {
			title = "Kode",
			tower = "58c6a2",
			floor = "9375ee",
			beat = "ee75d2",
			hot = "deee75",
			back = "000000",
		},
		terminal = { title = "Terminal", tower = 6, floor = 4, beat = 9, hot = 11, back = "000000" },
	}
	-- The order the theme key cycles through.
	THEME_ORDER = { "hackers", "mechanoonna", "tokyonight", "catppuccin", "gruvbox", "kode", "terminal" }

	-- "Tokyo Night", "tokyo-night" and "tokyonight" all match, and so does a
	-- name with a suffix like "catppuccin-mocha". Without a match it returns
	-- nil and the normalized name.
	function find_theme(name)
		name = (name or ""):lower():match("^[%w%s_%-]*"):gsub("[^%w]", "")
		if THEMES[name] then
			return name
		end
		for _, known in ipairs(THEME_ORDER) do
			if #known < #name and name:sub(1, #known) == known then
				return known
			end
		end
		return nil, name
	end

	local function hex_rgb(hex)
		return { tonumber(hex:sub(1, 2), 16), tonumber(hex:sub(3, 4), 16), tonumber(hex:sub(5, 6), 16) }
	end

	-- SGR parameter for palette color n.
	local function palette(n, bg)
		if n < 8 then
			return (bg and 40 or 30) + n
		elseif n < 16 then
			return (bg and 92 or 82) + n
		end
		return (bg and "48;5;" or "38;5;") .. n
	end

	function apply_theme(name)
		local def = THEMES[name]

		-- A color key of the config, "#rrggbb" or a palette index, falling
		-- back to the theme. Returns {r, g, b} or {index = n}, or nil for an
		-- optional color that isn't set anywhere.
		local function read_color(key)
			-- Six hex digits are a color, with or without #. A number on its
			-- own is a palette index. The space ends a value that has nothing
			-- after it.
			local value = (p:config(key) or "") .. " "
			local hex = value:match("^%s*#?(%x%x%x%x%x%x)%X")
			local index = not hex and tonumber(value:match("^%s*(%d+)%X") or "")
			if not hex and not index then
				if type(def[key]) == "number" then
					index = def[key]
				else
					hex = def[key]
				end
			end
			if index then
				return { index = min(index, 255) }
			end
			return hex and hex_rgb(hex)
		end

		-- Shades are mixed from the background so that far towers fade into
		-- it. That needs RGB, so a palette index for back is ignored.
		local back = read_color("back")
		if back.index then
			back = hex_rgb(def.back)
		end

		-- Truecolor SGR parameter: c at shade, then lightened towards white.
		local function rgb(c, shade, white, bg)
			local ch = {}
			for i = 1, 3 do
				local v = back[i] + (c[i] - back[i]) * shade
				ch[i] = floor(v + (255 - v) * white + 0.5)
			end
			return string.format("%d;2;%d;%d;%d", bg and 48 or 38, ch[1], ch[2], ch[3])
		end

		-- Foreground sequence for step 1-4 (far to near) or 5 (highlight).
		-- A palette color has no shades, so it goes faint, normal, bright.
		-- Every sequence starts with 22 because the one before may have set
		-- bold or faint.
		local function fg(c, step)
			local n = c.index
			if not n then
				return "\27[22;" .. rgb(c, SHADES[min(step, 4)], step == 5 and 0.55 or 0) .. "m"
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
			return "\27[" .. weight .. palette(n) .. "m"
		end

		local tower, ground, beat = read_color("tower"), read_color("floor"), read_color("beat")
		local drop = read_color("drop") or beat
		COLOR[GRID] = ground.index and fg(ground, 1) or "\27[22;" .. rgb(ground, 0.6, 0) .. "m"
		for step = 1, 4 do
			COLOR[FAR + step - 1] = fg(tower, step)
		end
		COLOR[LIT] = fg(tower, 5)
		COLOR[BEAT] = fg(beat, 4)
		COLOR[DROP] = fg(drop, 4)
		COLOR[HOT] = fg(read_color("hot"), 4)

		-- glass = "off", "dots" or a color; the default is the tower color.
		-- Only an RGB color can be shaded: a palette color gives one flat
		-- background, and towers in a palette color get dots.
		GLASS, GLASS_DROP = {}, {}
		glass_on, glass_dots = false, false
		GLASS_LEVELS, GLASS_GAIN = 16, 1
		local mode = p:config("glass") or ""
		if mode:match("^%s*off") then
			return
		end
		glass_on = true
		local glass = read_color("glass")
		if mode:match("^%s*dots") or not glass and tower.index then
			glass_dots = true
			GLASS_LEVELS, GLASS_GAIN = 4, 1.3
			return
		end
		glass = glass or tower
		if glass.index then
			GLASS_LEVELS, GLASS_GAIN = 1, 2
			GLASS[1] = "\27[" .. palette(glass.index, true) .. "m"
			GLASS_DROP = GLASS
			return
		end
		for level = 1, GLASS_LEVELS do
			local shade = GLASS_MAX * level / GLASS_LEVELS
			GLASS[level] = "\27[" .. rgb(glass, shade, 0, true) .. "m"
			GLASS_DROP[level] = drop.index and GLASS[level] or "\27[" .. rgb(drop, shade, 0, true) .. "m"
		end
	end
end

-- The theme key saves its pick in the store, together with the theme the
-- config named at that time. On the next start the pick wins as long as the
-- config still names the same theme, so whichever changed last counts.
local theme, theme_changed = "hackers", false

-- Time of the last render. Other visualizers bind the same key, so it only
-- counts while the Gibson is on screen. destroy runs when cliamp switches
-- to another visualizer and clears it.
local shown_at = -huge

do
	local cfg_theme = p:config("theme") or ""
	local saved = cliamp.store.get("theme")
	if type(saved) == "string" and THEMES[saved] and cliamp.store.get("config") == cfg_theme then
		theme = saved
	else
		if saved ~= nil then
			-- The config changed since. Drop the pick, or it comes back when
			-- the config is set back to the old theme.
			cliamp.store.clear()
		end
		local found, unknown = find_theme(cfg_theme)
		if found then
			theme = found
		elseif unknown ~= "" then
			cliamp.log.warn("unknown theme " .. unknown .. ", using " .. theme)
		end
	end
	apply_theme(theme)

	local function set_theme(name)
		theme, theme_changed = name, true
		apply_theme(name)
		cliamp.store.set("theme", name)
		cliamp.store.set("config", cfg_theme)
		cliamp.message("Hack the Gibson: " .. THEMES[name].title)
	end

	-- theme_key = "off" leaves the key unbound.
	local key = (p:config("theme_key") or "ctrl+t"):lower():match("^%s*([%w+_%-]*)")
	if key ~= "" and key ~= "off" then
		local ok, err = p:bind(key, "Next theme", function()
			-- A paused or stopped player renders every 1.5 s.
			if os.clock() - shown_at > 3 then
				return
			end
			for i, name in ipairs(THEME_ORDER) do
				if name == theme then
					return set_theme(THEME_ORDER[i % #THEME_ORDER + 1])
				end
			end
		end)
		if not ok then
			cliamp.log.warn("can't bind " .. key .. ": " .. tostring(err))
		end
	end

	-- cliamp plugins call "Hack the Gibson" theme [name]. The shell splits
	-- "Tokyo Night" into two arguments.
	p:command("theme", function(args)
		local name = find_theme(table.concat(args, " "))
		if name then
			set_theme(name)
			return THEMES[name].title
		end
		local lines = {}
		for i, known in ipairs(THEME_ORDER) do
			lines[i] = (known == theme and "* " or "  ") .. THEMES[known].title
		end
		return table.concat(lines, "\n")
	end)
end

-- delay_ms holds the bands back, for a cliamp that hands plugins the audio
-- before it is heard. In ticks, one second at most.
local DELAY = floor(conf_num("delay_ms", 0, 0, 1000) / (TICK * 1000) + 0.5)

-- pulse scales how much of the beat shows: 0 is off, 2 is double.
local PULSE = conf_num("pulse", 1, 0, 2)

-- State -----------------------------------------------------------------

local s

local function filled(n, v)
	local t = {}
	for i = 1, n do
		t[i] = v
	end
	return t
end

-- Stable pseudo-random number in [0, 1) for item i. slot selects the stream.
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

-- Direction of a leg, given the one before: mostly straight on, 15% each
-- for left and right.
local function pick_turn(leg, dir)
	local r = hash(leg, 1)
	if r < 0.15 then
		return (dir + 1) % 4
	elseif r < 0.3 then
		return (dir + 3) % 4
	end
	return dir
end

local function reset()
	s = {
		travel = 0, -- blocks flown
		speed = 0, -- blocks/s
		loud = 0, -- overall level, smoothed, 0..1
		clock = 0, -- s of playback; stands still while paused
		playing = false,
		mute = 0, -- s left in which hits are ignored
		has_prev = false,
		last_kick = -huge,

		-- Tempo. flux is a ring of the onset strength per tick, the newest
		-- at flux_head. beat is the period in s (0 = none yet), beat_at the
		-- time of a beat. rival is a period that may take over, rival_count
		-- how many checks in a row it has won.
		flux = filled(FLUX_LEN, 0),
		flux_head = FLUX_LEN,
		since_tempo = 0, -- ticks
		beat = 0,
		beat_at = 0,
		confidence = 0, -- 0..1
		rival = 0,
		rival_count = 0,

		-- Slow averages of the top three bands and of all of them. Music
		-- with hardly any highs, like lo-fi, counts as calm.
		avg_top = 0,
		avg_all = 0,
		calm = false,

		-- Drops: a short energy average against a long one.
		energy_fast = 0,
		energy_slow = 0,
		drop_at = -huge,
		drop = 0, -- envelope, 0..1
		lift = 0, -- 0 in the streets, 1 above the roofs
		heard = 0, -- s of sound since the last silence
		quiet = SILENCE_STOP, -- s of silence

		-- Snares roll the camera, alternating sides.
		roll = 0,
		roll_to = 0,
		roll_side = 1,

		-- Route. The current leg starts at crossing (nx, nz) and runs one
		-- block in direction dir.
		leg = 0,
		nx = 0,
		nz = 0,
		prev_dir = 0,
		dir = 0,
		next_dir = 0,
		turned_at = -huge,
		turned_leg = 0, -- first leg after the last turn

		pulse_count = 0,
		scan_at = -huge,
		scan_up = false,

		-- thump is the pulse of the beat and snap that of the snare: both
		-- jump on a hit and decay right away. predicted_at is the last beat
		-- that came from the tempo instead of a kick.
		thump = 0,
		snap = 0,
		predicted_at = -huge,
		beat_phase = 0,

		hat_count = 0,
		hat_at = -huge,
		hat_strength = 0,

		-- Range of each band. Starts inverted, so the first frame sets it.
		band_min = filled(BANDS, 1),
		band_max = filled(BANDS, 0),
		level = filled(BANDS, 0), -- each band within its range, smoothed
		prev = filled(BANDS, 0),
		typical = { 0, 0, 0 }, -- usual hit strength per drum
		pulses = {},
		delay_ring = {}, -- the bands of the last DELAY ticks
		delay_at = 0,
		delayed = filled(BANDS, 0),
		last_bands = filled(BANDS, 0), -- the bands of the previous frame
		mid_bands = filled(BANDS, 0),

		-- Kick, snare, hi-hat. A hit is a rise over bands from..to that
		-- tops mean + k * deviation of the recent rises, and floor. gap is
		-- the least distance between two hits in ticks: 240 kicks a minute.
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
		s.delay_ring[i] = filled(BANDS, 0)
	end
end

reset()

-- Camera position, then yaw, pitch and roll in radians. A turn is a quarter
-- circle around the corner of a crossing, from the middle of one block to
-- the middle of the next.
local camera

do
	local EYE = 0.9 -- height above the ground
	local BOB = 0.35 -- extra height at full loudness
	local CLIMB = 6 -- extra height in a drop
	local TILT = 0.04 -- looks down a little
	local DIVE = 0.42 -- and more from above the roofs
	local BANK = 0.16

	function camera()
		local t = (s.travel - s.leg) * BLOCK
		local dir = s.dir
		local ax, az = DX[dir], DZ[dir]
		local x, z = (s.nx + 0.5) * BLOCK, (s.nz + 0.5) * BLOCK
		local bx, bz, angle
		if t < TURN and s.prev_dir ~= dir then
			-- Second half of the turn into this leg.
			bx, bz, ax, az = ax, az, DX[s.prev_dir], DZ[s.prev_dir]
			angle = (1 + t / TURN) * pi / 4
		elseif t > BLOCK - TURN and s.next_dir ~= dir then
			-- First half of the turn out of it.
			bx, bz = DX[s.next_dir], DZ[s.next_dir]
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
		return x, EYE + BOB * s.loud + CLIMB * s.lift, z, yaw, TILT + DIVE * s.lift, bank + s.roll
	end
end

-- Music ------------------------------------------------------------------

-- play runs the ticks of one frame of playback, rest one tick of a pause.
local play, rest

do
	local SPEED = conf_num("speed", 1, 0.25, 2) -- factor on the flight speed
	local BEATS_PER_BLOCK = 2
	local CRUISE = 0.5 -- blocks/s without a tempo
	local LOUD_GAIN = 0.4
	local DROP_BOOST = 0.6 -- share of speed a drop adds

	-- Between two turns: at least this many seconds and blocks.
	local TURN_GAP = 2.5
	local TURN_BLOCKS = 2

	-- The tempo is read every TEMPO_EVERY ticks, as a beat of LAG_MIN to
	-- LAG_MAX ticks (60 to 185 BPM). Hi-hats count half in the flux, or the
	-- eighths pass for the beat.
	local TEMPO_EVERY = 20
	local LAG_MIN, LAG_MAX = 13, 40
	local FLUX_WEIGHT = { 1, 1, 0.5 }
	local PRIOR_WIDTH = 1.0 -- octaves
	-- The bands can't tell a beat from half or double of it, so the period
	-- is folded into one octave: FOLD to 2 * FOLD seconds (85 to 170 BPM),
	-- or 55 to 110 BPM for calm music. Music turns calm when the top bands
	-- hold less than MUFFLED of the level, and lively again above BRIGHT.
	local FOLD, FOLD_CALM = 0.5 / 2 ^ 0.5, 0.55
	local MUFFLED, BRIGHT = 0.045, 0.06
	local FOLD_SLACK = 1.08 -- the beat may be this far outside the octave before it's refolded
	local SALIENT = 1.5 -- best score against the mean score, to count as a beat
	local SAME = 0.06 -- periods this close are the same tempo
	local MARGIN = 1.3 -- another tempo has to score this much better
	local RIVAL_WINS = 3 -- this many checks in a row to take over
	local CONF_STEP = 0.25
	local PHASES = 16
	local LOCK = 0.3 -- speed change per beat of phase error
	local LOCK_MAX = 0.15

	-- A drop: the short energy average jumps above the long one.
	local DROP_RATIO = 1.5
	local DROP_FLOOR = 0.12
	local DROP_GAP = 8.0 -- s between drops
	local DROP_WARMUP = 4.0 -- s of music before a drop counts
	local SILENCE = 0.02
	local MUTE = 0.3 -- s without hits after a break, while the bands rise again
	local DROP_RISE = 0.15
	local DROP_FADE = 0.6
	local DROP_LIFE = 2.5
	local HOVER = 2.2 -- s above the roofs

	-- A predicted beat fires LEAD seconds early, because the bands lag the
	-- sound.
	local LEAD = 0.05
	local BEAT_THUMP = 0.7 -- its thump at full confidence

	local HIT_TYPICAL = 0.6 -- strength of a hit as strong as the recent ones
	local ROLL = 0.035 -- camera roll per snare
	local HAT_WAIT = 2 -- no hi-hat within this many ticks of a snare
	local PULSE_FROM = 2.5 * BLOCK -- a pulse across the street starts this far to the side

	local BAND_RELAX = 0.08 -- how fast the range of a band closes in, per second
	local BAND_SPAN = 0.12 -- its least width

	-- Smoothing factor per tick for a rate of r per second.
	local function per_tick(r)
		return 1 - exp(-r * TICK)
	end

	local K_SPEED, K_FALL, K_LOUD = per_tick(2.0), per_tick(2.5), per_tick(1.5)
	local K_LEVEL_UP, K_LEVEL_DOWN = per_tick(12), per_tick(6)
	local K_ROLL, K_LIFT = per_tick(14), per_tick(2.5)
	local K_FAST, K_SLOW = per_tick(4.0), per_tick(0.15)
	local K_THUMP, K_SNAP = per_tick(8), per_tick(11)

	-- Tracks each band against its own recent range. Returns the overall
	-- loudness, 0..1.
	local function track_levels(bands)
		local lo, hi, level = s.band_min, s.band_max, s.level
		local loud = 0
		for i = 1, BANDS do
			local b = bands[i]
			hi[i] = max(b, hi[i] - BAND_RELAX * TICK)
			lo[i] = min(b, lo[i] + BAND_RELAX * TICK)
			local v = (b - lo[i]) / max(hi[i] - lo[i], BAND_SPAN)
			local old = level[i]
			level[i] = old + (v - old) * (v > old and K_LEVEL_UP or K_LEVEL_DOWN)
			loud = loud + v / BANDS
		end
		return loud
	end

	-- Starts a pulse of light on the ground. They alternate between running
	-- down a street next to the camera (or the one it is in) and crossing
	-- the street ahead.
	local function spawn_pulse(strength)
		local n = s.pulse_count
		s.pulse_count = n + 1
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

	-- A beat also repeats at its multiples, so half and double tempo fit
	-- the music just as well. PRIOR prefers the period closest to 0.5 s.
	-- It is indexed in quarter ticks from LAG_MIN, like scores below.
	local PRIOR = {}
	for i = 0, (LAG_MAX - LAG_MIN) * 4 do
		local octaves = math.log((LAG_MIN + i / 4) * TICK / 0.5) / math.log(2)
		PRIOR[i] = exp(-0.5 * (octaves / PRIOR_WIDTH) ^ 2)
	end

	-- Scratch tables of estimate_tempo: the flux oldest first, the same
	-- smoothed and less its mean, its autocorrelation by lag in ticks, the
	-- score per period, and the flux summed per part of a beat.
	local raw, wave, acf, scores, phases = {}, {}, {}, {}, {}
	local ACF_MAX = 4 * LAG_MAX + 3 -- refining the period looks 3 ticks past 4 beats

	-- Autocorrelation at a fractional lag.
	local function acf_at(lag)
		local whole = floor(lag)
		return acf[whole] + (acf[whole + 1] - acf[whole]) * (lag - whole)
	end

	-- Where the top of a peak lies between its three samples, as an offset
	-- of -0.5..0.5 from the middle one.
	local function peak_offset(before, top, after)
		local bend = before - 2 * top + after
		if not (bend < 0) then
			return 0
		end
		return max(-0.5, min(0.5, 0.5 * (before - after) / bend))
	end

	-- Music repeats every two beats more than every single one, and its
	-- eighths repeat too, so a period may be double the beat or half of it.
	-- fold_period moves it into the octave for the current mood.
	local function fold_period(period)
		local least = s.calm and FOLD_CALM or FOLD
		while period >= 2 * least do
			period = period / 2
		end
		while period < least do
			period = period * 2
		end
		return period
	end

	-- Decides between calm and lively from the share of the top bands, and
	-- refolds the beat when that changes.
	local function update_calm(top, all)
		if all < SILENCE then
			return
		end
		if s.avg_all == 0 then
			s.avg_top, s.avg_all = top, all
		end
		s.avg_top = s.avg_top + (top - s.avg_top) * K_SLOW
		s.avg_all = s.avg_all + (all - s.avg_all) * K_SLOW
		local share = s.avg_top / s.avg_all
		local calm = s.calm
		if share < MUFFLED then
			calm = true
		elseif share > BRIGHT then
			calm = false
		end
		if calm ~= s.calm then
			s.calm = calm
			if s.beat > 0 then
				s.beat = fold_period(s.beat)
			end
		end
	end

	-- How well the current beat still fits: the best score near its period,
	-- near half of it and near double.
	local function current_score()
		local best = 0
		for octave = -1, 1 do
			local ticks = s.beat * 2 ^ octave / TICK
			local from = ceil((ticks * (1 - SAME) - LAG_MIN) * 4)
			local to = floor((ticks * (1 + SAME) - LAG_MIN) * 4)
			for i = max(0, from), min((LAG_MAX - LAG_MIN) * 4, to) do
				best = max(best, scores[i])
			end
		end
		return best
	end

	-- Reads the beat from the rises of all bands instead of the kicks alone:
	-- a breakbeat has its kicks off the beat and the snare on it. The beat is
	-- the lag at which the flux repeats, at its multiples too.
	local function estimate_tempo()
		-- cliamp analyzes the audio every other tick, so a rise shows up a
		-- tick early or late. Without smoothing, beats that fall between two
		-- ticks don't correlate.
		local flux, head = s.flux, s.flux_head
		local mean = 0
		for i = 1, FLUX_LEN do
			raw[i] = flux[(head + i - 1) % FLUX_LEN + 1]
			mean = mean + raw[i] / FLUX_LEN
		end
		raw[-1], raw[0], raw[FLUX_LEN + 1], raw[FLUX_LEN + 2] = 0, 0, 0, 0
		local power = 0
		for i = 1, FLUX_LEN do
			local v = (raw[i - 2] + 2 * raw[i - 1] + 3 * raw[i] + 2 * raw[i + 1] + raw[i + 2]) / 9
			v = max(0, v - mean)
			wave[i] = v
			power = power + v * v
		end
		local best, lag, total = 0, 0, 0
		if power > 1e-6 then
			for l = LAG_MIN, ACF_MAX do
				local sum = 0
				for t = l + 1, FLUX_LEN do
					sum = sum + wave[t] * wave[t - l]
				end
				acf[l] = sum / (FLUX_LEN - l)
			end
			for i = 0, (LAG_MAX - LAG_MIN) * 4 do
				local l = LAG_MIN + i / 4
				local score = (acf_at(l) + acf_at(2 * l) + acf_at(3 * l) + acf_at(4 * l)) * PRIOR[i]
				scores[i] = score
				total = total + score
				if score > best then
					best, lag = score, l
				end
			end
		end
		if best <= 0 or best * ((LAG_MAX - LAG_MIN) * 4 + 1) < SALIENT * total then
			-- No beat in there.
			s.confidence = max(0, s.confidence - CONF_STEP / 2)
			return
		end

		-- Refine the period at four beats, where it's four times as precise.
		local at = floor(4 * lag + 0.5)
		local peak = acf[at]
		for l = at - 2, at + 2 do
			if acf[l] > peak then
				peak, at = acf[l], l
			end
		end
		local period = fold_period((at + peak_offset(acf[at - 1], peak, acf[at + 1])) / 4 * TICK)
		-- A period right at the edge of the octave lands on the other side
		-- at the next check, and the flight would double its speed. So stay
		-- with the current beat, unless that one has left the octave for
		-- good.
		local least = s.calm and FOLD_CALM or FOLD
		if s.beat > 0 and (s.beat < least / FOLD_SLACK or s.beat >= 2 * least * FOLD_SLACK) then
			s.beat = fold_period(s.beat)
		end
		if abs(2 * period - s.beat) < SAME * s.beat then
			period = 2 * period
		elseif abs(period / 2 - s.beat) < SAME * s.beat then
			period = period / 2
		end

		if s.beat == 0 or abs(period - s.beat) < SAME * s.beat then
			s.beat = s.beat == 0 and period or s.beat + (period - s.beat) * 0.4
			s.confidence = min(1, s.confidence + CONF_STEP)
			s.rival_count = 0
		elseif best > MARGIN * current_score() then
			-- Another tempo fits much better. It takes over if it lasts.
			s.confidence = max(0, s.confidence - CONF_STEP / 2)
			if abs(period - s.rival) < SAME * s.rival then
				s.rival_count = s.rival_count + 1
			else
				s.rival, s.rival_count = period, 1
			end
			if s.rival_count >= RIVAL_WINS then
				s.beat, s.rival_count = period, 0
			end
		else
			-- The current beat fits about as well. Dense music has many
			-- periods that do; don't hop between them.
			s.confidence = min(1, s.confidence + CONF_STEP)
			s.rival_count = 0
		end

		-- Phase: the part of the beat that collects the most flux is the beat.
		local ticks = s.beat / TICK
		for i = 1, PHASES do
			phases[i] = 0
		end
		for t = 1, FLUX_LEN do
			local part = floor((FLUX_LEN - t) % ticks / ticks * PHASES) % PHASES + 1
			phases[part] = phases[part] + wave[t]
		end
		local most, part = 0, 1
		for i = 1, PHASES do
			if phases[i] > most then
				most, part = phases[i], i
			end
		end
		local shift = peak_offset(phases[(part - 2) % PHASES + 1], most, phases[part % PHASES + 1])
		local ago = (part - 0.5 + shift) / PHASES * ticks
		s.beat_at = s.clock - ago * TICK
	end

	local function thump(strength)
		s.thump = max(s.thump, strength)
	end

	-- Thumps on the beats of the tempo, so the city also beats where no
	-- kick was found.
	local function predict_beat()
		if s.beat <= 0 or s.confidence < 0.5 then
			return
		end
		local beats = (s.clock + LEAD - s.beat_at) / s.beat
		local phase = beats - floor(beats)
		-- The phase wraps on a beat. It can also wrap when the tempo was
		-- just re-read, so require most of a beat since the last one.
		if phase < s.beat_phase and s.clock - s.predicted_at > 0.6 * s.beat then
			s.predicted_at = s.clock
			thump(BEAT_THUMP * s.confidence)
		end
		s.beat_phase = phase
	end

	-- Finds kick, snare and hi-hat as rises, not levels, so a loud bass line
	-- doesn't hide the kicks.
	local function detect_hits(bands)
		local prev = s.prev
		local flux = 0
		if s.has_prev then
			local onsets = s.onsets
			for part, o in ipairs(onsets) do
				local rise = 0
				for i = o.from, o.to do
					rise = rise + max(0, bands[i] - prev[i])
				end
				flux = flux + rise * FLUX_WEIGHT[part]
				local threshold = max(o.mean + o.k * o.dev, o.floor)
				o.over = rise / threshold
				o.mean = o.mean * 0.92 + rise * 0.08
				o.dev = o.dev * 0.92 + abs(rise - o.mean) * 0.08
			end
			local kick, snare, hat = onsets[1], onsets[2], onsets[3]
			for part, o in ipairs(onsets) do
				local hit = o.over > 1 and o.since + 1 >= o.gap
				if o == hat then
					-- A snare is noise from the mids up, so highs that rise
					-- right after one are not a hi-hat.
					hit = hit and snare.since > HAT_WAIT
				end
				o.since = hit and 0 or o.since + 1
				if hit and s.mute <= 0 then
					-- Rate the hit against the recent ones, or every kick
					-- looks hard.
					local usual = s.typical[part]
					local strength = HIT_TYPICAL
					if usual > 0 then
						strength = min(1, HIT_TYPICAL * o.over / usual)
						s.typical[part] = usual + (o.over - usual) * 0.2
					else
						s.typical[part] = o.over
					end
					if o == kick then
						spawn_pulse(strength)
						thump(strength)
						s.last_kick = s.clock
					elseif o == snare then
						-- A frame of light runs up the towers, the next one down.
						s.roll_to, s.roll_side = s.roll_side * ROLL, -s.roll_side
						s.scan_at, s.scan_up = s.clock, not s.scan_up
						s.snap = max(s.snap, strength)
						-- Sometimes the highs of a snare rise a tick before
						-- its mids. Take that hi-hat back.
						if s.clock - s.hat_at < (HAT_WAIT + 0.5) * TICK then
							s.hat_count, s.hat_at = s.hat_count - 1, -huge
						end
					else
						s.hat_count, s.hat_at, s.hat_strength = s.hat_count + 1, s.clock, strength
					end
				end
			end
		end
		s.has_prev = true
		for i = 1, BANDS do
			prev[i] = bands[i]
		end
		s.flux_head = s.flux_head % FLUX_LEN + 1
		s.flux[s.flux_head] = flux
	end

	-- Finds drops in the raw energy. A drop lifts the camera above the roofs.
	local function detect_drop(energy)
		if energy < SILENCE then
			s.heard = 0
			s.quiet = s.quiet + TICK
		else
			s.quiet = 0
			if s.heard == 0 then
				-- A track that starts out of silence is no drop.
				s.energy_fast, s.energy_slow = energy, energy
			end
			s.heard = s.heard + TICK
		end
		s.energy_fast = s.energy_fast + (energy - s.energy_fast) * K_FAST
		-- During warm-up the long average follows as fast as the short one.
		s.energy_slow = s.energy_slow + (energy - s.energy_slow) * (s.heard < DROP_WARMUP and K_FAST or K_SLOW)
		local jump = s.energy_fast > DROP_RATIO * s.energy_slow and s.energy_fast > DROP_FLOOR
		if jump and s.heard >= DROP_WARMUP and s.clock - s.drop_at > DROP_GAP then
			s.drop_at = s.clock
		end
		local age = s.clock - s.drop_at
		if age < 0 or age > DROP_LIFE then
			s.drop = 0
		elseif age < DROP_RISE then
			s.drop = age / DROP_RISE
		else
			s.drop = exp(-(age - DROP_RISE) / DROP_FADE)
		end
		s.lift = s.lift + ((age >= 0 and age < HOVER and 1 or 0) - s.lift) * K_LIFT
		if s.lift < 1e-4 then
			s.lift = 0
		end
	end

	-- One block per BEATS_PER_BLOCK beats when the tempo is known, else the
	-- cruise speed. Zero in silence.
	local function target_speed()
		if s.quiet >= SILENCE_STOP then
			return 0
		end
		local target = CRUISE + LOUD_GAIN * s.loud
		if s.beat > 0 then
			-- Phase error in beats. It is 0 when the camera is at a crossing
			-- or in the middle of a block on the beat. With a speed other
			-- than 1 there is no such place, so there is nothing to lock to.
			local err = BEATS_PER_BLOCK * s.travel - (s.clock - s.beat_at) / s.beat
			err = err - round(err)
			local lock = SPEED == 1 and max(-LOCK_MAX, min(LOCK_MAX, -LOCK * err)) * (1 - s.drop) or 0
			target = target + ((1 + lock) / (BEATS_PER_BLOCK * s.beat) - target) * s.confidence
		end
		return target * (1 + DROP_BOOST * s.drop) * SPEED
	end

	-- Moves the camera by one tick and, at each crossing, picks the
	-- direction of the leg after the next.
	local function fly()
		s.travel = s.travel + s.speed * TICK
		while s.travel - s.leg >= 1 do
			s.leg = s.leg + 1
			s.nx, s.nz = s.nx + DX[s.dir], s.nz + DZ[s.dir]
			local next_dir = s.next_dir
			if s.clock - s.turned_at >= TURN_GAP and s.leg + 1 - s.turned_leg >= TURN_BLOCKS then
				next_dir = pick_turn(s.leg + 1, next_dir)
				if next_dir ~= s.next_dir then
					s.turned_at, s.turned_leg = s.clock, s.leg + 1
				end
			end
			s.prev_dir, s.dir, s.next_dir = s.dir, s.next_dir, next_dir
		end
	end

	-- Swaps the bands for those of DELAY ticks ago.
	local function delay(bands)
		if DELAY == 0 then
			return bands
		end
		s.delay_at = s.delay_at % DELAY + 1
		local slot, late = s.delay_ring[s.delay_at], s.delayed
		for i = 1, BANDS do
			late[i], slot[i] = slot[i], bands[i]
		end
		return late
	end

	-- cliamp smooths the bands and hands over their state at the end of a
	-- frame, with a faster attack than release. These are its two rates.
	local EASE_UP, EASE_DOWN = 34, 10

	-- The bands at share `after` of the way through a frame of span seconds.
	local function between(bands, after, span)
		local up = (1 - exp(-EASE_UP * after * span)) / (1 - exp(-EASE_UP * span))
		local down = (1 - exp(-EASE_DOWN * after * span)) / (1 - exp(-EASE_DOWN * span))
		local from, mid = s.last_bands, s.mid_bands
		for i = 1, BANDS do
			local change = bands[i] - from[i]
			mid[i] = from[i] + change * (change > 0 and up or down)
		end
		return mid
	end

	-- One tick of playback.
	local function step(bands)
		bands = delay(bands)
		s.loud = s.loud + (track_levels(bands) - s.loud) * K_LOUD
		s.clock = s.clock + TICK
		if not s.playing then
			-- The bands rise out of the break. That is no drum hit.
			s.has_prev, s.mute, s.playing = false, MUTE, true
		end
		s.mute = max(0, s.mute - TICK)
		s.thump, s.snap = s.thump - s.thump * K_THUMP, s.snap - s.snap * K_SNAP
		detect_hits(bands)
		predict_beat()
		s.roll = s.roll + (s.roll_to - s.roll) * K_ROLL
		s.since_tempo = s.since_tempo + 1
		if s.since_tempo >= TEMPO_EVERY then
			s.since_tempo = 0
			estimate_tempo()
		end
		local sum = 0
		for i = 1, BANDS do
			sum = sum + bands[i]
		end
		detect_drop(sum / BANDS)
		update_calm((bands[BANDS - 2] + bands[BANDS - 1] + bands[BANDS]) / 3, sum / BANDS)

		s.speed = s.speed + (target_speed() - s.speed) * K_SPEED
		fly()
	end

	-- The last tick of a frame gets the bands as cliamp gave them, the ticks
	-- before it get the bands on the way there.
	function play(bands, steps)
		local last = s.last_bands
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

	-- The camera eases to a stop.
	function rest()
		s.playing = false
		s.thump, s.snap = s.thump - s.thump * K_THUMP, s.snap - s.snap * K_SNAP
		s.speed = s.speed - s.speed * K_FALL
		if s.speed < 0.01 then
			s.speed = 0
		end
		fly()
	end
end

-- Drawing ----------------------------------------------------------------

local draw, resize
local lod = 1 -- level of detail: 1 draws everything, higher numbers less

do
	local Z_NEAR = 0.12 -- near clipping plane

	-- Focal length as a share of half the panel. A flat panel gets a wider
	-- lens, or it only shows a strip of the towers.
	local LENS, TELE, WIDE = 1.19, 2.75, 0.6

	-- View distances in blocks, by lod.
	local VIEW_DIST = { 6, 5, 4, 3 }
	local GRID_DIST = { 3.6, 3, 2.4, 1.8 }
	local CODE_DIST = { 3.2, 2.6, 2, 1.5 }
	local SCAN_DIST = 3.5
	local BACK_DIST = 2 -- back edges show through the glass up to here

	local EMPTY = 0.1 -- share of lots without a tower
	local BREATHE = 0.25 -- how much a tower grows with its band

	local FACE = 0.85 -- glass one face adds
	local FADE = 0.5 -- how much thinner the glass is at the top of a face
	local PAD = 0.8 -- half the width of the glow under a tower

	-- Code on the faces.
	local LINE = 0.14 -- line height
	local MARGIN = 0.1
	local INDENT = 0.1
	local BLANK = 0.25 -- share of blank lines
	local REVEAL = 0.4 -- share of a face that has code when a cycle starts
	local LINE_GAP = 4 -- least distance between two lines, in dots
	local FLASH = 0.12 -- s a hi-hat lights its lines

	-- What the pulse of the beat does: zoom in, taller towers, denser glass,
	-- and edges this many shades brighter.
	local ZOOM = 0.06
	local JUMP = 0.1
	local GLASS_PUMP = 0.9
	local EDGE_PUMP = 1.2

	local GRID_STEP = BLOCK / 4
	local SCAN_TIME = 0.45
	local SCAN_TOP = 1.7 * TALL -- how high the frame of light rises
	local PULSE_LIFE = 0.9
	local PULSE_SPEED = 16
	local PULSE_TAIL = 2.2
	local PULSE_WIDTH = 0.05 -- between two of its three lines
	local PULSE_SHINE = 0.35 -- half the width of its shine

	-- Braille bit of each dot in a cell, row by row.
	local DOT = { 1, 8, 2, 16, 4, 32, 64, 128 }

	local GLYPH = {}
	local HAS = {} -- HAS[mask * 8 + k]: does a cell with these dots have dot k?
	for mask = 0, 255 do
		GLYPH[mask] = string.char(0xE2, 0xA0 + floor(mask / 64), 0x80 + mask % 64)
		for k, bit in ipairs(DOT) do
			HAS[mask * 8 + k] = mask % (2 * bit) >= bit
		end
	end

	-- Dot patterns for dotted glass, two per level from thin to dense. The
	-- two alternate from cell to cell so the dots don't line up.
	local STIPPLE = { 0x02, 0x20, 0x21, 0x0C, 0x15, 0x15, 0x95, 0x95 }

	-- Corners of a tower, going around it.
	local CX = { -HALF, HALF, HALF, -HALF }
	local CZ = { -HALF, -HALF, HALF, HALF }

	-- Per cell: its dots and its tier. haze is the glass of each row as a
	-- difference array, with one entry more than the row has cells.
	local dots, tiers, haze = {}, {}, {}
	-- Lookup from dot column x and dot row y to the cell and the dot in it.
	local cell_x, dot_x, cell_y, dot_y = {}, {}, {}, {}
	local out, chunks = {}, {}
	local CHUNK = 1000

	-- Per-frame state.
	local w, h, cols, rows -- panel size in dots and in cells
	local half_w, half_h, focal
	local ex, ey, ez -- camera position
	local m11, m12, m13, m21, m22, m23, m31, m32, m33 -- world to view
	local fwd_x, fwd_z, spread, view_dist
	local clock, drop, level
	local thump, snap -- s.thump and s.snap, scaled by PULSE
	local scan -- height of the frame of light, or nil

	-- Scratch: corners of a tower in view space at the ground (g) and the
	-- roof (r), the quad to fill (q) and its projection (p).
	local gx, gy, gz, rx, ry, rz = {}, {}, {}, {}, {}, {}
	local qx, qy, qz, px, py = {}, {}, {}, {}, {}

	function resize(lines, columns)
		cols, rows, w, h = columns, lines, columns * 2, lines * 4
		for x = 0, w - 1 do
			cell_x[x], dot_x[x] = floor(x / 2), x % 2
		end
		for y = 0, h - 1 do
			cell_y[y], dot_y[y] = floor(y / 4) * cols + 1, y % 4 * 2 + 1
		end
	end

	-- Draws a line between two points in view space (x right, y up, z away
	-- from the camera). It is clipped to the near plane and the panel first,
	-- so a long line only costs as much as its visible part.
	local function seg(ax, ay, az, bx, by, bz, tier)
		if az < Z_NEAR then
			if bz < Z_NEAR then
				return
			end
			local t = (Z_NEAR - az) / (bz - az)
			ax, ay, az = ax + (bx - ax) * t, ay + (by - ay) * t, Z_NEAR
		elseif bz < Z_NEAR then
			local t = (Z_NEAR - bz) / (az - bz)
			bx, by, bz = bx + (ax - bx) * t, by + (ay - by) * t, Z_NEAR
		end
		local x0, y0 = half_w + focal * ax / az, half_h - focal * ay / az
		local dx, dy = half_w + focal * bx / bz - x0, half_h - focal * by / bz - y0
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
			-- Rounding can still leave a point just off the panel.
			local x, y = x0 + dx * i, y0 + dy * i
			if x >= 0 and x < w and y >= 0 and y < h then
				local xi, yi = floor(x), floor(y)
				local c, k = cell_y[yi] + cell_x[xi], dot_y[yi] + dot_x[xi]
				local mask = dots[c]
				if not HAS[mask * 8 + k] then
					dots[c] = mask + DOT[k]
				end
				if tier > tiers[c] then
					tiers[c] = tier
				end
			end
		end
	end

	-- Like seg, but for points relative to the camera in world axes.
	local function line(x0, y0, z0, x1, y1, z1, tier)
		seg(
			m11 * x0 + m12 * y0 + m13 * z0,
			m21 * x0 + m22 * y0 + m23 * z0,
			m31 * x0 + m32 * y0 + m33 * z0,
			m11 * x1 + m12 * y1 + m13 * z1,
			m21 * x1 + m22 * y1 + m23 * z1,
			m31 * x1 + m32 * y1 + m33 * z1,
			tier
		)
	end

	-- Adds glass to the cells under the quad in qx, qy, qz. The quad is
	-- clipped to the near plane, then scanned row by row. The glass is
	-- denser at the foot of the quad.
	local function fill(amount)
		local n = 0
		local ux, uy, uz = qx[4], qy[4], qz[4]
		for k = 1, 4 do
			local x, y, z = qx[k], qy[k], qz[k]
			if (z >= Z_NEAR) ~= (uz >= Z_NEAR) then
				local t = (Z_NEAR - uz) / (z - uz)
				n = n + 1
				px[n] = (half_w + focal * (ux + (x - ux) * t) / Z_NEAR) / 2
				py[n] = (half_h - focal * (uy + (y - uy) * t) / Z_NEAR) / 4
			end
			if z >= Z_NEAR then
				n = n + 1
				px[n], py[n] = (half_w + focal * x / z) / 2, (half_h - focal * y / z) / 4
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
			local from_x, from_y = px[n], py[n]
			for k = 1, n do
				local to_x, to_y = px[k], py[k]
				if (from_y <= y) ~= (to_y <= y) then
					local x = from_x + (to_x - from_x) * (y - from_y) / (to_y - from_y)
					left, right = min(left, x), max(right, x)
				end
				from_x, from_y = to_x, to_y
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

	-- Writes lines of code on the face between two corners. A line is a run
	-- of dots with a hashed indent and length. The face fills up from the
	-- top and then starts over with new lines.
	local function draw_code(x0, z0, x1, z1, tall, id, tier, dist)
		local every = max(1, ceil(LINE_GAP * dist / (focal * LINE)))
		local turns = clock / (2 + 3 * hash(id, 4)) + hash(id, 5)
		local cycle = floor(turns)
		local shown = floor(tall / LINE * (REVEAL + (1 - REVEAL) * (turns - cycle))) - 1
		local flash = clock - s.hat_at < FLASH and 0.3 + 0.6 * s.hat_strength or 0
		local slot = 10 + s.hat_count % 7 -- another set of lines for each hat
		for k = 0, shown - 1, every do
			local key = id + k * 7.31 + cycle * 3.17
			if hash(key, 6) > BLANK then
				local from = MARGIN + INDENT * floor(hash(key, 7) * 4)
				local to = from + (1 - MARGIN - from) * (0.2 + 0.6 * hash(key, 8))
				local y = tall - (k + 1) * LINE - ey
				line(
					x0 + (x1 - x0) * from,
					y,
					z0 + (z1 - z0) * from,
					x0 + (x1 - x0) * to,
					y,
					z0 + (z1 - z0) * to,
					hash(key, slot) < flash and LIT or tier
				)
			end
		end
	end

	-- The pattern on a roof: a 5x5 grid of cells, each on or off, drawn as
	-- runs along the rows.
	local function draw_roof(x, z, y, id, tier)
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

	-- Draws the faces of the tower at x, z: edges, glass, code and the frame
	-- of light. Expects the corners in gx..rz. fog is 1 at the camera and 0
	-- at the view distance.
	local function draw_faces(x, z, tall, id, dist, fog, loud, tier)
		local amount = FACE * fog * (0.45 + 0.55 * loud)
		local close = dist < CODE_DIST[lod] * BLOCK
		local code_tier = max(FAR, FAR + min(3, floor(fog * 4)) - 1)
		local lit = scan and scan < tall and dist < SCAN_DIST * BLOCK and scan / tall
		local crown = snap > 0.3 and dist < SCAN_DIST * BLOCK
		local above = ey > tall
		local a = 4
		for b = 1, 4 do
			-- Only the faces turned towards the camera. No occlusion: the
			-- towers are glass.
			local facing
			if b == 1 then
				facing = x > HALF
			elseif b == 2 then
				facing = z > HALF
			elseif b == 3 then
				facing = x < -HALF
			else
				facing = z < -HALF
			end
			if facing then
				seg(gx[a], gy[a], gz[a], rx[a], ry[a], rz[a], tier)
				seg(gx[b], gy[b], gz[b], rx[b], ry[b], rz[b], tier)
				seg(gx[a], gy[a], gz[a], gx[b], gy[b], gz[b], tier)
				if glass_on then
					qx[1], qy[1], qz[1] = gx[a], gy[a], gz[a]
					qx[2], qy[2], qz[2] = gx[b], gy[b], gz[b]
					qx[3], qy[3], qz[3] = rx[b], ry[b], rz[b]
					qx[4], qy[4], qz[4] = rx[a], ry[a], rz[a]
					fill(amount * (b % 2 == 1 and 1 or 0.6))
				end
				if close then
					draw_code(x + CX[a], z + CZ[a], x + CX[b], z + CZ[b], tall, id + b, code_tier, dist)
				end
			end
			if facing or above then
				-- A snare lights the roof edges.
				seg(rx[a], ry[a], rz[a], rx[b], ry[b], rz[b], crown and BEAT or tier)
			end
			if lit and facing then
				seg(
					gx[a] + (rx[a] - gx[a]) * lit,
					gy[a] + (ry[a] - gy[a]) * lit,
					gz[a] + (rz[a] - gz[a]) * lit,
					gx[b] + (rx[b] - gx[b]) * lit,
					gy[b] + (ry[b] - gy[b]) * lit,
					gz[b] + (rz[b] - gz[b]) * lit,
					BEAT
				)
			end
			a = b
		end
		if above then
			if glass_on then
				for c = 1, 4 do
					qx[c], qy[c], qz[c] = rx[c], ry[c], rz[c]
				end
				fill(amount)
			end
			if close then
				draw_roof(x, z, tall - ey, id, tier)
			end
		end
		if glass_on and close then
			-- The glow a tower throws on the ground.
			for c = 1, 4 do
				local dx, dz = x + CX[c] * PAD / HALF, z + CZ[c] * PAD / HALF
				qx[c] = m11 * dx - m12 * ey + m13 * dz
				qy[c] = m21 * dx - m22 * ey + m23 * dz
				qz[c] = m31 * dx - m32 * ey + m33 * dz
			end
			fill(0.4 * amount)
		end
	end

	-- Draws the tower of lot (i, j), unless the lot is empty or out of view.
	-- Each tower follows one band of the spectrum.
	local function draw_tower(i, j)
		local x, z = i * BLOCK - ex, j * BLOCK - ez
		local depth = x * fwd_x + z * fwd_z
		if depth < -1 or abs(x * fwd_z - z * fwd_x) > (depth + 1.5) * spread + 1 then
			return
		end
		local dist = sqrt(x * x + z * z)
		local id = i * 127.1 + j * 311.7
		if dist >= view_dist or hash(id, 12) < EMPTY then
			return
		end
		local loud = level[1 + floor(hash(id, 13) * BANDS)]
		local tall = TALL * (0.7 + 0.9 * hash(id, 14)) * (1 + BREATHE * loud + JUMP * thump)
		local fog = 1 - dist / view_dist
		local tier = FAR + min(3, floor(fog * 4 + EDGE_PUMP * thump))
		if fog > 0.5 then
			if drop > 0.5 then
				tier = DROP
			elseif loud > 0.8 or thump > 0.6 then
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
		if dist < BACK_DIST * BLOCK then
			-- All edges in the dimmest shade first, so the back ones show
			-- through the glass.
			local a = 4
			for b = 1, 4 do
				seg(gx[b], gy[b], gz[b], rx[b], ry[b], rz[b], FAR)
				seg(rx[a], ry[a], rz[a], rx[b], ry[b], rz[b], FAR)
				seg(gx[a], gy[a], gz[a], gx[b], gy[b], gz[b], FAR)
				a = b
			end
		end
		draw_faces(x, z, tall, id, dist, fog, loud, tier)
	end

	-- The grid on the ground. Every other line is half as long, or the lines
	-- merge in the distance.
	local function draw_grid()
		local reach = min(view_dist, GRID_DIST[lod] * BLOCK)
		local y = -ey
		for k = ceil((ex - reach) / GRID_STEP), floor((ex + reach) / GRID_STEP) do
			local x = k * GRID_STEP - ex
			local far = k % 2 == 0 and reach or 0.5 * reach
			if abs(x) < far then
				line(x, y, -far, x, y, far, GRID)
			end
		end
		for k = ceil((ez - reach) / GRID_STEP), floor((ez + reach) / GRID_STEP) do
			local z = k * GRID_STEP - ez
			local far = k % 2 == 0 and reach or 0.5 * reach
			if abs(z) < far then
				line(-far, y, z, far, y, z, GRID)
			end
		end
	end

	-- The pulses of the kicks: three lines side by side with a hot head, and
	-- their shine on the ground.
	local function draw_pulses()
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
					line(x + dx * tail, y, z + dz * tail, x + dx * mid, y, z + dz * mid, NEAR)
					line(x + dx * mid, y, z + dz * mid, x + dx * head, y, z + dz * head, HOT)
				end
				if glass_on then
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

	local function setup_view()
		local yaw, pitch, roll
		ex, ey, ez, yaw, pitch, roll = camera()
		local cy, sy, cp, sp, cr, sr = cos(yaw), sin(yaw), cos(pitch), sin(pitch), cos(roll), sin(roll)
		m11, m12, m13 = cr * cy + sr * sp * sy, sr * cp, sr * sp * cy - cr * sy
		m21, m22, m23 = cr * sp * sy - sr * cy, cr * cp, sr * sy + cr * sp * cy
		m31, m32, m33 = cp * sy, -sp, cp * cy
		fwd_x, fwd_z = sy, cy
		half_w, half_h = w / 2, h / 2
		thump, snap = min(1.5, s.thump * PULSE), min(1.5, s.snap * PULSE)
		focal = max(WIDE * half_w, min(LENS * half_w, TELE * half_h)) * (1 + ZOOM * thump)
		spread = 1.3 * half_w / focal + 0.3
		-- A low panel has no room for the far towers anyway.
		view_dist = min(VIEW_DIST[lod], 2 + rows / 7) * BLOCK
		clock, drop, level = s.clock, s.drop, s.level
		local age = (clock - s.scan_at) / SCAN_TIME
		scan = nil
		if age >= 0 and age <= 1 then
			scan = SCAN_TOP * (s.scan_up and age or 1 - age)
		end
	end

	-- Turns the cells into lines of colored Braille. A cell without dots
	-- doesn't switch the foreground color; only its glass shows. With
	-- dotted glass such a cell gets a few dots instead. The frame is joined
	-- in chunks because the Lua stack limits how many strings one concat
	-- takes.
	local function encode()
		local ramp = drop > 0.5 and GLASS_DROP or GLASS
		local gain = GLASS_GAIN * (1 + GLASS_PUMP * thump)
		local n, c, d, joined = 0, 0, 0, 0
		for row = 1, rows do
			local tier, lit, sum = 0, 0, 0
			for col = 1, cols do
				c, d = c + 1, d + 1
				sum = sum + haze[d]
				local glass = floor(min(1, sum * gain) * GLASS_LEVELS + 0.5)
				local t, mask = tiers[c], dots[c]
				if glass_dots then
					if glass > 0 and mask == 0 then
						t, mask = FAR, STIPPLE[2 * glass - (col + row) % 2]
					end
				elseif glass ~= lit then
					n = n + 1
					out[n] = glass > 0 and ramp[glass] or "\27[49m"
					lit = glass
				end
				if t ~= 0 and t ~= tier then
					-- Two tiers can share a color, DROP and BEAT for one.
					if COLOR[t] ~= COLOR[tier] then
						n = n + 1
						out[n] = COLOR[t]
					end
					tier = t
				end
				n = n + 1
				out[n] = GLYPH[mask]
				if n >= CHUNK then
					joined = joined + 1
					chunks[joined] = table.concat(out, "", 1, n)
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
		joined = joined + 1
		chunks[joined] = table.concat(out, "", 1, n)
		return table.concat(chunks, "", 1, joined)
	end

	function draw()
		for i = 1, rows * cols do
			dots[i], tiers[i] = 0, 0
		end
		for i = 1, rows * (cols + 1) do
			haze[i] = 0
		end
		setup_view()
		draw_grid()
		draw_pulses()
		for i = floor((ex - view_dist) / BLOCK), ceil((ex + view_dist) / BLOCK) do
			for j = floor((ez - view_dist) / BLOCK), ceil((ez + view_dist) / BLOCK) do
				draw_tower(i, j)
			end
		end
		return encode()
	end
end

-- Plugin -----------------------------------------------------------------

local FRAME = 0.05 -- assumed time between two frames when the clock is no help
local MAX_GAP = 0.25 -- a longer wait than this is a break, not a slow frame
local MAX_STEPS = 4
local DRAW_GAP = 0.04 -- s between two draws while music plays

-- cliamp gives render 50 ms and keeps the old frame if it takes longer. Two
-- draws in a row slower than SLOW drop a level of detail, a draw faster than
-- SWIFT brings one back.
local SLOW, SWIFT = 0.03, 0.012
local MAX_LOD = 4

local last_at, last_frame, backlog = nil, nil, 0
local text, text_rows, text_cols -- the last frame drawn, and its size
local dirty, drawing, drawn_at, slow_draws = true, false, 0, 0

function p:init()
	reset()
	last_at, last_frame, backlog, dirty = nil, nil, 0, true
end

function p:destroy()
	shown_at = -huge
end

function p:render(bands, frame, rows, cols)
	rows, cols = floor(rows), floor(cols)
	if rows < 1 or cols < 1 then
		return ""
	end

	local now = os.clock() -- wall time in cliamp's Lua VM
	shown_at = now
	local state = cliamp.player.state()
	local moving = s.speed ~= 0
	if state == "stopped" then
		dirty = dirty or moving
		s.speed, s.playing, last_at = 0, false, nil
	elseif state == "paused" or frame ~= last_frame then
		-- cliamp also renders between its ticks, on a key press for
		-- example. The bands are only new when the frame number is. A pause
		-- holds the frame number.
		local dt = last_at and now - last_at or FRAME
		if dt <= 0 or dt > MAX_GAP then
			dt = FRAME
			if state == "paused" then
				-- cliamp slows its ticks down in a pause, before the camera
				-- has come to rest.
				s.speed = 0
			end
			s.playing = false
		end
		last_at, last_frame = now, frame
		backlog = backlog + dt
		local steps = min(MAX_STEPS, floor((backlog + 1e-6) / TICK))
		backlog = backlog - steps * TICK
		if backlog > TICK then
			backlog = 0
		end
		if state == "paused" then
			for _ = 1, steps do
				rest()
			end
		elseif steps > 0 then
			play(bands, steps)
		end
		dirty = dirty or steps > 0 and (moving or state ~= "paused")
	end

	if rows ~= text_rows or cols ~= text_cols then
		resize(rows, cols)
		text, text_rows, text_cols = nil, rows, cols
	end
	if theme_changed then
		text, theme_changed = nil, false
	end
	-- cliamp shows 20 frames a second, so drawing more often is wasted.
	if not text or dirty and (now - drawn_at > DRAW_GAP or state ~= "playing") then
		if drawing then
			lod = min(MAX_LOD, lod + 1) -- cliamp cut the last draw off
		end
		drawing = true
		text = draw()
		drawing = false
		local took = os.clock() - now
		slow_draws = took > SLOW and slow_draws + 1 or 0
		if slow_draws > 1 and lod < MAX_LOD then
			lod, slow_draws = lod + 1, 0
		elseif took < SWIFT and lod > 1 then
			lod = lod - 1
		end
		dirty, drawn_at = false, now
	end
	return text
end

-- Mess with the best, die like the rest.
--
--           ##########
--       ##################
--     ##    ################
--   ########    #############
--   ############    ###########
-- ########  ########      #####
-- ########  ########      #####
-- ########################   ###
-- ###########################
-- ######  ##############  ######
--   ######  ##########  ######
--   ########          ########
--     ######################
--       ##################
--           ##########
--
--        HACK THE PLANET
