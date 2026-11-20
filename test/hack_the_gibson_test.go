// Package test runs hack-the-gibson.lua in gopher-lua, the Lua VM of cliamp,
// against fakes of the plugin and cliamp tables.
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
	"runtime"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"

	lua "github.com/yuin/gopher-lua"
)

var (
	update  = flag.Bool("update", false, "rewrite the golden frame hashes for this architecture")
	shots   = flag.String("shots", "", "write PNGs of a few frames to this directory")
	gallery = flag.String("themes", "", "write a PNG of each theme to this directory")
)

const (
	source = "../hack-the-gibson.lua"
	// Frames are not bit-identical across architectures: arm64 fuses a
	// multiply and an add, amd64 only does in some places, and a dot right on
	// a cell boundary then lands in the next cell. The hashes were recorded on
	// arm64, so TestFrames only runs there.
	golden = "testdata/frames_" + runtime.GOARCH + ".txt"
	tick   = 0.05 // seconds per cliamp tick

	block = 2.9 // BLOCK in the plugin
	half  = 0.5 // HALF in the plugin
)

// peek is appended to the plugin source so the tests can read its locals.
const peek = `
function __peek() return s.last_kick, s.beat, s.confidence, s.speed, s.travel, s.dir end
function __camera() return camera() end
function __hits() return s.pulse_count, s.scan_at, s.hat_count end
function __thump() return s.thump end
`

// host is a fake cliamp: a sandboxed VM with the plugin loaded.
type host struct {
	t      testing.TB
	L      *lua.LState
	meta   *lua.LTable // argument of plugin.register
	plugin *lua.LTable // and what it returned
	clock  float64     // os.clock, in seconds
	status string      // cliamp.player.state
	frame  int

	keys     map[string]*lua.LFunction // p:bind callbacks by key
	about    map[string]string         // and their descriptions
	commands map[string]*lua.LFunction // p:command handlers by name
	store    map[string]lua.LValue     // cliamp.store; survives a restart
	said     []string                  // cliamp.message calls
	warned   []string                  // cliamp.log.warn calls
}

// load starts the plugin with an empty store. config is its section of
// config.toml.
func load(t testing.TB, config map[string]string) *host {
	t.Helper()
	return start(t, config, map[string]lua.LValue{}, nil)
}

// start loads the plugin the way cliamp does on startup. store is what
// earlier runs left behind, taken are the keys cliamp reserves for itself.
func start(t testing.TB, config map[string]string, store map[string]lua.LValue, taken []string) *host {
	t.Helper()
	src, err := os.ReadFile(source)
	if err != nil {
		t.Fatal(err)
	}
	h := &host{
		t: t, L: lua.NewState(), status: "playing", store: store,
		keys: map[string]*lua.LFunction{}, about: map[string]string{}, commands: map[string]*lua.LFunction{},
	}
	t.Cleanup(h.L.Close)
	L := h.L

	// The same sandbox as luaplugin/sandbox.go in cliamp.
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
	kept := L.NewTable()
	kept.RawSetString("get", L.NewFunction(func(L *lua.LState) int {
		if v, ok := h.store[L.CheckString(1)]; ok {
			L.Push(v)
		} else {
			L.Push(lua.LNil)
		}
		return 1
	}))
	kept.RawSetString("set", L.NewFunction(func(L *lua.LState) int {
		h.store[L.CheckString(1)] = L.Get(2)
		return 0
	}))
	kept.RawSetString("clear", L.NewFunction(func(*lua.LState) int {
		clear(h.store)
		return 0
	}))
	logs := L.NewTable()
	logs.RawSetString("warn", L.NewFunction(func(L *lua.LState) int {
		h.warned = append(h.warned, L.CheckString(1))
		return 0
	}))
	cliamp := L.NewTable()
	cliamp.RawSetString("player", player)
	cliamp.RawSetString("store", kept)
	cliamp.RawSetString("log", logs)
	cliamp.RawSetString("message", L.NewFunction(func(L *lua.LState) int {
		h.said = append(h.said, L.CheckString(1))
		return 0
	}))
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
		// p:bind(key, description, fn). Like cliamp it lowercases the key and
		// refuses reserved ones.
		h.plugin.RawSetString("bind", L.NewFunction(func(L *lua.LState) int {
			key := strings.ToLower(strings.TrimSpace(L.CheckString(2)))
			if slices.Contains(taken, key) {
				L.Push(lua.LFalse)
				L.Push(lua.LString("key reserved by cliamp: " + key))
				return 2
			}
			h.keys[key], h.about[key] = L.CheckFunction(4), L.CheckString(3)
			L.Push(lua.LTrue)
			return 1
		}))
		h.plugin.RawSetString("command", L.NewFunction(func(L *lua.LState) int {
			h.commands[L.CheckString(2)] = L.CheckFunction(3)
			return 0
		}))
		L.Push(h.plugin)
		return 1
	}))
	L.SetGlobal("plugin", register)

	if err := L.DoString(string(src) + peek); err != nil {
		t.Fatalf("load: %v", err)
	}
	if h.plugin == nil {
		t.Fatal("plugin.register was not called")
	}
	return h
}

