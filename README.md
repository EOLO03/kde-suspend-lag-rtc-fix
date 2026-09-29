# Desktop laggy after suspend until reboot? Check your clock.

If your Linux desktop (seen on Fedora 44 KDE Plasma 6.7, Wayland) becomes **slow and choppy after waking from sleep**, with every animation and even the mouse cursor stuttering, and **only a reboot fixes it**, the cause may have nothing to do with your GPU, compositor or kernel.

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

1. With the RTC in local time, the system clock came back from suspend shifted by the UTC offset (3 hours here).
2. chrony noticed the offset. Its default Fedora config (`makestep 1.0 3`) only allows stepping the clock during the first 3 updates after boot. After that it **slews** the clock instead.
3. To slew, the kernel slows the clock down by up to ~8.3%. On the affected machine, the kernel `tick` was **9167** instead of 10000. `CLOCK_MONOTONIC` then ran at **0.917×** real speed. At that rate a 3-hour offset takes about **36 hours** to correct.
4. Animations are timed against that slowed clock, while the display still refreshes at a real 60 Hz. The compositor's frame timing drifts out of step with the panel, so everything is both slower and choppier.
5. On reboot chrony is allowed to step the clock at once, which is why a reboot "fixes" it.

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
- KWin itself: hardware-accelerated. Disabling blur, toggling DPMS and re-setting the display mode did not help.

## Tested on

- Lenovo ThinkBook 16p G5 (i9-14900HX, Intel UHD iGPU + RTX 4060 in integrated mode), Fedora 44, kernel 7.2.7, KDE Plasma 6.7.5, Mesa 26.2.3, chrony, Windows dual-boot.
- The same symptom was seen on a Huawei laptop (13th-gen Intel i9, no discrete GPU) running Fedora 44 KDE.

## References

- [Laptop framerate tanks after waking from sleep (KDE) – Fedora Discussion](https://discussion.fedoraproject.org/t/laptop-framerate-tanks-after-waking-from-sleep-kde/124812)
- [Fedora 44 KDE Lagging – Fedora Discussion](https://discussion.fedoraproject.org/t/fedora-44-kde-lagging/197952)
- [Screen refresh rate drop after sleep – KDE Discuss](https://discuss.kde.org/t/screen-refresh-rate-drop-after-sleep/17555)
- `man chrony.conf` → `makestep`

---

## Türkçe özet

Uykudan uyandıktan sonra KDE kasıyor ve sadece yeniden başlatınca düzeliyorsa, sebep saat olabilir. Bu durum özellikle bilgisayarda Windows da kuruluysa görülür.

Donanım saati yerel saatte tutulduğunda, uyanışta sistem saati saat dilimi kadar (Türkiye'de 3 saat) kayabiliyor. chrony bu farkı saati yaklaşık %8 yavaşlatarak düzeltmeye çalışıyor ve bu yaklaşık 36 saat sürüyor. Bu süre boyunca bütün animasyonlar yavaş ve takılarak çalışıyor.

- Anlık çözüm: `sudo chronyc makestep`
- Kalıcı çözüm: Linux'ta `sudo timedatectl set-local-rtc 0`, Windows'ta yukarıdaki `reg add` komutu.

## License

MIT
