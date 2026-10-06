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

## Read this first: security limits

1. **Secure Boot must be off for this fork's UEFI PBA** (unsigned syslinux).
   PCR 7 then only says "Secure Boot is off", and PCR 4 only identifies the
   syslinux binary – the kernel and initrd are **not** measured. Someone who
   boots the same `syslinux.efi` with their own kernel/initrd (from USB, with
   the shadow MBR) can unseal the TPM secret. The **CIK and the PIN** are what
   actually protect you here. A signed/measured PBA (shim or UKI + Secure
   Boot, PCR 7/11) is the real fix and is not implemented.
2. If the CIK card stays in the laptop, a thief has the CIK; only the PIN and
   TPM lockout remain. Remove the card when unattended, or keep `CZ_USE_PIN=1`.
3. **Losing the TPM secret or the CIK loses the data.** Use `--escrow`, keep
   it offline, and consider a second Opal user as break-glass.
4. Opal passwords are passed on `sedutil-cli` command lines (visible in `ps`
   inside the PBA/rescue environment only).
5. Sleep (S3) is unsupported by this sedutil fork; unlocked drives stay
   unlocked across suspend on some firmware.

## Status: not built or run

Only the shell logic (hex/CIK/KDF round trip) was exercised, under `dash`
on a dev machine. **Nothing was built into an image or tried against a TPM or
SED.** Specifically unverified: the Buildroot bump 2019.02.6 -> 2022.02.12
(`images/conf`, needed for tpm2-tools >= 4; the old 4.14 kernel config goes
through `olddefconfig`), tpm2-tools flag spellings, busybox applet
availability (`od`, `sha256sum`, `stty`), and the 32-bit image (untouched,
still stock passphrase PBA and may need the same Buildroot fixes). Test on
expendable data first.

## Setup

1. Prepare the microSD on a normal machine (destroys its contents):

       sgdisk --zap-all /dev/sdX && sgdisk -n 1:0:+1M -c 1:CIK /dev/sdX

2. Review `etc/cryptozero.conf` (PCRs, PIN on/off). Build: `images/getresources`,
   `buildpbaroot`, `buildUEFI64`, `buildrescue Rescue64` as usual.
3. Boot **Rescue64** from USB with the microSD inserted (enrollment must run
   in the PBA's boot chain so PCR 4 matches; confirm PCRs after a PBA test
   boot, see below), then:

       gunzip /usr/sedutil/UEFI64-*.img.gz
       cz-enroll /dev/nvme0 /dev/mmcblk0p1 --pba /usr/sedutil/UEFI64-*.img --escrow /media/usb/cz-escrow.txt

   It seals and writes the secrets and **verifies the round trip before
   touching the drive's Opal configuration**.
4. Power off, boot normally: the PBA asks for the PIN, reads the CIK, unseals,
   unlocks and reboots into the OS.

If the unseal fails after a good enrollment, the Rescue and PBA boot chains
differ in a measured PCR. Drop PCR(s) from `CZ_PCRS` (rebuild, re-enroll) and
accept the weaker binding, or move to a signed PBA.