// draw calls render under a deadline, like cliamp does.
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

// tick advances the clock by dt and renders. Like in cliamp, the frame number
// goes up unless playback is paused.
func (h *host) tick(bands [10]float64, rows, cols int, dt float64) string {
	h.t.Helper()
	h.clock += dt
	if h.status != "paused" {
		h.frame++
	}
	return h.draw(bands, rows, cols)
}

// press triggers a key the plugin bound.
func (h *host) press(key string) {
	h.t.Helper()
	fn, ok := h.keys[key]
	if !ok {
		h.t.Fatalf("key %q is not bound; bound: %v", key, h.about)
	}
	if err := h.L.CallByParam(lua.P{Fn: fn, Protect: true}, lua.LString(key)); err != nil {
		h.t.Fatalf("key %q: %v", key, err)
	}
}

// call runs a command of the plugin, like `cliamp plugins call`.
func (h *host) call(name string, args ...string) string {
	h.t.Helper()
	fn, ok := h.commands[name]
	if !ok {
		h.t.Fatalf("no command %q", name)
	}
	list := h.L.NewTable()
	for _, arg := range args {
		list.Append(lua.LString(arg))
	}
	if err := h.L.CallByParam(lua.P{Fn: fn, NRet: 1, Protect: true}, list); err != nil {
		h.t.Fatalf("command %q: %v", name, err)
	}
	out := h.L.Get(-1)
	h.L.Pop(1)
	if out == lua.LNil {
		return ""
	}
	return out.String()
}

// restart calls init, as cliamp does when the visualizer is selected again.
func (h *host) restart(rows, cols int) {
	h.t.Helper()
	call := lua.P{Fn: h.plugin.RawGetString("init"), Protect: true}
	if err := h.L.CallByParam(call, h.plugin, lua.LNumber(rows), lua.LNumber(cols)); err != nil {
		h.t.Fatalf("init: %v", err)
	}
}

// numbers calls a Lua global that returns n numbers.
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

type flight struct{ lastKick, beat, confidence, speed, travel, dir float64 }

func (h *host) flight() flight {
	h.t.Helper()
	v := h.numbers("__peek", 6)
	return flight{v[0], v[1], v[2], v[3], v[4], v[5]}
}

type camera struct{ x, y, z, yaw, pitch, roll float64 }

func (h *host) camera() camera {
	h.t.Helper()
	v := h.numbers("__camera", 6)
	return camera{v[0], v[1], v[2], v[3], v[4], v[5]}
}

// music fakes the bands of a track at time sec: a kick on every beat, a snare
// on every other one, hats on the off-eighths. gain scales all of it.
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

