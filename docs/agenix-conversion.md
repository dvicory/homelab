# Agenix-Rekey Conversion

> Implemented 2026-06-01. Modeled on sini's [den-examples/sini](https://github.com/sini/den-examples) agenix-rekey pattern.

## Architecture

```
.secrets/
  pub/master.key                          # master age public key (SSH-derived, committed)
  priv/master.age                         # master age private key (gitignored, at ~/.config/agenix/master.age)
  hosts/<name>/
    runtime_host_key.pub                  # host SSH public key (committed, used for rekeying)
    *.age                                 # source secrets (encrypted to master + host)
    generated/                            # agenix-rekey generated secrets
      boot-host-key.age                   # initrd SSH key (ssh-key generator, encrypted, committed)
      boot-host-key.pub                   # public key (plain, committed)
    rekeyed/                              # agenix-rekey rekeyed copies
      <sha256>-<name>.age                 # encrypted to host SSH key only
  shared/
    *.age                                 # cross-host secrets
    rekeyed/

modules/den/
  batteries/agenix.nix                    # battery: inputs, imports, identityPaths, rekey, HM, activation
  schema/host.nix                         # host schema: secretPath, public_key
  aspects/
    secrets/
      agenix.nix                          # secretRequests → age.secrets mapper (rekeyFile)
      _generators.nix                     # ssh-key, passphrase, hex, base64 generators
    core/
      remote-unlock.nix                   # boot-host-key via age-secrets quirk
      secrets-collector.nix               # merges age-secrets quirk → NixOS config
    quirks/secrets.nix                    # age-secrets quirk declaration
    disk/impermanence.nix                 # persist.files for SSH host keys
  secrets-config.nix                      # den.secretsConfig.masterIdentities (fleet scope)

scripts/
  generate-secrets.sh                     # idempotent boot key generation per host
  rekey.sh                                # rekey all secrets for all hosts
  provision-keys.sh                       # generate + rekey + git commit pipeline
  install.sh                              # nixos-anywhere helper (decrypt + stage boot key)
  migrate-secrets.sh                      # one-time sops→agenix migration (archive)
```

## Key Decisions

### Host identity: SSH key, not age-converted
`age` (Go) supports SSH ed25519 keys for BOTH `-e -r` (encryption) and `-d -i` (decryption). We use the SSH public key directly as the encryption recipient. The ssh-to-age tool produces INCOMPATIBLE age keys — encrypting with ssh-to-age output and decrypting with age -d -i fails.

**Correct flow:**
```bash
age -e -r "$(cat runtime_host_key.pub)" secret   # encrypt with SSH pubkey
age -d -i /persist/etc/ssh/ssh_host_ed25519_key  # decrypt with SSH privkey
```

### hostPubkey from runtime_host_key.pub
The battery reads `builtins.readFile host.public_key` for `age.rekey.hostPubkey`. `host.public_key` defaults to `.secrets/hosts/<name>/runtime_host_key.pub`. agenix-rekey passes this to `age -e -r` during rekeying.

### rekeyFile, not file, in the mapper
The `secretRequests` mapper must set `age.secrets.<name>.rekeyFile` (not `file`). Setting `file` directly blocks agenix-rekey's auto-set of the rekeyed file path (from `localStorageDir + hash`). With `rekeyFile`, agenix-rekey reads the original, rekeys it, and sets `file` to the rekeyed output.

### Hash formula for rekeyed filenames
```
sha256(sha256(hostPubkey) + sha256(rekeyFile))[:32]
```
`hostPubkey` is read via `builtins.readFile` (includes trailing newline). Both `rekey.sh` and agenix-rekey's Nix implementation must match.

### Master identity: env var with file fallback
```nix
masterIdentities =
  let envIdentity = builtins.getEnv "AGENIX_MASTER_IDENTITY";
  in lib.optional (envIdentity != "") envIdentity
     ++ [ (self + "/.secrets/priv/master.age") ];
```
- `AGENIX_MASTER_IDENTITY` takes precedence (set to `~/.config/agenix/master.age` for rekey operations)
- Falls back to `.secrets/priv/master.age` (gitignored, user creates manually)
- Both point to the same PRIVATE age key derived from SSH ed25519

### Self-contained battery
The battery declares its own flake inputs (`agenix`, `agenix-rekey`) and imports `agenix-rekey.flakeModule`. No other module needs to know about agenix inputs. Input declarations removed from `modules/meta/inputs.nix`.

