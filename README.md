# Desktop laggy after suspend until reboot? Check your clock.

> **Not KDE-specific.** Despite the repository name, this affects any desktop that times its animations against the system clock. It has been seen on both **KDE Plasma** and **GNOME**.

If your Linux desktop (seen on Fedora 44 with KDE Plasma and with GNOME, Wayland) becomes **slow and choppy after waking from sleep**, with every animation and even the mouse cursor stuttering, and **only a reboot fixes it**, the cause may have nothing to do with your GPU, compositor or kernel.

It may be your **system clock running ~8% slow** while the NTP daemon tries to correct a multi-hour offset.

This is most likely on **Windows dual-boot** machines, where the hardware clock (RTC) is kept in local time.

## Symptoms

- Lag starts right after resume from suspend (s2idle). It does not happen every time.
- Everything is slow: animations, window moves, cursor, menus.
- CPU load, GPU load, temperatures and memory all look normal.
- A reboot fixes it until the next bad resume.
- `timedatectl` shows `RTC in local TZ: yes`.

## Quick check

```bash
git clone https://github.com/EOLO03/kde-suspend-lag-rtc-fix
cd kde-suspend-lag-rtc-fix
bash check.sh
```

The script is read-only and does not need root.

Or check by hand:

```bash
timedatectl | grep "RTC in local TZ"
chronyc tracking | grep "System time"
journalctl -b | grep "System clock wrong by"
```

On an affected machine this looked like:

```
RTC in local TZ: yes
System time     : 10681.260742188 seconds fast of NTP time
chronyd[1511]: System clock wrong by -10799.997000 seconds
```

`-10799.997 s` is exactly **3 hours**, the machine's UTC offset (UTC+3).

## What is going on