// checkFrame fails unless out is rows lines of cols Braille cells with nothing
// but color codes in between.
func checkFrame(t *testing.T, out string, rows, cols int) {
	t.Helper()
	lines := strings.Split(colors.ReplaceAllString(out, ""), "\n")
	if len(lines) != rows {
		t.Fatalf("%d lines, want %d", len(lines), rows)
	}
	for _, line := range lines {
		cells := []rune(line)
		if len(cells) != cols {
			t.Fatalf("line has %d cells, want %d", len(cells), cols)
		}
		for _, cell := range cells {
			if cell < 0x2800 || cell > 0x28FF {
				t.Fatalf("%q in the frame, want only Braille", cell)
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
	// keymap is for the theme key. Nothing else should be requested.
	var permissions []string
	if list, ok := h.meta.RawGetString("permissions").(*lua.LTable); ok {
		list.ForEach(func(_, v lua.LValue) { permissions = append(permissions, v.String()) })
	}
	if !slices.Equal(permissions, []string{"keymap"}) {
		t.Errorf("permissions = %v, want only keymap", permissions)
	}
	for _, name := range []string{"render", "init"} {
		if _, ok := h.plugin.RawGetString(name).(*lua.LFunction); !ok {
			t.Errorf("plugin has no %s function", name)
		}
	}
}

// gopher-lua allows 200 locals per function, and the top level of the file
// counts as one. Keep some headroom so a small edit doesn't stop it loading.
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
		t.Fatalf("no room for 60 more top-level locals: %v", err)
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

// run turns the parts of a track into one step per cliamp tick.
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

// scenes are short runs that together exercise every effect.
func scenes() map[string][]step {
	return map[string][]step{
		"silence": run(part{1, "playing", 0}),
		"music":   run(part{15, "playing", 1}),
		"drop":    run(part{6, "playing", 0.25}, part{6, "playing", 1}),
		"breaks": run(part{5, "playing", 1}, part{1.5, "paused", 0}, part{3, "playing", 1},
			part{1, "stopped", 0}, part{3, "playing", 1}, part{1.5, "playing", 0}, part{2, "playing", 1}),
	}
}

// Golden test: one hash per scene and panel size. Run with -update after a
// change that is meant to alter the picture.
func TestFrames(t *testing.T) {
	want := map[string]string{}
	if _, err := os.Stat(golden); err != nil && !*update {
		t.Skipf("no golden frames for %s", runtime.GOARCH)
	}
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

// fold mirrors fold_period in the plugin: the beat it should settle on for a
// true beat period in seconds. The bands can't tell a beat from half or double
// of it, so the plugin takes the one between 0.35 and 0.71 s (85-170 BPM), or
// between 0.55 and 1.1 s (55-110 BPM) for calm music.
func fold(period float64, calm bool) float64 {
	least := math.Sqrt2 / 4
	if calm {
		least = 0.55
	}
	for period >= 2*least {
		period /= 2
	}
	for period < least {
		period *= 2
	}
	return period
}

// With a steady kick the camera covers one block per two beats.
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
			want := 0.5 / fold(60/bpm, false)
			if got := mean / float64(n); state.confidence != 1 || math.Abs(got-want) > 0.03*want {
				t.Fatalf("speed %.4f blocks/s, confidence %.2f, beat %.3f s; want speed %.4f and confidence 1", got, state.confidence, state.beat, want)
			}
		})
	}
}

// The camera stays in the streets, also while turning, and never jumps.
func TestStaysInTheStreets(t *testing.T) {
	h := load(t, nil)
	last := camera{}
	turned := 0.0
	for i := range 6000 {
		h.tick(music(128, float64(i)*tick, 1), 3, 20, tick)
		e := h.camera()
		offX := math.Abs(e.x - block*math.Round(e.x/block))
		offZ := math.Abs(e.z - block*math.Round(e.z/block))
		if offX < half+0.4 && offZ < half+0.4 {
			t.Fatalf("tick %d: camera at %.2f, %.2f is %.2f and %.2f from the center of a tower", i, e.x, e.z, offX, offZ)
		}
		if i > 0 {
			if d := math.Hypot(e.x-last.x, e.z-last.z); d > 0.6 {
				t.Fatalf("tick %d: camera jumped %.2f", i, d)
			}
			turn := math.Abs(math.Remainder(e.yaw-last.yaw, 2*math.Pi))
			if turn > 0.25 {
				t.Fatalf("tick %d: camera turned %.2f rad in one tick", i, turn)
			}
			turned += turn
		}
		last = e
	}
	if turned < math.Pi {
		t.Fatalf("camera only turned %.2f rad in five minutes", turned)
	}
}

// recording is a track from testdata/bands: the bands cliamp produced for
// each tick, and the times of its drum hits in seconds.
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

