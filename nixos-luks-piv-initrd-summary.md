# NixOS LUKS Unlock via PIV Smartcard (YubiKey) in Initrd

## Summary & Implementation Plan for Claude Code

**Date:** 2026-04-04
**Goal:** Enable LUKS partition unlock at boot using a YubiKey PIV applet (PKCS#11) on NixOS with systemd-based initrd. Deliver as a reusable NixOS module, targeting NUR for publication.

---

## 1. Current Status

### What Has Been Accomplished

- **PKCS#11 enrollment works.** Using `systemd-cryptenroll --pkcs11-token-uri=auto`, a YubiKey PIV slot with an ECCP384 key has been successfully enrolled into a LUKS2 partition. The enrolled token appears in `cryptsetup luksDump` output. A passphrase slot is retained as fallback.

- **NixOS module implemented.** `modules/boot/initrd-pkcs11.nix` provides `boot.initrd.systemd.pkcs11.{enable, modules, pcscd.plugins}` options. It configures pcscd socket/service, p11-kit module files, and storePaths in the initrd.

- **Single-boot VM integration test passes.** `tests/initrd-pkcs11.nix` tests the full enroll + attach chain using softhsm as a software PKCS#11 token. Runs on aarch64-darwin (QEMU/TCG) in ~18s. Covers: token setup → LUKS format → PKCS#11 enrollment → PKCS#11 unlock → filesystem mount/verify.

- **Boot-cycle VM test written but untested.** `tests/initrd-pkcs11-boot.nix` tests the full reboot flow (enroll on first boot → reboot into specialisation → initrd unlocks LUKS via PKCS#11). Requires KVM; not yet run.

- **Eval tests exist.** `tests/initrd-pkcs11-eval.nix` provides pure Nix evaluation tests for module option validation.

- **The boot unlock does NOT work yet on real hardware.** The module and tests use softhsm. Real YubiKey testing requires physical hardware and has not been done.

### Key Research Findings

#### 1.1 The Dependency Chain

The full runtime dependency chain for PIV-based LUKS unlock is:

```
systemd-cryptsetup (in initrd)
  → libcryptsetup-token-systemd-pkcs11.so  (cryptsetup token plugin, ships with systemd)
    → libp11-kit.so  (PKCS#11 module discovery/dispatch)
      → /etc/pkcs11/modules/ykcs11.module  (config file pointing to libykcs11)
        → libykcs11.so  (Yubico's PKCS#11 module, from yubico-piv-tool)
          → libykpiv.so  (Yubico PIV library, dependency of libykcs11)
            → libpcsclite.so  (PC/SC client library)
              → pcscd  (PC/SC Smart Card Daemon)
                → ccid driver  (USB CCID smart card reader driver, loaded by pcscd)
                  → YubiKey hardware (USB)
```

Both `p11-kit` and `pcscd` are required at runtime in the initrd. This was confirmed by researching:
- dracut's `91pkcs11` module (handles p11-kit layer only, not pcscd — because pcscd is handled separately)
- The Nitrokey/Gentoo guide (vtimofeenko.com) which documents the full chain
- systemd source code behavior: `systemd-cryptsetup` uses `libcryptsetup-token-systemd-pkcs11.so` which calls p11-kit, which dispatches to the configured PKCS#11 module (libykcs11 for YubiKey PIV), which talks to pcscd

#### 1.2 The pcscd Ordering Problem

This is a known issue across distros (not NixOS-specific):

- `pcscd` is socket-activated by default. The `pcscd.socket` unit is pulled in by `sockets.target`.
- In the initrd, `sockets.target` runs *after* `cryptsetup.target` in the dependency graph.
- This creates a deadlock: `systemd-cryptsetup` needs pcscd to talk to the YubiKey, but pcscd won't start until after cryptsetup finishes.
- **Fix:** Override `pcscd.socket` and `pcscd.service` with `DefaultDependencies=no` and `WantedBy=cryptsetup-pre.target`, so they start *before* cryptsetup attempts to open volumes.

#### 1.3 How NixOS Handles TPM2 (The Reference Pattern)

In `nixos/modules/system/boot/luksroot.nix`, TPM2 support is wired as follows:

```nix
boot.initrd.systemd.storePaths = [
  "${config.boot.initrd.systemd.package}/bin/systemd-cryptsetup"
  "${config.boot.initrd.systemd.package}/lib/systemd/system-generators/systemd-cryptsetup-generator"
]
++ lib.optionals config.boot.initrd.systemd.tpm2.enable [
  "${config.boot.initrd.systemd.package}/lib/cryptsetup/libcryptsetup-token-systemd-tpm2.so"
];
```

Key observations:
- The `boot.initrd.systemd.tpm2.enable` option simply adds the `.so` plugin to `storePaths`.
- TPM2 needs no userspace daemon (it uses the kernel's `/dev/tpmrm0` interface), so it's much simpler than PKCS#11.
- FIDO2 has no dedicated NixOS module either — it works via `crypttabExtraOpts = ["fido2-device=auto"]` and relies on systemd's built-in FIDO2 support (which also doesn't need pcscd).

#### 1.4 NixOS-Specific Wrapping

NixOS patches `cryptsetup` and wraps `systemd-cryptsetup` / `systemd-cryptenroll` to set `LD_LIBRARY_PATH` pointing to systemd's `lib/cryptsetup/` directory. This means the `libcryptsetup-token-systemd-pkcs11.so` plugin is found automatically **if it exists in the initrd store paths** — the wrapping is already handled.

#### 1.5 What Does NOT Exist Today

- No `boot.initrd.systemd.pkcs11.enable` option in nixpkgs.
- No NixOS module that adds pcscd to the initrd.
- No NixOS integration test for PKCS#11 initrd LUKS unlock (tests exist for TPM2 and FIDO2).
- nixpkgs issue #265366 confirms that vanilla `cryptsetup` cannot use systemd's token plugins (FIDO2, PKCS#11, TPM2) outside of `systemd-cryptsetup` due to library path issues. The initrd's `systemd-cryptsetup` wrapper handles this, but only if the `.so` files are in the store paths.

---

## 2. Additional Research Steps (For Claude Code)

These should be done with direct access to the nixpkgs tree and NUR:

### 2.1 Source Code Analysis (Priority: High)

Read and understand these files in the nixpkgs tree:

1. **`nixos/modules/system/boot/luksroot.nix`** — The primary file. Understand:
   - How `storePaths` is populated for `systemd-cryptsetup` and the TPM2 plugin
   - How `crypttabExtraOpts` flows into the generated crypttab
   - The assertions and guards for systemd stage 1
   - The `stage1Crypttab` generation logic

2. **`nixos/modules/system/boot/systemd/initrd.nix`** — Understand:
   - How `boot.initrd.systemd.storePaths` works (does it follow Nix store closures automatically, or do transitive `.so` deps need explicit listing?)
   - How `boot.initrd.systemd.contents` works for injecting config files
   - How `boot.initrd.systemd.services` works for adding custom services
   - How `boot.initrd.systemd.initrdBin` works vs. `storePaths`

3. **`nixos/modules/services/hardware/pcscd.nix`** — The existing pcscd module for the running system. Understand:
   - How it references `pkgs.pcsclite`, `pkgs.ccid`
   - The systemd unit configuration it generates
   - How the CCID driver path (`${pkgs.ccid}/lib/pcsc/drivers`) is configured for pcscd

4. **`pkgs/tools/security/yubico-piv-tool/`** — Check:
   - That `libykcs11.so` is built and available in the output
   - What its runtime dependencies are (should be `libykpiv.so`, `libpcsclite.so`, `libcrypto.so`)

5. **`nixos/tests/systemd-initrd-luks-tpm2.nix`** (or similar test file) — Reference pattern for writing a PKCS#11 integration test.

### 2.2 Dependency Verification (Priority: High)

Run these checks to confirm the exact store paths and transitive dependencies:

```bash
# Check what libykcs11 links against
nix-shell -p yubico-piv-tool --run "ldd $(nix eval --raw nixpkgs#yubico-piv-tool)/lib/libykcs11.so"

# Check the pkcs11 token plugin's dependencies
nix-shell -p systemd --run "ldd $(nix eval --raw nixpkgs#systemd)/lib/cryptsetup/libcryptsetup-token-systemd-pkcs11.so"

# Confirm p11-kit module directory location
nix-shell -p p11-kit --run "ls $(nix eval --raw nixpkgs#p11-kit)/etc/pkcs11/modules/ 2>/dev/null || echo 'no default modules dir'"

# Check if store closure of libcryptsetup-token-systemd-pkcs11.so already pulls in p11-kit
nix path-info -r $(nix eval --raw nixpkgs#systemd)/lib/cryptsetup/libcryptsetup-token-systemd-pkcs11.so 2>/dev/null
```

### 2.3 Verify pcscd Requirements in Initrd (Priority: Medium)

- Determine whether pcscd needs a config file (`/etc/reader.conf.d/` or similar) or if it auto-detects CCID readers.
- Check if pcscd needs the full `${pkgs.ccid}/lib/pcsc/drivers` directory tree or just specific `.bundle` directories.
- Determine if USB kernel modules (`usbhid`, etc.) need to be explicitly added to `boot.initrd.availableKernelModules` beyond what's already typically present.

### 2.4 Check Existing Community Work (Priority: Medium)

Search for:
- Any NUR packages or modules that already attempt PKCS#11 initrd support
- Any open nixpkgs PRs adding `boot.initrd.systemd.pkcs11`
- Any NixOS Discourse / GitHub discussions with working configs

---

## 3. Implementation Steps

### Phase 1: Minimal Working Configuration (Manual Wiring)

Before building a proper module, get it working as a raw NixOS config to validate the approach.

#### 3.1 Draft Configuration

```nix
{ config, pkgs, lib, ... }:

{
  # PREREQUISITE: systemd-based initrd
  boot.initrd.systemd.enable = true;

  # --- LUKS device with PKCS#11 ---
  boot.initrd.luks.devices."cryptroot" = {
    device = "/dev/disk/by-uuid/<UUID>";
    crypttabExtraOpts = [
      "pkcs11-uri=pkcs11:"    # bare URI = try any available PKCS#11 token
      "token-timeout=10"      # seconds to wait for token before passphrase fallback
    ];
  };

  # --- Store paths needed in initrd ---
  boot.initrd.systemd.storePaths = [
    # The PKCS#11 token plugin (same pattern as TPM2)
    "${config.boot.initrd.systemd.package}/lib/cryptsetup/libcryptsetup-token-systemd-pkcs11.so"

    # p11-kit (used by the plugin to discover PKCS#11 modules)
    "${pkgs.p11-kit}/lib/libp11-kit.so.0"

    # YubiKey PKCS#11 module + its PIV dependency
    "${pkgs.yubico-piv-tool}/lib/libykcs11.so"
    "${pkgs.yubico-piv-tool}/lib/libykpiv.so"

    # pcscd + client library + CCID driver
    "${pkgs.pcsclite}/bin/pcscd"
    "${pkgs.pcsclite}/lib/libpcsclite.so.1"
    "${pkgs.ccid}/lib/pcsc/drivers"
  ];

  # --- p11-kit module config (so it finds libykcs11) ---
  boot.initrd.systemd.contents."/etc/pkcs11/modules/ykcs11.module".text = ''
    module: ${pkgs.yubico-piv-tool}/lib/libykcs11.so
  '';

  # --- pcscd service in initrd with correct ordering ---
  boot.initrd.systemd.services.pcscd = {
    description = "PC/SC Smart Card Daemon (initrd)";
    wantedBy = [ "cryptsetup-pre.target" ];
    before = [ "cryptsetup-pre.target" ];
    unitConfig = {
      DefaultDependencies = "no";
    };
    serviceConfig = {
      ExecStart = "${pkgs.pcsclite}/bin/pcscd --foreground";
      Type = "simple";
    };
  };

  # --- Running system: pcscd for enrollment/management ---
  services.pcscd.enable = true;

  # --- Running system: p11-kit module config ---
  environment.etc."pkcs11/modules/ykcs11.module".text = ''
    module: ${pkgs.yubico-piv-tool}/lib/libykcs11.so
  '';
}
```

#### 3.2 Open Questions to Resolve During Implementation

These are things that need empirical verification (build and test):

1. **Does `storePaths` follow Nix store closure?** If yes, adding `libcryptsetup-token-systemd-pkcs11.so` might pull in `libp11-kit` automatically. If not, every `.so` in the chain needs explicit listing. **Check `initrd.nix` source to confirm.**

2. **pcscd CCID driver path:** pcscd finds CCID drivers via a compile-time path or `PCSCLITE_HP_DROPDIR` env var. In the initrd, the Nix store path to `${pkgs.ccid}/lib/pcsc/drivers` must be accessible. Verify how NixOS's pcscd.nix configures this on the running system and replicate it for initrd. May need:
   ```nix
   boot.initrd.systemd.contents."/etc/reader.conf.d/ccid".text = ''
     # or whatever pcscd needs to find the CCID bundle
   '';
   ```
   Or an environment variable override in the service unit.

3. **`pcscd.socket` vs `pcscd.service`:** On the running system, pcscd is socket-activated. In the initrd, we may want direct service activation (not socket-activated) to avoid the ordering problem. The draft above uses a direct service. Verify this works — pcscd may refuse to start without its socket unit.

4. **p11-kit trust/config paths:** p11-kit may look for config in paths beyond `/etc/pkcs11/modules/`. Verify with `strace` or p11-kit documentation that the module file location is correct for the initrd environment.

5. **USB kernel modules:** Ensure the initrd has the necessary USB/HID kernel modules to detect the YubiKey. Likely needed:
   ```nix
   boot.initrd.availableKernelModules = [ "usbhid" "usb_storage" "xhci_pci" ];
   ```
   (Many of these are already included by default on most hardware configs.)

6. **`--auto-exit` flag for pcscd:** Using `--auto-exit` could cause pcscd to exit before systemd-cryptsetup finishes if there's a timing issue. Safer to omit it and let the initrd's switch-root cleanup handle termination.

### Phase 2: NixOS Module (For NUR)

Once Phase 1 is validated, wrap it into a proper NixOS module.

#### 3.3 Module Structure

Target file: `modules/system/boot/initrd-pkcs11.nix` (or similar)

```
nur-packages/
└── modules/
    └── nixos/
        └── initrd-pkcs11/
            ├── default.nix          # The NixOS module
            └── README.md            # Usage documentation
```

#### 3.4 Module Options to Expose

```nix
boot.initrd.systemd.pkcs11 = {
  enable = mkEnableOption "PKCS#11 smartcard support for LUKS unlock in initrd";

  # Which PKCS#11 module to use (default: yubico-piv-tool's libykcs11)
  package = mkOption {
    type = types.package;
    default = pkgs.yubico-piv-tool;
    description = "Package providing the PKCS#11 module (.so) for the smartcard.";
  };

  # The .so filename within the package's lib directory
  modulePath = mkOption {
    type = types.str;
    default = "lib/libykcs11.so";
    description = "Relative path to the PKCS#11 .so module within the package.";
  };
};
```

#### 3.5 Module Implementation Sketch

The module's `config` block should:

1. Add `libcryptsetup-token-systemd-pkcs11.so` to `boot.initrd.systemd.storePaths`
2. Add `p11-kit`, the PKCS#11 module package (e.g., `yubico-piv-tool`), `pcsclite`, and `ccid` to store paths
3. Create `/etc/pkcs11/modules/<name>.module` in `boot.initrd.systemd.contents`
4. Add the `pcscd` service with correct ordering to `boot.initrd.systemd.services`
5. Optionally add required kernel modules to `boot.initrd.availableKernelModules`

The module should NOT:
- Auto-configure `boot.initrd.luks.devices` — the user sets `crypttabExtraOpts` themselves
- Perform enrollment — that's a manual `systemd-cryptenroll` step
- Assume YubiKey specifically — the module should be generic enough for any PKCS#11 token that uses pcscd (though YubiKey PIV is the primary target)

### Phase 3: Integration Test

#### 3.6 Test Strategy

Write a NixOS VM test (following the pattern of `systemd-initrd-luks-tpm2`):

- This is complex because it requires a virtual smartcard in the VM. Options:
  - `softhsm2` — a software PKCS#11 implementation that doesn't need pcscd (would test the p11-kit → plugin path but NOT the pcscd path)
  - `virt_cacard` / `vpcd` — virtual smart card over virtual USB (would test the full path including pcscd, but is much more complex to set up in a NixOS VM test)
  - **Pragmatic approach:** Start with `softhsm2` to validate the p11-kit/plugin integration, document that pcscd path testing requires real hardware or a virtual smartcard setup.

---

## 4. Risk Register

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| `storePaths` doesn't follow closures → missing transitive `.so` deps | Medium | Boot fails, falls back to password | Explicitly list all `.so` files; verify with `ldd` |
| pcscd can't find CCID drivers in initrd Nix store paths | Medium | Token not detected, falls back to password | Check pcscd's driver discovery mechanism; may need env var or config |
| p11-kit can't find module config in initrd `/etc/pkcs11/modules/` | Medium | Token not detected, falls back to password | Verify p11-kit's search paths; may need `P11_KIT_CONFIG_DIR` env var |
| Ordering issue: pcscd starts too late despite our overrides | Low | Token not detected, falls back to password | Test carefully; may need additional `After=` / `Requires=` on cryptsetup unit |
| YubiKey USB not enumerated fast enough in initrd | Low | Token not detected, falls back to password | `token-timeout` in crypttab provides a wait window |
| NixOS updates change systemd wrapping / store path layout | Low | Future breakage | Pin to specific NixOS version for initial development; add CI test |

---

## 5. Reference Links

- **Previous conversation:** https://claude.ai/chat/a1f7860d-ea92-4f04-876b-08577d616387
- **nixpkgs `luksroot.nix`:** `nixos/modules/system/boot/luksroot.nix` (the TPM2 storePaths pattern)
- **nixpkgs `initrd.nix`:** `nixos/modules/system/boot/systemd/initrd.nix` (storePaths/contents/services API)
- **nixpkgs `pcscd.nix`:** `nixos/modules/services/hardware/pcscd.nix` (running-system pcscd reference)
- **nixpkgs issue #265366:** Vanilla cryptsetup can't use systemd token plugins (FIDO2, PKCS#11, TPM2)
- **Lennart Poettering's blog post:** https://0pointer.net/blog/unlocking-luks2-volumes-with-tpm2-fido2-pkcs11-security-hardware-on-systemd-248.html
- **dracut `91pkcs11` commit:** https://github.com/dracutdevs/dracut/commit/83ea8cf (reference for what dracut installs for PKCS#11)
- **Nitrokey/Gentoo guide:** https://vtimofeenko.com/posts/unlocking-luks2-with-x509-nitrokey-during-boot/ (non-NixOS full-chain walkthrough)

---

## 6. Glossary

- **PIV:** Personal Identity Verification — the smart card applet on YubiKeys used for X.509 certificate-based crypto operations
- **PKCS#11:** Standard API for cryptographic tokens (smart cards, HSMs). `libykcs11.so` implements this for YubiKey PIV.
- **p11-kit:** Middleware that loads PKCS#11 modules based on config files in `/etc/pkcs11/modules/`
- **pcscd:** PC/SC Smart Card Daemon — userspace daemon that manages communication with smart card readers over USB/CCID
- **CCID:** USB device class for smart card readers; the `ccid` package provides the driver that pcscd uses
- **crypttab:** `/etc/crypttab` — systemd reads this (or generates it from the generator) to know how to open LUKS volumes. `pkcs11-uri=pkcs11:` tells it to try PKCS#11.
- **`libcryptsetup-token-systemd-pkcs11.so`:** The cryptsetup token plugin shipped with systemd. Loaded by `libcryptsetup` when processing a PKCS#11 token entry in the LUKS2 header.
- **`cryptsetup-pre.target`:** systemd target that runs before any LUKS volumes are opened. Services needed for unlock (like pcscd) should be wanted by this target.

---

## 7. Research Results (2026-04-03 — Claude Code Review)

### 7.1 Current Implementation State

A first draft of the NixOS module exists at `modules/boot/initrd-pkcs11.nix` and is wired into `modules/default.nix` and exposed via `flake.nix` as `nixosModules.initrd-pkcs11`. A dev shell with smartcard tooling was added to `flake.nix`.

### 7.2 Verified Research Findings

#### `make-initrd-ng` DOES Follow ELF Dependencies (Partially)
- **Source:** `pkgs/build-support/kernel/make-initrd-ng/src/main.rs`
- `make-initrd-ng` **does** parse ELF `DT_NEEDED` entries and follows RPATH/RUNPATH to include direct shared library dependencies automatically.
- It also supports systemd's `.note.dlopen` ELF metadata for conditional dlopen dependencies.
- **However**, libraries loaded via `dlopen()` at runtime (without ELF notes) — like p11-kit loading `libykcs11.so` from a config file — are NOT auto-detected and must be listed explicitly in `storePaths`.
- **Impact on module:** The `libcryptsetup-token-systemd-pkcs11.so` will auto-pull `libp11-kit.so` (since it's a direct ELF dependency). But `libykcs11.so` (loaded by p11-kit at runtime) must be explicit — which the module already does correctly.

#### `boot.initrd.systemd.sockets` Exists
- **Source:** `nixos/modules/system/boot/systemd/initrd.nix:374`
- There is a proper `boot.initrd.systemd.sockets` option (type: `initrdSockets`) alongside `services`, `targets`, `paths`, etc.
- The `wantedBy` attribute on these NixOS options creates `.wants` symlinks declaratively during build. Raw `[Install] WantedBy=` in unit text does nothing in initrd (no `systemctl enable`).

#### `pcsclite` Driver Discovery via `PCSCLITE_HP_DROPDIR`
- **Source:** `pkgs/by-name/pc/pcsclite/package.nix:49`
- Compile-time `usbdropdir` is set to `/var/lib/pcsc/drivers` (a non-existent Nix store path).
- The running system pcscd module overrides this with `PCSCLITE_HP_DROPDIR` env var pointing to a `buildEnv` of `${plugin}/pcsc/drivers`.
- **Important:** The `ccid` package's drivers live at `${pkgs.ccid}/lib/pcsc/drivers/` (note the `lib/` prefix).

#### p11-kit Module Discovery
- **Source:** `pkgs/by-name/p1/p11-kit/package.nix:54-55`
- p11-kit is built with `--sysconfdir=/etc`, so it reads module files from `/etc/pkcs11/modules/`.
- The nixpkgs package patches `p11-kit/meson.build` to install sample configs to `$out/etc/pkcs11` (line 74-75).
- **The module's `contents."/etc/pkcs11/modules/${cfg.moduleName}.module"` approach is correct.**

#### `ccid` is NOT a Kernel Module
- `modinfo ccid` returns "Module ccid not found."
- `ccid` is a userspace pcscd driver package providing `lib/pcsc/drivers/ifd-ccid.bundle/`.
- There is no kernel module named "ccid".

#### `yubico-piv-tool` Outputs
- **Source:** `pkgs/by-name/yu/yubico-piv-tool/package.nix`
- Provides `libykcs11.so` and `libykpiv.so` (pkgConfigModules: `ykcs11`, `ykpiv`).
- Runtime deps: `openssl`, `pcsclite` (as buildInputs).
- Single output `out` contains both binaries and libraries.

#### systemd Issue #23479 — PKCS#11 URI `type=cert` vs `type=private`
- When enrolling via `systemd-cryptenroll --pkcs11-token-uri=auto`, the URI stored in LUKS2 header might use `type=cert` instead of `type=private`.
- This was fixed in systemd PR #29692 which auto-converts the URI during enrollment.
- **Impact:** Users on older systemd versions may need to use `--pkcs11-token-uri=pkcs11:` (bare URI) to avoid this issue.

#### NixOS TPM2 Test Pattern (Reference)
- **Source:** `nixos/tests/systemd-initrd-luks-tpm2.nix`
- Pattern: create LUKS volume → enroll token → reboot into specialisation → verify mount.
- Uses `virtualisation.tpm.enable = true` for virtual TPM.
- PKCS#11 test would need a virtual smartcard (e.g., `softhsm2` or `vpcd`/`virt_cacard`).

#### No Existing Community PKCS#11 Initrd Module
- No NUR packages, nixpkgs PRs, or Discourse posts found implementing PKCS#11 initrd support for NixOS.
- The existing [nixos-yubikey-luks](https://github.com/sgillespie/nixos-yubikey-luks) repo uses HMAC-SHA1 challenge-response (not PIV/PKCS#11) and is unmaintained (last commit 2019).
- This module would be the first NixOS implementation of PIV/PKCS#11-based LUKS initrd unlock.

### 7.3 Bugs Found in Current `initrd-pkcs11.nix`

#### BUG 1 (Critical): `pcscd.socket` Uses Raw `units` — WantedBy Won't Work
**Location:** `modules/boot/initrd-pkcs11.nix:112-126`

The module defines `boot.initrd.systemd.units."pcscd.socket"` with raw unit text containing `[Install] WantedBy=cryptsetup-pre.target`. In NixOS initrd, this `[Install]` section is informational only — it requires `systemctl enable` to create symlinks, which doesn't happen during build.

**Fix:** Use `boot.initrd.systemd.sockets.pcscd` with the `wantedBy` NixOS option:
```nix
boot.initrd.systemd.sockets.pcscd = {
  wantedBy = [ "cryptsetup-pre.target" ];
  unitConfig.DefaultDependencies = false;
  listenStreams = [ "/run/pcscd/pcscd.comm" ];
  socketConfig.SocketMode = "0666";
};
```

#### BUG 2: `"ccid"` in `availableKernelModules` is Invalid
**Location:** `modules/boot/initrd-pkcs11.nix:151`

`ccid` is a userspace pcscd driver package, not a kernel module. Adding it to `availableKernelModules` will silently do nothing (or cause a warning).

**Fix:** Remove `"ccid"` from the kernel modules list.

#### ~~BUG 3: `pluginEnv` Path Structure Mismatch~~ — VERIFIED CORRECT
**Location:** `modules/boot/initrd-pkcs11.nix:15`

The `ccid` package installs drivers to `$out/pcsc/drivers` (confirmed in `pkgs/by-name/cc/ccid/package.nix:31`). The module's `"${p}/pcsc/drivers"` path matches both the package output and the reference `pcscd.nix` pattern. **This is correct.**

#### ~~BUG 4: `pcscd` ExecStart Uses `--auto-exit` Flag~~ — NOT A BUG
**Location:** `modules/boot/initrd-pkcs11.nix:135`

Initially thought `--auto-exit` would cause pcscd to exit before USB enumeration. **This is incorrect.** Per `pcscd(8)`, `--auto-exit` (`-x`) means "quit after 60 seconds of inactivity after the release of the last PC/SC context" — it exits 60s after the last *client disconnects*, not when no readers are found. pcscd waits for clients regardless of reader state. 60 seconds is more than sufficient. Furthermore, `--auto-exit` is *desirable* in the initrd so pcscd cleans up after LUKS unlock rather than lingering through switch-root. The reference `pcscd.nix` also uses `-x`.

**Action:** Kept `--auto-exit` (short form `-x`). Switched from long-form flags to short-form (`-f -x -c`) to match reference `pcscd.nix` style.

#### Issue 5: Missing `-c` Flag for pcscd Config File
**Location:** `modules/boot/initrd-pkcs11.nix:135`

The reference pcscd.nix always passes `-c ${cfgFile}` to prevent pcscd from scanning `/etc` for config files (nixpkgs issue #121088). The initrd module should do the same.

#### Issue 6: `pcscd.service` Should Have `Before` Ordering
The service should explicitly declare `before = [ "cryptsetup-pre.target" ]` to ensure it's fully started before LUKS unlock attempts begin.

### 7.4 Risk Register Updates

| Risk | Status | Notes |
|---|---|---|
| `storePaths` doesn't follow closures | **RESOLVED** | `make-initrd-ng` follows ELF `DT_NEEDED` deps. Only dlopen'd libs need explicit listing. |
| pcscd can't find CCID drivers | **RESOLVED** | `pluginEnv` path `"${p}/pcsc/drivers"` matches `ccid` output (`$out/pcsc/drivers`). |
| p11-kit can't find module config | **RESOLVED** | p11-kit uses `--sysconfdir=/etc`, our `/etc/pkcs11/modules/` path is correct. |
| Ordering issue: pcscd starts too late | **FIXED** | BUG 1: Replaced raw `units."pcscd.socket"` with `sockets.pcscd` using NixOS `wantedBy` attribute. |
| `--auto-exit` race condition | **NOT A BUG** | `-x`/`--auto-exit` exits 60s after last PC/SC context release, not on missing readers. Desirable in initrd for cleanup. |

---

## 8. Bug Fixes Applied (2026-04-03)

All bugs identified in section 7.3 have been fixed. Module evaluation verified with `lib.nixosSystem`.

### Fixes Applied

| Bug | Fix | Verified |
|---|---|---|
| **BUG 1** (Critical): `pcscd.socket` raw unit `[Install] WantedBy=` does nothing in initrd | Replaced `boot.initrd.systemd.units."pcscd.socket"` with `boot.initrd.systemd.sockets.pcscd` using NixOS `wantedBy` attribute that creates `.wants/` symlinks at build time | `nix eval` confirms `socketWantedBy = [ "cryptsetup-pre.target" ]` |
| **BUG 2**: `"ccid"` in `availableKernelModules` is invalid (userspace driver, not kernel module) | Removed `"ccid"` from list; added comment explaining it's handled via `pluginEnv`/`PCSCLITE_HP_DROPDIR` | `nix eval` confirms only real kernel modules present |
| ~~**BUG 4**~~: `--auto-exit` initially thought to risk race condition | **Not a bug.** `-x`/`--auto-exit` exits 60s after last client disconnects, not on missing readers. Kept; switched to short-form flags (`-f -x -c`) matching reference. | Verified via `pcscd(8)` man page |
| **Issue 5**: Reference pcscd.nix always passes `-c ${cfgFile}` (nixpkgs#121088) | Already had `-c ${readerConf}`, kept and clarified with comment | Verified in module source |
| **Issue 6**: `pcscd.service` missing `Before` ordering | Added `before = [ "cryptsetup-pre.target" ]` to service | `nix eval` confirms `serviceBefore = [ "cryptsetup-pre.target" ]` |

### Eval Test Suite

Created `tests/initrd-pkcs11-eval.nix` (same pattern as `tests/mktxp-eval.nix`) with 8 test groups, wired into `flake.nix` as `checks.*.initrd-pkcs11-eval-*`:

| Test | What it checks |
|---|---|
| `pcscd-socket` | Socket exists, wantedBy `cryptsetup-pre.target`, `DefaultDependencies=false`, listens on `/run/pcscd/pcscd.comm` |
| `pcscd-service` | Service exists, after `pcscd.socket`, before `cryptsetup-pre.target`, `-f -x -c` flags, `PCSCLITE_HP_DROPDIR` set |
| `store-paths` | `libcryptsetup-token-systemd-pkcs11.so`, `libykcs11.so`, `pcscd` present in storePaths |
| `p11-kit-module` | `/etc/pkcs11/modules/ykcs11.module` exists with correct content |
| `reader-conf` | `/etc/reader.conf` present in initrd contents |
| `kernel-modules` | `usbhid`, `xhci_pci` present; `ccid` NOT present |
| `disabled` | No pcscd socket/service/storePaths when `enable = false` |
| `custom-package` | Custom `package`/`modulePath`/`moduleName` (opensc) reflected correctly |

All 8 tests pass: `nix build .#checks.x86_64-linux.initrd-pkcs11-eval-*`

**Note:** `storePaths` entries in NixOS are structured submodules (`{ source, target, dlopen, enable }`) — tests check `p.source` for path matching, not the entry directly.

---

## 9. Options Refactoring (2026-04-04)

### Motivation

The original three options (`package`, `modulePath`, `moduleName`) were unnecessarily complex:
- `package` was always used together with `modulePath` to form a single store path
- There was no use case requiring `package` as a separate option
- Only one PKCS#11 module could be configured at a time

### New Design

Replaced all three with a single `modules` attrset:

```nix
boot.initrd.systemd.pkcs11.modules = {
  ykcs11 = "${pkgs.yubico-piv-tool}/lib/libykcs11.so";
  # Multiple modules can be specified for multi-vendor support:
  # opensc = "${pkgs.opensc}/lib/opensc-pkcs11.so";
};
```

- Type: `lib.types.attrsOf lib.types.str`
- Each key becomes a p11-kit module file: `/etc/pkcs11/modules/<name>.module`
- Each value is the absolute Nix store path to the `.so` library
- Default: `{ ykcs11 = "${pkgs.yubico-piv-tool}/lib/libykcs11.so"; }`

### Implementation Changes

1. **Module (`modules/boot/initrd-pkcs11.nix`):**
   - Removed `package`, `modulePath`, `moduleName` options
   - Added `modules` attrset option
   - `storePaths` now uses `lib.attrValues cfg.modules` to include all .so files
   - `contents` uses `lib.mapAttrs'` to generate one p11-kit module file per entry

2. **Eval tests (`tests/initrd-pkcs11-eval.nix`):**
   - Replaced `custom-package` test (Scenario C: opensc) with `multi-module` test
   - Scenario C now tests two simultaneous modules (ykcs11 + opensc)
   - All 8 tests pass

---

## 10. VM Integration Test (2026-04-04) — IN PROGRESS

### Strategy

Using **softhsm** as a software PKCS#11 token to test the full unlock chain:
`systemd-cryptsetup` → `libcryptsetup-token-systemd-pkcs11.so` → p11-kit → `libsofthsm2.so` → token data

**What this tests:** p11-kit module discovery, cryptsetup PKCS#11 token plugin, LUKS enrollment and unlock, store path completeness in initrd.

**What this does NOT test:** pcscd/CCID/USB stack (softhsm is a pure software token that doesn't need pcscd). Testing the full pcscd chain requires real hardware or `vsmartcard-vpcd`.

### Test Architecture

File: `tests/initrd-pkcs11.nix`, wired into flake as `checks.x86_64-linux.initrd-pkcs11`.

Pattern follows `nixos/tests/systemd-initrd-luks-tpm2.nix`:
1. **First boot:** Create LUKS volume → enroll softhsm PKCS#11 token via `systemd-cryptenroll`
2. **Reboot** into specialisation that imports `initrd-pkcs11` module
3. **Second boot:** Verify LUKS volume unlocked and mounted via PKCS#11

### Softhsm-Specific Setup

Softhsm has requirements that real hardware tokens (YubiKey) don't:
- **Config file:** `SOFTHSM2_CONF` env var pointing to `softhsm2.conf` (specifies token directory)
- **Token data:** Pre-built at Nix build time via `pkgs.runCommand` — initializes softhsm slot, generates RSA 2048 key pair, imports self-signed X.509 certificate (required by `systemd-cryptenroll`)
- **Initrd injection:** Both `softhsm2.conf` and token data directory must be in initrd `contents`

### Key Challenge: Environment Variable Injection

`systemd-cryptsetup@` is spawned by the systemd cryptsetup generator. We need `SOFTHSM2_CONF=/etc/softhsm2.conf` in its environment. Approaches considered:

1. ~~**Drop-in conf file** at `/etc/systemd/system/systemd-cryptsetup@.service.d/`~~ — Failed because `/etc/systemd/system` is a symlink to a Nix store path (`stage1Units`), and `make-initrd-ng` cannot create subdirectories inside it via `contents`. The `@` in the service name also complicates directory creation.

2. **`boot.initrd.systemd.settings.Manager.DefaultEnvironment`** — Sets the `DefaultEnvironment=` directive in initrd `system.conf`, which applies to all services including generator-spawned ones like `systemd-cryptsetup@`. Current approach:
   ```nix
   boot.initrd.systemd.settings.Manager.DefaultEnvironment =
     lib.mkForce "PATH=/bin:/sbin SOFTHSM2_CONF=/etc/softhsm2.conf";
   ```
   Caveat: uses `mkForce` to override the default `PATH=/bin:/sbin` — the PATH must be preserved.

3. *(Not tried)* `boot.initrd.systemd.units` with `overrideStrategy` — might work for creating drop-ins within the `stage1Units` derivation, but more complex.

### Test Token Preparation

The `testTokenData` derivation:
```
softhsm2-util --init-token  →  creates slot with PIN=1234, SO-PIN=12345678
softhsm2-util --import      →  imports RSA 2048 private key as id=01
pkcs11-tool --write-object   →  imports matching X.509 DER certificate as id=01
```

PKCS#11 URI for enrollment and unlock: `pkcs11:token=test;pin-value=1234`

### Build Attempts and Issues Encountered

1. **x86_64-linux + `useBootLoader`/specialisation/reboot pattern** — Failed. `make-initrd-ng` permission error: "failed to create directories to `./root//etc/systemd/system/systemd-cryptsetup@.service.d`" because `/etc/systemd/system` is a symlink to the Nix store `stage1Units`. Fixed by switching from drop-in to `DefaultEnvironment` in `system.conf`.

2. **x86_64-linux + `useBootLoader`** (with DefaultEnvironment fix) — Building worked, but the disk image builder step internally runs QEMU to create a UEFI disk image. Under Rosetta (the host is aarch64 Apple M1 Pro → AppleVZ Linux VM), this x86_64 QEMU runs under emulation and is extremely slow. The disk image build hung.

3. **aarch64-linux + `useBootLoader`** — Same problem: `useBootLoader = true` triggers `nixos-disk-image` which runs its own QEMU VM internally. Without KVM (not available in AppleVZ), the inner QEMU falls back to TCG and produces `error while reading directory` / `virtiofsd` errors and hangs.

4. **aarch64-linux + simplified test (no `useBootLoader`)** — **Progressed significantly.** Removed `useBootLoader`/`useEFIBoot`/`mountHostNixStore`/specialisation. Uses `runNixOSTest` (like mktxp test). Tests enrollment + unlock in a single boot using `systemd-cryptsetup attach` directly instead of reboot. VM boots successfully (~2 min under TCG), token is detected, LUKS volume created, `systemd-cryptenroll` starts and discovers the softhsm module. **But RSA crypto operations under TCG are extremely slow** — enrollment stuck for 10+ minutes with no progress. The mktxp test works fine because it doesn't do crypto.

### Current Status

- **Both tests evaluate correctly** on both architectures
- **Single-boot test partially verified** — VM boots, softhsm token data loads, `systemd-cryptenroll` finds the PKCS#11 module via p11-kit. Crypto operations too slow under TCG to complete.
- **Boot-cycle test not yet run** — requires KVM
- **Cannot complete on current hardware** — RSA operations via softhsm in QEMU/TCG (no KVM) are too slow
- All 8 eval tests pass: `nix build .#checks.aarch64-linux.initrd-pkcs11-eval-{pcscd-socket,pcscd-service,store-paths,p11-kit-module,reader-conf,kernel-modules,disabled,multi-module} --no-link`

### VM Test Inventory

| Flake check | File | Description | KVM required? |
|---|---|---|---|
| `initrd-pkcs11` | `tests/initrd-pkcs11.nix` | Single-boot: enroll + `systemd-cryptsetup attach` | Recommended (crypto is slow under TCG) |
| `initrd-pkcs11-boot` | `tests/initrd-pkcs11-boot.nix` | Full boot-cycle: enroll → reboot → initrd unlocks LUKS | **Yes** (`useBootLoader` disk image builder hangs under TCG) |

Both tests use **softhsm** as a software PKCS#11 token (no pcscd needed). They share the same `testTokenData` derivation that pre-builds an RSA 2048 key pair + X.509 certificate.

### Files Modified

| File | Change |
|---|---|
| `modules/boot/initrd-pkcs11.nix` | Replaced `package`/`modulePath`/`moduleName` with `modules` attrset |
| `tests/initrd-pkcs11-eval.nix` | Updated for new options; replaced `custom-package` with `multi-module` test |
| `tests/initrd-pkcs11.nix` | **NEW** — Single-boot VM test (enroll + attach) |
| `tests/initrd-pkcs11-boot.nix` | **NEW** — Full boot-cycle VM test (enroll → reboot → initrd unlock) |
| `flake.nix` | Added both VM tests to Linux-only checks |

---

## 11. Continuation Instructions for VM Integration Tests

This section is written for a developer or Claude Code session that will continue
working on the VM integration tests from a different host.

### Prerequisites

- A host with **KVM support** (native Linux with `/dev/kvm`, or macOS with appropriate QEMU acceleration)
- Clone or access to the repository at the current state
- `nix` with flakes enabled

### Quick Verification

```bash
# 1. Eval tests (should pass everywhere, no VM needed):
nix build .#checks.x86_64-linux.initrd-pkcs11-eval-{pcscd-socket,pcscd-service,store-paths,p11-kit-module,reader-conf,kernel-modules,disabled,multi-module} --no-link

# 2. Single-boot VM test (enroll + attach, no reboot):
nix build .#checks.x86_64-linux.initrd-pkcs11 --no-link --print-build-logs

# 3. Full boot-cycle VM test (enroll → reboot → initrd unlock):
nix build .#checks.x86_64-linux.initrd-pkcs11-boot --no-link --print-build-logs
```

Use `aarch64-linux` instead of `x86_64-linux` on ARM hosts.

### What the Tests Do

**`initrd-pkcs11` (single-boot):**
1. Boot VM, copy pre-built softhsm token data to `/var/lib/softhsm/tokens/`
2. `cryptsetup luksFormat /dev/vdb` (empty disk image)
3. `systemd-cryptenroll --pkcs11-token-uri='pkcs11:token=test;pin-value=1234' /dev/vdb`
4. `systemd-cryptsetup attach test-crypt /dev/vdb - 'pkcs11-uri=...'`
5. Verify `/dev/mapper/test-crypt` exists, create ext4, mount, write marker

**`initrd-pkcs11-boot` (boot-cycle):**
1. Boot VM (with UEFI boot loader), enroll as above
2. `bootctl set-default` to specialisation, crash + reboot
3. Specialisation boots with `boot.initrd.luks.devices.cryptroot` pointing to `/dev/vdb`
4. `systemd-cryptsetup` in initrd unlocks via PKCS#11 automatically
5. Verify `/dev/mapper/cryptroot on / type ext4` in `mount` output

### Softhsm-Specific Test Setup (Would NOT Apply to Real YubiKey)

These parts of the test are softhsm workarounds, not part of the module itself:

1. **`testTokenData` derivation** — Pre-builds softhsm slot with RSA 2048 key + X.509 cert at Nix build time. The cert import uses `pkcs11-tool` because `softhsm2-util` can only import keys, not certs.

2. **`SOFTHSM2_CONF` env var** — softhsm needs this to find `softhsm2.conf` (which points to the token directory). Real YubiKeys carry keys in hardware and need no config file.

3. **`DefaultEnvironment` in initrd `system.conf`** (boot-cycle test only) — Sets `SOFTHSM2_CONF=/etc/softhsm2.conf` for all initrd services including generator-spawned `systemd-cryptsetup@`. Uses `lib.mkForce` to override the default `PATH=/bin:/sbin` (PATH is preserved in the override value). A drop-in conf at `/etc/systemd/system/systemd-cryptsetup@.service.d/` was tried but failed because `/etc/systemd/system` is a symlink to the Nix store `stage1Units` directory.

4. **Token data + config in initrd `contents`** (boot-cycle test only) — Both `/etc/softhsm2.conf` and `/var/lib/softhsm/tokens` are injected into the initrd.

### Known Issues and Things to Watch

1. **~~Crypto slowness~~ RESOLVED** — RSA 2048 enrollment+unlock completes in ~0.5s total under QEMU/TCG on aarch64-darwin. The earlier "15-minute hang" was caused by the missing `$PIN` env var (see item 3 below), not crypto performance.

2. **softhsm token writability** — softhsm may need write access to the token directory for internal locking. The `contents` approach copies token data as read-only Nix store paths into the initrd. If unlock fails with "read-only" errors in the boot-cycle test, a workaround may be needed (e.g. `tmpfiles` rule to copy token data to a writable tmpfs before cryptsetup runs, or use softhsm's `objectstore.backend = file` without locking).

3. **~~`pin-value=` in PKCS#11 URI~~ RESOLVED — `$PIN` env var required** — systemd's `pkcs11_token_login()` (in `src/shared/pkcs11-util.c:262`) does NOT read `pin-value=` from the PKCS#11 URI. Instead it: (a) tries NULL login, (b) reads the `$PIN` env var via `getenv_steal_erase("PIN")`, (c) falls back to `ask_password_auto()` with `UINT64_MAX` timeout — which hangs forever in non-interactive contexts. **Fix:** Always set `PIN=<pin>` in the environment when calling `systemd-cryptenroll` or `systemd-cryptsetup`. Similarly, `PASSWORD=<passphrase>` provides the existing LUKS passphrase to `systemd-cryptenroll` without interactive prompt.

4. **EC keys incompatible with softhsm for LUKS unlock** — EC P-256/P-384 keys imported via `softhsm2-util` get `Usage: sign, signRecover` but NOT `CKA_DERIVE`. systemd's PKCS#11 unlock needs `CKA_DERIVE` for ECDH key agreement. RSA 2048 keys work because `softhsm2-util` correctly sets `CKA_DECRYPT`. Real YubiKey PIV slots may handle EC differently (the PKCS#11 module controls attribute flags), but for softhsm-based testing, **use RSA 2048**.

5. **systemd version dependency** — `systemd-cryptenroll` PKCS#11 support improved over versions. URI handling (cert vs private key, auto-detection) was fixed in systemd PR #29692. The nixpkgs-unstable version should be recent enough.

6. **Cross-platform package references** — The outer `pkgs` in test files is the *host* platform (e.g. aarch64-darwin). Inside `nodes.machine`, `pkgs` is the *VM* platform (aarch64-linux). Store paths for shared libraries (`.so` files) used inside the VM **must** reference the node's `pkgs`, not the outer `pkgs`. The `testTokenData` derivation is an exception: it builds on the host, but its output is arch-independent data files. **Fix:** Define `softhsmModule` and `softhsmConf` inside the `nodes.machine` let-block where `pkgs` is Linux.

7. **Darwin VM tests work** — `pkgs.testers.runNixOSTest` works on aarch64-darwin via QEMU with TCG (HVF is unavailable inside the nix build sandbox). The full single-boot test completes in ~18s. The boot-cycle test (`initrd-pkcs11-boot`) requires KVM and will be very slow or hang under pure TCG.

### Architecture of the Module Under Test

```
modules/boot/initrd-pkcs11.nix
├── options.boot.initrd.systemd.pkcs11
│   ├── enable              (bool)
│   ├── modules             (attrsOf str: name → /nix/store/.../lib*.so)
│   └── pcscd.plugins       (listOf package, default: [pkgs.ccid])
└── config (when enabled)
    ├── storePaths          [cryptsetup-token-systemd-pkcs11.so, each module .so, pcscd, pluginEnv]
    ├── contents            [/etc/pkcs11/modules/<name>.module per module, /etc/reader.conf]
    ├── sockets.pcscd       [wantedBy cryptsetup-pre.target, DefaultDependencies=false]
    ├── services.pcscd      [after pcscd.socket, before cryptsetup-pre.target, -f -x -c]
    └── availableKernelModules [usbhid, xhci_pci, xhci_hcd, ehci_pci, ehci_hcd]
```