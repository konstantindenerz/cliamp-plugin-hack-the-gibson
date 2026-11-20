// probe tells how well the plugin hears the drums and the tempo of a track.
// It feeds PCM through the spectrum analysis of cliamp, tick by tick as the
// player does, into the plugin, and compares the hits that the plugin finds
// with the ones in the track.
//
//	go run . ../../hackthegibson.lua               # synthetic tracks, with the true hits
//	go run . -record ../testdata/bands ../../hackthegibson.lua
//	go run . -pcm dir ../../hackthegibson.lua      # real music: *.f32, mono, 44.1 kHz
//	go run . -tap latest ../../hackthegibson.lua   # what a plugin got before cliamp#738
//
// It is a module of its own, as it needs a checkout of cliamp: see go.mod.
package main

import (
	"encoding/binary"
	"flag"
	"fmt"
	"math"
	"math/cmplx"
	"math/rand"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/bjarneo/cliamp/ui"
	lua "github.com/yuin/gopher-lua"
)

const (
	sr   = 44100
	tick = 0.05 // s between two ticks of cliamp
	warm = 4.0  // s that the plugin takes to learn the levels of a track
)

var (
	record  = flag.String("record", "", "write the bands of the synthetic tracks to this directory")
	pcmDir  = flag.String("pcm", "", "run the *.f32 files of this directory instead of the synthetic tracks")
	tap     = flag.String("tap", "audible", "the tap of cliamp: audible (cliamp#738) or latest (before it)")
	verbose = flag.Bool("v", false, "show the rise of each band at the hits")
)

// peek lets the probe read the state that the plugin keeps to itself.
const peek = `
function __hits() return s.pulsed, s.scanAt, s.struck, s.beat, s.sure, s.speed end
`

// host stands in for cliamp: it runs the plugin when the visualizer of
// cliamp asks for a frame.
type host struct {
	L      *lua.LState
	plugin *lua.LTable
	clock  float64
	bands  [ui.DefaultSpectrumBands]float64
}

func (h *host) InitVis(string, int, int) {}
func (h *host) DestroyVis(string)        {}

func (h *host) RenderVis(_ string, bands [ui.DefaultSpectrumBands]float64, rows, cols int, frame uint64) string {
	h.bands = bands
	L := h.L
	levels := L.NewTable()
	for i, b := range bands {
		levels.RawSetInt(i+1, lua.LNumber(b))
	}
	call := lua.P{Fn: h.plugin.RawGetString("render"), NRet: 1, Protect: true}
	if err := L.CallByParam(call, h.plugin, levels, lua.LNumber(frame), lua.LNumber(rows), lua.LNumber(cols)); err != nil {
		panic(err)
	}
	out := L.Get(-1).String()
	L.Pop(1)
	return out
}

func (h *host) state() []float64 {
	L := h.L
	const n = 6
	if err := L.CallByParam(lua.P{Fn: L.GetGlobal("__hits"), NRet: n, Protect: true}); err != nil {
		panic(err)
	}
	v := make([]float64, n)
	for i := range v {
		v[i] = float64(L.Get(i - n).(lua.LNumber))
	}
	L.Pop(n)
	return v
}

func load(path string) *host {
	src, err := os.ReadFile(path)
	if err != nil {
		panic(err)
	}
	h := &host{L: lua.NewState()}
	L := h.L
	L.GetGlobal("os").(*lua.LTable).RawSetString("clock", L.NewFunction(func(L *lua.LState) int {
		L.Push(lua.LNumber(h.clock))
		return 1
	}))
	player := L.NewTable()
	player.RawSetString("state", L.NewFunction(func(L *lua.LState) int { L.Push(lua.LString("playing")); return 1 }))
	cliamp := L.NewTable()
	cliamp.RawSetString("player", player)
	L.SetGlobal("cliamp", cliamp)
	register := L.NewTable()
	register.RawSetString("register", L.NewFunction(func(L *lua.LState) int {
		h.plugin = L.NewTable()
		h.plugin.RawSetString("config", L.NewFunction(func(L *lua.LState) int { L.Push(lua.LNil); return 1 }))
		L.Push(h.plugin)
		return 1
	}))
	L.SetGlobal("plugin", register)
	if err := L.DoString(string(src) + peek); err != nil {
		panic(err)
	}
	return h
}

