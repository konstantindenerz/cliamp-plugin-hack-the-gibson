// Package test runs hackthegibson.lua in the Lua VM that cliamp uses, with
// stand-ins for the plugin and cliamp tables.
package test

import (
	"bufio"
	"context"
	"flag"
	"fmt"
	"hash/fnv"
	"image"
	"image/color"
	"image/png"
	"math"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"

	lua "github.com/yuin/gopher-lua"
)

var (
	update  = flag.Bool("update", false, "rewrite testdata/frames.txt")
	shots   = flag.String("shots", "", "write pictures of some frames to this directory")
	gallery = flag.String("themes", "", "write a picture of each theme to this directory")
)

const (
	source = "../hackthegibson.lua"
	golden = "testdata/frames.txt"
	tick   = 0.05 // s between two ticks of cliamp

	block = 2.9 // BLOCK in the plugin
	half  = 0.5 // HALF in the plugin
)

// peek lets a test read the state that the plugin keeps to itself.
const peek = `
function __peek() return s.lastKick, s.beat, s.sure, s.speed, s.travel, s.dir end
function __eye() return camera() end
function __hits() return s.pulsed, s.scanAt, s.struck end
`

// host stands in for cliamp: a sandboxed VM with the plugin loaded.
type host struct {
	t      testing.TB
	L      *lua.LState
	meta   *lua.LTable // what the plugin passed to plugin.register
	plugin *lua.LTable // what it got back
	clock  float64     // os.clock, in seconds
	status string      // cliamp.player.state
	frame  int
}

// load runs the plugin file. config is its section of config.toml.
func load(t testing.TB, config map[string]string) *host {
	t.Helper()
	src, err := os.ReadFile(source)
	if err != nil {
		t.Fatal(err)
	}
	h := &host{t: t, L: lua.NewState(), status: "playing"}
	t.Cleanup(h.L.Close)
	L := h.L

	// What cliamp takes away from a plugin.
	for _, name := range []string{"dofile", "loadfile", "load", "loadstring", "require", "module", "package", "debug", "io"} {
		L.SetGlobal(name, lua.LNil)
	}
	L.SetGlobal("print", L.NewFunction(func(*lua.LState) int { return 0 }))
	system := L.GetGlobal("os").(*lua.LTable)
	for _, name := range []string{"execute", "remove", "rename", "exit", "setlocale", "tmpname"} {
		system.RawSetString(name, lua.LNil)
	}
	system.RawSetString("clock", L.NewFunction(func(L *lua.LState) int {
		L.Push(lua.LNumber(h.clock))
		return 1
	}))

	player := L.NewTable()
	player.RawSetString("state", L.NewFunction(func(L *lua.LState) int {
		L.Push(lua.LString(h.status))
		return 1
	}))
	cliamp := L.NewTable()
	cliamp.RawSetString("player", player)
	L.SetGlobal("cliamp", cliamp)

	register := L.NewTable()
	register.RawSetString("register", L.NewFunction(func(L *lua.LState) int {
		h.meta = L.CheckTable(1)
		h.plugin = L.NewTable()
		h.plugin.RawSetString("config", L.NewFunction(func(L *lua.LState) int {
			if value, ok := config[L.CheckString(2)]; ok {
				L.Push(lua.LString(value))
			} else {
				L.Push(lua.LNil)
			}
			return 1
		}))
		L.Push(h.plugin)
		return 1
	}))
	L.SetGlobal("plugin", register)

	if err := L.DoString(string(src) + peek); err != nil {
		t.Fatalf("load: %v", err)
	}
	if h.plugin == nil {
		t.Fatal("the plugin did not register")
	}
	return h
}