1. With the RTC in local time, the system clock came back from suspend shifted by the UTC offset (3 hours here). This is a kernel bug, see [Root cause](#root-cause-a-kernel-bug-in-the-resume-path) below.
2. chrony noticed the offset. Its default Fedora config (`makestep 1.0 3`) only allows stepping the clock during the first 3 updates after boot. After that it **slews** the clock instead.
3. To slew, the kernel slows the clock down by up to ~8.3%. On the affected machine, the kernel `tick` was **9167** instead of 10000. `CLOCK_MONOTONIC` then ran at **0.917×** real speed. At that rate a 3-hour offset takes about **36 hours** to correct.
4. Animations are timed against that slowed clock, while the display still refreshes at a real 60 Hz. The compositor's frame timing (KWin on KDE, Mutter on GNOME) drifts out of step with the panel, so everything is both slower and choppier.
5. On reboot chrony is allowed to step the clock at once, which is why a reboot "fixes" it.

## Root cause: a kernel bug in the resume path

The 3-hour shift in step 1 comes from the kernel, not from chrony or the desktop.

On resume the kernel adds the time spent asleep to the system clock. It has three sources for that, in order of preference: a clocksource that keeps counting during suspend, the "persistent clock" (on x86 the CMOS RTC, read with a resolution of one second), and the RTC driver.

- `rtc_suspend()` saves the RTC time and the system time so that `rtc_resume()` can compare them later. On a machine with a persistent clock, which is every x86 PC, it returns early and saves nothing.
- `rtc_resume()` is skipped only if the timekeeping core has already added the sleep time. With suspend-to-idle (s2idle) the timekeeping core is frozen and unfrozen on every pass through the idle loop. If the last freeze is shorter than a second, the CMOS clock has not moved, so nothing is added and `rtc_resume()` runs.
- With nothing saved, `rtc_resume()` computes `RTC time − system time` and adds it as "sleep time". With the RTC in UTC that is about zero. With the RTC in local time east of UTC it is the UTC offset. West of UTC the value is negative and is not added.

So the jump needs three things: s2idle, the RTC in local time east of UTC, and a resume whose last freeze lasted less than a second. The last one is a matter of timing, which is why it only happens now and then (2 out of 35 suspend cycles in normal use on the affected machine).

The two conditions have been out of step since a change made in 2015, so the bug is not new. It only becomes visible on machines that keep the RTC in local time.

### Reproducing it

[`kernel-repro/repro.sh`](kernel-repro/repro.sh) triggers the jump on purpose. It needs root and an RTC that currently holds local time. It stops chronyd, shifts the system clock by less than a second relative to the RTC, suspends to idle with a wake alarm a few seconds ahead, and puts a kprobe on `timekeeping_inject_sleeptime64()` to record who adds the bogus sleep time. It restores the clock and restarts chronyd when it exits.

| Kernel | Control cycles (clock not shifted) | Test cycles (clock shifted) |
|---|---|---|
| 7.2.8-200.fc44 | 0 of 8 jumped | 7 of 30 jumped |
| 7.3-rc5, unpatched | 0 of 8 jumped | 4 of 30 jumped |
| 7.3-rc5, patched | 0 of 8 jumped | 0 of 30 jumped |

Every jump was 10797 to 10799 seconds, and every one came from `rtc_resume()`. In all of them timekeeping had been frozen for less than 0.9 seconds. On the patched kernel 6 cycles met that condition and none jumped. The logs and traces are in [`kernel-repro/`](kernel-repro/).

### Kernel patch

A fix was sent to the RTC and timekeeping maintainers on 3 October 2026: [\[PATCH\] rtc: class: Do not inject sleep time without a suspend snapshot](https://lore.kernel.org/all/20261003163138.14221-1-sabri.alperen03@gmail.com/). It is under review and not merged yet. Until a fixed kernel reaches your distribution, use the fix below.

## Fix

### Instant relief (no reboot)

```bash
sudo chronyc makestep
```

The lag disappears immediately. On the affected machine the clock-speed ratio went from `0.91668` back to `1.00001`.

### Permanent fix (recommended): keep the RTC in UTC

On Linux:

```bash
sudo timedatectl set-local-rtc 0
```

On Windows, if you dual-boot, run this in an **administrator** Command Prompt, then reboot:

```
reg add "HKLM\System\CurrentControlSet\Control\TimeZoneInformation" /v RealTimeIsUniversal /d 1 /t REG_DWORD /f
```

Do the Windows step the next time you boot Windows. Otherwise Windows shows the wrong time and writes local time back to the RTC.

### Alternative: let chrony always step large offsets

If you do not want to touch Windows, edit `/etc/chrony.conf`. Change

```
makestep 1.0 3
```

to

```
makestep 1.0 -1
```

Then restart chrony:

```bash
sudo systemctl restart chronyd
```

chrony will then step any offset larger than 1 second at any time, instead of slewing it for hours. The clock is still wrong for a few seconds after resume, until chrony gets an NTP reply, and it stays wrong if there is no network.

## Things that were ruled out

Full raw measurements are in [EVIDENCE.md](EVIDENCE.md).

These all measured healthy while the system was lagging, so they are probably not your problem if the checks above match:

- GPU frequency and throttling (i915): the GPU was 23% busy during animations.
- Panel Self Refresh: not supported by the affected panel.
- CPU frequency, thermal throttling and PROCHOT.
- Scheduler and timer wake-up latency: about 0.1–0.2 ms on all cores.
- Clocksource: still TSC.
- The compositor itself (KWin, measured on the KDE machine): hardware-accelerated. Disabling blur, toggling DPMS and re-setting the display mode did not help.

## Tested on

- Lenovo ThinkBook 16p G5 (i9-14900HX, Intel UHD iGPU + RTX 4060 in integrated mode), Fedora 44, kernel 7.2.7, KDE Plasma 6.7.5, Mesa 26.2.3, chrony, Windows dual-boot. All measurements in EVIDENCE.md are from this machine.
- The same machine showed the same symptom earlier while it was running **GNOME** (not measured at the time).
- The same symptom was seen on a Huawei laptop (13th-gen Intel i9, no discrete GPU) running Fedora 44 with **GNOME**.

## References

- **Kernel patch:** [rtc: class: Do not inject sleep time without a suspend snapshot](https://lore.kernel.org/all/20261003163138.14221-1-sabri.alperen03@gmail.com/) (linux-rtc, under review)
- **Bug report:** [Red Hat Bugzilla 2543517](https://bugzilla.redhat.com/show_bug.cgi?id=2543517)
- **Discussion:** [Fedora Discussion thread](https://discussion.fedoraproject.org/t/203245)
- [Laptop framerate tanks after waking from sleep (KDE) – Fedora Discussion](https://discussion.fedoraproject.org/t/laptop-framerate-tanks-after-waking-from-sleep-kde/124812)
- [Fedora 44 KDE Lagging – Fedora Discussion](https://discussion.fedoraproject.org/t/fedora-44-kde-lagging/197952)
- [Screen refresh rate drop after sleep – KDE Discuss](https://discuss.kde.org/t/screen-refresh-rate-drop-after-sleep/17555)
- `man chrony.conf` → `makestep`

---

## Türkçe özet

Uykudan uyandıktan sonra masaüstü (KDE veya GNOME fark etmez) kasıyor ve sadece yeniden başlatınca düzeliyorsa, sebep saat olabilir. Bu durum özellikle bilgisayarda Windows da kuruluysa görülür.

Donanım saati yerel saatte tutulduğunda, uyanışta sistem saati saat dilimi kadar (Türkiye'de 3 saat) kayabiliyor. chrony bu farkı saati yaklaşık %8 yavaşlatarak düzeltmeye çalışıyor ve bu yaklaşık 36 saat sürüyor. Bu süre boyunca bütün animasyonlar yavaş ve takılarak çalışıyor.

Kaymanın kaynağı kernel'deki bir hata: s2idle uyanışında son donma bir saniyeden kısa sürerse kernel, donanım saati ile sistem saati arasındaki farkı "uyku süresi" sanıp sistem saatine ekliyor. Hata `kernel-repro/repro.sh` ile isteyerek tetiklenebiliyor ve düzeltme yaması kernel bakımcılarına gönderildi (inceleme aşamasında).

- Anlık çözüm: `sudo chronyc makestep`
- Kalıcı çözüm: Linux'ta `sudo timedatectl set-local-rtc 0`, Windows'ta yukarıdaki `reg add` komutu.

## License

MIT