// result is what the plugin made of a track.
type result struct {
	kicks, snares, hats []float64                          // when it found a hit, in s
	beat, sure, speed   []float64                          // per tick
	bands               [][ui.DefaultSpectrumBands]float64 // per tick, as the plugin got them
}

// play runs pcm through the analysis of cliamp and the plugin, tick by tick.
func play(path string, pcm []float64) result {
	h := load(path)
	v := ui.NewVisualizer(sr)
	v.Rows, v.Cols = 3, 20
	v.RegisterLuaVisualizers([]string{"probe"}, h)
	mode, _ := v.ModeByName("probe")
	v.SetMode(mode)
	base := time.Unix(1_700_000_000, 0)
	var r result
	last := h.state()
	for at := tick; at < float64(len(pcm))/sr; at += tick {
		end := int(at * sr)
		if *tap == "latest" {
			// Before cliamp#738 a plugin got the frames that the decoder handed
			// to the audio device last: the device takes them an eighth of a
			// second at a time, one to two eighths ahead of the sound.
			end = min(len(pcm), int((math.Floor(at/0.125)+2)*0.125*sr))
		}
		start := max(0, end-2048)
		now := base.Add(time.Duration(at * float64(time.Second)))
		v.Tick(ui.VisTickContext{Now: now, Playing: true, Analyze: func(spec ui.VisAnalysisSpec) []float64 {
			return v.Analyze(pcm[start:end], spec)
		}})
		h.clock = at
		v.Render()
		r.bands = append(r.bands, h.bands)
		s := h.state()
		if s[0] != last[0] {
			r.kicks = append(r.kicks, at)
		}
		if s[1] != last[1] {
			r.snares = append(r.snares, at)
		}
		if s[2] > last[2] {
			r.hats = append(r.hats, at)
		}
		r.beat, r.sure, r.speed = append(r.beat, s[3]), append(r.sure, s[4]), append(r.speed, s[5])
		last = s
	}
	return r
}

// track is a mix and the times of its hits.
type track struct {
	name, file          string
	bpm                 float64
	pcm                 []float64
	kicks, snares, hats []float64
}

type hit struct {
	at   float64 // in beats
	gain float64
}

// build mixes a track of secs seconds from patterns of one bar of 4 beats.
// sub makes the kick an 808: a kick that is the bass too.
func build(file, name string, bpm, secs float64, kicks, snares, hats []hit, bass, pad float64, sub bool) track {
	rng := rand.New(rand.NewSource(1))
	n := int(secs * sr)
	pcm := make([]float64, n)
	beat := 60 / bpm
	t := track{name: name, file: file, bpm: bpm, pcm: pcm}
	add := func(at float64, length float64, f func(sec float64) float64) {
		start := int(at * sr)
		for i := 0; i < int(length*sr) && start+i < n; i++ {
			pcm[start+i] += f(float64(i) / sr)
		}
	}
	for bar := 0; bar < int(secs/(4*beat)); bar++ {
		origin := float64(bar) * 4 * beat
		for _, k := range kicks {
			at := origin + k.at*beat
			t.kicks = append(t.kicks, at)
			phase, tail := 0.0, 0.12
			if sub {
				tail = 0.45
			}
			add(at, tail*4, func(sec float64) float64 {
				// A tone that falls from 158 to 48 Hz, and a click.
				phase += 2 * math.Pi * (48 + 110*math.Exp(-sec/0.03)) / sr
				click := 0.0
				if sec < 0.004 {
					click = 0.4 * (rng.Float64()*2 - 1)
				}
				return k.gain * (0.9*math.Sin(phase)*math.Exp(-sec/tail) + click)
			})
		}
		for _, s := range snares {
			at := origin + s.at*beat
			t.snares = append(t.snares, at)
			last := 0.0
			add(at, 0.35, func(sec float64) float64 {
				// A body at 190 Hz, and noise without its lows.
				white := rng.Float64()*2 - 1
				high := white - 0.85*last
				last = white
				return s.gain * (0.35*math.Sin(2*math.Pi*190*sec)*math.Exp(-sec/0.07) + 0.45*high*math.Exp(-sec/0.1))
			})
		}
		for _, hh := range hats {
			at := origin + hh.at*beat
			t.hats = append(t.hats, at)
			a, b := 0.0, 0.0
			add(at, 0.12, func(sec float64) float64 {
				// Noise, twice differenced: only its top is left.
				white := rng.Float64()*2 - 1
				d1 := white - a
				a = white
				d2 := d1 - b
				b = d1
				return hh.gain * 0.16 * d2 * math.Exp(-sec/0.025)
			})
		}
		root := []float64{55, 55, 65.4, 49}[bar%4]
		for q := 0; q < 8 && bass > 0; q++ {
			add(origin+float64(q)*beat/2+0.02, beat/2-0.03, func(sec float64) float64 {
				env := math.Min(1, sec/0.01) * math.Exp(-sec/0.25)
				return bass * env * (math.Sin(2*math.Pi*root*sec) + 0.4*math.Sin(2*math.Pi*2*root*sec) + 0.2*math.Sin(2*math.Pi*3*root*sec))
			})
		}
		if pad > 0 {
			add(origin, 4*beat, func(sec float64) float64 {
				sum := 0.0
				for _, f := range []float64{220, 277.2, 329.6, 440, 880, 1318} {
					sum += math.Sin(2 * math.Pi * f * sec)
				}
				return pad * sum * (0.8 + 0.2*math.Sin(2*math.Pi*0.3*sec))
			})
		}
	}
	for i := range pcm {
		pcm[i] = math.Tanh(0.8 * pcm[i]) // the limiter of a master
	}
	return t
}

