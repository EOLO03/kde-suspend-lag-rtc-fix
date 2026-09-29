# Evidence

These are raw measurements taken on the affected machine during one lag episode, on 2026-09-29.

- Machine: Lenovo ThinkBook 16p G5, i9-14900HX, Intel UHD iGPU (RTX 4060 disabled via envycontrol `integrated`), Fedora 44, kernel 7.2.7-200.fc44, KDE Plasma / KWin 6.7.5 (Wayland), Mesa 26.2.3, running on battery.
- The system had resumed from s2idle at 14:45:04 local time and was lagging.

Output was trimmed to the relevant lines. Nothing else was changed.

## 1. The trigger: RTC in local time, clock off by exactly 3 hours after resume

```
$ timedatectl
               Local time: Tue 2026-09-29 15:06:45 EEST
           Universal time: Tue 2026-09-29 12:06:45 UTC
                 RTC time: Tue 2026-09-29 12:08:43
                Time zone: Asia/Nicosia (EEST, +0300)
System clock synchronized: no
              NTP service: active
          RTC in local TZ: yes
```

Journal, 11 seconds after resume:

```
2026-09-29T14:45:04+03:00 systemd-logind: Lid opened.
2026-09-29T14:45:05+03:00 kernel: PM: suspend exit
2026-09-29T14:45:15+03:00 chronyd[1511]: System clock wrong by -10799.997000 seconds
```

`10799.997 s` is 3 hours, which equals the UTC+3 offset.

The same boot logged `Clock change detected` after 14 different resumes.

## 2. chrony is slewing instead of stepping

```
$ chronyc tracking
System time     : 10681.260742188 seconds fast of NTP time
RMS offset      : 1323.141235352 seconds
Frequency       : 11.309 ppm slow
```

```
$ grep makestep /etc/chrony.conf
makestep 1.0 3
```

`makestep 1.0 3` only allows stepping during the first 3 clock updates after chronyd starts. Later offsets are slewed.

## 3. The kernel clock is running 8.3% slow

`adjtimex()` values:

```
tick 9167 (normal 10000)  freq_ppm -22.97  status 0x40
```

`CLOCK_MONOTONIC` compared with the unadjusted `CLOCK_MONOTONIC_RAW` over 5 seconds:

```
MONOTONIC / MONOTONIC_RAW ratio: 0.91668   (healthy ≈ 1.00000)
```

With a remaining offset of about 10 700 s and a slew of about 8.3%, the correction would take about 36 hours.

## 4. The fix works instantly

```
$ sudo chronyc makestep
$ chronyc tracking | grep "System time"
System time     : 0.000000001 seconds slow of NTP time

MONOTONIC / MONOTONIC_RAW ratio: 1.00001
```

The desktop lag disappeared immediately, without a reboot.

After `sudo timedatectl set-local-rtc 0`:

```
                 RTC time: Tue 2026-09-29 17:52:14
           Universal time: Tue 2026-09-29 17:52:14 UTC
System clock synchronized: yes
          RTC in local TZ: no
```

## 5. What was ruled out, measured while lagging

| Check | Result |
|---|---|
| CPU load | 97.8% idle, load average about 1.4 |
| Memory | 7.5 GiB available, no swap use, PSI memory/io/cpu about 0 |
| Temperatures | Package 44 °C |
| CPU boost | Single core reached 5.7 GHz. All-core load gave 1.8–2.1 GHz, which is the normal 35 W battery limit |
| Thermal throttling / PROCHOT | `package_throttle_count` +0 at idle and under full load |
| Timer wake-up latency, all 32 CPUs | Median 86–188 µs, max < 0.9 ms |
| Clocksource | `tsc`, no "unstable" messages |
| cpuidle | `intel_idle`, all states enabled |
| ACPI interrupt storm | 0 GPEs in 5 s |
| KWin renderer | OpenGL 4.6, Mesa Intel (RPL-S), hardware accelerated |
| KWin scheduling | SCHED_RR, affinity 0–31, no cgroup CPU limit |
| iGPU busy during Overview animation | 23% (RC6 residency), no throttle reasons |
| iGPU frequency | 300–1650 MHz range available, SLPC active |
| Panel Self Refresh | `PSR = no, Panel Replay = no` (not supported by the panel) |
| i915 errors in the last 6 boots | None |

None of these interventions helped:
- Disabling the KWin blur effect.
- Turning the display off and on with DPMS.
- Switching the display mode from 60 Hz to 165 Hz and back.
