# ACL: Unified Access Control

## Overview

Groups are the single primitive for access control. They can contain users and
other groups (transitive membership, matching Kanidm's native model). Groups are
defined once in a shared top-level `groups` option and consumed by multiple
provisioners — Kanidm OAuth2, Unix system accounts, Kubernetes RBAC.

Access is environment-scoped: `fleet.user-access` binds groups to environments.
Host login is gate-controlled: `environments.<env>.system-access-groups` and
`hosts.<host>.system-access-groups` declare which system-scoped groups grant
Unix account creation. Both lists are merged at resolution time.

## Three-Level Resolution

```
groups                                    <- shared definitions (posix, oauth-grant, user-role labels)
  |
fleet.user-access.by-environment          <- group grants per environment
  |
environments.<env>.system-access-groups   <- env-wide baseline login gates
  + hosts.<host>.system-access-groups     <- host-specific login gates (merged with env)
  |
resolved user                             <- enable + systemGroups derived from above
```

## Group Schema

```nix
den.groups.<name> = {
  labels      = [ "posix" | "oauth-grant" | "user-role" ];
  gid         = <int>;  # required for posix groups
  description = "Human-readable purpose";
  members     = [ "other-group" ... ];  # group-to-group transitive membership
};
```

### Labels

| Label | Purpose | Consumed by |
|-------|---------|-------------|
| `posix` | Unix system groups (requires `gid`) | NixOS `extraGroups` |
| `oauth-grant` | OAuth2/OIDC access grants | Kanidm provisioner |
| `user-role` | Access control label only | Access policies |

### Example Groups

```nix
den.groups = {
  # --- System login gates ---
  admins = {
    labels = [ "posix" ];
    gid = 949;
    description = "Full administrative access";
  };

  system-access = {
    labels = [ "posix" ];
    gid = 950;
    description = "Login access to all hosts";
  };

  server-access = {
    labels = [ "posix" ];
    gid = 951;
    description = "Login access to servers";
    members = [ "system-access" ];  # server-access implies system-access
  };

  # --- Service access (future: oauth-grant for Kanidm) ---
  # "grafana.access" = {
  #   labels = [ "oauth-grant" ];
  #   description = "Grafana login";
  #   members = [ "users" ];
  # };
};
```

## Access Grants

`fleet.user-access.by-environment.<env>.groups` lists which groups grant access
to all hosts in an environment. `fleet.user-access.by-host.<host>.groups` grants
access to a specific host.

```nix
fleet.user-access = {
  by-environment = {
    prod.groups = [ "system-access" ];
    dev.groups  = [ "system-access" ];
  };
  # by-host = { special-host.groups = [ "admin-access" ]; };
};
```

## Login Gates

Login gates are defined at two levels and merged at resolution time:

- **Environment-level**: `environments.<env>.system-access-groups` — baseline
  gates for all hosts in the environment.
- **Host-level**: `hosts.<host>.system-access-groups` — additional gates
  specific to a host.

The effective gate list is:
`unique(env.system-access-groups ++ host.system-access-groups)`.

```nix
# Environment baseline
den.environments.prod.system-access-groups = [ "system-access" ];
den.environments.dev.system-access-groups  = [ "system-access" ];

# Host-specific
den.hosts.x86_64-linux.hvn-hyp1.system-access-groups = [ "system-access" ];
```

## Resolution Algorithm

For a given host `H` in environment `E`:

1. Read `fleet.user-access` grants for the environment and host.
2. Compute `effectiveGate = unique(E.system-access-groups ++ H.system-access-groups)`.
3. Compute `allGrants = unique(envGrant ++ hostGrant ++ hostGate)`.
4. `accessGroups = if effectiveGate == [] then allGrants else filter(in effectiveGate, allGrants)`.
5. For each user in registry: if `user.groups ∩ accessGroups ≠ ∅` → resolve onto host.
6. ACL scope engine expands groups transitively, partitions by scope:
   - `systemGroups` → NixOS `extraGroups`
   - `kanidmGroups` → Kanidm OIDC claims
7. Login check: `systemGroups ∩ effectiveGate ≠ ∅` → `enable = true`.

### Example: daniel on hvn-hyp1

```
daniel.groups           = ["admins", "system-access"]
fleet.user-access.prod  = ["system-access"]
env.system-access-groups = ["system-access"]
host.system-access-groups = ["system-access"]

effectiveGate = ["system-access"]
allGrants     = ["system-access"]
accessGroups  = ["system-access"]

daniel.groups ∩ accessGroups = ["system-access"] ≠ [] → resolved

ACL: systemGroups = ["admins", "system-access"] (both posix-labeled)
     ∩ effectiveGate = ["system-access"] → enable = true
```

## User Schema

```nix
den.users.registry.<name> = {
  identity = {
    displayName = "Name";
    email = "email@example.com";
    sshKeys = [ { tag = "laptop"; key = "ssh-ed25519 AAAA..."; } ];
    gpgKey = "0x...";
  };
  system = {
    uid = 1000;
    gid = 1000;
    linger = false;
    enableUnixAccount = true;
  };
  groups = [ "admins" "system-access" ];
};
```

- `identity` — single source of truth for user identity
- `system` — Unix account configuration
- `groups` — direct group memberships (expanded transitively by ACL)
- `classes = []` — identity-only user (no Unix account, no home-manager)