func tracks(secs float64) []track {
	four := []hit{{0, 1}, {1, 1}, {2, 1}, {3, 1}}
	backbeat := []hit{{1, 1}, {3, 1}}
	off8 := []hit{{0.5, 1}, {1.5, 1}, {2.5, 1}, {3.5, 1}}
	var all8, all16 []hit
	for i := range 8 {
		all8 = append(all8, hit{float64(i) / 2, 0.7 + 0.3*float64(i%2)})
	}
	for i := range 16 {
		all16 = append(all16, hit{float64(i) / 4, 0.5 + 0.5*float64((i+1)%2)})
	}
	return []track{
		build("house", "house: 4 kicks, clap 2+4, offbeat hats", 128, secs, four, backbeat, off8, 0.25, 0.03, false),
		build("techno", "techno: 4 kicks, 16th hats, no snare", 138, secs, four, nil, all16, 0.3, 0.02, false),
		build("rock", "rock: kick 1+3, snare 2+4, 8th hats", 100, secs, []hit{{0, 1}, {2, 1}, {2.5, 0.8}}, backbeat, all8, 0.25, 0.04, false),
		build("dnb", "dnb: break, 16th hats", 174, secs, []hit{{0, 1}, {2.5, 1}}, backbeat, all16, 0.3, 0.03, false),
		build("trap", "trap: 808 kicks, snare 3, hat rolls", 140, secs, []hit{{0, 1}, {1.5, 0.9}, {2.75, 0.9}}, []hit{{2, 1}}, all16, 0, 0.03, true),
		build("kick", "kick only", 120, secs, four, nil, nil, 0, 0, false),
		build("snare", "snare only", 120, secs, nil, backbeat, nil, 0, 0, false),
		build("hats", "hats only", 120, secs, nil, nil, all8, 0, 0, false),
		build("nodrums", "no drums: bass and pad", 120, secs, nil, nil, nil, 0.3, 0.05, false),
	}
}

// match counts the true hits that a detection follows, the detections that
// follow none, and the mean time from hit to detection.
func match(truth, found []float64) (caught, extra int, late float64) {
	early, lag := 0.03, 0.16
	if *tap == "latest" {
		early, lag = 0.3, 0.1 // that tap is ahead of the sound
	}
	used := make([]bool, len(found))
	for _, at := range truth {
		for i, f := range found {
			if !used[i] && f >= at-early && f <= at+lag {
				used[i] = true
				caught++
				late += f - at
				break
			}
		}
	}
	for _, u := range used {
		if !u {
			extra++
		}
	}
	if caught > 0 {
		late /= float64(caught)
	}
	return
}

// fold gives the beat that the plugin flies to for a true beat period: the
// plugin takes half or twice a period to stay between 0.35 and 0.71 s.
func fold(period float64) float64 {
	for period > math.Sqrt2/2 {
		period /= 2
	}
	for period < math.Sqrt2/4 {
		period *= 2
	}
	return period
}

