# lunatune

A one-command tuner for [Moonlight](https://moonlight-stream.org) game streaming on macOS over Wi-Fi. It strips out the background radio and CPU work that makes a Mac stutter, keeps the Wi-Fi radio awake, shows you live latency while you play, and puts everything back when you press Ctrl+C.

![lunatune demo](assets/demo.gif)

## Why

Streaming from a gaming PC to a MacBook over Wi-Fi tends to hitch: random freezes where audio and video stall together, while Moonlight's overlay reports **zero** dropped frames. The same stream to an Android phone on the same network is smooth.

Three things on macOS cause it, roughly in order of impact:

1. **Wi-Fi power-save.** A game stream is almost all downlink, so between bursts the Mac's radio dozes off and every wake-up delays packets. Moonlight for Android holds a `WIFI_MODE_FULL_LOW_LATENCY` lock for the whole stream, which prevents exactly this. macOS has no public equivalent, and Moonlight's desktop client only sends a few uplink packets a second. lunatune sends a steady 50 Hz ping to the streaming host, which keeps the radio awake. On the machine this was built on, that ping alone fixed the stutter.
2. **AWDL** (`awdl0`), the peer-to-peer link behind AirDrop, AirPlay, Sidecar and Universal Control, periodically pulls the radio off your router's channel. On 6 GHz it can't share the channel at all.
3. **Location Services** (`locationd`) triggers Wi-Fi scans that show up as 60–300 ms latency spikes.

## What it changes

Everything is temporary. It's recorded in `~/.local/state/lunatune/` and restored to the exact previous value on exit.

| Change | Why | Undone by |
|---|---|---|
| 50 Hz ping to the streaming host | keeps the Wi-Fi radio out of power-save | killed on exit |
| `awdl0`, `llw0`, `nan0` down, and knocked down again the moment macOS raises them | stops off-channel hops | brought back up |
| AirDrop set to "No One" | stops AirDrop waking AWDL | previous setting restored |
| Pause (`SIGSTOP`) `locationd`, `mds_stores`, `photoanalysisd`, `mediaanalysisd`, `bird`, `cloudd` | no Wi-Fi scans, indexing, or sync bursts | `SIGCONT` |
| Moonlight: `nice -10`, top throughput/latency tier | keeps decode and audio threads scheduled | priority reset |
| Timer coalescing off | tighter wakeups | restored |
| Low Power Mode off, Time Machine auto-backup paused (only if they were on) | no throttling, no backup I/O | restored |
| `caffeinate` | no sleep mid-session | exits with the script |

On Ethernet, the Wi-Fi steps are skipped automatically.

## Install

```sh
git clone https://github.com/MaroonBrian1928/lunatune.git
ln -s "$PWD/lunatune/lunatune.sh" ~/.local/bin/lunatune   # any directory on your PATH
```

Requirements: macOS on Apple Silicon, an admin account (it asks for `sudo` once), and Moonlight. Perl and bash ship with macOS.

## Use

```sh
lunatune            # tune, show live stats, Ctrl+C to restore everything
lunatune --status   # link and power report only, changes nothing
lunatune --restore  # undo a session that crashed or was killed
lunatune --demo     # the visuals with simulated data, changes nothing, no sudo
```

Start it before or after launching Moonlight. It finds Moonlight's process and your PC's IP on its own.

The status bar shows session time, a latency sparkline (green → red), average and peak latency, how many times AWDL tried to come back, and whether Moonlight is running. When you quit, a summary card grades the session by the share of seconds with no spike of 30 ms or more.

**While it runs**, AirDrop, AirPlay to this Mac, Sidecar, Universal Control, Continuity Camera, Location Services and iCloud sync are paused. They come back when you press Ctrl+C.

## Configure

The settings are at the top of `lunatune.sh`:

| Setting | Default | |
|---|---|---|
| `KEEPALIVE_INTERVAL` | `0.02` | ping interval in seconds; `""` disables the keepalive |
| `SYSTEM_STOP` / `USER_STOP` | see script | processes to pause; add sync clients like `Dropbox` |
| `P2P_IFACES` | `awdl0 llw0 nan0` | interfaces kept down |
| `MOONLIGHT_NICE` | `-10` | Moonlight's priority boost |

Powerline glyphs and icons turn on automatically in Ghostty, WezTerm and kitty. Force them with `LUNATUNE_NERD=1` (needs a [Nerd Font](https://www.nerdfonts.com)) or turn them off with `LUNATUNE_NERD=0`.

## If something goes wrong

- **The script was killed or the terminal closed:** run `lunatune --restore`. A reboot also resets everything except AirDrop discoverability, Low Power Mode and Time Machine, which `--restore` handles.
- **"Wi-Fi details timed out":** another lunatune session is running with `locationd` paused, so the Wi-Fi report can't complete. This is harmless.
- **Still stuttering:** try Ethernet. If it's smooth there, the problem is your Wi-Fi itself, such as signal strength, 2.4 GHz, or router settings. `lunatune --status` flags weak signal, 2.4 GHz and 20 MHz channels.

## Notes

- Tested on macOS 27.0, MacBook Pro M3 Pro, Ghostty, and Moonlight 6.1 streaming from Sunshine. Written for `/bin/bash` 3.2 so it runs on a stock Mac.
- System Integrity Protection blocks unloading Apple's daemons, so lunatune pauses them with signals instead. Nothing on disk is modified apart from the AirDrop, Low Power Mode and Time Machine settings it restores.
- Not affiliated with Moonlight or Apple.

## License

[MIT](LICENSE)
