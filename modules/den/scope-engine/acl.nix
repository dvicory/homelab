# ACL scope graph: group membership + system-access gating.
#
# Three-level resolution (groups -> environments -> hosts), evaluated via
# gen-scope (HOAG). A user's POSIX/kanidm group membership is the transitive
# closure of their registry groups over the group-membership graph (M edges),
# partitioned by group scope.
#
# Evaluated attributes:
#   effectiveGates — merged environment and host access capabilities
#   resolveUser    — paramAttr (hostId) (userName) → access record
#                    { enable, systemGroups, kanidmGroups, allGroups, ... }
{
  inputs,
  lib,
  config,
  den,
  ...
}:
let
  inherit (lib) mkOption types;

  engine = inputs.scope-engine.lib;

  flatHosts = lib.foldl' (acc: system: acc // (den.hosts.${system} or { })) { } (
    builtins.attrNames (den.hosts or { })
  );

  groups = config.den.groups or { };
  environments = config.den.environments or { };
  registry = config.den.users.registry or { };
  hosts = flatHosts;

  groupNames = builtins.attrNames groups;
  envNames = builtins.attrNames environments;
  hostNames = builtins.attrNames hosts;

  scopeOf =
    gname:
    let
      labels = groups.${gname}.labels or [ ];
    in
    if builtins.elem "posix" labels then
      "system"
    else if builtins.elem "oauth-grant" labels then
      "kanidm"
    else
      "system";

  kinds = engine.mkKinds (
    map (name: engine.mkKind { inherit name; }) [
      "root"
      "group"
      "environment"
      "host"
    ]
  );

  scope = engine.buildRoots {
    parentGraph = engine.overlays (
      [ (engine.star "root" (map (e: "env:${e}") envNames)) ]
      ++ map (host: engine.edge "host:${host}" "env:${hosts.${host}.environment or "prod"}") hostNames
    );

    edgeGraphs = [
      {
        label = "M";
        graph = engine.overlays (
          (lib.concatMap (
            gname: map (member: engine.edge "group:${member}" "group:${gname}") (groups.${gname}.members or [ ])
          ) groupNames)
          ++ [ (engine.vertices (map (g: "group:${g}") groupNames)) ]
        );
      }
    ];

    decls = lib.listToAttrs (
      [
        {
          name = "root";
          value = { };
        }
      ]
      ++ map (gname: {
        name = "group:${gname}";
        value = {
          scope = scopeOf gname;
          description = groups.${gname}.description or "";
          name = gname;
        };
      }) groupNames
      ++ map (ename: {
        name = "env:${ename}";
        value = {
          name = ename;
          system-access-groups = environments.${ename}.system-access-groups or [ ];
        };
      }) envNames
      ++ map (hname: {
        name = "host:${hname}";
        value = {
          name = hname;
          system-access-groups = hosts.${hname}.system-access-groups or [ ];
        };
      }) hostNames
    );

    inherit kinds;
    types = lib.listToAttrs (
      [
        {
          name = "root";
          value = "root";
        }
      ]
      ++ map (g: {
        name = "group:${g}";
        value = "group";
      }) groupNames
      ++ map (e: {
        name = "env:${e}";
        value = "environment";
      }) envNames
      ++ map (h: {
        name = "host:${h}";
        value = "host";
      }) hostNames
    );
  };

  transitiveGroups =
    self: groupId:
    let
      walk =
        seen: id:
        if builtins.elem id seen then
          [ ]
        else
          [ id ] ++ lib.concatMap (walk (seen ++ [ id ])) (engine.followEdge "M" self id);
    in
    lib.unique (walk [ ] groupId);

  resolveAccess =
    self: hostId: userName: directGroups:
    let
      allGroupIds = lib.unique (
        lib.concatMap (gname: transitiveGroups self "group:${gname}") directGroups
      );
      knownGroupIds = builtins.filter (gid: scope.nodes ? ${gid}) allGroupIds;
      namesForScope =
        wanted:
        map (gid: (self.node gid).decls.name) (
          builtins.filter (gid: ((self.node gid).decls.scope or "") == wanted) knownGroupIds
        );
      gates = self.get hostId "effectiveGates";
      enable = builtins.any (g: builtins.elem "group:${g}" knownGroupIds) gates;
    in
    {
      inherit userName enable directGroups;
      allGroups = builtins.sort builtins.lessThan (map (gid: (self.node gid).decls.name) knownGroupIds);
      systemGroups = namesForScope "system";
      kanidmGroups = namesForScope "kanidm";
      effectiveGates = gates;
    };

  attributes = {
    children = _self: id: lib.filterAttrs (_: n: n.parent == id) scope.nodes;
    imports = _self: _id: [ ];
    "edges-M" = _self: id: (_self.node id).decls.__edges.M or [ ];

    effectiveGates =
      self: id:
      let
        node = self.node id;
        hostGates = node.decls.system-access-groups or [ ];
        envGates =
          if node.parent != null then (self.node node.parent).decls.system-access-groups or [ ] else [ ];
      in
      lib.unique (envGates ++ hostGates);

    resolveGroups = engine.paramAttr (
      self: hostId: directGroups:
      resolveAccess self hostId null directGroups
    );

    resolveUser = engine.paramAttr (
      self: hostId: userName:
      resolveAccess self hostId userName (registry.${userName}.groups or [ ])
    );
  };
in
{
  options.fleet.acl = mkOption {
    type = types.raw;
    description = "Evaluated ACL scope graph from scope-engine";
    readOnly = true;
  };

  config.fleet.acl = engine.eval { inherit scope attributes; };
}
