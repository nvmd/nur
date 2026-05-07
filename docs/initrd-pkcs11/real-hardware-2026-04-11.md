# Real-hardware debugging session — 2026-04-11

First attempt at using the `boot.initrd.systemd.pkcs11` module on a live
x86_64-linux machine with a YubiKey. Multiple LUKS partitions are required
for boot. The softhsm-based tests all pass, but real hardware does not
unlock. This document captures the state of the investigation for the next
session.

## Environment

- Target: x86_64-linux workstation with multiple LUKS volumes required
  at boot (root + data partitions on the same keyslot scheme).
- YubiKey enrolled on every LUKS volume via `systemd-cryptenroll
  --pkcs11-token-uri=…`.  `cryptsetup luksDump` confirms the `pkcs11`
  tokens are present in each LUKS2 header.
- Module enabled via `boot.initrd.systemd.pkcs11.enable = true` with the
  default `modules = { ykcs11 = ".../libykcs11.so"; }`.

## Observations

### Attempt 1 — no `pkcs11-uri=auto` in crypttab

- Boot neither broke nor unlocked via the token.
- YubiKey LED flashed once briefly at boot.  Retrospectively this was
  almost certainly leftover behaviour from a stray `fido2-device=auto`
  left over from an earlier experiment, not the PKCS#11 path.
- LUKS prompted for a passphrase as before, and the **password reuse
  across volumes worked** — entering the passphrase once unlocked all
  volumes.
- With a wrong passphrase the system dropped straight into the emergency
  shell without retrying (vs. the usual multi-attempt behaviour).  Origin
  of that regression is unclear — maybe related to the module, maybe
  unrelated.

