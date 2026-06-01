# Agenix-Rekey Conversion

> Implemented 2026-06-01. Modeled on sini's [den-examples/sini](https://github.com/sini/den-examples) agenix-rekey pattern.

## Architecture

```
.secrets/
  pub/master.key                          # master age public key (SSH-derived)
  hosts/<name>/
    ssh_host_ed25519_key.pub              # host age public key (reference only, deprecated)
    *.age                                 # source secrets (encrypted to master + host)
    generated/                            # agenix-rekey generated secrets
      boot-host-key.age                   # initrd SSH key (ssh-key generator)
      boot-host-key.pub
    rekeyed/                              # agenix-rekey rekeyed copies
      <sha256>-<name>.age                 # encrypted to host SSH key only

modules/den/
  batteries/agenix.nix                    # battery: identityPaths, rekey config, imports
  schema/host.nix                         # host schema: secretPath, public_key
  aspects/
    secrets/
      agenix.nix                          # secretRequests → age.secrets mapper (rekeyFile)
      _generators.nix                     # ssh-key, passphrase, hex, base64 generators
    core/
      remote-unlock.nix                   # boot-host-key via age-secrets quirk
      secrets-collector.nix               # merges age-secrets quirk into NixOS config
    quirks/secrets.nix                    # age-secrets quirk declaration
    disk/impermanence.nix                 # persist.files for SSH host keys
  secrets-config.nix                      # den.secretsConfig.masterIdentities
```

## Key Decisions

### Host identity: SSH key, not age-converted
`age` (Go) supports SSH ed25519 keys for BOTH `-e -r` (encryption) and `-d -i` (decryption). We use the SSH public key directly as the encryption recipient. The ssh-to-age tool produces INCOMPATIBLE age keys — encrypting with ssh-to-age output and decrypting with age -d -i fails.

**Correct flow:**
```bash
age -e -r "$(cat runtime_host_key.pub)" secret   # encrypt with SSH pubkey
age -d -i /persist/etc/ssh/ssh_host_ed25519_key  # decrypt with SSH privkey
```

**Do NOT use ssh-to-age in the encryption path.** It's used for sops-nix consistency but breaks agenix's SSH key handling.

### hostPubkey from runtime_host_key.pub
The battery reads `builtins.readFile host.public_key` for `age.rekey.hostPubkey`. `host.public_key` defaults to `modules/den/hosts/<name>/runtime_host_key.pub` — the SSH public key. agenix-rekey passes this to `age -e -r` during rekeying.

### rekeyFile, not file, in the mapper
The `secretRequests` mapper must set `age.secrets.<name>.rekeyFile` (not `file`). Setting `file` directly blocks agenix-rekey's auto-set of the rekeyed file path (from `localStorageDir + hash`). With `rekeyFile`, agenix-rekey reads the original, rekeys it, and sets `file` to the rekeyed output.

### Hash formula for rekeyed filenames
```
sha256(sha256(hostPubkey) + sha256(rekeyFile))[:32]
```
`hostPubkey` is read via `builtins.readFile` (includes trailing newline). The rekey script's `age_rekey_hash` function must match exactly.

## Boot Key (initrd SSH)

Declared as `age-secrets` quirk in `remote-unlock.nix`:
```nix
age.secrets.boot-host-key = {
    path = "/boot/boot_host_key";          # ESP, always available
    symlink = false;                       # ESP is FAT32, no symlinks
    generator.script = "ssh-key";          # auto-generates once
};
```

Generated once by the rekey script, then committed. The ESP is never rolled back, so no persist.files needed. `symlink = false` because agenix can't symlink over an existing file on FAT32.

**On fresh install**: the boot key doesn't exist on ESP. Hoopsnake fails (no remote unlock on first boot). System activates → generator creates key → subsequent boots work.

## Current State

### Working
- `nh os switch` activates cleanly (no agenix errors)
- All gocryptfs secrets decrypt on hvn-hyp1
- Boot key placed at `/boot/boot_host_key`
- Builder host: agenix infrastructure in place, secrets still use sops-nix (coexisting)

### Pending
- [ ] **Builder migration**: switch builder's secrets from sops-nix to agenix
- [ ] **Known_hosts update**: boot key changed — update Hoopsnake entry in `modules/den/hosts/hvn-hyp1/known_hosts`
- [ ] **Reboot test**: confirm initrd SSH works with new boot key
- [ ] **Remove sops-nix**: after builder migration complete
- [ ] **Clean sops.key fallback** from rekey.sh (all originals should be re-encrypted with SSH master key)
- [ ] **Audit rekey.sh**: split generate from rekey, add conditional boot key generation (only if missing)
- [ ] **Nas1 host**: if/when that host exists, add agenix secrets
- [ ] **secretRequests → age-secrets quirk**: migrate remaining secrets (crowdsec, passwords) from mapper to quirk pipe

### Cleanup
- Remove `sops-nix` input, `modules/den/aspects/secrets/sops.nix`, `modules/flake/sops.nix`, `.sops.yaml`, `sops.key`
- Archive `scripts/migrate-secrets.sh` (one-time use)
- Remove `.secrets/hosts/<name>/ssh_host_ed25519_key.pub` files (age keys, replaced by runtime_host_key.pub SSH keys)
- Remove `.secrets/pub/master.key` reference file (keep for documentation?)

## Lessons

1. **Test crypto round-trip before building infrastructure.** `echo test | age -e -r <recipient> | age -d -i <identity>` is 10 seconds.
2. **ssh-to-age ≠ age's SSH parser.** They derive different age keys from the same SSH keypair. Only use ssh-to-age if the tool consuming the output also uses ssh-to-age for decryption.
3. **rekeyFile, not file.** Let agenix-rekey manage the rekeyed file path. Setting `file` directly blocks it.
4. **The hash algorithm is not sha256sum.** It's `sha256(sha256(hostPubkey) + sha256(rekeyFile))`.
5. **symlink = false for ESP paths.** FAT32 doesn't support symlinks. agenix copies instead.