func after(xs []float64, sec float64) []float64 {
	return xs[sort.SearchFloat64s(xs, sec):]
}

func mean(xs []float64) float64 {
	sum := 0.0
	for _, x := range xs {
		sum += x
	}
	return sum / float64(len(xs))
}

func median(xs []float64) float64 {
	sorted := append([]float64(nil), xs...)
	sort.Float64s(sorted)
	return sorted[len(sorted)/2]
}

func pct(a, b int) float64 {
	if b == 0 {
		return 0
	}
	return 100 * float64(a) / float64(b)
}

// onBeat is the share of the second half of a run in which the beat of the
// plugin is the period, or half or twice it, within 4%.
func onBeat(r result, period float64) float64 {
	locked, n := 0, 0
	for _, beat := range r.beat[len(r.beat)/2:] {
		n++
		for _, m := range []float64{0.5, 1, 2} {
			if beat > 0 && math.Abs(beat/(period*m)-1) < 0.04 {
				locked++
			}
		}
	}
	return pct(locked, n)
}

func synthetic(path string) {
	for _, t := range tracks(60) {
		r := play(path, t.pcm)
		half := len(r.beat) / 2
		fmt.Printf("%-40s %3.0f BPM  beat %.3f s (true %.3f)  sure %.2f  on the beat %3.0f%% of the time\n",
			t.name, t.bpm, median(r.beat[half:]), fold(60/t.bpm), mean(r.sure[half:]), onBeat(r, 60/t.bpm))
		for _, row := range []struct {
			name         string
			truth, found []float64
		}{{"kick", t.kicks, r.kicks}, {"snare", t.snares, r.snares}, {"hat", t.hats, r.hats}} {
			truth, found := after(row.truth, warm), after(row.found, warm)
			caught, extra, late := match(truth, found)
			fmt.Printf("    %-6s true %4d  caught %4d (%3.0f%%)  extra %4d  late %+4.0f ms\n",
				row.name, len(truth), caught, pct(caught, len(truth)), extra, late*1000)
			if *verbose && len(truth) > 0 {
				// The largest rise of each band from one tick to the next, in
				// the three ticks after a hit, on average.
				var rise [ui.DefaultSpectrumBands]float64
				for _, at := range truth {
					i := int(at / tick)
					for b := range rise {
						most := 0.0
						for k := max(1, i); k <= i+3 && k < len(r.bands); k++ {
							most = math.Max(most, r.bands[k][b]-r.bands[k-1][b])
						}
						rise[b] += most / float64(len(truth))
					}
				}
				fmt.Print("           rise per band:")
				for _, x := range rise {
					fmt.Printf(" %.2f", x)
				}
				fmt.Println()
			}
		}
	}
}

// write records the bands of the synthetic tracks, for the tests of the
// plugin: they need no cliamp then. A band is 3 hex digits, 000 to fff.
func write(path, dir string) {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		panic(err)
	}
	for _, t := range tracks(30) {
		r := play(path, t.pcm)
		var out strings.Builder
		fmt.Fprintf(&out, "# %s\n# The bands that cliamp gives a plugin, one line per tick of 50 ms.\n# Recorded by test/probe; do not edit.\n", t.name)
		fmt.Fprintf(&out, "bpm %g\n", t.bpm)
		for _, row := range []struct {
			name string
			at   []float64
		}{{"kicks", t.kicks}, {"snares", t.snares}, {"hats", t.hats}} {
			out.WriteString(row.name)
			for _, at := range row.at {
				fmt.Fprintf(&out, " %.3f", at)
			}
			out.WriteByte('\n')
		}
		for _, bands := range r.bands {
			for _, b := range bands {
				fmt.Fprintf(&out, "%03x", int(math.Round(math.Max(0, math.Min(1, b))*4095)))
			}
			out.WriteByte('\n')
		}
		if err := os.WriteFile(filepath.Join(dir, t.file+".txt"), []byte(out.String()), 0o644); err != nil {
			panic(err)
		}
	}
}

