## 1. Foundation — Den input and activation (zakuciael pattern)

- [x] 1.1 Add `den` as a flake input
- [x] 1.2 Create `nix/den.nix` — pipeline, manual output bridge
- [x] 1.3 Hydrate `modules/namespace.nix` — `dlab` namespace

## 2. Aspect directory structure + den.schema.host

- [x] 2.1 Create `modules/aspects/default.nix` — default includes
- [x] 2.2 Create `modules/aspects/nix/default.nix` — den.default.nixos for nix config
- [x] 2.3 Create `modules/schema/host.nix` — den.schema.host (zfs, networking interfaces)
- [x] 2.4 Create `modules/aspects/deployment/default.nix` — config.deployment NixOS option
- [x] 2.5 Create `modules/aspects/secrets/sops.nix` — secretRequests option + SOPS provider

## 3. Host declarations (den.hosts + host aspects)

- [x] 3.1 Declare testvm, hvn-hyp1, builder via den.hosts with per-host metadata
- [x] 3.2 Set per-host config.deployment values in host aspects

## 4. Profile conversion to den aspects

- [x] 4.1 Convert `time` profile — `den.aspects."dlab/profile/time"` (static)
- [x] 4.2 Convert `facter` profile — `den.aspects."dlab/profile/facter"` (static)
- [x] 4.3 Convert `hypervisor` profile — `den.aspects."dlab/profile/hypervisor"` (static)
- [x] 4.4 Convert `networking` profile — `den.aspects."dlab/profile/networking"` (parametric, reads `host.networking.interfaces`)
- [x] 4.5 Convert `disks` profile — `den.aspects."dlab/profile/disks"` (parametric, reads `host.zfs.*`)
- [x] 4.6 Convert `impermanence` profile — `den.aspects."dlab/profile/impermanence"` (parametric, reads `host.zfs.*`)
- [x] 4.7 Convert `crowdsec` service — `den.aspects."dlab/services/crowdsec"` (static, uses secretRequests)
- [x] 4.8 Convert `remote-unlock` profile — `den.aspects."dlab/profile/remote-unlock"` (parametric, reads host data). **Fix**: hoopsnake module uses `importApply` — import must be at top level of nixos module, not inside mkIf. Now working: `boot.initrd.network.hoopsnake.enable = true` on hvn-hyp1.
- [x] 4.9 Convert `server` profile — `den.aspects."dlab/profile/server"` (static, aggregates crowdsec + remote-unlock)

## 5. deploy-rs adaptation

- [x] 5.1 Adapt `modules/flake/deploy-rs.nix` — read from `config.deployment`
- [x] 6.1 Remove `modules/lib/mk-os.nix`
- [x] 6.2 Remove `modules/flake/hosts.nix`
- [x] 6.3 Remove/disable class modules (nixos-class.nix, darwin-class.nix)
- [x] 6.4 Remove old profile files after conversion
- [x] 6.5 Final verification — all 3 Linux hosts evaluate, deploy-rs shows correct nodes, secretRequests option present
