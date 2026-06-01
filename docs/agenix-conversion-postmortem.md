# Agenix Conversion Postmortem

## What went wrong

All `age.secrets` failed to decrypt at activation with "no identity matched any of the recipients." The root cause: **`ssh-to-age` and `age` (Go) derive incompatible age identity keys from the same SSH ed25519 key pair.**

The migration encrypted every `.age` file using `ssh-to-age`-converted host public keys:

```bash
# What we did (wrong):
ssh-to-age < runtime_host_key.pub    # → age1rxwhh...
rage -e -r age1rxwhh... secret       # encrypt with age-converted key
age -d -i runtime_host_key           # FAILS: age derives different key
```

`age` (Go) derives a different age key from the same SSH private key. Files encrypted with the `ssh-to-age`-converted recipient can never be decrypted by `age -d -i` using the SSH key. The two tools produce different age identities from identical SSH key material.

## Correct approach

Pass the SSH public key directly to `age` — it handles SSH keys natively for both encryption and decryption:

```bash
# What works:
age -e -r "$(cat runtime_host_key.pub)" secret   # encrypt with SSH pubkey
age -d -i runtime_host_key                       # decrypt with SSH privkey
```

No `ssh-to-age` anywhere in the encryption path. The SSH key becomes the recipient directly.

## Timeline

| Stage | Duration | Error |
|---|---|---|
| Initial migration from sops-nix | ~2h | Built battery, schema, quirks, generators |
| First deploy failure | ~1h | "no identity matched" — all 4 secrets |
| Digest calculation bug | ~1h | Hashed file content instead of `sha256(sha256(hostPubkey) + sha256(rekeyFile))` |
| `.age` identity workaround | ~2h | Built activation script, `ssh-to-age` conversion — it worked but was wrong |
| GitHub code search | ~30m | No public repos use `.age` identity conversion — should have been the clue |
| sini fork test | ~30m | Same failure — fork doesn't change identity handling |
| `age` v1.2.1 bisect | ~30m | Same failure — not a version regression |
| **Root cause found** | ~10m | Tested `age -e -r "$(cat pubkey)"` vs `age -e -r $(ssh-to-age < pubkey)` |

**5 hours** spent on a bug that a 30-second round-trip test would have caught.

## Why this was hard to find

1. **Both paths look identical**: `ssh-to-age` and `age`'s internal SSH parser both produce age-format keys (`age1...`). There's no visible difference in the output format — only the key value differs.
2. **sops-nix hides the issue**: sops-nix uses `ssh-to-age` for BOTH encryption and decryption, so it's self-consistent. Moving to agenix (which uses `age`'s native SSH parser for decryption) broke the symmetry.
3. **Other Nix configs don't expose it**: Most public agenix configs use the default `identityPaths` (SSH key paths) and rely on `age`'s bare SSH key handling end-to-end. Our `ssh-to-age` conversion was the unique broken link.
4. **Platform testing wasted time**: I tested `age` across macOS/Linux, multiple nixpkgs commits, and multiple version bisects — all showed the same failure because the tool mismatch was consistent everywhere.

## What I would change

1. **Test the round-trip before building anything**: `echo test | age -e -r <recipient> | age -d -i <identity>`. This 30-second test on any key proves the encryption/decryption chain works. I ran it a dozen times — always with `ssh-to-age`-converted keys, never with raw SSH keys.

2. **Question `ssh-to-age`'s role earlier**: sops-nix uses `ssh-to-age` internally both ways; agenix does not. When switching secret management tools, any external key derivation tool is a potential failure point.

3. **Trust the conflicting signals**: Every public Nix config pointed identityPaths at raw SSH keys. No one used `.age` identity conversion. My "workaround" of creating an `.age` identity file was solving a problem that shouldn't have existed.

4. **Isolate crypto from config**: The `rekeyFile`/`file` distinction, the hash algorithm, the `mkDefault` priority — these were all secondary issues that masked the primary crypto failure. A pure `age -d -i /persist/etc/ssh/ssh_host_ed25519_key <rekeyed-file>` test on the host would have cut through all of it.

## Current state

- **Host key decryption**: `age -d -i /persist/etc/ssh/ssh_host_ed25519_key` works for files encrypted with `age -e -r "$(cat runtime_host_key.pub)"`.
- **`identityPaths`**: Points at the raw SSH private key (`/persist/etc/ssh/ssh_host_ed25519_key`). No `.age` conversion.
- **`hostPubkey`**: Reads SSH public key from `modules/den/hosts/<name>/runtime_host_key.pub`. No `ssh-to-age`.
- **`rekeyFile`**: The mapper sets `rekeyFile` (not `file`), letting agenix-rekey compute the rekeyed path with correct hash prefixes.
- **Activation**: All gocryptfs secrets decrypt. Boot key symlink fixed. No errors at activation.
