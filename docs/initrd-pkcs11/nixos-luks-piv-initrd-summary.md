# NixOS LUKS Unlock via PIV Smartcard (YubiKey) in Initrd

**Goal:** Enable LUKS partition unlock at boot using a YubiKey PIV applet (PKCS#11) on NixOS with systemd-based initrd. Delivered as a reusable NixOS module in NUR.

---

## 1. Current Status

### Implemented

- **NixOS module** at `modules/boot/initrd-pkcs11.nix` providing `boot.initrd.systemd.pkcs11.{enable, modules, pcscd.plugins}`.
- **Single-boot VM test passes** (`tests/initrd-pkcs11.nix`): enroll + attach via softhsm, ~18s on aarch64-darwin/TCG.
- **Boot-cycle VM test passes** (`tests/initrd-pkcs11-boot.nix`): enroll → reboot → initrd unlocks LUKS via softhsm PKCS#11 token. ~53s on aarch64-darwin under TCG (no KVM needed).
- **Eval tests** (`tests/initrd-pkcs11-eval.nix`): 8 test groups covering module option validation.

### Not Done

- Real YubiKey hardware testing not done (softhsm tests bypass the pcscd/CCID/USB stack).
- Not upstreamed to nixpkgs.

---

## 2. The Runtime Dependency Chain

The full chain for PIV-based LUKS unlock, with the nixpkgs package providing each component:

```
systemd-cryptsetup (in initrd)
  → libcryptsetup-token-systemd-pkcs11.so  (ships with systemd package)
    → libp11-kit.so  (pkgs.p11-kit — PKCS#11 module discovery/dispatch)
      → /etc/pkcs11/modules/<name>.module  (config file, injected via initrd contents)
        → libykcs11.so  (pkgs.yubico-piv-tool — YubiKey's PKCS#11 implementation)
          → libykpiv.so  (pkgs.yubico-piv-tool — YubiKey PIV library)
            → libpcsclite.so  (pkgs.pcsclite — PC/SC client library)
              → pcscd  (pkgs.pcsclite — PC/SC Smart Card Daemon)
                → ccid driver  (pkgs.ccid — USB CCID reader driver, userspace)
                  → YubiKey hardware (USB)
```

This chain was confirmed by cross-referencing:
- **dracut's `91pkcs11` module** ([commit 83ea8cf](https://github.com/dracutdevs/dracut/commit/83ea8cf)) — handles p11-kit layer; pcscd is handled separately
- **Nitrokey/Gentoo guide** (https://vtimofeenko.com/posts/unlocking-luks2-with-x509-nitrokey-during-boot/) — documents the full chain for a non-NixOS system
- **systemd source code** — `systemd-cryptsetup` loads `libcryptsetup-token-systemd-pkcs11.so` which calls p11-kit, which dispatches to the configured PKCS#11 module

### What Is Automatically Resolved vs What Needs Explicit Configuration

**`make-initrd-ng`** (the Rust tool at `pkgs/build-support/kernel/make-initrd-ng/src/main.rs`) automatically follows:
- **ELF `DT_NEEDED` entries** (lines 142-146): direct shared library dependencies are parsed via `goblin` crate
- **RPATH/RUNPATH** (lines 128-140): RUNPATH takes precedence over RPATH per ELF spec; paths are searched for each needed library
- **systemd's `.note.dlopen` metadata** (lines 100-126): JSON-encoded notes listing libraries to be dlopen'd, filtered by priority and feature flags

**NOT automatically resolved:** Libraries loaded via plain `dlopen()` at runtime without `.note.dlopen` annotations. This is the case for p11-kit loading PKCS#11 modules — p11-kit reads module paths from `/etc/pkcs11/modules/*.module` config files and dlopen's them at runtime.

**Impact on module design:** Adding `libcryptsetup-token-systemd-pkcs11.so` to `storePaths` does NOT automatically pull in `libp11-kit.so.0`. Despite the original assumption that it would be a direct ELF dependency, `libcryptsetup-token-systemd-pkcs11.so` actually loads `libp11-kit.so.0` via `dlopen()` at runtime (confirmed by the boot test — see §8). `libp11-kit.so.0` **must be listed explicitly in `storePaths`**. Additionally, `libykcs11.so` (or any PKCS#11 module) must be listed explicitly in `storePaths`, and its `/etc/pkcs11/modules/` config file must be injected via `contents`.

---

## 3. How NixOS Handles TPM2 (The Reference Pattern)

The TPM2 LUKS unlock in nixpkgs is the closest reference for PKCS#11 support. Key differences: TPM2 needs no userspace daemon (uses kernel's `/dev/tpmrm0`), making it much simpler.

### storePaths in luksroot.nix (lines 1225-1231)

```nix
boot.initrd.systemd.storePaths = [
  "${config.boot.initrd.systemd.package}/bin/systemd-cryptsetup"
  "${config.boot.initrd.systemd.package}/lib/systemd/system-generators/systemd-cryptsetup-generator"
]
++ lib.optionals config.boot.initrd.systemd.tpm2.enable [
  "${config.boot.initrd.systemd.package}/lib/cryptsetup/libcryptsetup-token-systemd-tpm2.so"
];
```

The pattern: `boot.initrd.systemd.tpm2.enable` adds the `.so` plugin to `storePaths`. NixOS wraps `systemd-cryptsetup`/`systemd-cryptenroll` to set `LD_LIBRARY_PATH` to systemd's `lib/cryptsetup/` dir (via `nixos/modules/system/boot/luksroot.nix`), so token plugins are found automatically if present in initrd store paths.

### crypttabExtraOpts flow (luksroot.nix, lines 590-611)

User-provided `crypttabExtraOpts` (e.g. `["pkcs11-uri=auto" "token-timeout=60"]`) are placed first in the options list when generating `/etc/crypttab`. The generated crypttab is installed at line 1216 via `contents."/etc/crypttab".source = stage1Crypttab`.

### TPM2 test pattern (nixos/tests/systemd-initrd-luks-tpm2.nix)

```
1. First boot: create LUKS volume → enroll TPM2 via systemd-cryptenroll
2. bootctl set-default to specialisation → crash (reboot)
3. Second boot: systemd-cryptsetup in initrd reads crypttab → loads TPM2 plugin → unseals passphrase
4. Verify /dev/mapper/cryptroot mounted as /
```

Uses `useBootLoader = true`, `useEFIBoot = true`, `efi.OVMF = pkgs.OVMFFull` (OVMFFull contains TCG support), `virtualisation.tpm.enable = true`, and the specialisation pattern with `lib.mkVMOverride`.

### What PKCS#11 adds on top of TPM2

PKCS#11 needs everything TPM2 needs, plus:
1. **pcscd daemon** with correct ordering before `cryptsetup-pre.target`
2. **CCID drivers** discoverable via `PCSCLITE_HP_DROPDIR`
3. **p11-kit module config files** in `/etc/pkcs11/modules/`
4. **USB kernel modules** for smartcard reader enumeration

---

## 4. Design Decisions and Their Basis

### pcscd ordering: `wantedBy cryptsetup-pre.target` with `DefaultDependencies=false`

**Problem:** pcscd is socket-activated by default. `pcscd.socket` is pulled in by `sockets.target`, which runs *after* `cryptsetup.target` in the default dependency graph. This creates a deadlock: `systemd-cryptsetup` needs pcscd, but pcscd won't start until after cryptsetup finishes.

**Decision:** Override both `pcscd.socket` and `pcscd.service` with `DefaultDependencies=no` (avoids implicit `After=sysinit.target`) and `wantedBy = [ "cryptsetup-pre.target" ]` so they start *before* cryptsetup attempts to open volumes.

Note: unlike clevis (which produces a key file for a *specific* `systemd-cryptsetup@<name>.service`), pcscd is a shared daemon needed by *all* PKCS#11 LUKS volumes. `cryptsetup-pre.target` is the correct anchor because the cryptsetup generator orders it `Before=` all cryptsetup services.

**Future exploration: per-device activation (clevis approach).** Currently pcscd and all PKCS#11 initrd infrastructure starts unconditionally when `boot.initrd.systemd.pkcs11.enable = true`, even if no LUKS volume actually uses PKCS#11 unlock. Clevis avoids this by targeting specific `systemd-cryptsetup@<name>.service` units. We could follow a similar approach: inspect `crypttabExtraOpts` for PKCS#11-related options (e.g. `pkcs11-uri=`) and only wire up pcscd/storePaths/contents for volumes that actually need it. Taken further, if no volume needs PKCS#11, the module could become a no-op — saving initrd size and boot time. Trade-off: this adds implementation complexity (introspecting crypttab config at module eval time) and may not be worth it until the module is fully working with real hardware. Explore once the core module is validated end-to-end.

**Why NixOS `sockets` option, not raw `units`:** In NixOS initrd, raw `[Install] WantedBy=` in unit text is informational only — it requires `systemctl enable` to create symlinks, which never happens during image assembly. The NixOS `boot.initrd.systemd.sockets` option (`nixos/modules/system/boot/systemd/initrd.nix:367-379`) creates proper `.wants/` symlinks declaratively at build time via `generateUnits`.

### pcscd clean shutdown: `conflicts` + `before` shutdown/switch-root targets

**Learned from:** The initrd-ssh module (`initrd-ssh.nix`) uses `before = [ "shutdown.target" ]` + `conflicts = [ "shutdown.target" ]`. The clevis implementation in `luksroot.nix` adds `before` and `conflicts` for both `initrd-switch-root.target` and `shutdown.target`. Both patterns ensure daemons are terminated cleanly before the initrd transitions to the real root filesystem.

**Applied to pcscd:** Added `Requires=pcscd.socket` (matching the upstream unit shipped by pcsclite — not strictly required in the initrd since the socket is always started via `wantedBy`, but kept to stay consistent with upstream), and `before` + `conflicts` for `initrd-switch-root.target` and `shutdown.target`, ensuring clean daemon termination before switch-root.

### CCID driver discovery via `PCSCLITE_HP_DROPDIR`

**Source:** `pkgs/by-name/pc/pcsclite/package.nix:49` — compile-time `usbdropdir` is set to `/var/lib/pcsc/drivers`, a non-existent path in NixOS.

**Reference pattern:** `nixos/modules/services/hardware/pcscd.nix:15-18` builds a `pluginEnv` from plugin packages:
```nix
pluginEnv = pkgs.buildEnv {
  name = "pcscd-plugins";
  paths = map (p: "${p}/pcsc/drivers") config.services.pcscd.plugins;
};
```
And sets `PCSCLITE_HP_DROPDIR = pluginEnv` (line 115) on the pcscd service.

**Our module** replicates this pattern exactly for the initrd pcscd service. The `ccid` package installs drivers to `$out/pcsc/drivers/` (specifically `ifd-ccid.bundle/`). Note: `ccid` is a userspace pcscd driver package, NOT a kernel module — `modinfo ccid` returns "not found".

### p11-kit module files in `/etc/pkcs11/modules/`

**Source:** `pkgs/by-name/p1/p11-kit/package.nix:55` — p11-kit is built with `--sysconfdir=/etc`, so it reads module files from `/etc/pkcs11/modules/` at runtime.

**Decision:** The module generates one file per entry in `cfg.modules` via `boot.initrd.systemd.contents`, each containing `module: <path-to-so>`.

### pcscd eager start: `wantedBy` on service, not only socket

**Problem:** Socket activation starts pcscd lazily — only when a client connects. In the initrd, that client is libpcsclite (inside systemd-cryptsetup via ykcs11). This creates a race: pcscd starts only when libpcsclite connects, then must probe the USB bus and detect the reader, all while libpcsclite is waiting for the response. If pcscd is slow to probe, libpcsclite may time out before the reader is ready.

**Decision:** Add `wantedBy = ["cryptsetup-pre.target"]` to `pcscd.service` (in addition to the socket unit already having it). This makes pcscd start eagerly before cryptsetup, giving it time to probe and enumerate readers before systemd-cryptsetup even runs. The socket unit is kept for socket lifecycle management; the socket fd is passed to pcscd when it starts.

### USB kernel modules: `kernelModules` instead of `availableKernelModules`

**Problem:** `availableKernelModules` adds modules to the initrd image but only autoloads them when udev detects matching hardware. On systems where the root FS is on NVMe/SATA (no USB-attached storage), xhci_pci may not be autoloaded before pcscd starts, even though the USB host controller is present. The exact timing depends on udev processing order.

**Decision:** Use `boot.initrd.kernelModules` (force-loaded at initrd start) instead of `availableKernelModules` for all USB modules (`xhci_pci`, `xhci_hcd`, `ehci_pci`, `ehci_hcd`, `usbhid`). This guarantees the USB host controller is active before pcscd runs, eliminating any autoload timing dependency.

### `pkcs11-uri=` warning in `crypttabExtraOpts`

**Problem:** `systemd-cryptsetup` only attempts PKCS#11 unlock when the crypttab entry for a volume includes `pkcs11-uri=auto` (or an explicit URI) — enrolling a PKCS#11 token in the LUKS2 header is not enough on its own. A user who sets `boot.initrd.systemd.pkcs11.enable = true` without adding `pkcs11-uri=auto` to `crypttabExtraOpts` will see no PKCS#11 attempt and no error — just a passphrase prompt.

**Decision:** Add a NixOS `warnings` entry that fires when `pkcs11.enable = true`, at least one LUKS device is configured (`boot.initrd.luks.devices != {}`), and none of the configured devices have `pkcs11-uri=` in `crypttabExtraOpts`. This surfaces the misconfiguration at `nixos-rebuild` time.

### pcscd flags: `-f -x -c ${readerConf}`

- **`-f` (foreground):** Required for systemd `Type=simple` service.
- **`-x` (auto-exit):** Exits 60s after the last PC/SC context is released (last client disconnects). This is desirable in initrd so pcscd cleans up after LUKS unlock rather than lingering through switch-root. Confirmed via `pcscd(8)`: exits on inactivity, not on missing readers.
- **`-c` (config path):** Explicitly specifies reader.conf path to prevent pcscd from scanning all of `/etc` (nixpkgs issue #121088). The reference `pcscd.nix` always passes this flag (line 134-137).

### `modules` attrset instead of single `package`/`modulePath`

**Decision:** A single `modules` option (`attrsOf str`) mapping names to `.so` paths:
```nix
modules = {
  ykcs11 = "${pkgs.yubico-piv-tool}/lib/libykcs11.so";
};
```

Each key becomes a p11-kit module file; each value is added to `storePaths`. Supports multi-vendor setups. Default: `{ ykcs11 = "${pkgs.yubico-piv-tool}/lib/libykcs11.so" }`.

---

## 5. Module Architecture

```
modules/boot/initrd-pkcs11.nix
├── options.boot.initrd.systemd.pkcs11
│   ├── enable              (bool)
│   ├── modules             (attrsOf str: name → /nix/store/.../lib*.so)
│   └── pcscd.plugins       (listOf package, default: [pkgs.ccid])
└── config (when enabled)
    ├── warnings            [fires when LUKS devices configured but none have pkcs11-uri= in crypttabExtraOpts]
    ├── storePaths          [cryptsetup-token-systemd-pkcs11.so, libp11-kit.so.0, p11-kit-trust.so, each module .so, pcscd, pluginEnv]
    ├── contents            [/etc/pkcs11/modules/<name>.module per module, /etc/reader.conf]
    ├── sockets.pcscd       [wantedBy cryptsetup-pre.target, DefaultDependencies=false]
    ├── services.pcscd      [wantedBy cryptsetup-pre.target (eager start), requires+after pcscd.socket, before cryptsetup-pre.target + switch-root + shutdown, conflicts switch-root + shutdown, -f -x -c]
    └── kernelModules       [usbhid, xhci_pci, xhci_hcd, ehci_pci, ehci_hcd]  ← force-loaded, not just available
```

---

## 6. Key Technical Findings

### systemd PIN handling (CRITICAL)

systemd's `pkcs11_token_login()` (`src/shared/pkcs11-util.c:262`) does NOT read `pin-value=` from the PKCS#11 URI. The actual flow:
1. Try NULL login
2. Read `$PIN` env var via `getenv_steal_erase("PIN")`
3. Fall back to `ask_password_auto()` with `UINT64_MAX` timeout — **hangs forever** in non-interactive contexts

**Always set `PIN=<pin>` in the environment** for `systemd-cryptenroll` and `systemd-cryptsetup`. Similarly, `PASSWORD=<passphrase>` provides the existing LUKS passphrase to `systemd-cryptenroll` (read via `getenv_steal_erase("PASSWORD")` in `src/cryptenroll/cryptenroll-password.c:30`).

For the boot-cycle test, `PIN` must reach the generator-spawned `systemd-cryptsetup@` service in initrd. This is done via `boot.initrd.systemd.settings.Manager.DefaultEnvironment` (which writes to initrd `system.conf`, applying to all services). For real YubiKey usage, the PIN would come from `ask_password_auto()` (plymouth, console prompt, or systemd-ask-password agent).

### EC keys don't work with softhsm

EC keys (P-256/P-384) imported via `softhsm2-util` get `Usage: sign, signRecover` but NOT `CKA_DERIVE`. systemd needs `CKA_DERIVE` for ECDH key agreement (dispatched in `src/shared/openssl-util.c:1240-1398`, `pkey_generate_volume_keys()` → EC variant needs ECDH). RSA 2048 works because `softhsm2-util` correctly sets `CKA_DECRYPT`. Real YubiKey PIV may handle EC differently (the PKCS#11 module controls attribute flags). **Use RSA 2048 for softhsm-based testing.**

### Cross-platform test architecture

The outer `pkgs` in test files is the *host* platform (e.g. aarch64-darwin). Inside `nodes.machine`, `pkgs` is the *VM* platform (aarch64-linux). `.so` paths used in the VM must reference the node's `pkgs`.

The `testTokenData` derivation is an exception: it builds on the host, but outputs arch-independent data files (serialised softhsm token directory state).

QEMU binary selection is in `nixos/lib/qemu-common.nix:46`: aarch64-darwin hosting aarch64-linux uses `qemu-system-aarch64 -machine virt,gic-version=2,accel=hvf:tcg -cpu max`. HVF is unavailable in the nix build sandbox, so it falls back to TCG.

### systemd URI handling

`systemd-cryptenroll` PKCS#11 URI handling (cert vs private key auto-detection) was fixed in systemd PR #29692. nixpkgs-unstable should be recent enough. nixpkgs issue #265366 confirms that vanilla `cryptsetup` cannot use systemd's token plugins (FIDO2, PKCS#11, TPM2) outside of `systemd-cryptsetup` due to `LD_LIBRARY_PATH` issues — the NixOS wrapper handles this.

---

## 7. Test Inventory

| Check | File | Description | Works on TCG? |
|---|---|---|---|
| `initrd-pkcs11-eval-*` | `tests/initrd-pkcs11-eval.nix` | 10 pure eval tests for module options | Yes (no VM) |
| `initrd-pkcs11` | `tests/initrd-pkcs11.nix` | Single-boot: enroll + attach | **Yes** (~18s) |
| `initrd-pkcs11-boot` | `tests/initrd-pkcs11-boot.nix` | Boot-cycle: enroll → reboot → initrd unlock | **Yes** (~53s on aarch64-darwin/TCG) |

### Softhsm test setup (not needed for real YubiKey)

Both VM tests use softhsm as a software PKCS#11 token. This tests the p11-kit → PKCS#11 module → libcryptsetup-token-systemd-pkcs11.so chain, but NOT the pcscd/CCID/USB stack (softhsm doesn't need pcscd). Testing the full pcscd chain requires `vsmartcard-vpcd` or real hardware.

Softhsm-specific parts:
- `testTokenData` derivation: pre-builds softhsm slot with RSA 2048 key + X.509 cert at Nix build time. The cert import uses `pkcs11-tool` because `softhsm2-util` can only import keys, not certs.
- `SOFTHSM2_CONF` env var: points softhsm to `softhsm2.conf` (token directory location). Real YubiKeys carry keys in hardware and need no config file.
- Boot-cycle test: `DefaultEnvironment` in initrd `system.conf` sets `SOFTHSM2_CONF` and `PIN` for generator-spawned services. Uses `lib.mkForce` to override the default `PATH=/bin:/sbin` (PATH is preserved in the override value).
- Boot-cycle test: `softhsm-copy-tokens` oneshot service copies read-only token data to writable tmpfs, ordered `before` the specific `systemd-cryptsetup@cryptroot.service` using the clevis ordering pattern.
- Boot-cycle test: token data + config injected into initrd via `contents`.

---

## 8. Boot-Cycle Test Debugging History (All Resolved)

The boot-cycle test (`initrd-pkcs11-boot`) was debugged through multiple iterations (2026-04-03 to 2026-04-05). All issues have been resolved and the test passes in ~53s on aarch64-darwin/TCG.

#### 1. nixpkgs `__structuredAttrs` bug (disk image builder hang)

`useBootLoader = true` triggers `make-disk-image.nix` → `vmTools.runInLinuxVM`. nixpkgs PR #498273 added `__structuredAttrs = true` to `runInLinuxVM`, which broke `lib.overrideDerivation` — the `requiredSystemFeatures = ["kvm"]` attribute was silently dropped. **Fix:** Pinned `flake.lock` to nixpkgs `bcd464ccd2a1` (pre-bug). **Upstream:** nixpkgs issue #505925, revert PR #505929.

#### 2. Missing PIN in initrd DefaultEnvironment

systemd's `pkcs11_token_login()` reads PIN from `$PIN` env var. **Fix:** Added `PIN=1234` to `boot.initrd.systemd.settings.Manager.DefaultEnvironment` (writes to initrd `system.conf`, affecting all services including generator-spawned ones).

#### 3. Softhsm token data not writable in initrd

Softhsm needs write access to its token directory for internal lock files. `boot.initrd.systemd.contents` creates read-only store paths. **Fix:** `softhsm-copy-tokens` oneshot service copies token data from read-only `/var/lib/softhsm/tokens-ro` to writable `/var/lib/softhsm/tokens/`. Uses `extraBin` for coreutils and `storePaths` for the script (because `make-initrd-ng` doesn't follow Nix store references in shell scripts).

#### 4. `libp11-kit.so.0` missing from initrd (root cause of kernel panic)

`libcryptsetup-token-systemd-pkcs11.so` loads `libp11-kit.so.0` via `dlopen()` at runtime — NOT as an ELF dependency. Without it: error -95 (ENOTSUP) → `systemd-cryptsetup@cryptroot.service` exits 1 → `boot.panic_on_fail` triggers sysrq crash. **Fix:** Added `"${pkgs.p11-kit}/lib/libp11-kit.so.0"` and `"${pkgs.p11-kit}/lib/pkcs11/p11-kit-trust.so"` to `storePaths` in the module.

#### 5. Token not found / passphrase prompt hang (service ordering)

After libp11-kit fix, systemd-cryptsetup loaded p11-kit successfully but couldn't find the softhsm token. Timed out after `token-timeout` seconds, fell back to interactive passphrase prompt, hung forever. **Root cause:** `softhsm-copy-tokens` was ordered `before cryptsetup-pre.target` but this didn't guarantee it ran before the specific `systemd-cryptsetup@cryptroot.service`. **Fix:** Changed to clevis-style ordering: `wantedBy = [ "systemd-cryptsetup@cryptroot.service" ]`, `before = [ "systemd-cryptsetup@cryptroot.service" "cryptsetup-pre.target" ]`, `DefaultDependencies = false`.

---

## 8a. Lessons Learned

### Initrd service ordering patterns (from clevis, SSH, and boot test debugging)

Three reference implementations in nixpkgs inform how initrd services should be ordered:

**Clevis** (`luksroot.nix:1248-1284`): Per-device services that produce key files.
- `wantedBy = [ "systemd-cryptsetup@${name}.service" ]` — tied to specific LUKS device
- `before = [ "systemd-cryptsetup@${name}.service" "initrd-switch-root.target" "shutdown.target" ]`
- `conflicts = [ "initrd-switch-root.target" "shutdown.target" ]`
- `unitConfig.DefaultDependencies = "no"`

**SSH** (`initrd-ssh.nix:336-358`): Long-running daemon needed throughout initrd.
- `wantedBy = [ "initrd.target" ]`
- `after = [ "network.target" "initrd-nixos-copy-secrets.service" ]`
- `before = [ "shutdown.target" ]`, `conflicts = [ "shutdown.target" ]`
- `unitConfig.DefaultDependencies = false`

**Key takeaways applied to our module:**

1. **`DefaultDependencies=false`** is mandatory for all initrd services that must run before cryptsetup. Without it, systemd adds implicit `After=sysinit.target` which creates a deadlock (sysinit depends on cryptsetup completing first).

2. **Use `wantedBy` + `before` the specific `systemd-cryptsetup@<name>.service`** for per-device prep services (like clevis key decryption or softhsm token copying). For shared daemons (like pcscd) that serve all LUKS devices, `wantedBy = [ "cryptsetup-pre.target" ]` is correct because the generator orders `cryptsetup-pre.target` before all cryptsetup services.

3. **Always add `conflicts` + `before` for `initrd-switch-root.target` and `shutdown.target`** on daemons. This ensures clean termination before the initrd transitions. Without these, a daemon may be killed abruptly by switch-root, potentially leaving state (lock files, sockets) that confuses the real root.

4. **`Requires=<socket>`** should be set on socket-activated services to ensure the socket exists when the service starts.

### `make-initrd-ng` dependency resolution

`make-initrd-ng` (the Rust tool that populates the initrd) follows:
- ELF `DT_NEEDED` entries (direct shared library dependencies)
- RPATH/RUNPATH for library search paths
- systemd's `.note.dlopen` metadata (JSON-encoded dlopen hints)

It does **NOT** follow:
- Plain `dlopen()` calls without `.note.dlopen` annotations
- Nix store references in shell scripts
- Symlinks from `buildEnv` into their target packages (these are followed at the filesystem level, but the target store paths must already be in the closure)

**Practical impact:** Any library loaded via `dlopen()` at runtime must be listed explicitly in `storePaths`. This includes `libp11-kit.so.0` (loaded by `libcryptsetup-token-systemd-pkcs11.so`), `p11-kit-trust.so` (loaded by `libp11-kit`), and each PKCS#11 module `.so` (loaded by p11-kit from `/etc/pkcs11/modules/` config files).

### Debugging initrd boot failures

- **Kernel cmdline params** `systemd.log_level=debug` and `rd.systemd.log_level=debug` enable PID 1 debug logging to kmsg (visible on console). This is different from `SYSTEMD_LOG_LEVEL=debug` in `DefaultEnvironment`, which only affects spawned services.
- **`boot.panic_on_fail`** (set by the NixOS test framework) causes immediate sysrq kernel crash on critical service failure, making errors hard to see. Debug logging must be enabled *before* the failure to capture the root cause.
- **`token-timeout=N`** in crypttab controls how long systemd-cryptsetup waits for the security device before falling back to passphrase prompt. A short value (10s) speeds up debugging iterations.

---

## 8b. Open Issues

### Real hardware testing (pcscd/CCID/USB path untested)

The boot-cycle test uses softhsm (a software PKCS#11 token), which bypasses the entire pcscd/CCID/USB stack. The module configures pcscd + CCID drivers + USB kernel modules, but this path has never been exercised in a test. Potential issues:
- USB device enumeration timing in initrd
- CCID driver compatibility with the pluginEnv `buildEnv` symlinks
- pcscd startup ordering with actual hardware reader detection

Testing with a real YubiKey or with `vsmartcard-vpcd` (virtual smartcard for pcscd) would validate this path.

### PIN delivery in real boot scenario

The tests use `PIN=1234` env var via `DefaultEnvironment`, but real initrd boot needs a way to prompt for PIN. Options:
- systemd's `ask_password_auto()` — plymouth prompt, console prompt, or `systemd-ask-password` agent (this is what systemd uses when `$PIN` is not set)
- `pin-source=` in PKCS#11 URI (if systemd supports it — needs investigation)
- Embedding PIN in crypttab options (insecure but functional for automated servers)

For interactive desktop/laptop use, the default systemd behaviour (prompting via `ask_password_auto()`) should work without any `PIN=` env var. The test sets `PIN=` only because softhsm requires non-interactive PIN entry.

---

## 9. Risk Register

| Risk | Status | Notes |
|---|---|---|
| Store paths missing dlopen'd deps | **Resolved** | `libp11-kit.so.0` and `p11-kit-trust.so` added explicitly to storePaths. Verified: boot test passes end-to-end. |
| p11-kit can't find modules | **Resolved** | `/etc/pkcs11/modules/` via `contents` is correct. Verified in boot test. |
| pcscd can't find CCID drivers | **Resolved** (untested with hardware) | `PCSCLITE_HP_DROPDIR` env var set via `pluginEnv`, matching `pcscd.nix` pattern |
| pcscd ordering deadlock | **Resolved** | `wantedBy cryptsetup-pre.target` + `DefaultDependencies=false` on socket and service |
| pcscd not cleaned up at switch-root | **Resolved** | Added `conflicts` + `before` for `initrd-switch-root.target` and `shutdown.target` (following clevis/SSH patterns) |
| pcscd-starts-after-reader probe race | **Resolved** | pcscd.service now has `wantedBy=cryptsetup-pre.target` for eager start, so pcscd probes hardware before systemd-cryptsetup even starts |
| USB kernel modules not loaded in time | **Resolved** | Moved from `availableKernelModules` (autoload-on-demand) to `kernelModules` (force-loaded at initrd start), eliminating any autoload timing issues on NVMe/SATA root systems |
| User forgets `pkcs11-uri=` in crypttab | **Resolved** | NixOS warning fires when pkcs11.enable=true and LUKS devices exist but none have `pkcs11-uri=` in `crypttabExtraOpts` |
| `--auto-exit` race | **Not a bug** | Exits 60s after last client disconnects, not on missing readers |
| PIN delivery hangs enrollment/unlock | **Resolved** | `$PIN` env var required; `pin-value=` in URI is ignored by systemd |
| YubiKey USB not enumerated in time | Open | `token-timeout` in crypttab provides wait window; force-loaded USB modules mitigate timing; untested with hardware |
| nixpkgs `__structuredAttrs` bug | **Resolved** | Pinned flake.lock to pre-bug nixpkgs; upstream revert PR #505929 |

---

## 10. Running the Tests

```bash
# Eval tests (no VM, works everywhere):
nix build .#checks.aarch64-darwin.initrd-pkcs11-eval-{pcscd-socket,pcscd-service,store-paths,p11-kit-module,reader-conf,kernel-modules,disabled,multi-module,missing-pkcs11-uri,pkcs11-uri-present} --no-link

# Single-boot VM test (works on aarch64-darwin/TCG):
nix build .#checks.aarch64-darwin.initrd-pkcs11 --no-link --print-build-logs --show-trace

# Boot-cycle VM test (works on aarch64-darwin/TCG with pinned nixpkgs):
nix build .#checks.aarch64-darwin.initrd-pkcs11-boot --no-link --print-build-logs --show-trace
```

---

## 11. Reference Links

- **nixpkgs `luksroot.nix`:** `nixos/modules/system/boot/luksroot.nix` — storePaths (lines 1225-1231), crypttab generation (lines 590-611), assertions (lines 1057-1126)
- **nixpkgs `initrd.nix`:** `nixos/modules/system/boot/systemd/initrd.nix` — makeInitrdNG (lines 129-136), storePaths option (lines 221-238), contents (lines 503-544), sockets/services (lines 367-379)
- **`make-initrd-ng`:** `pkgs/build-support/kernel/make-initrd-ng/src/main.rs` — ELF parsing (lines 142-146), RPATH (lines 128-140), `.note.dlopen` (lines 100-126)
- **nixpkgs `pcscd.nix`:** `nixos/modules/services/hardware/pcscd.nix` — pluginEnv (lines 15-18), PCSCLITE_HP_DROPDIR (line 115), ExecStart (lines 134-137)
- **nixpkgs `pcsclite`:** `pkgs/by-name/pc/pcsclite/package.nix` — compile-time usbdropdir (line 49)
- **nixpkgs `p11-kit`:** `pkgs/by-name/p1/p11-kit/package.nix` — `--sysconfdir=/etc` (line 55)
- **nixpkgs `qemu-common.nix`:** `nixos/lib/qemu-common.nix` — QEMU binary/accel selection (line 46)
- **nixpkgs `make-disk-image.nix`:** `nixos/lib/make-disk-image.nix` — UEFI disk image builder, uses `vmTools.runInLinuxVM`
- **nixpkgs TPM2 test:** `nixos/tests/systemd-initrd-luks-tpm2.nix` — reference test pattern
- **nixpkgs issue #265366:** Vanilla cryptsetup can't use systemd token plugins outside `systemd-cryptsetup`
- **nixpkgs issue #121088:** pcscd scanning `/etc` without `-c` flag
- **systemd source `pkcs11-util.c:262`:** `pkcs11_token_login()` — PIN handling via `$PIN` env var
- **systemd source `openssl-util.c:1240-1398`:** `pkey_generate_volume_keys()` — RSA/EC dispatch
- **systemd PR #29692:** URI `type=cert` vs `type=private` auto-conversion fix
- **dracut `91pkcs11`:** https://github.com/dracutdevs/dracut/commit/83ea8cf
- **Nitrokey/Gentoo guide:** https://vtimofeenko.com/posts/unlocking-luks2-with-x509-nitrokey-during-boot/
- **Lennart Poettering's blog:** https://0pointer.net/blog/unlocking-luks2-volumes-with-tpm2-fido2-pkcs11-security-hardware-on-systemd-248.html

---

## 12. Glossary

- **PIV:** Personal Identity Verification — YubiKey smart card applet for X.509 crypto
- **PKCS#11:** Standard API for cryptographic tokens. `libykcs11.so` implements it for YubiKey PIV.
- **p11-kit:** Middleware that loads PKCS#11 modules from `/etc/pkcs11/modules/`
- **pcscd:** PC/SC Smart Card Daemon — manages USB smart card reader communication
- **CCID:** USB device class for smart card readers; the `ccid` package provides the userspace pcscd driver (NOT a kernel module)
- **`cryptsetup-pre.target`:** systemd target running before LUKS volumes are opened; services needed for unlock should be wanted by this
- **`make-initrd-ng`:** Rust tool that populates the initrd filesystem, following ELF dependencies and `.note.dlopen` metadata
- **`libcryptsetup-token-systemd-pkcs11.so`:** Cryptsetup token plugin shipped with systemd; loaded by `libcryptsetup` when processing a PKCS#11 token entry in the LUKS2 header
