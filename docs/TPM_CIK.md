# TPM + CIK pre-boot authentication (UEFI64)

The PBA derives the Opal password from two independent secrets, so neither
factor alone unlocks the drive:

    Opal password = SHA-256("cryptozero-v1:" || TPM_secret || CIK)   (64 hex chars)

* **TPM secret** – 32 random bytes sealed in the TPM at persistent handle
  `CZ_TPM_HANDLE`, bound to PCRs `CZ_PCRS`, and (optionally) a PIN enforced by
  the TPM itself (`policyauthvalue`, so the TPM's dictionary-attack lockout
  rate-limits guesses).
* **CIK** – 32 random bytes in a raw GPT partition named `CIK` on the microSD
  (8-byte magic `CZCIK001` + key). No filesystem.

The sedutil hashing (PBKDF2-SHA512, salted with the drive serial) is applied on
top, exactly as for a typed passphrase. If either factor is missing or the TPM
refuses, `cz-unlock` falls back to the stock passphrase prompt.

Files: `images/buildroot/64bit/overlay/{etc/cryptozero.conf,usr/lib/cryptozero/cz-lib.sh,usr/sbin/cz-unlock,usr/sbin/cz-enroll}`,
`linuxpba --key-stdin` (LinuxPBA/LinuxPBA.cpp).

## Secure Boot: self-signed UKI

The PBA is one **signed Unified Kernel Image** (`EFI/BOOT/BOOTX64.EFI`:
kernel + initrd + cmdline, systemd-stub) built by `images/buildUEFI64` via
`images/mkuki`. You sign it with your own key; the firmware trusts it because
you enrolled your cert in its `db`. Syslinux is no longer used for UEFI.
A public code-signing CA (DigiCert, Azure Trusted Signing) is *not* a drop-in:
firmware does not trust those roots.

The TPM secret is bound to **PCR 7** (Secure Boot state/keys) and **PCR 11**
(UKI contents). With Secure Boot on, a different kernel/initrd/cmdline or an
unsigned loader cannot unseal it. The stub ignores command-line overrides
when Secure Boot is on.

The UEFI64 image is also the enrollment/rescue stick: boot it from USB and, if
the TPM has nothing sealed, it drops to a shell (enrollment mode). Same binary
=> same PCR 7/11 as when it runs from the shadow MBR.

### 1. Keys (once, keep them offline)

    sudo apt install openssl efitools sbsigntool systemd-boot-efi systemd-ukify
    images/secureboot/gen-keys.sh ~/.cryptozero-secureboot

### 2. Enroll in the firmware

Easiest: firmware setup -> Secure Boot -> Custom/User mode -> append/enroll a
`db` key from file, using `db.cer` on a FAT USB stick (keep the existing
Microsoft entries so option ROMs keep working). Or from Linux with the
firmware in Setup Mode: `efi-updatevar -f db.auth db` (needs KEK/PK enrolled
first; `PK.auth`/`KEK.auth` are generated). Leave Secure Boot **on**.

### 3. Build and sign

    export SB_KEY=~/.cryptozero-secureboot/db.key SB_CERT=~/.cryptozero-secureboot/db.crt
    cd images && ./getresources && ./buildpbaroot && ./buildUEFI64