**Root cause of the no-unlock symptom:** enrolling a PKCS#11 token in the
LUKS2 header is not enough on its own.  `systemd-cryptsetup` only tries
the token path when the crypttab entry for the volume carries
`pkcs11-uri=auto` (or an explicit URI) — exactly like TPM2 needs
`tpm2-device=auto`.  The working boot-cycle test sets it explicitly in
[tests/initrd-pkcs11-boot.nix:128-131](../../tests/initrd-pkcs11-boot.nix#L128-L131).
The module never surfaces this requirement in its option docs.

### Attempt 2 — with `pkcs11-uri=auto` + `token-timeout=…` in crypttab

- `boot.initrd.luks.devices.<name>.crypttabExtraOpts = ["pkcs11-uri=auto"
  "token-timeout=…"]` added to the PKCS#11 volume(s).
- Without the YubiKey inserted: the system waits, then prompts for
  passphrases **multiple times** — one per volume.  Password reuse across
  volumes is now broken.
- With the YubiKey inserted: same behaviour as without — multiple
  passphrase prompts, **no LED blink** on the YubiKey at all.  So
  whatever `systemd-cryptsetup` is doing, it is not actually reaching
  the card.

## Hypotheses (ranked)

### H1 — the PKCS#11 token plugin isn't loaded / ykcs11 returns no slots (leading)

The "no LED blink" combined with "passphrase reuse broke" fits a path
where `systemd-cryptsetup` *tries* to load the PKCS#11 plugin on every
volume, the attempt fails (or returns zero slots) fast, the volume falls
back to a fresh passphrase prompt, and the kernel-keyring password cache
is skipped/invalidated because a token was configured.

Sub-hypotheses for *why* the plugin path fails:

- **H1a — USB modules not actually loaded in initrd.**  The module adds
  `usbhid xhci_pci xhci_hcd ehci_pci ehci_hcd` via `availableKernelModules`
  (same mechanism TPM2 uses for `tpm-tis`/`tpm-crb`).  If the root FS
  lives on NVMe/SATA and no USB device triggers udev autoload, xhci may
  never come up in the initrd on this specific box.  Verify with
  `dmesg | grep xhci` from the emergency shell.  Fix: move the modules
  into `boot.initrd.kernelModules` (force-load).

- **H1b — pcscd.service never actually starts.**  The socket has
  `WantedBy=cryptsetup-pre.target` via `boot.initrd.systemd.sockets`,
  which does create `cryptsetup-pre.target.wants/pcscd.socket` in the
  generated initrd-units dir (verified on the dev machine).  But socket
  activation only starts the service when a client connects; if
  libpcsclite fails to connect for any reason (e.g. permissions, path
  mismatch), the service never runs and pcscd never probes the reader.
  Verify with `systemctl status pcscd.socket pcscd.service` and
  `journalctl -u pcscd.*` from the emergency shell.

- **H1c — `libcryptsetup-token-systemd-pkcs11.so` can't load p11-kit /
  ykcs11.**  All three .so files are in `storePaths` and
  `/etc/pkcs11/modules/ykcs11.module` is created via `contents`.  The
  systemd-cryptsetup binary is wrapped at build time with
  `LD_LIBRARY_PATH=$out/lib/cryptsetup` (confirmed:
  `bin/systemd-cryptsetup` is a cc wrapper that sets LD_LIBRARY_PATH and
  exec's `.systemd-cryptsetup-wrapped`; `lib/systemd/systemd-cryptsetup`
  is a symlink to it).  So `dlopen("libcryptsetup-token-systemd-pkcs11.so")`
  should find it.  But something downstream may still fail — e.g. p11-kit
  unable to read `/etc/pkcs11/modules/` (SELinux? file missing in
  initrd?), or ykcs11 erroring on a missing dependency not in storePaths.
  Verify with `SYSTEMD_LOG_LEVEL=debug` in the initrd.

### H2 — USB device enumeration timing

Even with xhci loaded, YubiKey enumeration can be slow enough that pcscd
probes the reader before the card is ready.  `token-timeout=` in crypttab
would normally absorb this, but a fresh pcscd `-x` (auto-exit) might race
with the hotplug.  Lower-confidence; only relevant if H1 is ruled out.

### H3 — downgraded: missing `RuntimeDirectory=pcscd` on socket/service

Earlier hypothesis, now weakened.  Upstream pcsclite ships
`/run/pcscd/pcscd.comm` as a `ListenStream=` without any `RuntimeDirectory=`
and it works fine on the running system — modern systemd auto-creates
parent dirs for `AF_UNIX` listen paths.  Keeping this here only as a
fallback "belt-and-suspenders" tweak if nothing else explains it.

## What TPM2 and FIDO2 do differently (answered)

- **Kernel modules:** TPM2 adds `availableKernelModules = ["tpm-tis"
  "tpm-crb"]` ([tpm2.nix:67-72](../../../virt-share/taunusanlage/sk/nixpkgs/nixos/modules/system/boot/systemd/tpm2.nix#L67-L72)).
  Same mechanism as us — not `kernelModules`.  FIDO2 adds *no* kernel
  modules ([fido2.nix:18-31](../../../virt-share/taunusanlage/sk/nixpkgs/nixos/modules/system/boot/systemd/fido2.nix#L18-L31));
  it ships a udev rule (`60-fido-id.rules`) + `fido_id` helper and
  relies on the normal HID/USB stack being present.  So our
  `availableKernelModules` approach matches TPM2 exactly and is already
  more aggressive than FIDO2's.  This is probably not the differentiator.

- **RuntimeDirectory:** neither TPM2 nor FIDO2 has an equivalent (they
  don't run a userspace daemon).  Upstream `pcscd.service` shipped by
  pcsclite 2.3.0 does **not** set `RuntimeDirectory=pcscd` either, and
  the stage-2 pcscd works anyway.  Conclusion: not the issue.

## Next actions when the user resumes

1. **Enable debug logging** in the initrd:
   ```nix
   boot.kernelParams = [
     "rd.systemd.log_level=debug"
     "rd.systemd.log_target=console"
   ];
   ```
2. **Force-load USB modules** (eliminate H1a):
   ```nix
   boot.initrd.kernelModules = [ "xhci_pci" "xhci_hcd" "usbhid" ];
   ```
3. Reboot with the YubiKey inserted.  Expect to land in the emergency
   shell after the token path fails.  From there, capture:
   - `systemctl status pcscd.socket pcscd.service`
   - `journalctl -b`  (look for `libcryptsetup-token-systemd-pkcs11`,
     `p11-kit`, `ykcs11`, `pcscd`, `xhci`)
   - `ls /sys/bus/usb/devices/`
   - `dmesg | grep -iE 'usb|yubi|ccid|xhci'`
   - If pcscd ran: `PCSCLITE_HP_DROPDIR=<the env from the unit>
     pcsc_scan` (need to install it or bind-mount it in)
4. Based on what shows up, decide whether to:
   - Add an explicit `pcsc_scan` or other probe to confirm reader
     enumeration, or
   - Dig into the p11-kit module discovery path (strace, log level), or
   - Try a minimal "no pcscd, just softhsm-style mock" on the real box
     to narrow down whether the break is in the pcscd stack or the
     p11-kit stack.

## Open questions for the next session

- **Why is passphrase reuse broken when `pkcs11-uri=auto` is set even
  with no card inserted?**  Is this a known systemd behaviour (token
  configured → cache bypass), or a side effect of something we do in
  the module?  Look at `src/cryptsetup/cryptsetup.c` for the
  interaction between `pkcs11-uri=` and the keyring cache path.
- **The "no retry, straight to emergency shell" symptom from attempt 1**
  may or may not be related.  Revisit after the main unlock flow works.
- **Should the module assert/warn when `pkcs11-uri=auto` is not set on
  any volume?**  Would have caught attempt 1 immediately.

## Cross-references

- Main technical summary: [summary.md](summary.md)
- Module source: [modules/boot/initrd-pkcs11.nix](../../modules/boot/initrd-pkcs11.nix)
- Working boot-cycle test: [tests/initrd-pkcs11-boot.nix](../../tests/initrd-pkcs11-boot.nix)
