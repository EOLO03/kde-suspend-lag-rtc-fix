#!/usr/bin/env bash
# Detects the "desktop is laggy after suspend until reboot" problem caused by
# the system clock being slewed (slowed down) after a large post-resume offset.
# Read-only: changes nothing on the system. No root required.

set -u

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }

problems=0

echo "== 1. Is the hardware clock (RTC) kept in local time?"
if timedatectl 2>/dev/null | grep -q "RTC in local TZ: yes"; then
    red   "   YES - RTC is in local time (typical on Windows dual-boot). This is the usual trigger."
    problems=$((problems + 1))
else
    green "   No - RTC is in UTC."
fi

echo "== 2. How fast is the system clock running compared to the hardware?"
ratio=$(python3 - <<'EOF'
import time
r0 = time.clock_gettime(time.CLOCK_MONOTONIC_RAW); m0 = time.clock_gettime(time.CLOCK_MONOTONIC)
time.sleep(3)
r1 = time.clock_gettime(time.CLOCK_MONOTONIC_RAW); m1 = time.clock_gettime(time.CLOCK_MONOTONIC)
print(f"{(m1 - m0) / (r1 - r0):.5f}")
EOF
)
echo "   CLOCK_MONOTONIC / CLOCK_MONOTONIC_RAW = $ratio  (healthy: ~1.00000)"
if awk -v r="$ratio" 'BEGIN { exit !(r < 0.999 || r > 1.001) }'; then
    red   "   The system clock is being slewed. Animations and frame timing run at the wrong speed."
    problems=$((problems + 1))
else
    green "   Normal."
fi

echo "== 3. What does the NTP daemon think?"
if command -v chronyc >/dev/null 2>&1; then
    line=$(chronyc tracking 2>/dev/null | grep "System time")
    echo "   ${line:-chronyc tracking returned nothing}"
    secs=$(echo "$line" | awk '{print $4}')
    if [ -n "$secs" ] && awk -v s="$secs" 'BEGIN { exit !(s > 60) }'; then
        red   "   Clock is off by more than a minute and is being corrected slowly."
        problems=$((problems + 1))
    fi
else
    yellow "   chronyc not found, skipping."
fi

echo "== 4. Large clock corrections in the journal (last 2 days)"
journalctl --since "-2 days" --no-pager -o short-iso 2>/dev/null \
    | grep -E "System clock wrong by|Time jumped|Clock change detected" | tail -3 | sed 's/^/   /'

echo
if [ "$problems" -gt 0 ]; then
    red "Looks like the clock-slew problem. See README.md -> Fix."
    echo "Instant relief (no reboot):  sudo chronyc makestep"
else
    green "No sign of the clock-slew problem right now."
    echo "If the lag is intermittent, run this again right after the next resume while it is laggy."
fi
