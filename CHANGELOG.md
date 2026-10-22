# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) · [SemVer](https://semver.org/)

## [2.0.0] — 2026-10-23

Rilis ini memperbaiki bug yang membuat failover **tidak pernah benar-benar jalan**
dan, pada kondisi tertentu, mematikan internet box sepenuhnya.

### Fixed — CRLF di semua file (root cause unit systemd gagal start)

Seluruh file di repo tersimpan dengan line ending CRLF. Shebang jadi
`#!/usr/bin/env bash\r`, sehingga `ExecStart=/usr/local/sbin/opa-isp2lte.sh`
gagal dengan `bad interpreter`. Akibatnya unit systemd tidak pernah hidup dan
daemon cuma bisa dijalankan manual sebagai `nohup bash opa-isp2lte.sh &`
(PPid 1, tanpa restart policy, tanpa cgroup, log tidak masuk journal).

- Semua file dikonversi ke LF.
- `.gitattributes` ditambahkan untuk memaksa `eol=lf` pada `*.sh`, `oitl`,
  `*.service`, `*.conf`.
- `install.sh` menjalankan `sed -i 's/\r$//'` + `bash -n` sebelum memasang.

### Fixed — route destruktif (bisa bikin box blackout total)

`switch_to()` lama:

```bash
while ip route show default; do ip route del default; done
ip route add default via "$gw" dev "$iface"
```

Dua masalah: menghapus **semua** default route (termasuk milik
NetworkManager), dan kalau `ip route add` gagal, box berakhir **tanpa default
route sama sekali** — total blackout, bukan failover.

- Sekarang memakai `ip route replace default ... metric $ROUTE_METRIC`:
  atomik, tidak pernah ada jendela tanpa default route.
- opa hanya memiliki satu route (metric `ROUTE_METRIC`, default `50`).
  Route NetworkManager tidak pernah disentuh dan tetap jadi jaring pengaman
  kalau daemon mati.

### Fixed — failover ke LTE yang mati (outage, bukan redundancy)

v1 memutuskan layak-tidaknya BACKUP hanya dari `carrier` (`link_up`). Modem LTE
dengan SIM habis kuota / tanpa pulsa tetap `carrier=1`, jadi daemon memindahkan
seluruh trafik ke jalur yang tidak punya internet.

- Gate baru `backup_usable()`: `VERIFY_BACKUP=1` mewajibkan BACKUP lolos probe
  sebelum dipakai. Kalau tidak lolos, daemon **tetap di PRIMARY** dan mencatat
  alasannya.

### Fixed — deteksi internet cuma ICMP

- `PROBE_MODE` baru: `auto` (default) / `tcp` / `icmp`.
  - `auto` memakai probe TCP (`curl --interface`) sebagai otoritatif, ICMP
    sebagai fallback kalau `curl` tidak terpasang.
  - Menangani dua kasus yang dulu salah: ICMP di-block upstream padahal data
    normal (dulu: false failover), dan ICMP hidup padahal data mati
    (dulu: gagal failover).

### Fixed — parser config menelan komentar inline

Parser lama memakai `grep -vE '^\s*(#|$)'` yang hanya membuang komentar
**satu baris penuh**. Baris seperti `INTERVAL=10  # detik` menghasilkan
`INTERVAL="10  # detik"`, sehingga `sleep "$INTERVAL"` gagal dan loop berjalan
secepat mungkin (spin).

- Parser baru memotong komentar inline, merapikan spasi, dan menolak nilai kosong.
- Semua nilai numerik lewat `_sane_int()` — nilai korup dikembalikan ke default,
  dengan batas bawah, jadi loop tidak mungkin spin.

### Fixed — tailscaled restart tiap switch

v1 me-restart `tailscaled` pada **setiap** switch tanpa throttle. Saat route
berosilasi, tailscaled ikut restart berulang dan koneksi SSH via Tailscale putus.

- Default sekarang `RESTART_TAILSCALE=0`.
- Kalau diaktifkan, dibatasi `TAILSCALE_RESTART_COOLDOWN` (default 300 s).

### Fixed — `install.sh` memasang daemon berbeda dari repo

`install.sh` menyimpan salinan daemon v1 secara embedded sebagai fallback. Pada
pola `curl -fsSL install.sh | sudo bash`, file sibling tidak ada sehingga yang
terpasang **selalu** salinan embedded yang buggy — bukan versi repo.

- Fallback embedded dihapus; installer mengunduh `opa-isp2lte.sh` dan
  `opa-isp2lte.service` dari repo.
- Installer sekarang membunuh instance orphan (`nohup`) sebelum enable unit,
  supaya tidak ada dua daemon berebut route.

### Fixed — `oitl switch` destruktif

`oitl switch isp|lte` juga memakai `ip route del default`. Diganti ke
`ip route replace ... metric $ROUTE_METRIC`.

### Added

- `flock` single-instance lock (`/var/lib/opa-isp2lte/lock`).
- State persist (`/var/lib/opa-isp2lte/mode`) — restart tidak kehilangan mode.
- `SWITCH_COOLDOWN` (default 20 s) — anti bolak-balik.
- `MANAGE_ROUTES=0` — mode monitor-only.
- `opa-isp2lte.sh --check` / `oitl check` — self test read-only: nilai config
  efektif, dependency (`ip`, `ping`, `curl`, `nmcli`, `conntrack`, `flock`,
  `tailscale`), carrier/IPv4 tiap interface, semua default route, hasil probe
  per jalur, dan keputusan gate BACKUP.
- `conntrack` yang tidak terpasang sekarang dicatat sebagai WARN (dulu silent).
- Unit systemd: `After=NetworkManager-wait-online.service`, `StartLimitIntervalSec=0`,
  `Nice=5`, dan `UnsetEnvironment` untuk variabel proxy supaya probe `curl`
  tidak ikut lewat proxy.

### Changed

- Logika switch memakai jalur efektif dari kernel (`ip route show default`),
  bukan asumsi interface.
- `RECOVERY_COOLDOWN` sekarang benar-benar dibaca dari config (v1 hanya default).

## [1.0.0] — sebelumnya

Rilis awal: failover ISP ↔ LTE berbasis ICMP, plus recovery profil
NetworkManager.
