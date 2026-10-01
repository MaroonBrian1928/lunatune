#!/bin/bash
# lunatune — Moonlight game-streaming tuner for macOS (Apple Silicon)
#
#   lunatune            tune, hold until Ctrl+C, then restore everything
#   lunatune --status   print link/power diagnostics only, change nothing
#   lunatune --restore  undo a previous run that crashed or was killed
#   lunatune --demo     preview the visuals with simulated data (changes nothing)
#
# Everything here is temporary and reversible. Nothing survives a reboot except
# Time Machine / AirDrop / Low Power Mode, and those are recorded in the state
# file and restored to their exact prior values.
#
# Written for /bin/bash 3.2 (no associative arrays, no coproc).

# ── Config ──────────────────────────────────────────────────────────────────

# System daemons to SIGSTOP (any owner other than you — these run as service
# accounts like _locationd / _mds_stores). locationd drives the periodic Wi-Fi
# scans that show up as 60–300 ms spikes; mds_stores is Spotlight's indexer.
SYSTEM_STOP=(locationd mds_stores)

# Per-user processes to SIGSTOP (exact process names, matched with pgrep -x).
# Add your own sync clients here, e.g. Dropbox, OneDrive, "Google Drive".
USER_STOP=(photoanalysisd mediaanalysisd bird cloudd)

# Peer-to-peer Wi-Fi interfaces that pull the radio off your AP's channel.
#   awdl0 – AirDrop / AirPlay / Sidecar / Universal Control / Continuity
#   llw0  – Low-latency WLAN, AWDL's companion
#   nan0  – Wi-Fi Aware (NAN), new in 26
P2P_IFACES=(awdl0 llw0 nan0)

MOONLIGHT_NICE=-10

# Wi-Fi keepalive: a steady 50 Hz ping stops the radio from dozing between
# stream bursts (power-save wakeups show up as random A/V hitches with zero
# network drops in Moonlight's overlay). Targets the streaming host once
# Moonlight connects, the router until then. Set to "" to disable.
KEEPALIVE_INTERVAL=0.02

# ── Plumbing ────────────────────────────────────────────────────────────────

GRN='\033[0;32m'; YLW='\033[1;33m'; RED='\033[0;31m'; DIM='\033[2m'; BLD='\033[1m'; RST='\033[0m'

# Character counts and per-char colouring assume UTF-8; bash re-reads the locale
# when LC_CTYPE is assigned, so this fixes ${#var} for box padding mid-script.
[[ "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" == *UTF-8* ]] || export LC_CTYPE=en_US.UTF-8

# Eye candy only on a real terminal; piped/logged output stays plain.
FANCY=false
[[ -t 1 && "${TERM:-dumb}" != dumb ]] && FANCY=true
CLR=""; $FANCY && CLR='\r\033[K'   # wipe the live status bar before printing over it

# Moonlit palette (256-color): violet → periwinkle → ice.
PALETTE=(93 99 105 111 117 123 159)
c256() { printf '\033[38;5;%sm' "$1"; }

ts()   { date '+%H:%M:%S'; }
log()  { echo -e "${CLR}${DIM}$(ts)${RST} $(c256 111)›${RST} $*"; }
ok()   { echo -e "${CLR}${DIM}$(ts)${RST} ${GRN}✓${RST} $*"; }
warn() { echo -e "${CLR}${DIM}$(ts)${RST} ${YLW}⚠${RST} $*"; }
err()  { echo -e "${CLR}${DIM}$(ts)${RST} ${RED}✗${RST} $*"; }
note() { echo -e "${CLR}${DIM}$(ts)   $*${RST}"; }