// testdata/bands holds what the spectrum analysis of cliamp makes of synthetic
// drum tracks (recorded by test/probe). The plugin has to find the drums and
// the tempo in them.
//
// 10 bands at 20 Hz can't separate everything: the body of a snare looks like
// a kick, so a lone snare also counts as kicks, and a track without a snare
// gets the odd snare from whatever else moves in the mids. Those cases have
// a share of 0, which checks nothing.
func TestHearsTheDrums(t *testing.T) {
	const warm = 4.0 // seconds the plugin needs to learn the levels of a track
	for _, tc := range []struct {
		name                string
		kicks, snares, hats float64 // share that must be found; -1 = none may be found
		calm                bool    // nothing in the top bands, so the slow tempo range applies
	}{
		{"house", 0.95, 0.9, 0, false},
		{"techno", 0.95, 0, 0, false},
		{"rock", 0.95, 0.9, 0, false},
		{"dnb", 0.9, 0.85, 0, false},
		{"trap", 0.9, 0.9, 0, false},
		{"kick", 0.95, -1, -1, true},
		{"snare", 0, 0.95, -1, false},
		{"hats", -1, -1, 0.95, false},
		{"nodrums", -1, -1, -1, true},
		{"lofi", 0.75, 0.5, 0, true}, // soft drums
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := readBands(t, tc.name)
			h := load(t, nil)
			var found [3][]float64
			var beats, confidence []float64
			last := h.numbers("__hits", 3)
			for n, bands := range r.bands {
				h.tick(bands, 3, 20, tick)
				now := h.numbers("__hits", 3)
				for i := range now {
					// The hat counter goes down again when a hat turns out to
					// be the start of a snare.
					if now[i] != last[i] && (i != 2 || now[i] > last[i]) && h.clock >= warm {
						found[i] = append(found[i], h.clock)
					}
				}
				last = now
				// The tempo needs a while to settle, so skip the first quarter.
				if 4*n >= len(r.bands) {
					state := h.flight()
					beats, confidence = append(beats, state.beat), append(confidence, state.confidence)
				}
			}
			for i, row := range []struct {
				name  string
				truth []float64
				share float64
			}{{"kicks", r.kicks, tc.kicks}, {"snares", r.snares, tc.snares}, {"hi-hats", r.hats, tc.hats}} {
				// A hit counts as found if the plugin reacts within 160 ms.
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
				t.Logf("%s: found %d of %d, %d detections in total", row.name, caught, total, len(found[i]))
				if row.share < 0 && len(found[i]) > 0 {
					t.Errorf("%d %s detected, the track has none", len(found[i]), row.name)
				}
				if row.share > 0 && float64(caught) < row.share*float64(total) {
					t.Errorf("found %d of %d %s, want %.0f%%", caught, total, row.name, 100*row.share)
				}
			}
			// Median beat and mean confidence over the rest.
			slices.Sort(beats)
			beat, want := beats[len(beats)/2], fold(60/r.bpm, tc.calm)
			mean := 0.0
			for _, v := range confidence {
				mean += v / float64(len(confidence))
			}
			t.Logf("beat %.3f s, want %.3f s; confidence %.2f", beat, want, mean)
			if math.Abs(beat-want) > 0.04*want || mean < 0.75 {
				t.Errorf("beat %.3f s, confidence %.2f; want %.3f s and at least 0.75", beat, mean, want)
			}
		})
	}
}

// The beat pulse is high around the kicks and low in between, also where a
// kick wasn't detected. The pulse option scales how much of it is drawn.
func TestPulseOfTheBeat(t *testing.T) {
	for _, name := range []string{"house", "rock", "lofi"} {
		t.Run(name, func(t *testing.T) {
			r := readBands(t, name)
			h := load(t, nil)
			var pulse []float64
			for _, bands := range r.bands {
				h.tick(bands, 3, 20, tick)
				pulse = append(pulse, h.numbers("__thump", 1)[0])
			}
			// Every beat of the track from its first kick on, kick or not.
			beat := 60 / r.bpm
			on, off, beats := 0.0, 0.0, 0
			for at := r.kicks[0]; at < float64(len(pulse))*tick-beat; at += beat {
				if at < 8 {
					continue // the tempo hasn't locked yet
				}
				// The peak within 150 ms of the beat, and the value half a
				// beat later.
				most := 0.0
				for i := int(at / tick); i <= int((at+0.15)/tick); i++ {
					most = max(most, pulse[i])
				}
				on, off, beats = on+most, off+pulse[int((at+beat/2+0.1)/tick)], beats+1
			}
			on, off = on/float64(beats), off/float64(beats)
			t.Logf("pulse %.2f on the beat, %.2f between two beats", on, off)
			if on < 0.5 || off > 0.5*on {
				t.Errorf("pulse %.2f on the beat and %.2f between two beats", on, off)
			}
		})
	}

	// pulse = 0 has to make a visible difference.
	r := readBands(t, "house")
	loud, mute := load(t, nil), load(t, map[string]string{"pulse": "0"})
	differs := 0
	for _, bands := range r.bands {
		if loud.tick(bands, 26, 100, tick) != mute.tick(bands, 26, 100, tick) {
			differs++
		}
	}
	if differs < len(r.bands)/3 {
		t.Errorf("pulse = 0 only changes %d of %d frames", differs, len(r.bands))
	}
}