// fft is a radix-2 transform in place; len(x) is a power of two.
func fft(x []complex128) {
	n := len(x)
	for i, j := 1, 0; i < n; i++ {
		bit := n >> 1
		for ; j&bit != 0; bit >>= 1 {
			j ^= bit
		}
		j ^= bit
		if i < j {
			x[i], x[j] = x[j], x[i]
		}
	}
	for size := 2; size <= n; size <<= 1 {
		w := cmplx.Exp(complex(0, -2*math.Pi/float64(size)))
		for start := 0; start < n; start += size {
			f := complex(1, 0)
			for k := 0; k < size/2; k++ {
				a, b := x[start+k], x[start+k+size/2]*f
				x[start+k], x[start+k+size/2] = a+b, a-b
				f *= w
			}
		}
	}
}

// reference estimates the beat period of pcm in seconds, apart from the
// plugin: the flux of the whole spectrum every 10 ms, and the lag between
// 0.33 and 1 s whose multiples line the onsets up best.
func reference(pcm []float64) float64 {
	const size, hop = 1024, 441
	window := make([]float64, size)
	for i := range window {
		window[i] = 0.5 * (1 - math.Cos(2*math.Pi*float64(i)/float64(size-1)))
	}
	var flux []float64
	prev := make([]float64, size/2)
	buf := make([]complex128, size)
	for start := 0; start+size <= len(pcm); start += hop {
		for i := range buf {
			buf[i] = complex(pcm[start+i]*window[i], 0)
		}
		fft(buf)
		sum := 0.0
		for k := 1; k < size/2; k++ {
			level := math.Log(1 + 100*cmplx.Abs(buf[k]))
			sum += math.Max(0, level-prev[k])
			prev[k] = level
		}
		flux = append(flux, sum)
	}
	// Take the slow part out: the mean of the second around each frame.
	flat := make([]float64, len(flux))
	for i := range flux {
		lo, hi := max(0, i-50), min(len(flux), i+50)
		flat[i] = math.Max(0, flux[i]-mean(flux[lo:hi]))
	}
	ac := func(lag int) float64 {
		sum := 0.0
		for i := lag; i < len(flat); i++ {
			sum += flat[i] * flat[i-lag]
		}
		return sum / float64(len(flat)-lag)
	}
	best, bestLag := 0.0, 0
	for lag := 33; lag <= 100; lag++ {
		if score := ac(lag) + ac(2*lag) + ac(3*lag) + ac(4*lag); score > best {
			best, bestLag = score, lag
		}
	}
	a, b, c := ac(bestLag-1), ac(bestLag), ac(bestLag+1)
	shift := 0.0
	if d := a - 2*b + c; d < 0 {
		shift = 0.5 * (a - c) / d
	}
	return (float64(bestLag) + shift) * hop / sr
}

// music runs the tracks of a directory of raw PCM (f32le, mono, 44.1 kHz).
// There the hits have no truth: it shows how many the plugin finds, and how
// its beat compares with the reference.
func music(path, dir string) {
	files, _ := filepath.Glob(filepath.Join(dir, "*.f32"))
	sort.Strings(files)
	for _, file := range files {
		raw, err := os.ReadFile(file)
		if err != nil {
			panic(err)
		}
		pcm := make([]float64, len(raw)/4)
		for i := range pcm {
			pcm[i] = float64(math.Float32frombits(binary.LittleEndian.Uint32(raw[4*i:])))
		}
		r := play(path, pcm)
		ref := reference(pcm)
		half := len(r.beat) / 2
		mins := float64(len(pcm)) / sr / 60
		fmt.Printf("%-12s reference %.3f s (%3.0f BPM)  plugin %.3f s  sure %.2f  on the beat %3.0f%% of the time | per minute: kick %3.0f snare %3.0f hat %3.0f\n",
			filepath.Base(file), ref, 60/ref, median(r.beat[half:]), mean(r.sure[half:]), onBeat(r, ref),
			float64(len(r.kicks))/mins, float64(len(r.snares))/mins, float64(len(r.hats))/mins)
	}
}

func main() {
	flag.Parse()
	if flag.NArg() != 1 {
		fmt.Fprintln(os.Stderr, "usage: probe [-record dir] [-pcm dir] [-tap audible|latest] [-v] plugin.lua")
		os.Exit(2)
	}
	path := flag.Arg(0)
	switch {
	case *record != "":
		write(path, *record)
	case *pcmDir != "":
		music(path, *pcmDir)
	default:
		synthetic(path)
	}
}