# Per-character gradient across PALETTE.
gradient() {
    local s="$1" out="" i ch n=${#PALETTE[@]}
    for (( i=0; i<${#s}; i++ )); do
        ch="${s:$i:1}"
        out+="$(c256 "${PALETTE[$(( i * n / ${#s} ))]}")$ch"
    done
    printf '%s\033[0m' "$out"
}

# Nerd Font glyphs (powerline caps + icons). Ghostty, WezTerm and kitty bundle
# them; anywhere else falls back to plain text. Force with LUNATUNE_NERD=1/0.
NERD=false
case "${LUNATUNE_NERD:-auto}:${TERM_PROGRAM:-}" in
    1:*|auto:ghostty|auto:WezTerm) NERD=true ;;
    auto:*) [[ -n "${KITTY_WINDOW_ID:-}" ]] && NERD=true ;;
esac
$FANCY || NERD=false
PL_L=$'\xee\x82\xb6'      # round left cap
PL_R=$'\xee\x82\xb4'      # round right cap / separator
I_PAD=$'\xef\x84\x9b'     # gamepad
I_SHIELD=$'\xef\x84\xb2'  # shield
I_PULSE=$'\xef\x88\x9e'   # heartbeat

# N box-drawing dashes shaded violet → ice across the run (no subshells).
grad_rule() {
    local n=$1 i out="" k=${#PALETTE[@]}
    for (( i=0; i<n; i++ )); do out+="\033[38;5;${PALETTE[$(( i * k / n ))]}m─"; done
    printf '%b\033[0m' "$out"
}

section() {
    local title="$1"
    echo -e "$(c256 93)╭─ ${RST}${BLD}${title}${RST} $(grad_rule $(( 40 - ${#title} )))"
}
section_end() { echo -e "$(c256 93)╰$(grad_rule 42)"; }

# ── 3D moon intro ───────────────────────────────────────────────────────────
# A lit, cratered sphere spinning at ~24 fps, rendered in half-blocks by perl
# (ships with macOS — bash is far too slow for per-pixel shading). Plays while
# the Wi-Fi lookup runs, then freezes on its last frame as the banner.
read -r -d '' MOON_PL <<'PERL'
use strict; use warnings;
use Time::HiRes qw(time sleep);
use POSIX qw(floor);

# args: watch_pid min_secs max_secs truecolor(0/1) shadow_secs side_line x9
# Spins a shaded moon while $watch is alive, then does a PS1-style boot:
# the sphere dissolves into the crescent logo, flashes, and the title fades up.
my ($watch, $min_s, $max_s, $tc, $sh_secs, @side) = @ARGV;
$sh_secs = 7 unless $sh_secs && $sh_secs > 0;   # how long the wane takes (≈ the Wi-Fi lookup)
my $PI2 = 6.283185307;
my ($W, $H) = (19, 9);                      # the logo's grid: 19 x 18 px in half-blocks
my ($cx, $cy, $R) = ($W / 2, $H, $H - 0.3);
my @ROW256 = (195, 159, 123, 117, 111, 105, 99, 93, 57);   # the logo's per-row colours
my $TRANS  = 1.6;                           # dissolve + flash, seconds

# ── colour helpers ──────────────────────────────────────────────────────────
my @LV = (0, 95, 135, 175, 215, 255);
sub x256 {                                   # 256-colour index -> rgb
    my $i = shift;
    return (8 + 10 * ($i - 232)) x 3 if $i >= 232;
    $i -= 16;
    return ($LV[int($i / 36)], $LV[int($i / 6) % 6], $LV[$i % 6]);
}
sub to256 {                                  # rgb -> nearest cube index
    my @q = map { $_ < 48 ? 0 : $_ < 115 ? 1 : int(($_ - 35) / 40) } @_;
    return 16 + 36 * $q[0] + 6 * $q[1] + $q[2];
}
sub esc {
    my ($layer, @c) = @_;
    $tc ? sprintf("\e[%d;2;%d;%d;%dm", $layer, @c) : sprintf("\e[%d;5;%dm", $layer, to256(@c));
}

# Moonlit gradient for the sphere: indigo shadow -> purple -> blue -> cyan -> ice.
my @STOPS = ([0.00, 14, 6, 34], [0.22, 62, 22, 128], [0.45, 88, 70, 220],
             [0.68, 50, 150, 235], [0.86, 90, 220, 245], [1.00, 215, 250, 255]);
sub grad {
    my $i = shift;
    for my $k (1 .. $#STOPS) {
        my ($a, $b) = ($STOPS[$k - 1], $STOPS[$k]);
        next if $i > $b->[0];
        my $f = ($i - $a->[0]) / ($b->[0] - $a->[0]);
        return map { $a->[$_] + ($b->[$_] - $a->[$_]) * $f } 1 .. 3;
    }
    return @{ $STOPS[-1] }[1 .. 3];
}

# ── moon surface ────────────────────────────────────────────────────────────
srand(42);
my @crater;
push @crater, [ (rand() * 2 - 1) * 1.25, rand() * $PI2, 0.07 + rand() ** 2 * 0.26, 0.35 + rand() * 0.3 ] for 1 .. 22;
my @maria = ([0.35, 0.8, 0.55], [-0.2, 1.7, 0.45], [0.55, 2.5, 0.35],
             [-0.45, 3.6, 0.50], [0.10, 4.7, 0.60], [0.60, 5.5, 0.30]);
$_ = [ @$_, sin($_->[0]), cos($_->[0]) ] for @crater, @maria;

# Phase = the logo's own geometry, not real lighting: a shadow disk the size of
# the logo's cut-out slides in from the right and parks exactly where the logo
# cuts, so the lit area ends up *being* the crescent. A fixed key light from the
# left adds curvature on top.
my $SH_R    = $R * 0.95;
my $SH_END  = 6;                 # logo cut-out offset (px)
my $SH_FROM = 2 * $R + 2;        # starts fully off the disk: full moon
my $SH_X;                        # current shadow-disk centre offset
# $u: 0 = full moon, 1 = the logo crescent.
sub set_shadow { my $u = shift; $u = 1 if $u > 1; $SH_X = $SH_END + ($SH_FROM - $SH_END) * (1 - $u * $u * (3 - 2 * $u)) }
my @KEY = (-0.55, -0.30, 0.78);
{ my $n = sqrt($KEY[0]**2 + $KEY[1]**2 + $KEY[2]**2); $_ /= $n for @KEY; }

# Per-pixel: sphere geometry (if on the disk), logo membership, dissolve seed.
# The logo is the original crescent: this disk minus one shifted 6 px right.
my @px;
for my $y (0 .. 2 * $H - 1) {
    for my $x (0 .. $W - 1) {
        my ($ux, $uy) = ($x + 0.5, $y + 0.5);
        my $in   = ($ux - $cx) ** 2 + ($uy - $cy) ** 2 <= $R ** 2;
        next unless $in;
        my $logo = !(($ux - $cx - 6) ** 2 + ($uy - $cy) ** 2 <= ($R * 0.95) ** 2);
        my ($dx, $dy) = (($ux - $cx) / $R, ($uy - $cy) / $R);
        my $dz  = sqrt(1 - $dx * $dx - $dy * $dy);
        my $lat = -atan2($dy, sqrt($dx * $dx + $dz * $dz));
        $px[$y][$x] = { lat => $lat, lon => atan2($dx, $dz), sl => sin($lat), cl => cos($lat),
                        n => [$dx, $dy, $dz], rad => sqrt($dx * $dx + $dy * $dy),
                        logo => $logo, seed => rand(), row => int($y / 2), ux => $ux, uy => $uy };
    }
}

sub shade {
    my ($p, $theta) = @_;
    my $lon = $p->{lon} + $theta;
    my $a = 0.86;
    for my $m (@maria) {
        my $cd = $p->{sl} * $m->[3] + $p->{cl} * $m->[4] * cos($lon - $m->[1]);
        my $d = $cd >= 1 ? 0 : atan2(sqrt(1 - $cd * $cd), $cd);
        $a -= 0.36 * exp(-2.2 * ($d / $m->[2]) ** 2);
    }
    for my $c (@crater) {
        my $cd = $p->{sl} * $c->[4] + $p->{cl} * $c->[5] * cos($lon - $c->[1]);
        next if $cd < 0.8;
        my $d = atan2(sqrt(1 - $cd * $cd), $cd) / $c->[2];
        if    ($d < 0.85) { $a -= $c->[3] * 0.45 * (1 - $d * $d) }
        elsif ($d < 1.15) { $a += 0.10 }
    }
    my $w = $lon - $PI2 * floor($lon / $PI2);
    $a += ((((int(($p->{lat} + 2) * 11) * 73856093) ^ (int($w * 11) * 19349663)) % 997) / 997 - 0.5) * 0.07;
    my ($nx, $ny, $nz) = @{ $p->{n} };
    my $vol = $nx * $KEY[0] + $ny * $KEY[1] + $nz * $KEY[2];
    $vol = 0.45 + 0.55 * ($vol > 0 ? $vol : 0);                       # sphere curvature
    my $sd  = sqrt(($p->{ux} - $cx - $SH_X) ** 2 + ($p->{uy} - $cy) ** 2);
    my $lit = smooth(($sd - $SH_R + 0.7) / 1.4);                  # soft-edged shadow disk
    my $i = $a * $lit * $vol + $a * 0.10 + 0.015 * (1 - $p->{rad});   # + earthshine
    return $i < 0 ? 0 : $i > 1 ? 1 : $i;
}

sub smooth { my $u = shift; $u = 0 if $u < 0; $u = 1 if $u > 1; $u * $u * (3 - 2 * $u) }

# Colour of one pixel, or undef for empty space. $u = transition progress (<0 = spinning).
sub pixel {
    my ($p, $theta, $u) = @_;
    return undef unless $p;
    my @s = grad(shade($p, $theta));
    return \@s if $u < 0;
    my $fade = 1 - smooth($u / 0.55);                          # sphere dims out
    @s = map { $_ * $fade } @s;
    if ($p->{logo}) {
        my $g = smooth(($u - 0.45 * $p->{seed}) / 0.35);      # staggered dissolve-in
        my @l = x256($ROW256[$p->{row}]);
        my $flash = ($u > 0.55 && $u < 1) ? sin(3.14159 * ($u - 0.55) / 0.45) * 0.65 : 0;
        @l = map { ($_ + (255 - $_) * $flash) * $g } @l;
        @s = map { my $v = $s[$_] + $l[$_]; $v > 255 ? 255 : $v } 0 .. 2;
    }
    return (($s[0] + $s[1] + $s[2]) < 12) ? undef : \@s;
}

# Everything beside the moon sits at fixed screen columns (matching the static
# banner): title block at col 18, stars scattered around it, loader at col 24.
my $TEXT_COL = 18;
my @stars = ([0, 23, '·', 0.0], [0, 36, '✦', 1.7], [7, 29, '⋆', 3.1], [8, 40, '·', 4.2]);

sub vwidth { my $s = shift; $s =~ s/\e\[[0-9;]*m//g; my $n = () = $s =~ /[\x00-\x7f\xc0-\xff]/g; $n }

# [col, string] items for row $r
sub side_items {
    my ($r, $t, $mode, $u) = @_;
    my @it;
    if ($mode eq 'spin' && $r == 4 && $watch) {
        push @it, [24, "\e[38;5;111m" . (qw(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏))[int($t * 12) % 10] . "\e[0m\e[2m reading Wi-Fi link…\e[0m"];
    }
    if (($side[$r] // '') ne '') {
        if ($mode eq 'final') {
            push @it, [$TEXT_COL, $side[$r]];
        } elsif ($mode eq 'trans') {
            (my $plain = $side[$r]) =~ s/\e\[[0-9;]*m//g;
            my $k = smooth(($u - 0.6 - 0.06 * ($r - 2)) / 0.3);   # rows fade up top-down, after the sphere is gone
            push @it, [$TEXT_COL, "\e[38;5;" . (232 + int($k * 21)) . "m$plain"] if $k > 0;
        }
    }
    for my $s (grep { $_->[0] == $r } @stars) {
        my $col = $mode eq 'final' ? 60 : (17, 18, 24, 31, 38, 45, 51, 159)[int((0.5 + 0.5 * sin($t * 2.3 + $s->[3])) * 7.99)];
        push @it, [$s->[1], "\e[38;5;${col}m$s->[2]\e[0m"];
    }
    return sort { $a->[0] <=> $b->[0] } @it;
}

sub frame {
    my ($theta, $t, $u, $mode) = @_;
    # Full sphere width while it's visible; the logo's 14 columns once it's gone.
    my $cols = ($mode eq 'final' || ($mode eq 'trans' && $u >= 0.6)) ? 14 : $W;
    my $out = '';
    for my $r (0 .. $H - 1) {
        my $line = '  ';
        for my $x (0 .. $cols - 1) {
            my ($pa, $pb) = ($px[2 * $r][$x], $px[2 * $r + 1][$x]);
            if ($mode eq 'final') {       # the exact original logo: row colour, crisp glyphs
                my ($a, $b) = ($pa && $pa->{logo}, $pb && $pb->{logo});
                my $fg = "\e[38;5;$ROW256[$r]m";
                $line .= $a && $b ? "$fg█" : $a ? "$fg▀" : $b ? "$fg▄" : "\e[0m ";
                next;
            }
            my ($a, $b) = (pixel($pa, $theta, $u), pixel($pb, $theta, $u));
            if    ($a && $b) { $line .= esc(38, @$a) . esc(48, @$b) . '▀' }
            elsif ($a)       { $line .= "\e[49m" . esc(38, @$a) . '▀' }
            elsif ($b)       { $line .= "\e[49m" . esc(38, @$b) . '▄' }
            else             { $line .= "\e[0m " }
        }
        $line .= "\e[0m";
        my $at = 2 + $cols;
        for my $it (side_items($r, $t, $mode, $u)) {
            my $pad = $it->[0] - $at; $pad = 1 if $pad < 1;
            $line .= (' ' x $pad) . $it->[1] . "\e[0m";
            $at += $pad + vwidth($it->[1]);
        }
        $out .= "\r$line\e[K\n";
    }
    return $out;
}

$| = 1;
if (!-t STDOUT) { print frame(0, 0, 1, 'final'); exit 0 }

$SIG{INT} = $SIG{TERM} = sub { print "\e[0m\e[?25h\n"; exit 130 };
print "\e[?25l";
my ($t0, $first, $trans_at) = (time, 1, undef);
while (1) {
    my $el = time - $t0;
    $trans_at //= $el if $el >= $max_s || ($el >= $min_s && !($watch && kill 0, $watch));
    my $u = defined $trans_at ? ($el - $trans_at) / $TRANS : -1;
    my $mode = $u >= 1 ? 'final' : $u >= 0 ? 'trans' : 'spin';
    # Wane paced to the lookup; if it lands early, finish the shadow fast
    # (before the dissolve gets going) so the shape never jumps.
    my $wane = $el / $sh_secs;
    if (defined $trans_at) { my $k = ($el - $trans_at) / 0.45; $wane = $wane + (1 - $wane) * ($k > 1 ? 1 : $k) if $wane < 1 }
    set_shadow($wane);
    my $theta = 0.6 + 0.85 * $el;                    # steady spin the whole way through
    print(($first ? '' : "\e[${H}A") . frame($theta, $el, $u, $mode));
    $first = 0;
    last if $mode eq 'final';
    sleep(1 / 24);
}
print "\e[?25h";
PERL

# $1 = PID to spin for (may be empty), $2 = min seconds, $3 = max seconds
moon_intro() {
    local tc=0 sub
    [[ "${COLORTERM:-}" == truecolor || "${COLORTERM:-}" == 24bit ]] && tc=1
    sub="macOS $(sw_vers -productVersion) · $(sysctl -n machdep.cpu.brand_string 2>/dev/null | sed 's/^Apple //')"
    # Nine rows beside the 9-row moon; stars are drawn by the renderer.
    local side=(
        "" ""
        "$(gradient "L U N A T U N E")"
        "$(c256 60)━━━━━━━━━━━━━━━$(printf '\033[0m')"
        "$(printf '\033[1mmoonlight stream tuner\033[0m')"
        "$(printf '\033[2m%s\033[0m' "$sub")"
        "" "" ""
    )
    echo ""
    # Pace the wane to how long the lookup took last time, minus what has already
    # elapsed (e.g. at the sudo prompt). Wired / no lookup: wane within the minimum.
    local sh=2.3 last now
    if $DEMO; then
        sh=5.5
    elif [[ -n "$1" ]]; then
        last=$(cat "$SCAN_FILE" 2>/dev/null); [[ "$last" =~ ^[0-9]+$ ]] || last=7
        now=$(date +%s)
        sh=$(( last - (now - ${WIFI_T0:-$now}) )); (( sh < 2 )) && sh=2
    fi
    perl -e "$MOON_PL" "${1:-}" "$2" "$3" "$tc" "$sh" "${side[@]}"
    echo ""
    # Remember this lookup's duration for next time (only if it finished).
    if ! $DEMO && [[ -n "$1" && -n "$WIFI_T0" ]] && ! kill -0 "$1" 2>/dev/null; then
        local took=$(( $(date +%s) - WIFI_T0 ))
        if (( took >= 2 && took <= 30 )); then mkdir -p "$STATE_DIR"; echo "$took" > "$SCAN_FILE"; fi
    fi
}

banner() {
    if $FANCY && [[ -n "$MOON_PL" ]]; then moon_intro "$WIFI_INFO_PID" 2.5 "$WIFI_DEADLINE"; return; fi
    # Crescent drawn in half-blocks (two circles, one cut from the other).
    # Every row is padded to 14 columns so the text column lines up.
    local moon=(
        "     ▄▄▄███▄  "
        "   ▄█████▀    "
        "  ██████▀     "
        " ██████▀      "
        " ██████       "
        " ██████▄      "
        "  ██████▄     "
        "   ▀█████▄    "
        "     ▀▀▀███▀  "
    )
    local shade=(195 159 123 117 111 105 99 93 57)
    local sub
    sub="macOS $(sw_vers -productVersion) · $(sysctl -n machdep.cpu.brand_string 2>/dev/null | sed 's/^Apple //')"
    local side=(
        "$(c256 60)       ·            ✦${RST}"
        ""
        "  $(gradient "L U N A T U N E")"
        "  $(c256 60)━━━━━━━━━━━━━━━${RST}"
        "  ${BLD}moonlight stream tuner${RST}"
        "  ${DIM}${sub}${RST}"
        ""
        "$(c256 60)             ⋆${RST}"
        "$(c256 60)                        ·${RST}"
    )
    local i
    echo ""
    for i in "${!moon[@]}"; do
        if $FANCY; then
            echo -e "  $(c256 "${shade[$i]}")${moon[$i]}${RST}${side[$i]}"
            sleep 0.035
        else
            echo -e "  ${moon[$i]}${side[$i]}" | perl -pe 's/\e\[[0-9;]*m//g'
        fi
    done
    echo ""
}

# Lives outside $TMPDIR so it survives the periodic /var/folders sweep.
DEMO=false
STATE_DIR="$HOME/.local/state/lunatune"
STATE_FILE="$STATE_DIR/state.env"
FIFO="$STATE_DIR/route.fifo"
LAT_FILE="$STATE_DIR/latency"   # "avg max lost" for the last ~second, written by the keepalive

# State (all restored by restore_all)
BOOT_TIME=""
STOPPED_PIDS=""          # space-separated
IFACES_DOWNED=""         # space-separated, only those that were UP when we started
TIMER_COALESCE_ORIG=""
LOWPOWER_ORIG=""
TM_DISABLED=false
AIRDROP_CHANGED=false
AIRDROP_ORIG=""          # "__unset__" when the key didn't exist
MOONLIGHT_PID=""

CAFFEINATE_PID=""
SUDO_KEEPALIVE_PID=""
MONITOR_PID=""
KEEPALIVE_PID=""
KEEPALIVE_TARGET=""
RESTORED=false
AWDL_HITS=0

# Live session stats (status bar + summary)
SESSION_LIVE=false
SPARK_W=24
SPARK=()                 # recent per-second max latency, oldest first ("-" = no data yet)
for (( _i=0; _i<SPARK_W; _i++ )); do SPARK+=("-"); done
LAT_SUM=0; LAT_N=0; LAT_WORST=0; LOST_TOTAL=0; SPIKY_SECS=0
LAT_HIST=()             # every per-second peak, for the end-of-session timeline
FRAME=0

boot_time() { sysctl -n kern.boottime | sed -E 's/.*sec = ([0-9]+).*/\1/'; }

save_state() {
    mkdir -p "$STATE_DIR"
    cat > "$STATE_FILE" <<EOF
BOOT_TIME='$BOOT_TIME'
STOPPED_PIDS='$STOPPED_PIDS'
IFACES_DOWNED='$IFACES_DOWNED'
TIMER_COALESCE_ORIG='$TIMER_COALESCE_ORIG'
LOWPOWER_ORIG='$LOWPOWER_ORIG'
TM_DISABLED=$TM_DISABLED
AIRDROP_CHANGED=$AIRDROP_CHANGED
AIRDROP_ORIG='$AIRDROP_ORIG'
MOONLIGHT_PID='$MOONLIGHT_PID'
EOF
}

iface_up() { ifconfig "$1" 2>/dev/null | head -1 | grep -q '<UP'; }

default_iface() { route -n get default 2>/dev/null | awk '/interface:/{print $2}'; }

wifi_iface() {
    networksetup -listallhardwareports 2>/dev/null \
        | awk '/Hardware Port: Wi-Fi/{getline; print $2}'
}

# ── Diagnostics ─────────────────────────────────────────────────────────────

# system_profiler takes ~8 s on Wi-Fi (it enumerates nearby networks), so kick
# it off in the background at launch and let the banner + sudo prompt hide it.
WIFI_INFO_FILE=""; WIFI_INFO_PID=""; WIFI_T0=""
SCAN_FILE="$STATE_DIR/scan_secs"   # how long the last lookup took, to pace the moon
prefetch_wifi() {
    [[ -n "$WIFI_INFO_PID" || "$(default_iface)" != "$(wifi_iface)" ]] && return
    WIFI_INFO_FILE=$(mktemp -t lunatune-wifi)
    WIFI_T0=$(date +%s)
    system_profiler SPAirPortDataType > "$WIFI_INFO_FILE" 2>/dev/null &
    disown
    WIFI_INFO_PID=$!
}

# The lookup talks to locationd; if a running session has it paused, the query
# never returns. Give it until WIFI_DEADLINE seconds after launch, then give up.
# The intro spins until the lookup lands (up to this deadline) so tuning never
# pauses locationd while the lookup is still in flight.
WIFI_DEADLINE=20
wifi_overdue() { [[ -n "$WIFI_T0" ]] && (( $(date +%s) - WIFI_T0 >= WIFI_DEADLINE )); }

wait_wifi() {
    local frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏) i=0
    while kill -0 "$WIFI_INFO_PID" 2>/dev/null; do
        if wifi_overdue; then
            kill "$WIFI_INFO_PID" 2>/dev/null
            $FANCY && printf '\r\033[K'
            return 1
        fi
        $FANCY && printf '\r  %s%s\033[0m %sreading Wi-Fi link…\033[0m' "$(c256 111)" "${frames[i % 10]}" "$(printf '%b' "$DIM")"
        i=$((i+1))
        sleep 0.1
    done
    $FANCY && printf '\r\033[K'
}

diagnose() {
    local def wifi batt lpm info phy chan sig rate rssi band
    def=$(default_iface); wifi=$(wifi_iface)
    section "Link & power"

    if [[ -z "$def" ]]; then
        warn "No default route — not connected?"
    elif [[ "$def" == "$wifi" ]]; then
        prefetch_wifi
        if wait_wifi; then
            info=$(sed -n '/Current Network Information/,/Other Local/p' "$WIFI_INFO_FILE")
        else
            info=""
            warn "Wi-Fi details timed out after ${WIFI_DEADLINE}s (locationd busy, or paused by another lunatune session)"
        fi
        rm -f "$WIFI_INFO_FILE"
        phy=$(awk -F': ' '/PHY Mode/{print $2; exit}' <<<"$info")
        chan=$(awk -F': ' '/Channel:/{print $2; exit}' <<<"$info")
        sig=$(awk -F': ' '/Signal \/ Noise/{print $2; exit}' <<<"$info")
        rate=$(awk -F': ' '/Transmit Rate/{print $2; exit}' <<<"$info")
        echo -e "  Path        Wi-Fi ($def)  $phy"
        if [[ -n "$info" ]]; then
            echo -e "  Channel     $chan"
            echo -e "  Signal      $sig   tx ${rate} Mbps"
        fi
        rssi=$(grep -oE '^-?[0-9]+' <<<"$sig")
        band=$(grep -oE '[0-9.]+GHz' <<<"$chan")
        [[ "$band" == "2.4GHz" ]] && warn "On 2.4 GHz — shares airtime with Bluetooth controllers. Use 5 or 6 GHz."
        [[ -n "$rssi" && "$rssi" -lt -67 ]] && warn "Signal ${rssi} dBm is weak; aim for -65 or better."
        [[ "$chan" == *"20MHz"* ]] && warn "20 MHz channel width caps throughput; 80 MHz is typical."
        [[ "$band" == "6GHz" ]] && echo -e "  ${DIM}6 GHz: AWDL can't share this channel, so suppressing it matters more.${RST}"
    else
        echo -e "  Path        wired ($def) — best case; Wi-Fi tweaks will be skipped"
    fi

    batt=$(pmset -g batt | head -1 | grep -oE "'[^']+'" | tr -d "'")
    lpm=$(pmset -g | awk '/lowpowermode/{print $2}')
    echo -e "  Power       ${batt:-unknown}  lowpowermode=${lpm:-n/a}"
    [[ "$batt" == "Battery Power" ]] && warn "On battery: system-sleep prevention (caffeinate -s) only works on AC. Plug in for long sessions."
    section_end
}

# ── Live status bar ─────────────────────────────────────────────────────────

# Latency → bar glyph + color on a fixed scale, so a spike looks like a spike.
spark_glyph() {
    [[ "$1" == "-" ]] && { printf '%s▁' "$(c256 237)"; return; }
    local ms=${1%.*} g c
    if   (( ms < 3 ));  then g=▁ c=48
    elif (( ms < 5 ));  then g=▂ c=48
    elif (( ms < 8 ));  then g=▃ c=84
    elif (( ms < 12 )); then g=▄ c=148
    elif (( ms < 20 )); then g=▅ c=184
    elif (( ms < 35 )); then g=▆ c=214
    elif (( ms < 60 )); then g=▇ c=202
    else                     g=█ c=196
    fi
    printf '%s%s' "$(c256 $c)" "$g"
}

fmt_dur() { printf '%02d:%02d:%02d' $(( $1/3600 )) $(( $1%3600/60 )) $(( $1%60 )); }

draw_status() {
    $FANCY && $SESSION_LIVE || return
    local moons=(🌑 🌒 🌓 🌔 🌕 🌖 🌗 🌘) avg="" max="" lost=0 spark="" v cols lat ml
    FRAME=$(( (FRAME + 1) % 8 ))

    if [[ -n "$KEEPALIVE_TARGET" && -s "$LAT_FILE" ]]; then
        # shellcheck disable=SC2046  # intentional: split into avg / max / lost
        set -- $(awk '{s+=$1; n++; if ($2>m) m=$2; l+=$3} END{if (n) printf "%.2f %.1f %d", s/n, m, l}' "$LAT_FILE")
        : > "$LAT_FILE"
        avg=$1 max=$2 lost=$3
        SPARK+=("$max")
        (( ${#SPARK[@]} > SPARK_W )) && SPARK=("${SPARK[@]:1}")
        LAT_SUM=$(awk -v a="$LAT_SUM" -v b="$avg" 'BEGIN{print a+b}'); LAT_N=$((LAT_N+1))
        LOST_TOTAL=$((LOST_TOTAL + ${lost:-0}))
        (( ${max%.*} > ${LAT_WORST%.*} )) && LAT_WORST=$max
        (( ${max%.*} >= 30 )) && SPIKY_SECS=$((SPIKY_SECS+1))
    fi
    [[ -n "$avg" ]] && LAT_HIST+=("$max")
    cols=$(tput cols 2>/dev/null || echo 100)

    if $NERD; then
        draw_pills "$avg" "$max" "$lost" "$cols"
        return
    fi

    for v in ${SPARK[@]+"${SPARK[@]}"}; do spark+=$(spark_glyph "$v"); done

    if [[ -n "$avg" ]]; then
        lat="${spark}${RST} $(printf '%5.1f' "$avg")ms ${DIM}pk $(printf '%.0f' "$max")${RST}"
        (( ${lost:-0} > 0 )) && lat+=" ${RED}✗${lost}${RST}"
    elif [[ -n "$KEEPALIVE_TARGET" ]]; then
        lat="${spark}${RST} ${DIM}  ···${RST}"
    else
        lat="${DIM}wired · no probe${RST}"
    fi

    if [[ -n "$MOONLIGHT_PID" ]] && kill -0 "$MOONLIGHT_PID" 2>/dev/null; then
        ml="${GRN}●${RST} Moonlight"
    else
        ml="${DIM}○ Moonlight${RST}"
    fi

    local sep bar
    sep=" $(c256 60)│${RST} "
    bar="${moons[$FRAME]} $(c256 159)${BLD}LIVE${RST} ${DIM}$(fmt_dur $SECONDS)${RST}${sep}${lat}${sep}AWDL $(c256 111)⊘${AWDL_HITS}${RST}${sep}${ml}"
    (( cols < 90 )) && bar="${moons[$FRAME]} ${DIM}$(fmt_dur $SECONDS)${RST}${sep}${lat}${sep}⊘${AWDL_HITS}"
    printf '\r\033[K%b' "$bar"
}

# Powerline status bar: rounded pills shaded through the moonlit palette.
# Each segment: background, foreground, contents. Separators take the previous
# pill's colour as foreground over the next pill's background.
PL_OUT=""; PL_PREV=""
pl_seg() {
    local bg=$1 fg=$2 text=$3
    if [[ -z "$PL_PREV" ]]; then
        PL_OUT+="\033[0m\033[38;5;${bg}m${PL_L}"
    else
        PL_OUT+="\033[38;5;${PL_PREV};48;5;${bg}m${PL_R}"
    fi
    PL_OUT+="\033[48;5;${bg};38;5;${fg}m ${text} "
    PL_PREV=$bg
}
pl_end() { PL_OUT+="\033[0m\033[38;5;${PL_PREV}m${PL_R}\033[0m"; PL_PREV=""; }

draw_pills() {
    local avg=$1 max=$2 lost=$3 cols=$4
    local moons=(🌑 🌒 🌓 🌔 🌕 🌖 🌗 🌘) spark="" i n start
    local narrow=false; (( cols < 90 )) && narrow=true

    # Sparkline (its glyphs only set the foreground, so the pill bg shows through).
    n=${#SPARK[@]}; start=0
    $narrow && (( n > 12 )) && start=$(( n - 12 ))
    for (( i=start; i<n; i++ )); do spark+=$(spark_glyph "${SPARK[$i]}"); done

    PL_OUT=""; PL_PREV=""
    pl_seg 54 231 "${moons[$FRAME]} \033[1mLIVE\033[22m \033[38;5;183m$(fmt_dur $SECONDS)"
    if [[ -n "$avg" ]]; then
        local lat
        lat="\033[38;5;177m${I_PULSE} ${spark} \033[38;5;255m$(printf '%.1f' "$avg")ms"
        $narrow || lat+=" \033[38;5;245mpk $(printf '%.0f' "$max")"
        (( ${lost:-0} > 0 )) && lat+=" \033[38;5;203m✗${lost}"
        pl_seg 235 252 "$lat"
    elif [[ -n "$KEEPALIVE_TARGET" ]]; then
        pl_seg 235 245 "\033[38;5;177m${I_PULSE} ${spark} \033[38;5;245m···"
    else
        pl_seg 235 245 "wired"
    fi
    pl_seg 61 231 "${I_SHIELD} ${AWDL_HITS}"
    if [[ -n "$MOONLIGHT_PID" ]] && kill -0 "$MOONLIGHT_PID" 2>/dev/null; then
        if $narrow; then pl_seg 30 231 "${I_PAD}"; else pl_seg 30 231 "${I_PAD} Moonlight"; fi
    else
        pl_seg 238 245 "${I_PAD}"
    fi
    pl_end
    printf '\r\033[K%b' "$PL_OUT"
}

# Session timeline: the whole run's per-second peaks squeezed into $1 columns
# (max per bucket, so short spikes survive the downsampling).
timeline() {
    local w=$1 v out=""
    (( ${#LAT_HIST[@]} == 0 )) && return
    for v in $(printf '%s\n' "${LAT_HIST[@]}" | awk -v w="$w" '
        { a[NR] = $1 } END {
            b = (NR < w) ? NR : w
            for (i = 0; i < b; i++) {
                lo = int(i * NR / b) + 1; hi = int((i + 1) * NR / b); if (hi < lo) hi = lo
                m = 0; for (j = lo; j <= hi; j++) if (a[j] > m) m = a[j]
                print m
            }
        }'); do
        out+=$(spark_glyph "$v")
    done
    printf '%s\033[0m' "$out"
}

session_summary() {
    local avg="—" clean="—" pct=0 worst="—" grade gcol
    if (( LAT_N > 0 )); then
        avg=$(awk -v s="$LAT_SUM" -v n="$LAT_N" 'BEGIN{printf "%.1f ms", s/n}')
        pct=$(awk -v s="$SPIKY_SECS" -v n="$LAT_N" 'BEGIN{printf "%.1f", 100*(n-s)/n}')
        clean="${pct}%"
        worst=$(printf '%.0f ms' "$LAT_WORST")
    fi
    # Verdict on the share of spike-free seconds.
    if   (( LAT_N == 0 ));                              then grade="no data";    gcol=245
    elif awk -v p="$pct" 'BEGIN{exit !(p >= 99.5)}';    then grade="✦ flawless"; gcol=159
    elif awk -v p="$pct" 'BEGIN{exit !(p >= 98)}';      then grade="solid";      gcol=117
    elif awk -v p="$pct" 'BEGIN{exit !(p >= 95)}';      then grade="decent";     gcol=184
    else                                                     grade="rough";      gcol=203
    fi

    local W=40 r=0
    edge() { printf '\033[38;5;%sm│\033[0m' "${PALETTE[$(( r % ${#PALETTE[@]} ))]}"; }
    # label, plain value, optional coloured value (same visible width as plain)
    card_row() {
        local label=$1 plain=$2 shown=${3:-$2}
        local pad=$(( W - 2 - 13 - 1 - ${#plain} )); (( pad < 0 )) && pad=0
        printf '%s  \033[2m%-13s\033[0m %b%*s%s\n' "$(edge)" "$label" "$shown" "$pad" '' "$(edge)"
        r=$((r+1))
    }

    echo ""
    echo -e "$(c256 93)╭─ ${RST}${BLD}Session${RST} $(grad_rule $(( W - 10 )))$(c256 159)╮${RST}"
    card_row "Verdict"     "$grade" "\033[1;38;5;${gcol}m${grade}\033[0m"
    card_row "Duration"    "$(fmt_dur $SECONDS)"
    card_row "Latency avg" "$avg"
    card_row "Worst spike" "$worst"
    card_row "Clean secs"  "$clean (<30 ms)"
    card_row "Lost pings"  "$LOST_TOTAL"
    card_row "AWDL blocks" "$AWDL_HITS"
    if (( ${#LAT_HIST[@]} > 0 )); then
        local tw=$(( W - 4 )) shown
        shown=$(timeline $tw)
        local got=$(( ${#LAT_HIST[@]} < tw ? ${#LAT_HIST[@]} : tw ))
        printf '%s  %s%*s  %s\n' "$(edge)" "$shown" $(( tw - got )) '' "$(edge)"; r=$((r+1))
    fi
    echo -e "$(c256 93)╰$(grad_rule $W)$(c256 159)╯${RST}"
}

# Sign-off with a highlight sweeping across it (perl: UTF-8-safe per-char colour).
shimmer() {
    local text="$1"
    if ! $FANCY; then echo "  $text"; return; fi
    perl -CSA -MTime::HiRes=sleep -e '
        my @c = split //, $ARGV[0]; my @pal = (93, 99, 105, 111, 117, 123, 159);
        $| = 1; print "\e[?25l";
        for (my $pos = -4; $pos <= @c + 4; $pos += 0.75) {
            my $s = "";
            for my $i (0 .. $#c) {
                my $d = abs($i - $pos);
                my $col = $d < 0.8 ? 231 : $d < 2.2 ? 195 : $pal[int($i * @pal / @c)];
                $s .= "\e[38;5;${col}m$c[$i]";
            }
            print "\r  $s\e[0m"; sleep 0.022;
        }
        my $s = join "", map { "\e[38;5;" . $pal[int($_ * @pal / @c)] . "m$c[$_]" } 0 .. $#c;
        print "\r  $s\e[0m\e[?25h\n";
    ' "$text"
}

# ── Restore (shared by Ctrl+C, crash, and --restore) ───────────────────────

restore_all() {
    $RESTORED && return
    RESTORED=true
    if $FANCY; then printf "\r\033[K\033[?25h"; fi
    echo ""
    section "Restoring"

    [[ -n "$MONITOR_PID" ]] && kill "$MONITOR_PID" 2>/dev/null
    [[ -n "$KEEPALIVE_PID" ]] && kill "$KEEPALIVE_PID" 2>/dev/null
    { exec 3<&-; } 2>/dev/null
    [[ -n "$WIFI_INFO_PID" ]] && kill "$WIFI_INFO_PID" 2>/dev/null
    [[ -n "$WIFI_INFO_FILE" ]] && rm -f "$WIFI_INFO_FILE"
    rm -f "$FIFO"

    local stale=false
    [[ -n "$BOOT_TIME" && "$BOOT_TIME" != "$(boot_time)" ]] && stale=true
    if $stale; then
        log "Rebooted since the tuned session — skipping volatile state (PIDs, sysctls, interfaces)"
    fi

    if ! $stale; then
        if [[ -n "$MOONLIGHT_PID" ]] && kill -0 "$MOONLIGHT_PID" 2>/dev/null; then
            sudo renice 0 -p "$MOONLIGHT_PID" >/dev/null 2>&1 && ok "Moonlight priority reset"
        fi

        if [[ -n "$STOPPED_PIDS" ]]; then
            local pid n=0
            for pid in $STOPPED_PIDS; do
                sudo kill -CONT "$pid" 2>/dev/null && n=$((n+1))
            done
            ok "Resumed $n stopped processes"
        fi

        local ifc
        for ifc in $IFACES_DOWNED; do
            sudo ifconfig "$ifc" up 2>/dev/null
        done
        [[ -n "$IFACES_DOWNED" ]] && ok "Brought back up: $IFACES_DOWNED ($AWDL_HITS re-suppressions this session)"

        if [[ -n "$TIMER_COALESCE_ORIG" ]]; then
            sudo sysctl -w "kern.timer.coalescing_enabled=$TIMER_COALESCE_ORIG" >/dev/null 2>&1 \
                && ok "Timer coalescing restored ($TIMER_COALESCE_ORIG)"
        fi
    fi

    if $AIRDROP_CHANGED; then
        if [[ "$AIRDROP_ORIG" == "__unset__" ]]; then
            defaults delete com.apple.sharingd DiscoverableMode 2>/dev/null
        else
            defaults write com.apple.sharingd DiscoverableMode -string "$AIRDROP_ORIG"
        fi
        killall sharingd 2>/dev/null
        ok "AirDrop discoverability restored (${AIRDROP_ORIG/__unset__/default})"
    fi

    if [[ -n "$LOWPOWER_ORIG" ]]; then
        sudo pmset -a lowpowermode "$LOWPOWER_ORIG" && ok "Low Power Mode restored ($LOWPOWER_ORIG)"
    fi

    $TM_DISABLED && sudo tmutil enable 2>/dev/null && ok "Time Machine auto-backup re-enabled"

    [[ -n "$CAFFEINATE_PID" ]] && kill "$CAFFEINATE_PID" 2>/dev/null
    [[ -n "$SUDO_KEEPALIVE_PID" ]] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null
    rm -f "$STATE_FILE" "$LAT_FILE"
    ok "Done."
    section_end
    if $SESSION_LIVE; then
        session_summary
        echo ""
        shimmer "🌘 moonset — everything's back to normal"
        echo ""
    fi
}

# Signals only raise a flag; the loop exits and restore runs from the EXIT trap.
# (Restoring inside the INT trap is unsafe: bash 3.2 lets a pending `read -t`
# timeout longjmp out of the handler halfway through.)
STOP=false
# shellcheck disable=SC2329  # both are invoked via trap
on_signal() { STOP=true; }
# shellcheck disable=SC2329
on_exit() { trap - INT TERM HUP EXIT; restore_all; }

# ── Demo ────────────────────────────────────────────────────────────────────
# `lunatune --demo`: the full show with simulated data. Changes nothing, needs
# no sudo — for trying the visuals and recording the README GIF.
run_demo() {
    if ! $FANCY; then err "--demo needs an interactive terminal"; exit 1; fi
    DEMO=true
    LAT_FILE=$(mktemp -t lunatune-demo)
    trap 'printf "\033[0m\033[?25h"; rm -f "$LAT_FILE"' EXIT
    trap 'exit 0' INT TERM

    sleep 6 & local fake_lookup=$!
    disown
    WIFI_T0=$(date +%s)
    moon_intro "$fake_lookup" 2.5 12

    section "Link & power"
    echo -e "  Path        Wi-Fi (en0)  802.11ax"
    echo -e "  Channel     149 (5GHz, 80MHz)"
    echo -e "  Signal      -54 dBm / -95 dBm   tx 864 Mbps"
    echo -e "  Power       AC Power  lowpowermode=0"
    section_end
    echo ""
    section "Tuning"
    local step
    for step in "Sleep prevention active" "Timer coalescing disabled" "AirDrop set to No One" \
                "Peer-to-peer Wi-Fi down: awdl0 llw0" "Paused 6 background processes" \
                "Moonlight boosted: nice -10, tier 0" "Wi-Fi keepalive → streaming host every 0.02s"; do
        ok "$step"; sleep 0.12
    done
    section_end
    echo ""
    log "Running. ${BLD}Ctrl+C${RST} restores everything. ${DIM}(demo: simulated data)${RST}"
    echo ""

    SECONDS=0; SESSION_LIVE=true; KEEPALIVE_TARGET=demo; MOONLIGHT_PID=$$
    printf '\033[?25l'
    local i v
    for (( i=0; i<14; i++ )); do
        v=$(( 2 + RANDOM % 3 )).$(( RANDOM % 10 ))
        (( i == 8 )) && v=24.6                      # a bump, to show how spikes register
        echo "$(( 2 + RANDOM % 2 )).$(( RANDOM % 10 )) $v 0" > "$LAT_FILE"
        draw_status
        sleep 0.6
        (( i == 5 )) && AWDL_HITS=1 && note "awdl0 came back up — suppressed (#1)"
    done
    printf '\r\033[K\033[?25h'
    echo ""
    section "Restoring"
    for step in "Moonlight priority reset" "Resumed 6 stopped processes" "Brought back up: awdl0 llw0" \
                "Timer coalescing restored (1)" "AirDrop discoverability restored" "Done."; do
        ok "$step"; sleep 0.08
    done
    section_end
    session_summary
    echo ""
    shimmer "🌘 moonset — everything's back to normal"
    echo ""
}

# ── Entry ───────────────────────────────────────────────────────────────────

if [[ $EUID -eq 0 ]]; then
    err "Run as your normal user (not sudo) — per-user processes and prefs need your session."
    exit 1
fi

case "${1:-}" in
    --demo)
        run_demo; exit 0 ;;
    --status)
        prefetch_wifi
        $FANCY && [[ -n "$MOON_PL" ]] && moon_intro "$WIFI_INFO_PID" 1 "$WIFI_DEADLINE"
        diagnose; exit 0 ;;
    --restore)
        if [[ ! -f "$STATE_FILE" ]]; then
            ok "No saved state at $STATE_FILE — nothing to restore."
            exit 0
        fi
        sudo -v || { err "sudo required"; exit 1; }
        # shellcheck disable=SC1090
        source "$STATE_FILE"
        restore_all
        exit 0 ;;
    "") ;;
    *)
        sed -n '2,8p' "$0"; exit 1 ;;
esac

if [[ -f "$STATE_FILE" ]]; then
    err "A previous session didn't clean up. Run: $0 --restore"
    exit 1
fi

prefetch_wifi

sudo -v || { err "sudo required"; exit 1; }
# Keepalive dies with us instead of lingering as an orphan.
( while kill -0 $$ 2>/dev/null; do sudo -n -v 2>/dev/null; sleep 50; done ) &
disown
SUDO_KEEPALIVE_PID=$!

trap on_signal INT TERM HUP
trap on_exit EXIT
BOOT_TIME=$(boot_time)
save_state

# Moon spins until the Wi-Fi lookup lands (or 12 s), then becomes the banner.
banner
$STOP && exit 0

# Wired: the link report is instant, show it now. Wi-Fi: system_profiler is
# still running, so the report drops in above the status bar when it lands.
DIAG_PENDING=false
if [[ -n "$WIFI_INFO_PID" ]] && kill -0 "$WIFI_INFO_PID" 2>/dev/null; then DIAG_PENDING=true; else diagnose; echo ""; fi
section "Tuning"

WIFI=$(wifi_iface)
ON_WIFI=false
[[ -n "$WIFI" && "$(default_iface)" == "$WIFI" ]] && ON_WIFI=true

# --- Sleep prevention (-w ties it to this script's lifetime) ---
caffeinate -dimsu -w $$ &
disown
CAFFEINATE_PID=$!
ok "Sleep prevention active"

# --- Low Power Mode ---
lpm=$(pmset -g | awk '/lowpowermode/{print $2}')
if [[ "$lpm" == "1" ]]; then
    sudo pmset -a lowpowermode 0 && { LOWPOWER_ORIG=1; save_state; ok "Low Power Mode off for the session"; }
fi

# --- Timer coalescing (tighter wakeups, slightly more power) ---
TIMER_COALESCE_ORIG=$(sysctl -n kern.timer.coalescing_enabled 2>/dev/null)
if [[ "$TIMER_COALESCE_ORIG" == "1" ]] && sudo sysctl -w kern.timer.coalescing_enabled=0 >/dev/null 2>&1; then
    ok "Timer coalescing disabled"
else
    TIMER_COALESCE_ORIG=""
fi
save_state

# --- Time Machine: only touch it if auto-backup is actually on ---
if [[ "$(defaults read /Library/Preferences/com.apple.TimeMachine AutoBackup 2>/dev/null)" == "1" ]]; then
    if sudo tmutil disable 2>/dev/null; then
        TM_DISABLED=true; save_state
        ok "Time Machine auto-backup paused"
    else
        warn "tmutil disable failed — Terminal needs Full Disk Access"
    fi
fi

# --- Wi-Fi-only: AWDL and friends ---
if $ON_WIFI; then
    # AirDrop "No One" stops sharingd from waking AWDL for discovery.
    cur=$(defaults read com.apple.sharingd DiscoverableMode 2>/dev/null) || cur="__unset__"
    if [[ "$cur" != "Off" ]]; then
        AIRDROP_ORIG="$cur"; AIRDROP_CHANGED=true; save_state
        defaults write com.apple.sharingd DiscoverableMode -string Off
        killall sharingd 2>/dev/null
        ok "AirDrop set to No One"
    fi

    for ifc in "${P2P_IFACES[@]}"; do
        if iface_up "$ifc" && sudo ifconfig "$ifc" down 2>/dev/null; then
            IFACES_DOWNED="$IFACES_DOWNED $ifc"
        fi
    done
    IFACES_DOWNED="${IFACES_DOWNED# }"
    save_state
    [[ -n "$IFACES_DOWNED" ]] && ok "Peer-to-peer Wi-Fi down: $IFACES_DOWNED"
fi

# --- SIGSTOP background work ---
# PIDs matching $name, filtered by owner ("mine" = you, "system" = anyone else).
# Skips iOS Simulator copies of daemons, which have nothing to do with the Mac.
find_pids() {
    local scope="$1" name="$2" pid uid
    for pid in $(pgrep -x "$name" 2>/dev/null); do
        uid=$(ps -o uid= -p "$pid" 2>/dev/null | tr -d ' ')
        [[ -z "$uid" ]] && continue
        [[ "$scope" == mine && "$uid" != "$UID" ]] && continue
        [[ "$scope" == system && "$uid" == "$UID" ]] && continue
        [[ "$(ps -o comm= -p "$pid")" == *CoreSimulator* ]] && continue
        echo "$pid"
    done
}

stop_procs() {
    local scope="$1"; shift
    local name pid
    for name in "$@"; do
        for pid in $(find_pids "$scope" "$name"); do
            if sudo kill -STOP "$pid" 2>/dev/null \
               && [[ "$(ps -o stat= -p "$pid" 2>/dev/null)" == T* ]]; then
                STOPPED_PIDS="$STOPPED_PIDS $pid"
                echo -e "  ${DIM}stopped $name ($pid)${RST}"
            fi
        done
    done
    STOPPED_PIDS="${STOPPED_PIDS# }"
    save_state
}
stop_procs system "${SYSTEM_STOP[@]}"
stop_procs mine "${USER_STOP[@]}"
loc_pid=$(find_pids system locationd | head -1)
if [[ -n "$loc_pid" && " $STOPPED_PIDS " != *" $loc_pid "* ]]; then
    warn "Couldn't pause locationd. Turn off Location Services manually:"
    warn "  System Settings › Privacy & Security › Location Services"
fi
n=$(wc -w <<<"$STOPPED_PIDS" | tr -d ' ')
[[ "$n" -gt 0 ]] && ok "Paused $n background processes"

# --- Moonlight ---
tune_moonlight() {
    local pid
    pid=$(pgrep -x Moonlight 2>/dev/null | head -1)
    [[ -z "$pid" || "$pid" == "$MOONLIGHT_PID" ]] && return
    MOONLIGHT_PID="$pid"
    sudo renice "$MOONLIGHT_NICE" -p "$pid" >/dev/null 2>&1
    # -B: make sure it isn't in the Darwin background band (E-cores + I/O throttle).
    # -t 0 / -l 0: highest throughput and timer-latency tiers.
    sudo taskpolicy -B -t 0 -l 0 -p "$pid" 2>/dev/null
    ok "Moonlight ($pid) boosted: nice $MOONLIGHT_NICE, tier 0"
    save_state
}
tune_moonlight
[[ -z "$MOONLIGHT_PID" ]] && log "Waiting for Moonlight to start…"

# --- Wi-Fi keepalive ---
# Host IP from the newest Moonlight session log ("Executing request: https://IP:port/…").
moonlight_host() {
    local L
    # shellcheck disable=SC2012  # ls -t: newest log by mtime; names are ours (Moonlight-<digits>.log)
    L=$(ls -t /tmp/Moonlight-*.log "${TMPDIR:-/tmp}"/Moonlight-*.log 2>/dev/null | head -1)
    [[ -n "$L" ]] || return
    grep -oE 'https://[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:' "$L" | tail -1 | sed -E 's#https://|:##g'
}

keepalive_retarget() {
    [[ -n "$KEEPALIVE_INTERVAL" ]] && $ON_WIFI || return
    local want
    want=$(moonlight_host)
    [[ -z "$want" ]] && want=$(route -n get default 2>/dev/null | awk '/gateway:/{print $2}')
    [[ -z "$want" || "$want" == "$KEEPALIVE_TARGET" ]] && return
    [[ -n "$KEEPALIVE_PID" ]] && kill "$KEEPALIVE_PID" 2>/dev/null
    # Wrapper reaps ping if this script dies without running restore.
    # Replies stream through awk, which drops "avg max lost" into LAT_FILE every
    # ~half second for the status bar. Killing awk takes ping down via SIGPIPE.
    local batch
    batch=$(awk -v i="$KEEPALIVE_INTERVAL" 'BEGIN{n=int(0.5/i); print (n<1?1:n)}')
    ( ping -i "$KEEPALIVE_INTERVAL" "$want" 2>/dev/null \
        | awk -v f="$LAT_FILE" -v b="$batch" '
            /time=/     { t=$0; sub(/.*time=/, "", t); t+=0; s+=t; if (t>m) m=t; n++ }
            /timeout/   { l++; n++ }
            n>=b        { printf "%.2f %.1f %d\n", (n>l ? s/(n-l) : 0), m, l >> f; close(f); s=m=n=l=0 }' &
      p=$!
      trap 'kill $p 2>/dev/null; exit' TERM
      while kill -0 $$ 2>/dev/null && kill -0 $p 2>/dev/null; do sleep 1; done
      kill $p 2>/dev/null ) &
    disown
    KEEPALIVE_PID=$!
    KEEPALIVE_TARGET="$want"
    : > "$LAT_FILE"
    ok "Wi-Fi keepalive → $want every ${KEEPALIVE_INTERVAL}s"
}
keepalive_retarget

section_end
echo ""
$ON_WIFI || log "Wired connection — skipping AWDL watch."
log "Running. ${BLD}Ctrl+C${RST} restores everything. Crash recovery: ${DIM}$(basename "$0") --restore${RST}"
echo ""

# Live from here: start the session clock, hide the cursor under the status bar.
SECONDS=0
SESSION_LIVE=true
$FANCY && printf "\033[?25l"

# One housekeeping pass per wall-clock second, however busy the routing socket is.
LAST_TICK=-1
tick() {
    (( SECONDS == LAST_TICK )) && return
    LAST_TICK=$SECONDS
    $ON_WIFI && resuppress
    tune_moonlight
    keepalive_retarget
    if $DIAG_PENDING && { ! kill -0 "$WIFI_INFO_PID" 2>/dev/null || wifi_overdue; }; then
        DIAG_PENDING=false
        $FANCY && printf "\r\033[K"
        diagnose
        echo ""
    fi
    draw_status
}

# --- Watch loop ---
# awdl0 is brought back up by the system on demand. Instead of polling every
# couple of seconds (and eating a spike each time), listen on the routing
# socket and knock it down the moment its link flags change. The 1 s read
# timeout doubles as a fallback poll and the Moonlight re-check.
resuppress() {
    local ifc
    for ifc in $IFACES_DOWNED; do
        if iface_up "$ifc"; then
            sudo ifconfig "$ifc" down 2>/dev/null
            AWDL_HITS=$((AWDL_HITS+1))
            note "$ifc came back up — suppressed (#$AWDL_HITS)"
        fi
    done
}

if $ON_WIFI && [[ -n "$IFACES_DOWNED" ]]; then
    rm -f "$FIFO"; mkfifo "$FIFO"
    route -n monitor > "$FIFO" 2>/dev/null &
    disown
    MONITOR_PID=$!
    exec 3<"$FIFO"
    while ! $STOP; do
        if read -r -t 1 -u 3 line; then
            [[ "$line" == RTM_IFINFO* ]] && resuppress
        else
            $STOP && break
            kill -0 "$MONITOR_PID" 2>/dev/null || { warn "route monitor exited"; break; }
        fi
        tick
    done
fi

# Wired, or the monitor died: plain poll.
while ! $STOP; do
    tick
    sleep 1
done
exit 0