// Lo-fi at 75 BPM should take a block per two beats, not per two eighths,
// and not get faster over the minutes.
func TestCalmMusicFliesSlowly(t *testing.T) {
	r := readBands(t, "lofi")
	h := load(t, nil)
	var minute [5]float64
	const ticks = 60 / tick
	for i := range int(5 * ticks) {
		// The recording is 30 s long, so loop it.
		h.tick(r.bands[i%len(r.bands)], 3, 20, tick)
		minute[int(float64(i)/ticks)] += h.flight().speed / ticks
	}
	t.Logf("blocks/s, minute by minute: %.2f", minute)
	want := r.bpm / 60 / 2
	for i, speed := range minute[1:] {
		if math.Abs(speed-want) > 0.08*want {
			t.Errorf("minute %d: %.2f blocks/s, want %.2f", i+2, speed, want)
		}
	}
	if minute[4] > 1.05*minute[1] {
		t.Errorf("the flight speeds up: %.2f blocks/s in minute 5, %.2f in minute 2", minute[4], minute[1])
	}

	// The speed option scales it.
	slow := load(t, map[string]string{"speed": "0.5"})
	mean := 0.0
	for i := range int(2 * ticks) {
		slow.tick(r.bands[i%len(r.bands)], 3, 20, tick)
		if i >= int(ticks) {
			mean += slow.flight().speed / ticks
		}
	}
	if math.Abs(mean-minute[1]/2) > 0.05*minute[1] {
		t.Errorf("speed = 0.5 gives %.2f blocks/s, want half of %.2f", mean, minute[1])
	}
}

// After a turn the camera flies straight for a while, however fast the
// track is.
func TestTurnsRarely(t *testing.T) {
	const gap = 2.5 // TURN_GAP in the plugin
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
			if least < gap-0.5 {
				t.Errorf("two turns %.2f s apart, want at least %.1f s", least, gap)
			}
			if turns < 30 || turns > 90 {
				t.Errorf("%d turns in five minutes, want 30 to 90", turns)
			}
		})
	}
}

// init resets everything: afterwards the plugin behaves like a fresh one.
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
		if a, b := used.camera(), fresh.camera(); a != b {
			t.Fatalf("tick %d after init: camera %+v, a fresh plugin has %+v", i, a, b)
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
		t.Fatal("the camera is not moving")
	}

	// A pause eases the camera to a stop. cliamp holds the frame number.
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
			t.Fatal("the frame changes at rest")
		}
	}
	if now := h.flight(); rest.speed != 0 || now.travel != rest.travel {
		t.Fatalf("speed %.3f, moved %.4f blocks at rest", rest.speed, now.travel-rest.travel)
	}

	// A stop halts it right away.
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
	const floor = "\x1b[22;38;2;64;62;116m" // hackers, the default
	const mechanoonna = "\x1b[22;38;2;129;62;54m"
	for _, tc := range []struct {
		name   string
		config map[string]string
		floor  string // escape sequence of the ground
		glass  string // prefix of the glass background sequence, "" for none
	}{
		{"defaults", nil, floor, "\x1b[48;2;"},
		{"index", map[string]string{"floor": "8", "tower": "14", "beat": "200", "hot": "1", "glass": "236"}, "\x1b[22;2;90m", "\x1b[48;5;236m"},
		{"hex", map[string]string{"floor": "#102030"}, "\x1b[22;38;2;10;20;35m", "\x1b[48;2;"},
		{"black ground", map[string]string{"floor": "#102030", "back": "#000000"}, "\x1b[22;38;2;10;19;29m", "\x1b[48;2;"},
		{"palette towers", map[string]string{"theme": "mechanoonna", "tower": "6"}, mechanoonna, ""}, // a theme without a glass color
		{"dotted glass", map[string]string{"glass": "dots"}, floor, ""},
		{"flat glass", map[string]string{"glass": "8"}, floor, "\x1b[100m"},
		{"glass color", map[string]string{"tower": "6", "glass": "#58C6A2"}, floor, "\x1b[48;2;"},
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
				t.Errorf("frame has no %q", tc.floor)
			}
			if got := glass.FindString(out); !strings.HasPrefix(got, tc.glass) || (tc.glass == "") != (got == "") {
				t.Errorf("glass %q in the frame, want %q", got, tc.glass)
			}
			checkFrame(t, out, 7, 76)
		})
	}
}

// themes mirrors THEMES in the plugin, in the order the theme key cycles
// through. terminal is missing because it has no RGB colors.
var themes = []struct {
	name, title                   string
	tower, floor, beat, hot, back string
	glass, drop                   string
}{
	{"hackers", "Hackers", "#81e3e8", "#6a66b7", "#a054e2", "#e6fdff", "#00020f", "#50c3bc", "#b75049"},
	{"mechanoonna", "Mechanoonna", "#e7c07c", "#c5564a", "#d94e38", "#fff8e8", "#1c1b19", "", ""},
	{"tokyo-night", "Tokyo Night", "#7dcfff", "#bb9af7", "#f7768e", "#e0af68", "#1a1b26", "", ""},
	{"catppuccin", "Catppuccin", "#cba6f7", "#89b4fa", "#f38ba8", "#f9e2af", "#1e1e2e", "", ""},
	{"gruvbox", "Gruvbox", "#8ec07c", "#83a598", "#fe8019", "#fabd2f", "#282828", "", ""},
	{"kode", "Kode", "#58c6a2", "#9375ee", "#ee75d2", "#deee75", "#000000", "", ""},
}