// draw calls render as cliamp does, under a deadline.
func (h *host) draw(bands [10]float64, rows, cols int) string {
	h.t.Helper()
	L := h.L
	levels := L.NewTable()
	for i, b := range bands {
		levels.RawSetInt(i+1, lua.LNumber(b))
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	L.SetContext(ctx)
	defer L.RemoveContext()
	call := lua.P{Fn: h.plugin.RawGetString("render"), NRet: 1, Protect: true}
	if err := L.CallByParam(call, h.plugin, levels, lua.LNumber(h.frame), lua.LNumber(rows), lua.LNumber(cols)); err != nil {
		h.t.Fatalf("render: %v", err)
	}
	out, ok := L.Get(-1).(lua.LString)
	L.Pop(1)
	if !ok {
		h.t.Fatal("render did not return a string")
	}
	return string(out)
}

// tick is one tick of cliamp, dt seconds after the last: new bands and,
// unless playback is paused, a new frame number.
func (h *host) tick(bands [10]float64, rows, cols int, dt float64) string {
	h.t.Helper()
	h.clock += dt
	if h.status != "paused" {
		h.frame++
	}
	return h.draw(bands, rows, cols)
}

// restart is what cliamp does when the mode is selected again.
func (h *host) restart(rows, cols int) {
	h.t.Helper()
	call := lua.P{Fn: h.plugin.RawGetString("init"), Protect: true}
	if err := h.L.CallByParam(call, h.plugin, lua.LNumber(rows), lua.LNumber(cols)); err != nil {
		h.t.Fatalf("init: %v", err)
	}
}

// numbers calls a global of the plugin that returns n numbers.
func (h *host) numbers(name string, n int) []float64 {
	h.t.Helper()
	L := h.L
	if err := L.CallByParam(lua.P{Fn: L.GetGlobal(name), NRet: n, Protect: true}); err != nil {
		h.t.Fatal(err)
	}
	values := make([]float64, n)
	for i := range values {
		values[i] = float64(L.Get(i - n).(lua.LNumber))
	}
	L.Pop(n)
	return values
}

type flight struct{ lastKick, beat, sure, speed, travel, dir float64 }

func (h *host) flight() flight {
	h.t.Helper()
	v := h.numbers("__peek", 6)
	return flight{v[0], v[1], v[2], v[3], v[4], v[5]}
}

type eye struct{ x, y, z, yaw, pitch, roll float64 }

func (h *host) eye() eye {
	h.t.Helper()
	v := h.numbers("__eye", 6)
	return eye{v[0], v[1], v[2], v[3], v[4], v[5]}
}

// music gives the bands of a track at second sec: a kick on the beat, a
// snare on every second one, hats on the off eighths. gain scales it all.
func music(bpm, sec, gain float64) [10]float64 {
	beat := 60 / bpm
	since := func(period, offset float64) float64 { return math.Mod(sec-offset+100*period, period) }
	kick := math.Exp(-since(beat, 0) / 0.08)
	snare := math.Exp(-since(2*beat, beat) / 0.06)
	hat := math.Exp(-since(beat/2, beat/4) / 0.03)
	swing := 0.85 + 0.15*math.Sin(sec*0.3)
	tilt := 0.5 + 0.5*math.Sin(sec*0.11)
	var bands [10]float64
	for i := range bands {
		switch {
		case i < 3:
			bands[i] = 0.3 + 0.55*kick
		case i < 6:
			bands[i] = 0.25 + 0.5*snare
		default:
			bands[i] = 0.15 + 0.2*tilt + 0.45*hat
		}
		bands[i] = min(1, bands[i]*swing*gain)
	}
	return bands
}

var colors = regexp.MustCompile(`\x1b\[[0-9;]*m`)

// checkFrame fails unless out is rows lines of cols Braille cells, with
// nothing but color codes between them.
func checkFrame(t *testing.T, out string, rows, cols int) {
	t.Helper()
	lines := strings.Split(colors.ReplaceAllString(out, ""), "\n")
	if len(lines) != rows {
		t.Fatalf("%d lines, want %d", len(lines), rows)
	}
	for _, line := range lines {
		cells := []rune(line)
		if len(cells) != cols {
			t.Fatalf("a line of %d cells, want %d", len(cells), cols)
		}
		for _, cell := range cells {
			if cell < 0x2800 || cell > 0x28FF {
				t.Fatalf("%q in the frame, want Braille only", cell)
			}
		}
	}
}

func TestRegisters(t *testing.T) {
	h := load(t, nil)
	for key, want := range map[string]string{"name": "Hack the Gibson", "type": "visualizer"} {
		if got := h.meta.RawGetString(key).String(); got != want {
			t.Errorf("%s = %q, want %q", key, got, want)
		}
	}
	if h.meta.RawGetString("permissions") != lua.LNil {
		t.Error("the plugin asks for permissions")
	}
	for _, name := range []string{"render", "init"} {
		if _, ok := h.plugin.RawGetString(name).(*lua.LFunction); !ok {
			t.Errorf("no %s", name)
		}
	}
}

// The VM allows 200 locals in one function, and the top level of the file is
// one. The file must stay well below that, or a small edit stops it loading.
func TestLeavesRoomForLocals(t *testing.T) {
	src, err := os.ReadFile(source)
	if err != nil {
		t.Fatal(err)
	}
	var more strings.Builder
	for i := range 60 {
		fmt.Fprintf(&more, "\nlocal spare%d = %d", i, i)
	}
	L := lua.NewState()
	defer L.Close()
	if _, err := L.LoadString(string(src) + more.String()); err != nil {
		t.Fatalf("60 more locals do not fit: %v", err)
	}
}

func TestFitsPanel(t *testing.T) {
	for _, size := range []struct{ cols, rows int }{{1, 1}, {2, 1}, {3, 2}, {13, 3}, {40, 1}, {76, 7}, {140, 40}, {300, 90}} {
		t.Run(fmt.Sprintf("%dx%d", size.cols, size.rows), func(t *testing.T) {
			h := load(t, nil)
			for i := range 60 {
				checkFrame(t, h.tick(music(128, float64(i)*tick, 1), size.rows, size.cols, tick), size.rows, size.cols)
			}
		})
	}
}

type step struct {
	status string
	bands  [10]float64
}

type part struct {
	secs   float64
	status string
	gain   float64
}

// run strings parts of a track together, one step per tick of cliamp.
func run(parts ...part) []step {
	var steps []step
	sec := 0.0
	for _, part := range parts {
		for end := sec + part.secs; sec < end-1e-9; sec += tick {
			s := step{status: part.status}
			if part.status == "playing" {
				s.bands = music(128, sec, part.gain)
			}
			steps = append(steps, s)
		}
	}
	return steps
}

// scenes are short runs that between them show every part of the city.
func scenes() map[string][]step {
	return map[string][]step{
		"silence": run(part{1, "playing", 0}),
		"music":   run(part{15, "playing", 1}),
		"drop":    run(part{6, "playing", 0.25}, part{6, "playing", 1}),
		"breaks": run(part{5, "playing", 1}, part{1.5, "paused", 0}, part{3, "playing", 1},
			part{1, "stopped", 0}, part{3, "playing", 1}, part{1.5, "playing", 0}, part{2, "playing", 1}),
	}
}

// A hash may change only on purpose.
func TestFrames(t *testing.T) {
	want := map[string]string{}
	if file, err := os.Open(golden); err == nil {
		lines := bufio.NewScanner(file)
		for lines.Scan() {
			if key, hash, ok := strings.Cut(lines.Text(), ": "); ok {
				want[key] = hash
			}
		}
		file.Close()
	}
	var names []string
	for name := range scenes() {
		names = append(names, name)
	}
	slices.Sort(names)

	var recorded strings.Builder
	for _, name := range names {
		for _, size := range []struct{ cols, rows int }{{13, 3}, {40, 1}, {76, 7}, {140, 40}} {
			key := fmt.Sprintf("%s %dx%d", name, size.cols, size.rows)
			h := load(t, nil)
			sum := fnv.New64a()
			for _, s := range scenes()[name] {
				h.status = s.status
				sum.Write([]byte(h.tick(s.bands, size.rows, size.cols, tick)))
				sum.Write([]byte{0})
			}
			got := fmt.Sprintf("%016x", sum.Sum64())
			fmt.Fprintf(&recorded, "%s: %s\n", key, got)
			if !*update && got != want[key] {
				t.Errorf("%s: hash %s, want %s", key, got, want[key])
			}
		}
	}
	if *update {
		if err := os.WriteFile(golden, []byte(recorded.String()), 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

// fold gives the beat that the plugin flies to for a beat period in seconds:
// it takes half or twice a period to stay between 0.35 and 0.71 s, 85 to 170
// BPM, so the eye flies at a like speed to any track.
func fold(period float64) float64 {
	for period > math.Sqrt2/2 {
		period /= 2
	}
	for period < math.Sqrt2/4 {
		period *= 2
	}
	return period
}

// With a steady kick the eye flies one block per beat.
func TestFollowsTempo(t *testing.T) {
	for _, bpm := range []float64{96, 120, 128, 150, 174} {
		t.Run(fmt.Sprint(bpm), func(t *testing.T) {
			h := load(t, nil)
			mean, n := 0.0, 0
			for i := range 400 {
				h.tick(music(bpm, float64(i)*tick, 1), 7, 76, tick)
				if i >= 200 {
					mean += h.flight().speed
					n++
				}
			}
			state := h.flight()
			want := 1 / fold(60/bpm)
			if got := mean / float64(n); state.sure != 1 || math.Abs(got-want) > 0.03*want {
				t.Fatalf("speed %.4f blocks/s, tempo sure %.2f, beat %.3f s; want %.4f and 1", got, state.sure, state.beat, want)
			}
		})
	}
}

// The eye stays in the streets, turns or not, and never jumps.
func TestStaysInTheStreets(t *testing.T) {
	h := load(t, nil)
	last := eye{}
	turned := 0.0
	for i := range 6000 {
		h.tick(music(128, float64(i)*tick, 1), 3, 20, tick)
		e := h.eye()
		offX := math.Abs(e.x - block*math.Round(e.x/block))
		offZ := math.Abs(e.z - block*math.Round(e.z/block))
		if offX < half+0.4 && offZ < half+0.4 {
			t.Fatalf("tick %d: the eye at %.2f, %.2f is %.2f and %.2f from the middle of a tower", i, e.x, e.z, offX, offZ)
		}
		if i > 0 {
			if d := math.Hypot(e.x-last.x, e.z-last.z); d > 0.6 {
				t.Fatalf("tick %d: the eye jumps %.2f", i, d)
			}
			turn := math.Abs(math.Remainder(e.yaw-last.yaw, 2*math.Pi))
			if turn > 0.25 {
				t.Fatalf("tick %d: the eye turns %.2f rad at once", i, turn)
			}
			turned += turn
		}
		last = e
	}
	if turned < math.Pi {
		t.Fatalf("the eye turned %.2f rad in five minutes", turned)
	}
}

// recording is a track as cliamp hands it to a plugin: the bands of each
// tick, from testdata/bands, and when its drums hit, in seconds.
type recording struct {
	bpm                 float64
	kicks, snares, hats []float64
	bands               [][10]float64
}

func readBands(t *testing.T, name string) recording {
	t.Helper()
	file, err := os.Open(filepath.Join("testdata", "bands", name+".txt"))
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	var r recording
	lines := bufio.NewScanner(file)
	lines.Buffer(nil, 1<<20)
	for lines.Scan() {
		line := lines.Text()
		key, rest, _ := strings.Cut(line, " ")
		var times []float64
		if key == "bpm" || key == "kicks" || key == "snares" || key == "hats" {
			for _, field := range strings.Fields(rest) {
				v, err := strconv.ParseFloat(field, 64)
				if err != nil {
					t.Fatal(err)
				}
				times = append(times, v)
			}
		}
		switch {
		case strings.HasPrefix(line, "#"):
		case key == "bpm":
			r.bpm = times[0]
		case key == "kicks":
			r.kicks = times
		case key == "snares":
			r.snares = times
		case key == "hats":
			r.hats = times
		default:
			var bands [10]float64
			for i := range bands {
				v, err := strconv.ParseUint(line[3*i:3*i+3], 16, 16)
				if err != nil {
					t.Fatal(err)
				}
				bands[i] = float64(v) / 4095
			}
			r.bands = append(r.bands, bands)
		}
	}
	return r
}

// The bands in testdata/bands are what cliamp makes of synthetic tracks:
// test/probe mixed the drums and ran them through the spectrum analysis of
// cliamp. The plugin must find the drums in them and the tempo.
//
// Two things it does not tell apart, as 10 bands 20 times a second do not
// show them: the body of a snare sounds like a kick, so a snare alone sends a
// pulse too; and a track without a snare gets a frame of light now and then
// from whatever else rises in the mids.
func TestHearsTheDrums(t *testing.T) {
	const warm = 4.0 // s that the plugin takes to learn the levels of a track
	for _, tc := range []struct {
		name                string
		kicks, snares, hats float64 // the share of each that it must find; -1 = it must find none
	}{
		{"house", 0.95, 0.9, 0},
		{"techno", 0.95, 0, 0},
		{"rock", 0.95, 0.9, 0},
		{"dnb", 0.9, 0.85, 0},
		{"trap", 0.9, 0.9, 0},
		{"kick", 0.95, -1, -1},
		{"snare", 0, 0.95, -1},
		{"hats", -1, -1, 0.95},
		{"nodrums", -1, -1, -1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := readBands(t, tc.name)
			h := load(t, nil)
			var found [3][]float64
			var beats, sure []float64
			last := h.numbers("__hits", 3)
			for _, bands := range r.bands {
				h.tick(bands, 3, 20, tick)
				now := h.numbers("__hits", 3)
				for i := range now {
					// A hi-hat that turned out to be a snare is taken back.
					if now[i] != last[i] && (i != 2 || now[i] > last[i]) && h.clock >= warm {
						found[i] = append(found[i], h.clock)
					}
				}
				last = now
				if 2*len(beats) >= len(r.bands)-2*len(beats) {
					state := h.flight()
					beats, sure = append(beats, state.beat), append(sure, state.sure)
				} else {
					beats = append(beats, 0)
				}
			}
			for i, row := range []struct {
				name  string
				truth []float64
				share float64
			}{{"kicks", r.kicks, tc.kicks}, {"snares", r.snares, tc.snares}, {"hi-hats", r.hats, tc.hats}} {
				// A hit is found when the plugin reacts within 160 ms of it.
				caught, total := 0, 0
				used := make([]bool, len(found[i]))
				for _, at := range row.truth {
					if at < warm {
						continue
					}
					total++
					for k, f := range found[i] {
						if !used[k] && f >= at-0.03 && f <= at+0.16 {
							used[k] = true
							caught++
							break
						}
					}
				}
				t.Logf("%s: %d of %d found, %d reactions in all", row.name, caught, total, len(found[i]))
				if row.share < 0 && len(found[i]) > 0 {
					t.Errorf("%d %s, the track has none", len(found[i]), row.name)
				}
				if row.share > 0 && float64(caught) < row.share*float64(total) {
					t.Errorf("%d of %d %s found, want %.0f%%", caught, total, row.name, 100*row.share)
				}
			}
			// The tempo, over the second half of the track.
			half := beats[len(beats)-len(sure):]
			slices.Sort(half)
			beat, want := half[len(half)/2], fold(60/r.bpm)
			mean := 0.0
			for _, v := range sure {
				mean += v / float64(len(sure))
			}
			t.Logf("beat %.3f s, want %.3f s; sure %.2f", beat, want, mean)
			if math.Abs(beat-want) > 0.04*want || mean < 0.75 {
				t.Errorf("beat %.3f s, sure %.2f; want %.3f s and at least 0.75", beat, mean, want)
			}
		})
	}
}

// A turn is an event: the eye flies straight on for a while after each one,
// however fast the track is.
func TestTurnsRarely(t *testing.T) {
	const calm = 2.5 // CALM in the plugin
	for _, bpm := range []float64{128, 174} {
		t.Run(fmt.Sprint(bpm), func(t *testing.T) {
			h := load(t, nil)
			dir, last, turns, least := 0.0, math.Inf(-1), 0, math.Inf(1)
			for i := range 6000 {
				h.tick(music(bpm, float64(i)*tick, 1), 3, 20, tick)
				if now := h.flight().dir; now != dir {
					least = min(least, h.clock-last)
					dir, last, turns = now, h.clock, turns+1
				}
			}
			t.Logf("%d turns in five minutes, at least %.2f s apart", turns, least)
			if least < calm-0.5 {
				t.Errorf("two turns %.2f s apart, want at least %.1f s", least, calm)
			}
			if turns < 30 || turns > 90 {
				t.Errorf("%d turns in five minutes, want 30 to 90", turns)
			}
		})
	}
}

// After init the plugin is as good as freshly loaded.
func TestRestart(t *testing.T) {
	used, fresh := load(t, nil), load(t, nil)
	for i := range 300 {
		used.tick(music(150, float64(i)*tick, 1), 7, 76, tick)
	}
	used.restart(7, 76)
	for i := range 240 {
		bands := music(128, float64(i)*tick, 1)
		used.tick(bands, 7, 76, tick)
		fresh.tick(bands, 7, 76, tick)
		if a, b := used.flight(), fresh.flight(); a != b {
			t.Fatalf("tick %d after init: %+v, a fresh plugin has %+v", i, a, b)
		}
		if a, b := used.eye(), fresh.eye(); a != b {
			t.Fatalf("tick %d after init: the eye %+v, a fresh plugin has %+v", i, a, b)
		}
	}
}

func TestPauseAndStop(t *testing.T) {
	h := load(t, nil)
	play := func(secs float64) {
		for i := 0; float64(i)*tick < secs; i++ {
			h.tick(music(128, h.clock, 1), 7, 76, tick)
		}
	}
	play(4)
	if h.flight().speed == 0 {
		t.Fatal("the eye does not fly")
	}

	// A pause eases the eye to rest. cliamp holds the frame number.
	h.status = "paused"
	before := h.flight().speed
	h.tick([10]float64{}, 7, 76, tick)
	if speed := h.flight().speed; speed == 0 || speed >= before {
		t.Fatalf("speed %.3f one tick into the pause, from %.3f", speed, before)
	}
	for range 80 {
		h.tick([10]float64{}, 7, 76, tick)
	}
	rest := h.flight()
	still := h.tick([10]float64{}, 7, 76, tick)
	for range 5 {
		if h.tick([10]float64{}, 7, 76, tick) != still {
			t.Fatal("the city moves at rest")
		}
	}
	if now := h.flight(); rest.speed != 0 || now.travel != rest.travel {
		t.Fatalf("speed %.3f, flew %.4f blocks at rest", rest.speed, now.travel-rest.travel)
	}

	// A stop halts it at once.
	h.status = "playing"
	play(3)
	h.status = "stopped"
	h.tick([10]float64{}, 7, 76, tick)
	if speed := h.flight().speed; speed != 0 {
		t.Fatalf("speed %.3f after a stop", speed)
	}
}

var glass = regexp.MustCompile(`\x1b\[(4[0-7]|10[0-7]|48;[25];[0-9;]+)m`)

func TestConfig(t *testing.T) {
	const floor = "\x1b[22;38;2;129;62;54m" // the default
	for _, tc := range []struct {
		name   string
		config map[string]string
		floor  string // the color code of the ground
		glass  string // the start of the code of the color behind the dots, "" for none
	}{
		{"defaults", nil, floor, "\x1b[48;2;"},
		{"index", map[string]string{"floor": "8", "tower": "14", "beat": "200", "hot": "1", "glass": "236"}, "\x1b[22;2;90m", "\x1b[48;5;236m"},
		{"hex", map[string]string{"floor": "#102030"}, "\x1b[22;38;2;21;30;39m", "\x1b[48;2;"},
		{"black ground", map[string]string{"floor": "#102030", "back": "#000000"}, "\x1b[22;38;2;10;19;29m", "\x1b[48;2;"},
		{"towers of a palette color", map[string]string{"tower": "6"}, floor, ""},
		{"dotted glass", map[string]string{"glass": "dots"}, floor, ""},
		{"flat glass", map[string]string{"glass": "8"}, floor, "\x1b[100m"},
		{"glass of its own color", map[string]string{"tower": "6", "glass": "#58C6A2"}, floor, "\x1b[48;2;"},
		{"comment after the value", map[string]string{"floor": "244  # gray", "delay_ms": "100 # ms"}, "\x1b[22;2;38;5;244m", "\x1b[48;2;"},
		{"junk", map[string]string{"floor": "abc", "tower": "#12", "beat": "-5", "hot": "", "back": "7", "delay_ms": "x", "glass": "on"}, floor, "\x1b[48;2;"},
		{"too big", map[string]string{"floor": "70000", "delay_ms": "99999999999", "glass": "70000"}, "\x1b[22;2;38;5;255m", "\x1b[48;5;255m"},
		{"escape codes", map[string]string{"floor": "7\x1b]0;x\x07", "tower": "#ffffff\x1b[2J"}, "\x1b[22;2;37m", "\x1b[48;2;"},
		{"no glass", map[string]string{"glass": "off"}, floor, ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			h := load(t, tc.config)
			out := ""
			for i := range 60 {
				out = h.tick(music(128, float64(i)*tick, 1), 7, 76, tick)
			}
			if !strings.Contains(out, tc.floor) {
				t.Errorf("no %q in the frame", tc.floor)
			}
			if got := glass.FindString(out); !strings.HasPrefix(got, tc.glass) || (tc.glass == "") != (got == "") {
				t.Errorf("glass %q in the frame, want %q", got, tc.glass)
			}
			checkFrame(t, out, 7, 76)
		})
	}
}

// themes are the themes of the plugin, with the colors of the towers, the
// ground, the frames of light and the heads of the pulses, and the
// background of the terminal that they are made for.
var themes = []struct {
	name                          string
	tower, floor, beat, hot, back string
}{
	{"mechanoonna", "#e7c07c", "#c5564a", "#d94e38", "#fff8e8", "#1c1b19"},
	{"tokyo-night", "#7dcfff", "#bb9af7", "#f7768e", "#e0af68", "#1a1b26"},
	{"catppuccin", "#cba6f7", "#89b4fa", "#f38ba8", "#f9e2af", "#1e1e2e"},
	{"gruvbox", "#8ec07c", "#83a598", "#fe8019", "#fabd2f", "#282828"},
	{"hackers", "#58c6a2", "#9375ee", "#ee75d2", "#deee75", "#000000"},
}

func rgb(t testing.TB, hex string) color.RGBA {
	t.Helper()
	n, err := strconv.ParseUint(strings.TrimPrefix(hex, "#"), 16, 32)
	if err != nil {
		t.Fatal(err)
	}
	return color.RGBA{uint8(n >> 16), uint8(n >> 8), uint8(n), 255}
}

// frame gives the frame after three seconds of music under a config.
func frame(t *testing.T, config map[string]string) string {
	t.Helper()
	h := load(t, config)
	out := ""
	for i := range 60 {
		out = h.tick(music(128, float64(i)*tick, 1), 7, 76, tick)
	}
	return out
}

// A theme is the same as its colors, key by key, and it has many names.
func TestThemes(t *testing.T) {
	for _, th := range themes {
		t.Run(th.name, func(t *testing.T) {
			want := frame(t, map[string]string{"tower": th.tower, "floor": th.floor, "beat": th.beat, "hot": th.hot, "back": th.back})
			if got := frame(t, map[string]string{"theme": th.name}); got != want {
				t.Errorf("theme %q does not have the colors %+v", th.name, th)
			}
			// The ground is the color of the theme at 0.6 of the way from the background.
			floor, back := rgb(t, th.floor), rgb(t, th.back)
			mix := func(a, b uint8) int { return int(math.Floor(float64(b) + (float64(a)-float64(b))*0.6 + 0.5)) }
			code := fmt.Sprintf("\x1b[22;38;2;%d;%d;%dm", mix(floor.R, back.R), mix(floor.G, back.G), mix(floor.B, back.B))
			if !strings.Contains(want, code) {
				t.Errorf("no ground of %q in the frame", code)
			}
			checkFrame(t, want, 7, 76)
		})
	}

	tokyo := frame(t, map[string]string{"theme": "tokyo-night"})
	for _, name := range []string{"Tokyo Night", "tokyonight", "TOKYO_NIGHT", " tokyo night  # the blue one", "tokyo-night-storm", "\"tokyo-night\""} {
		if frame(t, map[string]string{"theme": name}) != tokyo {
			t.Errorf("theme %q is not tokyo-night", name)
		}
	}
	plain := frame(t, nil)
	if frame(t, map[string]string{"theme": "mechanoonna"}) != plain {
		t.Error("the default theme is not mechanoonna")
	}
	for _, name := range []string{"no such theme", "", "#58c6a2", "tokyo", "7\x1b[2J"} {
		if frame(t, map[string]string{"theme": name}) != plain {
			t.Errorf("theme %q is not the default one", name)
		}
	}
	if tokyo == plain {
		t.Error("tokyo-night looks like mechanoonna")
	}

	// A color of the config goes before the one of the theme.
	mixed := frame(t, map[string]string{"theme": "tokyo-night", "floor": "#102030"})
	if mixed == tokyo || !strings.Contains(mixed, "\x1b[22;38;2;20;30;44m") {
		t.Error("the floor of the config does not replace the one of the theme")
	}

	// The theme of the terminal has palette colors and dotted glass.
	term := frame(t, map[string]string{"theme": "terminal"})
	if !strings.Contains(term, "\x1b[22;2;34m") || glass.FindString(term) != "" {
		t.Error("the terminal theme does not have the palette colors of the terminal")
	}
}

// With -themes=dir the test writes a picture of each theme, for the README.
func TestGallery(t *testing.T) {
	if *gallery == "" {
		t.Skip("no -themes directory")
	}
	if err := os.MkdirAll(*gallery, 0o755); err != nil {
		t.Fatal(err)
	}
	const rows, cols = 26, 100
	for _, th := range themes {
		h := load(t, map[string]string{"theme": th.name})
		out := ""
		for i, s := range scenes()["music"] {
			if float64(i)*tick > 4.2 {
				break
			}
			out = h.tick(s.bands, rows, cols, tick)
		}
		file, err := os.Create(filepath.Join(*gallery, th.name+".png"))
		if err != nil {
			t.Fatal(err)
		}
		if err := png.Encode(file, picture(out, rows, cols, rgb(t, th.back))); err != nil {
			t.Fatal(err)
		}
		file.Close()
	}
}

// Dotted glass is dots of its own: cells that are blank without it.
func TestGlassOfDots(t *testing.T) {
	cells := func(config map[string]string) int {
		h := load(t, config)
		out := ""
		for i := range 60 {
			out = h.tick(music(128, float64(i)*tick, 1), 40, 140, tick)
		}
		n := 0
		for _, cell := range colors.ReplaceAllString(out, "") {
			if cell > 0x2800 {
				n++
			}
		}
		return n
	}
	bare := cells(map[string]string{"glass": "off"})
	if shaded := cells(nil); shaded != bare {
		t.Errorf("%d cells with dots under glass of a color, %d without glass", shaded, bare)
	}
	if dotted := cells(map[string]string{"glass": "dots"}); dotted < bare+100 {
		t.Errorf("%d cells with dots under dotted glass, %d without glass", dotted, bare)
	}
}

// delay_ms holds the bands back, so a kick shows that much later.
func TestDelay(t *testing.T) {
	firstKick := func(config map[string]string) float64 {
		h := load(t, config)
		for i := range 200 {
			h.tick(music(128, float64(i)*tick, 1), 7, 76, tick)
			if h.flight().lastKick > 0 {
				return h.clock
			}
		}
		t.Fatal("no kick")
		return 0
	}
	if now, late := firstKick(nil), firstKick(map[string]string{"delay_ms": "200"}); math.Abs(late-now-0.2) > 1e-9 {
		t.Fatalf("the first kick shows at %.2f s, with a delay of 200 ms at %.2f s", now, late)
	}
}

// cliamp v2.4.0 can tick every 16 ms. The plugin still draws at most one
// frame per 40 ms and hears the same kicks.
func TestFastTicks(t *testing.T) {
	run := func(dt float64) (kicks, draws int) {
		h := load(t, nil)
		last, lastKick := "", 0.0
		for i := 0; float64(i)*dt < 20; i++ {
			out := h.tick(music(128, float64(i)*dt, 1), 7, 76, dt)
			if out != last {
				draws++
			}
			last = out
			if at := h.flight().lastKick; at != lastKick && at > 0 {
				kicks++
			}
			lastKick = h.flight().lastKick
		}
		return kicks, draws
	}
	kicks, _ := run(tick)
	fast, draws := run(0.016)
	if draws > 20/0.04+2 {
		t.Errorf("%d draws in 20 s, want at most one per 40 ms", draws)
	}
	if fast < kicks-2 || fast > kicks+2 {
		t.Errorf("%d kicks at 16 ms ticks, %d at 50 ms", fast, kicks)
	}
}

// Five minutes of music leave no number out of range.
func TestLongRun(t *testing.T) {
	h := load(t, nil)
	for i := range 6000 {
		checkFrame(t, h.tick(music(128, float64(i)*tick, 1), 3, 20, tick), 3, 20)
	}
	state := h.flight()
	for _, v := range []float64{state.beat, state.sure, state.speed, state.travel} {
		if math.IsNaN(v) || math.IsInf(v, 0) {
			t.Fatalf("%+v", state)
		}
	}
	if state.sure != 1 || state.travel < 50 {
		t.Fatalf("after five minutes: %+v", state)
	}
}

// A full-screen frame must leave most of the 50 ms that cliamp gives it.
func BenchmarkFullScreen(b *testing.B) {
	h := load(b, nil)
	for i := range 200 {
		h.tick(music(128, float64(i)*tick, 1), 40, 140, tick)
	}
	b.ResetTimer()
	for i := range b.N {
		h.tick(music(128, float64(200+i)*tick, 1), 40, 140, tick)
	}
}

// theme is the palette of the terminal in the pictures: Mechanoonna.
var theme = [16]color.RGBA{
	{0x1c, 0x1b, 0x19, 255}, {0xc5, 0x56, 0x4a, 255}, {0xa8, 0x99, 0x84, 255}, {0xeb, 0xdb, 0xb2, 255},
	{0x90, 0x8d, 0x88, 255}, {0xaf, 0xa4, 0x99, 255}, {0xd4, 0xbd, 0x99, 255}, {0xfb, 0xf1, 0xc7, 255},
	{0x6b, 0x65, 0x5c, 255}, {0xd9, 0x4e, 0x38, 255}, {0xc2, 0xa5, 0x71, 255}, {0xf7, 0xdf, 0x97, 255},
	{0xaa, 0xa0, 0x90, 255}, {0xcb, 0xae, 0x8e, 255}, {0xe7, 0xc0, 0x7c, 255}, {0xff, 0xf8, 0xe8, 255},
}

// picture paints a frame as a terminal would: 4 pixels per Braille dot.
func picture(out string, rows, cols int, ground color.RGBA) image.Image {
	const px = 4
	img := image.NewRGBA(image.Rect(0, 0, cols*2*px, rows*4*px))
	text := color.RGBA{0xf0, 0xe4, 0xc5, 255}
	fg, bg, faint := text, ground, false
	x, y := 0, 0
	for len(out) > 0 {
		if strings.HasPrefix(out, "\x1b[") {
			end := strings.IndexByte(out, 'm')
			var args []int
			for _, field := range strings.Split(out[2:end], ";") {
				n, _ := strconv.Atoi(field)
				args = append(args, n)
			}
			out = out[end+1:]
			for i := 0; i < len(args); i++ {
				switch n := args[i]; {
				case n == 0:
					fg, bg, faint = text, ground, false
				case n == 1, n == 22:
					faint = false
				case n == 2:
					faint = true
				case n == 49:
					bg = ground
				case n >= 30 && n <= 37:
					fg = theme[n-30]
				case n >= 90 && n <= 97:
					fg = theme[n-82]
				case n >= 40 && n <= 47:
					bg = theme[n-40]
				case n >= 100 && n <= 107:
					bg = theme[n-92]
				case (n == 38 || n == 48) && args[i+1] == 2:
					c := color.RGBA{uint8(args[i+2]), uint8(args[i+3]), uint8(args[i+4]), 255}
					if n == 38 {
						fg = c
					} else {
						bg = c
					}
					i += 4
				case n == 38 || n == 48:
					i += 2 // a color of the 256, not in the theme
				}
			}
			continue
		}
		if out[0] == '\n' {
			x, y, out = 0, y+1, out[1:]
			continue
		}
		cell := []rune(out[:3])[0] - 0x2800
		out = out[3:]
		for i := range 8 * px * px {
			img.Set(x*2*px+i%(2*px), y*4*px+i/(2*px), bg)
		}
		ink := fg
		if faint {
			// A faint color is halfway to the ground.
			half := func(a, b uint8) uint8 { return uint8((int(a) + int(b)) / 2) }
			ink = color.RGBA{half(fg.R, bg.R), half(fg.G, bg.G), half(fg.B, bg.B), 255}
		}
		// The dots of a cell as Braille bits, row by row.
		for k, bit := range []rune{1, 8, 2, 16, 4, 32, 64, 128} {
			if cell&bit != 0 {
				for i := range (px - 1) * (px - 1) {
					img.Set((x*2+k%2)*px+i%(px-1), (y*4+k/2)*px+i/(px-1), ink)
				}
			}
		}
		x++
	}
	return img
}

// With -shots=dir the test writes pictures of some frames, to look at.
func TestShots(t *testing.T) {
	if *shots == "" {
		t.Skip("no -shots directory")
	}
	if err := os.MkdirAll(*shots, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, shot := range []struct {
		scene      string
		cols, rows int
		at         []float64 // seconds into the scene
	}{
		{"music", 140, 40, []float64{2, 4.2, 6, 8.75, 11.1, 14}},
		{"music", 76, 7, []float64{4.2, 8.75, 11.1}},
		{"drop", 140, 40, []float64{6.4, 7, 8, 9.5}},
	} {
		h := load(t, nil)
		next := 0
		for i, s := range scenes()[shot.scene] {
			h.status = s.status
			out := h.tick(s.bands, shot.rows, shot.cols, tick)
			if next < len(shot.at) && float64(i)*tick >= shot.at[next] {
				name := fmt.Sprintf("%s-%dx%d-%04.1f.png", shot.scene, shot.cols, shot.rows, shot.at[next])
				file, err := os.Create(filepath.Join(*shots, name))
				if err != nil {
					t.Fatal(err)
				}
				if err := png.Encode(file, picture(out, shot.rows, shot.cols, theme[0])); err != nil {
					t.Fatal(err)
				}
				file.Close()
				e := h.eye()
				t.Logf("%s: eye %.1f %.1f %.1f, yaw %.2f pitch %.2f roll %.2f, %+v", name, e.x, e.y, e.z, e.yaw, e.pitch, e.roll, h.flight())
				next++
			}
		}
	}
}
