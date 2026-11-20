# cliamp-plugin-hackthegibson

A flight through a city of glass towers for [cliamp](https://github.com/bjarneo/cliamp), after the film Hackers (1995). The edges of the towers and the code on them are Braille dots, the glass is a tint of the cells behind them. All colors are yours to set.

The eye flies low through the streets of an endless city and turns at the crossings. It flies one block per beat; without a beat it cruises. A kick sends a pulse of light along the ground, a snare runs a frame of light up or down the towers, a hi-hat lights lines of code, and a sudden jump in energy lifts the eye above the roofs for a moment. Each tower belongs to one band of the spectrum: it grows a little and its glass gets denser while that band is loud.

The scene follows my CSS demo [Hack The Gibson](https://codepen.io/konstantindenerz/pen/poYmNxw).

## Install

```sh
cliamp plugins install konstantindenerz/cliamp-plugin-hackthegibson
```

Start cliamp and press `v` until you reach `Hack the Gibson`, or pick it with `Ctrl+V`. Press `V` for full screen. To start with it, set `visualizer = "Hack the Gibson"` in `config.toml`.

```sh
cliamp plugins remove hackthegibson
```

## Configuration

The plugin needs no configuration. These keys are optional and go into `~/.config/cliamp/config.toml`; the values below are the defaults:

```toml
[plugins.hackthegibson]
# Wait this long before the city reacts, when it is ahead of the sound.
delay_ms = 0
# Colors: "#rrggbb" or a palette index (0-255).
# Towers, ground, frames of light and drops, heads of the pulses.
tower = "#e7c07c"
floor = "#c5564a"
beat = "#d94e38"
hot = "#fff8e8"
# The background of the terminal, as "#rrggbb".
back = "#1c1b19"
# The glass of the towers: a color, "dots" or "off". The default is the
# color of the towers.
# glass = "#e7c07c"
```

The default colors are the amber and red of the Ghostty theme [Mechanoonna](https://github.com/HANCORE-linux/omarchy-mechanoonna-theme). A plugin cannot read the theme of the terminal or of cliamp, so set the colors of your own theme here.

A color given as `#rrggbb` has shades: the towers far away fade into `back`, and the glass is a background color between `back` and its own color, denser where a tower is near or loud. Set `back` to the background of your terminal, or the far towers and the thin glass stand out as dark or bright cells. The shades need a terminal with 24-bit color.

A palette index follows the theme of the terminal, but it has no shades. Towers of a palette color are faint far away and take the bright color of the same name when near: 14 for 6. Their glass is a grid of dots, which `glass = "dots"` gives to towers of any color. A palette index as `glass` is one flat background color.

The colors of the terminal:

```toml
[plugins.hackthegibson]
tower = 6
floor = 4
beat = 9
hot = 11
```

The colors of the CSS demo:

```toml
[plugins.hackthegibson]
tower = "#58C6A2"
floor = "#9375ee"
beat = "#ee75d2"
hot = "#deee75"
back = "#000000"
```

## Notes

- The plugin reads the tempo from how the whole spectrum rises and falls, not from the kicks alone, so it also finds the beat of a break or of a track without drums. It takes half or twice a tempo outside of 85 to 170 BPM, so the eye flies at a like speed to any track.
- Kick, snare and hi-hat come from 10 bands, 20 times a second. That does not tell everything apart: the body of a snare sounds like a kick, so a snare sends a pulse along the ground too, and a track without a snare gets a frame of light now and then from whatever else rises in the mids.
- The drums need a cliamp that gives plugins the sound as it plays ([bjarneo/cliamp#738](https://github.com/bjarneo/cliamp/pull/738)). Up to v2.4.1 a plugin gets the audio in bursts and ahead of the sound. With synthetic drum tracks the plugin then finds 56 to 83% of the kicks, about 150 ms before they sound; with the change it finds 95 to 100%, 40 ms after. `delay_ms = 175` lines up the kicks that an older cliamp does catch. The tempo holds either way.
- The terminal font needs the Braille block (U+2800 to U+28FF).
- cliamp gives a plugin 50 ms for a frame. A full-screen frame at 140x40 takes about a third of that on an Apple M-series CPU. When frames get slow, the plugin shows less of the city far away to stay in time.
- A low panel shows only the towers nearby. The city looks best in full screen.
- While playback is paused the eye eases to a stop. Silence stops it too.

## Development

```sh
cp hackthegibson.lua ~/.config/cliamp/plugins/
cliamp plugins trust hackthegibson
```

cliamp loads plugins at start and asks for the trust step again after each edit. Errors go to `~/.config/cliamp/plugins.log`.

The tests run the plugin in the Lua VM that cliamp uses, with stand-ins for cliamp:

```sh
cd test && go test ./...
```

`test/testdata/bands` holds what cliamp makes of synthetic drum tracks: the bands of each tick, and when the drums hit. The tests check that the plugin finds the drums and the tempo in them. `test/probe` recorded them: it mixes the tracks, runs them through the spectrum analysis of cliamp and into the plugin, and prints how many hits the plugin finds. It needs a checkout of cliamp with the change above next to this repository, as `go.mod` there says:

```sh
cd test/probe
go run . ../../hackthegibson.lua                            # the report
go run . -record ../testdata/bands ../../hackthegibson.lua  # record the bands again
go run . -pcm dir ../../hackthegibson.lua                   # music of your own: *.f32, mono, 44.1 kHz
```

After a change that is meant to alter the picture, `go test -update` records the frames in `test/testdata/frames.txt` again. `go test -run TestShots -shots=/tmp/shots` writes some frames as PNG files, to look at without cliamp.

## License

MIT