func rgb(t testing.TB, hex string) color.RGBA {
	t.Helper()
	n, err := strconv.ParseUint(strings.TrimPrefix(hex, "#"), 16, 32)
	if err != nil {
		t.Fatal(err)
	}
	return color.RGBA{uint8(n >> 16), uint8(n >> 8), uint8(n), 255}
}

// frame returns the frame after three seconds of music with a config.
func frame(t *testing.T, config map[string]string) string {
	t.Helper()
	h := load(t, config)
	out := ""
	for i := range 60 {
		out = h.tick(music(128, float64(i)*tick, 1), 7, 76, tick)
	}
	return out
}

// A theme looks exactly like its colors set one by one, and is found under
// every spelling of its name.
func TestThemes(t *testing.T) {
	for _, th := range themes {
		t.Run(th.name, func(t *testing.T) {
			// Without a glass or drop color of its own, a theme uses tower and
			// beat. Set them anyway, or the default theme's would apply.
			colors := map[string]string{
				"tower": th.tower, "floor": th.floor, "beat": th.beat, "hot": th.hot, "back": th.back,
				"glass": th.tower, "drop": th.beat,
			}
			if th.glass != "" {
				colors["glass"], colors["drop"] = th.glass, th.drop
			}
			want := frame(t, colors)
			if got := frame(t, map[string]string{"theme": th.name}); got != want {
				t.Errorf("theme %q does not match its colors %+v", th.name, th)
			}
			// The ground is drawn at 60% of the way from the background to floor.
			floor, back := rgb(t, th.floor), rgb(t, th.back)
			mix := func(a, b uint8) int { return int(math.Floor(float64(b) + (float64(a)-float64(b))*0.6 + 0.5)) }
			code := fmt.Sprintf("\x1b[22;38;2;%d;%d;%dm", mix(floor.R, back.R), mix(floor.G, back.G), mix(floor.B, back.B))
			if !strings.Contains(want, code) {
				t.Errorf("frame has no ground color %q", code)
			}
			checkFrame(t, want, 7, 76)
		})
	}

	tokyo := frame(t, map[string]string{"theme": "tokyo-night"})
	for _, name := range []string{"Tokyo Night", "tokyonight", "TOKYO_NIGHT", " tokyo night  # the blue one", "tokyo-night-storm"} {
		if frame(t, map[string]string{"theme": name}) != tokyo {
			t.Errorf("theme %q should be tokyo-night", name)
		}
	}
	plain := frame(t, nil)
	if frame(t, map[string]string{"theme": "hackers"}) != plain {
		t.Error("the default theme should be hackers")
	}
	for _, name := range []string{"no such theme", "", "#58c6a2", "tokyo", "7\x1b[2J"} {
		if frame(t, map[string]string{"theme": name}) != plain {
			t.Errorf("theme %q should fall back to the default", name)
		}
	}
	if tokyo == plain {
		t.Error("tokyo-night looks like the default theme")
	}

	// A color in the config overrides the one of the theme.
	mixed := frame(t, map[string]string{"theme": "tokyo-night", "floor": "#102030"})
	if mixed == tokyo || !strings.Contains(mixed, "\x1b[22;38;2;20;30;44m") {
		t.Error("floor in the config does not override the theme")
	}

	// terminal uses palette colors and dotted glass.
	term := frame(t, map[string]string{"theme": "terminal"})
	if !strings.Contains(term, "\x1b[22;2;34m") || glass.FindString(term) != "" {
		t.Error("the terminal theme does not use palette colors")
	}

	// An unknown name is logged, an empty one is not.
	if h := load(t, map[string]string{"theme": "No Such Theme"}); len(h.warned) != 1 || !strings.Contains(h.warned[0], "nosuchtheme") {
		t.Errorf("warnings for an unknown theme: %q", h.warned)
	}
	if h := load(t, nil); len(h.warned) != 0 {
		t.Errorf("warnings without a config: %q", h.warned)
	}
}

