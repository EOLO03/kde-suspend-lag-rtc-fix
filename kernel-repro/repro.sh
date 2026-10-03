#!/bin/bash
# Reproducer for RHBZ 2543517: bogus sleep time injected on s2idle resume
# when the RTC is ahead of system time (RTC in local time, east of UTC).
# Run as root. Needs the RTC to currently hold local time.
#   sudo bash repro.sh [control_cycles] [test_cycles] [alarm_min] [alarm_max] [alarm_rtc]
# alarm_min..alarm_max: wake alarm range in seconds. It has to straddle the
#   time this machine needs to reach s2idle, so that some cycles are frozen
#   for less than a second.
# alarm_rtc: rtc0 or rtc1. Probed when omitted.
set -u
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }

A=${1:-8}; B=${2:-30}; AMIN=${3:-3}; AMAX=${4:-6}; WAKE=${5:-}
T=/sys/kernel/tracing
RTC=/sys/class/rtc/rtc0
OUT="$(dirname "$0")/repro-$(date +%Y%m%d-%H%M%S)"
PROBE=8
TCLOCK=local
z=$(date +%z); TZOFF=$(( (10#${z:1:2}*3600 + 10#${z:3:2}*60) * ${z:0:1}1 ))
[ "$TZOFF" -gt 0 ] || { echo "timezone is not east of UTC, bug cannot show"; exit 1; }
off=$(( $(cat $RTC/since_epoch) - $(date +%s) ))
[ $(( off - TZOFF )) -ge -5 ] && [ $(( off - TZOFF )) -le 5 ] || { echo "RTC is not in local time (rtc-sys=$off)"; exit 1; }
[ "$AMAX" -ge "$AMIN" ] || { echo "alarm_max < alarm_min"; exit 1; }

exec > >(tee "$OUT.log") 2>&1
echo "kernel $(uname -r)  tz $z  rtc-sys=$off  alarm +$AMIN..+$AMAX"

settime() {  # system time := RTC (local) - TZOFF + $1 seconds
    hwclock --hctosys --localtime --noadjfile
    python3 -c "import time,sys; time.clock_settime(time.CLOCK_REALTIME, time.time()+float(sys.argv[1]))" "$1"
}
rtcoff() {  # system time minus RTC time, sampled at the next RTC second edge
    python3 - "$RTC/since_epoch" "$TZOFF" <<'EOF'
import sys,time
p,tz=sys.argv[1],int(sys.argv[2])
rd=lambda: int(open(p).read())
a=rd()
while True:
    b=rd(); t=time.time()
    if b!=a: break
print("%.3f" % (t-(b-tz)))
EOF
}
count() { grep -c "$1" $T/trace 2>/dev/null; }
cleanup() {
    cat $T/trace > "$OUT.trace" 2>/dev/null
    echo 0 > $T/events/power/suspend_resume/enable 2>/dev/null
    echo 0 > $T/events/rtcbug/inject/enable 2>/dev/null
    echo '!stacktrace' > $T/events/rtcbug/inject/trigger 2>/dev/null
    echo '-:rtcbug/inject' >> $T/kprobe_events 2>/dev/null
    echo "$TCLOCK" > $T/trace_clock 2>/dev/null
    echo 0 > /sys/power/pm_debug_messages
    for w in /sys/class/rtc/rtc[01]/wakealarm; do echo 0 > "$w" 2>/dev/null; done
    settime 0
    systemctl start chronyd
    [ -n "${SUDO_USER:-}" ] && chown "$SUDO_USER" "$OUT.log" "$OUT.trace"
    echo "restored. log: $OUT.log  trace: $OUT.trace"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

systemctl stop chronyd
echo 1 > /sys/power/pm_debug_messages
# The TSC keeps counting in s2idle, so with this clock the trace shows how
# long timekeeping was really frozen.
TCLOCK=$(sed 's/.*\[\(.*\)\].*/\1/' $T/trace_clock)
echo x86-tsc > $T/trace_clock 2>/dev/null || echo "WARNING: x86-tsc trace clock not available"
echo 1 > $T/tracing_on
echo > $T/trace
echo "cal $(date +%s.%N)" > $T/trace_marker; sleep 1; echo "cal $(date +%s.%N)" > $T/trace_marker
echo 1 > $T/events/power/suspend_resume/enable 2>/dev/null || echo "WARNING: suspend_resume tracepoint not available"
echo '-:rtcbug/inject' >> $T/kprobe_events 2>/dev/null
echo 'p:rtcbug/inject timekeeping_inject_sleeptime64 sec=+0(%di):s64 nsec=+8(%di):s64' >> $T/kprobe_events \
  && echo stacktrace > $T/events/rtcbug/inject/trigger \
  && echo 1 > $T/events/rtcbug/inject/enable || echo "WARNING: kprobe not available"

probe() {  # $1 rtc name: does its alarm wake the machine from s2idle on its own?
    local w=/sys/class/rtc/$1/wakealarm r0 d
    [ -w "$w" ] || return 1
    echo 0 > "$w" 2>/dev/null
    echo "+$PROBE" > "$w" 2>/dev/null || return 1
    r0=$(cat $RTC/since_epoch)
    echo "probe $1" > $T/trace_marker 2>/dev/null
    echo freeze > /sys/power/state 2>/dev/null
    d=$(( $(cat $RTC/since_epoch) - r0 ))
    echo 0 > "$w" 2>/dev/null
    echo "probe $1: alarm +$PROBE, woke after $d s"
    [ "$d" -ge $(( PROBE - 2 )) ] && [ "$d" -le $(( PROBE + 3 )) ]
}
if [ -z "$WAKE" ]; then
    echo "== probing wake alarms (press a key if the machine stays asleep for more than ~15 s)"
    for r in rtc0 rtc1; do probe $r && { WAKE=$r; break; }; done
    [ -n "$WAKE" ] || { echo "no RTC alarm wakes this machine from s2idle, cannot run unattended"; exit 1; }
fi
ALARM=/sys/class/rtc/$WAKE/wakealarm
echo "wake alarm: $WAKE"

jumps=0; OFF=
cycle() {  # $1 label, $2 shift of the system clock relative to the RTC
    local n=$(( AMIN + RANDOM % (AMAX - AMIN + 1) )) wc s0 r0 u0 s1 r1 u1 f0 k0 f1 k1 o rc
    OFF=
    settime "$2"
    sleep "0.$(( RANDOM % 10 ))"
    echo "cycle $1" > $T/trace_marker 2>/dev/null
    f0=$(count 'timekeeping_freeze.*begin'); k0=$(count ' inject: ')
    s0=$(date +%s.%N); r0=$(cat $RTC/since_epoch); u0=$(cut -d' ' -f1 /proc/uptime)
    echo 0 > $ALARM
    if ! echo "+$n" > $ALARM 2>/dev/null; then echo "$1: alarm not set, skipped"; return; fi
    # Arm wakeup event checking, so that an alarm firing before the wake IRQ
    # is armed aborts the suspend instead of getting lost.
    wc=$(timeout 2 cat /sys/power/wakeup_count) && echo "$wc" > /sys/power/wakeup_count 2>/dev/null
    if ! echo freeze > /sys/power/state 2>/dev/null; then echo "$1: alarm=+$n aborted before s2idle"; return; fi
    s1=$(date +%s.%N); r1=$(cat $RTC/since_epoch); u1=$(cut -d' ' -f1 /proc/uptime)
    o=$(rtcoff)
    f1=$(count 'timekeeping_freeze.*begin'); k1=$(count ' inject: ')
    python3 - "$1" "$n" "$2" "$s0" "$s1" "$r0" "$r1" "$u0" "$u1" "$o" "$(( f1 - f0 ))" "$(( k1 - k0 ))" <<'EOF'
import sys
l,n,sh,s0,s1,r0,r1,u0,u1,o,tk,kp=sys.argv[1:]; ds=float(s1)-float(s0); dr=int(r1)-int(r0); du=float(u1)-float(u0)
j=ds-dr>60
print("%s: alarm=+%s shift=%s d_sys=%.1f d_rtc=%d d_boottime=%.1f off_after=%s tk_freeze=%s rtc_inject=%s%s"
      % (l,n,sh,ds,dr,du,o,tk,kp,"   <== JUMP" if j else ""))
sys.exit(3 if j else 0)
EOF
    rc=$?
    [ $rc = 3 ] && jumps=$((jumps+1))
    # off_after of a normal resume is a lower bound for the offset that
    # timekeeping_suspend() tries to keep between system time and the RTC.
    [ $rc = 0 ] && [ $(( f1 - f0 )) -gt 0 ] && OFF=$o
}

echo "== control: $A cycles, system clock not shifted"
offs=()
for i in $(seq 1 "$A"); do cycle "control $i" 0; [ -n "$OFF" ] && offs+=("$OFF"); done
cj=$jumps
# Shift the system clock 0.9 s past the offset the kernel preserves: then a
# freeze shorter than about 0.9 s does not count as "persistent clock advanced".
SH=$(printf '%s\n' "${offs[@]}" | awk '$1!="" && $1>-1.5 && $1<1.5 { if (!n || $1>m) m=$1; n++ } END { if (n) printf "%.3f", m+0.9; else print "1.0" }')
echo "== test: $B cycles, system clock shifted +$SH s relative to RTC (off_after seen: ${offs[*]})"
for i in $(seq 1 "$B"); do cycle "test $i" "$SH"; done

echo "== result: control jumps=$cj/$A  test jumps=$((jumps-cj))/$B"
echo "== kprobe hits on timekeeping_inject_sleeptime64:"
grep -A18 ' inject: ' $T/trace | head -150
echo "== kernel messages:"
dmesg | grep "Timekeeping suspended" | tail -n $(( A + B + 12 ))