### Impermanence-aware identityPaths
```nix
let hasImpermanence = host.hasAspect den.aspects.disk.impermanence;
    persistPrefix = lib.optionalString hasImpermanence "/persist";
in [ "${persistPrefix}/etc/ssh/ssh_host_ed25519_key" ];
```
On non-impermanent hosts, the path is just `/etc/ssh/ssh_host_ed25519_key`.

## Boot Key (initrd SSH)

Declared as `age-secrets` quirk in `remote-unlock.nix`:
```nix
age.secrets.boot-host-key = {
    path = "/boot/boot_host_key";          # ESP, always available
    symlink = false;                       # ESP is FAT32, no symlinks
    generator.script = "ssh-key";          # auto-generates once
};
```

Generated once by `scripts/generate-secrets.sh <hostname>` (idempotent), then committed. Always encrypted to the host's SSH public key. The ESP is never rolled back, so no persist.files needed.

**On fresh install**: the boot key doesn't exist on ESP. Hoopsnake fails (no remote unlock on first boot). Solution: run `./scripts/provision-keys.sh <hostname>` BEFORE first activation, or accept one failure on first boot — subsequent boots work after agenix places the key.

## Scripts and Lifecycle

### New host setup
```bash
# 1. First boot (sshd auto-generates SSH host keys)
# 2. Copy the pubkey
scp root@<host>:/persist/etc/ssh/ssh_host_ed25519_key.pub \
    .secrets/hosts/<hostname>/runtime_host_key.pub

# 3. Generate boot key and rekey all secrets
./scripts/provision-keys.sh <hostname>
# 4. Push
git push
# 5. Apply
nh os switch <hostname>
# 6. Reboot — verify initrd SSH works
ssh -p 2222 root@<host>
```

### Day-to-day secret changes
```bash
# Edit a secret
age -e -r "$(cat .secrets/hosts/<name>/runtime_host_key.pub)" \
       -r "$(cat .secrets/pub/master.key)" > .secrets/hosts/<name>/new-secret.age

# Rekey
./scripts/rekey.sh

# Commit
git add -A .secrets/ && git commit -m "secrets: rekey"
git push
```

### Adding a new host
```bash
# 1. Create host directory
mkdir -p .secrets/hosts/<hostname>/generated .secrets/hosts/<hostname>/rekeyed

# 2. Copy pubkey from host (after first boot)
scp root@<host>:/persist/etc/ssh/ssh_host_ed25519_key.pub \
    .secrets/hosts/<hostname>/runtime_host_key.pub

# 3. Encrypt host-specific secrets
age -e -r "$(cat .secrets/hosts/<hostname>/runtime_host_key.pub)" \
       -r "$(cat .secrets/pub/master.key)" > .secrets/hosts/<hostname>/secret.age

# 4. Generate + rekey + commit
./scripts/provision-keys.sh <hostname>
git push
```

## Current State

### Working
- `nh os switch` activates cleanly (no agenix errors)
- All gocryptfs secrets decrypt on hvn-hyp1
- Boot key placed at `/boot/boot_host_key`
- Battery is self-contained with HM support
- Scripts: generate, rekey, provision, install

### Pending
- [ ] **Known_hosts update**: boot key changed — update Hoopsnake entry in `modules/den/hosts/hvn-hyp1/known_hosts`
- [ ] **Reboot test**: confirm initrd SSH works with new boot key
- [ ] **Builder migration**: switch builder's secrets from sops-nix to agenix
- [ ] **Remove sops-nix**: after builder migration complete
- [ ] **Nas1 host**: if/when that host exists, add agenix secrets
- [ ] **secretRequests → age-secrets quirk**: migrate remaining secrets (crowdsec, passwords) from mapper to quirk pipe

### Cleanup
- Remove `sops-nix` input, `sops.key`, `.sops.yaml`
- Archive `scripts/migrate-secrets.sh` (one-time use, already done)
- Add devshell with `age` + `age-plugin-yubikey` (optional future)

## Lessons

1. **Test crypto round-trip before building infrastructure.** `echo test | age -e -r <recipient> | age -d -i <identity>` is 10 seconds.
2. **ssh-to-age ≠ age's SSH parser.** They derive different age keys from the same SSH keypair.
3. **rekeyFile, not file.** Let agenix-rekey manage the rekeyed file path.
4. **The hash algorithm is not sha256sum.** It's `sha256(sha256(hostPubkey) + sha256(rekeyFile))`.
5. **symlink = false for ESP paths.** FAT32 doesn't support symlinks.
6. **Both master identity approaches coexist.** Env var for rekey scripts, static path for agenix-rekey CLI.