// The theme key cycles through the themes, and the pick survives a restart.
// Between the key and the config, whichever changed last wins.
func TestThemeKey(t *testing.T) {
	// after returns the frame after three seconds of music and some presses.
	after := func(h *host, presses int) string {
		t.Helper()
		warmUp(h)
		for range presses {
			h.press("ctrl+t")
		}
		return nextFrame(h)
	}
	names := []string{"hackers", "mechanoonna", "tokyo-night", "catppuccin", "gruvbox", "kode", "terminal"}
	titles := []string{"Hackers", "Mechanoonna", "Tokyo Night", "Catppuccin", "Gruvbox", "Kode", "Terminal"}
	for presses := range len(names) + 2 {
		want := names[presses%len(names)]
		h := load(t, nil)
		if got := after(h, presses); got != after(load(t, map[string]string{"theme": want}), 0) {
			t.Errorf("%d presses should give the theme %s", presses, want)
		}
		if presses > 0 {
			if said := h.said[len(h.said)-1]; said != "Hack the Gibson: "+titles[presses%len(names)] {
				t.Errorf("status message after %d presses: %q", presses, said)
			}
		}
	}
	if about := load(t, nil).about["ctrl+t"]; about != "Next theme" {
		t.Errorf("key description: %q", about)
	}

	// The new theme shows right away, also while stopped.
	h := load(t, nil)
	h.status = "stopped"
	before := h.tick([10]float64{}, 7, 76, tick)
	h.press("ctrl+t")
	if h.tick([10]float64{}, 7, 76, tick) == before {
		t.Error("a press does not show while stopped")
	}

	// The pick survives a restart.
	store := map[string]lua.LValue{}
	h = start(t, nil, store, nil)
	h.press("ctrl+t")
	h.press("ctrl+t")
	twoOn := after(load(t, map[string]string{"theme": names[2]}), 0)
	if after(start(t, nil, store, nil), 0) != twoOn {
		t.Error("the picked theme is gone after a restart")
	}
	// A config change after that wins, and a press after that wins again.
	gruvbox := map[string]string{"theme": "gruvbox"}
	if after(start(t, gruvbox, store, nil), 0) != after(load(t, gruvbox), 0) {
		t.Error("the picked theme hides a later config change")
	}
	h = start(t, gruvbox, store, nil)
	h.press("ctrl+t")
	kode := after(load(t, map[string]string{"theme": "kode"}), 0) // the one after gruvbox
	if after(start(t, gruvbox, store, nil), 0) != kode {
		t.Error("a pick made after a config change is gone after a restart")
	}
	// A pick that lost against the config stays gone, also when the config
	// goes back to the theme it had when the pick was made.
	store = map[string]lua.LValue{}
	start(t, gruvbox, store, nil).press("ctrl+t")
	start(t, map[string]string{"theme": "catppuccin"}, store, nil)
	if after(start(t, gruvbox, store, nil), 0) != after(load(t, gruvbox), 0) {
		t.Error("an old pick came back when the config was set back")
	}
	// Junk in the store gives the default theme.
	for _, junk := range []lua.LValue{lua.LString("no such theme"), lua.LNumber(7), lua.LTrue} {
		odd := map[string]lua.LValue{"theme": junk, "config": lua.LString("")}
		if after(start(t, nil, odd, nil), 0) != after(load(t, nil), 0) {
			t.Errorf("%v in the store should give the default theme", junk)
		}
	}

	// theme_key sets another key, or none. A key reserved by cliamp stays unbound.
	for _, tc := range []struct {
		key, bound string
		taken      []string
	}{
		{"ctrl+n", "ctrl+n", nil},
		{" Ctrl+N  # next", "ctrl+n", nil},
		{"off", "", nil},
		{"", "", nil},
		{"ctrl+t", "", []string{"ctrl+t"}},
	} {
		h := start(t, map[string]string{"theme_key": tc.key}, map[string]lua.LValue{}, tc.taken)
		var bound []string
		for key := range h.keys {
			bound = append(bound, key)
		}
		if tc.bound == "" && len(bound) > 0 || tc.bound != "" && !slices.Equal(bound, []string{tc.bound}) {
			t.Errorf("theme_key %q binds %v, want %q", tc.key, bound, tc.bound)
		}
		checkFrame(t, h.tick(music(128, 0, 1), 7, 76, tick), 7, 76)
	}
}

// `cliamp plugins call "Hack the Gibson" theme [name]` sets a theme or lists them.
func TestThemeCommand(t *testing.T) {
	h, want := load(t, nil), load(t, map[string]string{"theme": "tokyo-night"})
	warmUp(h)
	warmUp(want)
	if out := h.call("theme", "Tokyo Night"); out != "Tokyo Night" {
		t.Errorf("the command returned %q", out)
	}
	if nextFrame(h) != nextFrame(want) {
		t.Error("the command did not set the theme")
	}
	list := h.call("theme")
	if !strings.Contains(list, "* Tokyo Night") || !strings.Contains(list, "  Hackers") {
		t.Errorf("the command listed\n%s", list)
	}
	if h.call("theme", "no such theme") != list {
		t.Error("an unknown name should list the themes")
	}
}