Needs `ukify` (systemd >= 253), `systemd-boot-efi`, `sbsigntool`. The
signing step is the only place the key is used; for releases run it on a
machine or CI runner that holds the key (or use PKCS#11/HSM with `sbsign`).
Each user should ideally sign their own build.

### CI/CD (GitHub Actions)

* `.github/workflows/ci.yml` (pushes to master, PRs): builds `sedutil-cli`
  and `linuxpba` plus `make dist`, shellchecks the PBA scripts, runs
  `tests/tpm/run.sh` against a software TPM, and builds and signs a test UKI
  with throwaway keys.
* `.github/workflows/release.yml` (tags `v*`, or run it manually): builds the
  binaries and the Buildroot kernel/rootfs (several hours on hosted
  runners), then builds and signs the UEFI64 image and opens a **draft**
  release with the binaries, `UEFI64-*.img.gz`, `BOOTX64.EFI`,
  `cryptozero-db.cer` (the cert users enroll) and `SHA256SUMS`.

One-time setup: Settings -> Environments -> create `release`, add required
reviewers and limit deployments to tags `v*`, then add the secrets
`SB_DB_KEY` (contents of `db.key`) and `SB_DB_CERT` (contents of `db.crt`).
Anyone who can get a workflow to run in that environment can use the key,
which is why the reviewers matter. A manual run with `unsigned` checked
needs no key (Secure Boot off only). Release: `git tag v1.16.0 && git push
origin v1.16.0`, approve the deployment, review and publish the draft.

## Security limits

1. The CIK and PIN still matter: with Secure Boot on the TPM factor is real,
   but if the CIK card stays in the laptop a thief has it, leaving PIN +
   TPM lockout. Remove the card when unattended.
2. **PCR 7 changes** when `db`/`dbx`/Secure Boot state change (including some
   firmware updates); **PCR 11 changes** with every rebuilt UKI. After either,
   unsealing fails and the PBA falls back to the passphrase prompt: type the
   `opal_password` from your escrow file and boot. To reseal, evict the old
   object from the OS (`tpm2_evictcontrol -C o -c 0x81010020`), boot the new
   USB image (an empty handle gives the enrollment shell) and run `cz-enroll`
   with the escrow `opal_password` as the current password. A rebuilt PBA
   must also be re-loaded into the shadow MBR (`cz-enroll --pba`).
3. **Losing the TPM secret or the CIK loses the data.** Use `--escrow`, keep
   it offline, and consider a second Opal user as break-glass.
4. Opal passwords are passed on `sedutil-cli` command lines (visible in `ps`
   inside the PBA environment only).
5. Whoever holds `db.key` can sign anything your firmware will boot.
6. The PBA image keeps upstream's console root login (reached via the
   `debug` passphrase). `cz-unlock` extends the last policy PCR right after
   its unseal attempt and before any fallback, so that shell can no longer
   satisfy the TPM policy. The enrollment shell only appears when the TPM
   reports the handle empty, i.e. there is nothing to unseal.
7. Sleep (S3) is unsupported by this sedutil fork.

## Status: partially tested

Verified on a dev machine: key generation (`gen-keys.sh`), UKI build and
signing (`mkuki`, with a dummy kernel), `sbverify`, the CIK hex/partition
parsing and key derivation under `dash`, the C++ compiles, and the TPM
logic against a software TPM (swtpm, tpm2-tools 5.6): sealing, PIN/no-PIN
policy unseal, wrong-PIN refusal, no bare-password bypass, the post-unseal
PCR lock, re-enrollment over an existing handle (`tests/tpm/run.sh`, also
run in CI).
**Not verified:** the release workflow end to end, a real Buildroot build (the bump 2019.02.6 -> 2022.02.12 in
`images/conf` and the old 4.14 kernel config via `olddefconfig`), that the
kernel boots as a UKI under a given firmware, tpm2-tools older than 5.6,
busybox applets (`od`, `sha256sum`, `stty`), a real TPM's PCR 7/11 values
across USB vs shadow-MBR boots, systemd-stub booting the old 4.14 kernel,
and anything on a real SED. The 32-bit/BIOS images are untouched. Test on expendable data.

## Setup

1. Prepare the microSD on a normal machine (destroys its contents):

       sgdisk --zap-all /dev/sdX && sgdisk -n 1:0:+1M -c 1:CIK /dev/sdX

2. Review `etc/cryptozero.conf`, build as above, write
   `images/UEFI64/UEFI64-*.img.gz` (gunzipped) to a USB stick.
3. Boot the USB stick with Secure Boot on and the microSD inserted. The TPM is
   empty, so you get a shell:

       cz-enroll /dev/nvme0 /dev/mmcblk0p1 --pba /dev/sda --escrow /tmp/cz-escrow.txt

   (`/dev/sda` = the boot USB; copy the escrow file off to offline storage
   before powering down.) It seals the secrets, writes the CIK, **verifies
   the TPM unseal and CIK read-back before touching the drive's Opal
   configuration**, then programs Opal and loads the PBA into the shadow MBR.
4. Power off, remove the USB stick, boot: the PBA asks for the PIN, reads the
   CIK, unseals, unlocks and reboots into the OS.