// warmUp plays three seconds of music.
func warmUp(h *host) {
	h.t.Helper()
	for i := range 60 {
		h.tick(music(128, float64(i)*tick, 1), 7, 76, tick)
	}
}

// nextFrame returns the frame of the tick after warmUp.
func nextFrame(h *host) string {
	h.t.Helper()
	return h.tick(music(128, 3, 1), 7, 76, tick)
}

// With -themes=dir this writes the theme screenshots of the README.
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

// Dotted glass puts dots into cells that are blank otherwise. Colored glass
// must not add any.
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
		t.Errorf("%d cells with dots with colored glass, %d without glass", shaded, bare)
	}
	if dotted := cells(map[string]string{"glass": "dots"}); dotted < bare+100 {
		t.Errorf("%d cells with dots with dotted glass, %d without glass", dotted, bare)
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
		t.Fatalf("first kick at %.2f s, with delay_ms = 200 at %.2f s", now, late)
	}
}

// cliamp v2.4.0 can tick every 16 ms. The plugin should still draw at most
// once per 40 ms and find the same kicks.
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

// Five minutes of music: no NaN or Inf anywhere, and the tempo stays locked.
func TestLongRun(t *testing.T) {
	h := load(t, nil)
	for i := range 6000 {
		checkFrame(t, h.tick(music(128, float64(i)*tick, 1), 3, 20, tick), 3, 20)
	}
	state := h.flight()
	for _, v := range []float64{state.beat, state.confidence, state.speed, state.travel} {
		if math.IsNaN(v) || math.IsInf(v, 0) {
			t.Fatalf("%+v", state)
		}
	}
	if state.confidence != 1 || state.travel < 50 {
		t.Fatalf("after five minutes: %+v", state)
	}
}

// cliamp gives render 50 ms. A full-screen frame should stay well below that.
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

// palette is the 16 terminal colors used for the PNGs: Mechanoonna.
var palette = [16]color.RGBA{
	{0x1c, 0x1b, 0x19, 255}, {0xc5, 0x56, 0x4a, 255}, {0xa8, 0x99, 0x84, 255}, {0xeb, 0xdb, 0xb2, 255},
	{0x90, 0x8d, 0x88, 255}, {0xaf, 0xa4, 0x99, 255}, {0xd4, 0xbd, 0x99, 255}, {0xfb, 0xf1, 0xc7, 255},
	{0x6b, 0x65, 0x5c, 255}, {0xd9, 0x4e, 0x38, 255}, {0xc2, 0xa5, 0x71, 255}, {0xf7, 0xdf, 0x97, 255},
	{0xaa, 0xa0, 0x90, 255}, {0xcb, 0xae, 0x8e, 255}, {0xe7, 0xc0, 0x7c, 255}, {0xff, 0xf8, 0xe8, 255},
}

// picture renders a frame like a terminal would, with 4 pixels per Braille dot.
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
					fg = palette[n-30]
				case n >= 90 && n <= 97:
					fg = palette[n-82]
				case n >= 40 && n <= 47:
					bg = palette[n-40]
				case n >= 100 && n <= 107:
					bg = palette[n-92]
				case (n == 38 || n == 48) && args[i+1] == 2:
					c := color.RGBA{uint8(args[i+2]), uint8(args[i+3]), uint8(args[i+4]), 255}
					if n == 38 {
						fg = c
					} else {
						bg = c
					}
					i += 4
				case n == 38 || n == 48:
					i += 2 // 256-color index: not in the palette, ignored
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
			// Faint is drawn halfway to the background.
			half := func(a, b uint8) uint8 { return uint8((int(a) + int(b)) / 2) }
			ink = color.RGBA{half(fg.R, bg.R), half(fg.G, bg.G), half(fg.B, bg.B), 255}
		}
		// Braille bit of each dot, row by row.
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

// With -shots=dir this writes PNGs of a few frames, to check the picture
// without cliamp.
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
		// Kicks are 0.469 s apart here: one shot right after a kick, one between two.
		{"music", 100, 26, []float64{12.2, 12.45}},
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
				if err := png.Encode(file, picture(out, shot.rows, shot.cols, rgb(t, themes[0].back))); err != nil {
					t.Fatal(err)
				}
				file.Close()
				e := h.camera()
				t.Logf("%s: camera %.1f %.1f %.1f, yaw %.2f pitch %.2f roll %.2f, %+v", name, e.x, e.y, e.z, e.yaw, e.pitch, e.roll, h.flight())
				next++
			}
		}
	}
}
