# Settings cascade scope graph.
#
# Evaluated attributes:
#   resolvedSettings — full resolved settings for a node (local > import > parent)
#   setting          — paramAttr for per-key demand-driven lookup
#   settingSources   — provenance per key (local/import/inherited)
#   overriddenKeys   — keys that shadow a parent value
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

  environments = config.den.environments or { };
  hosts = flatHosts;

  envNames = builtins.attrNames environments;
  hostNames = builtins.attrNames hosts;

  parentEdges = engine.overlays (
    [ (engine.star "root" (map (e: "env:${e}") envNames)) ]
    ++ map (host: engine.edge "host:${host}" "env:${hosts.${host}.environment or "prod"}") hostNames
  );

  importEdges = engine.overlays (
    lib.concatMap (
      ename:
      let
        delegation = environments.${ename}.delegation or { };
        targets = lib.filter (t: t != null) [
          (delegation.metricsTo or null)
          (delegation.authTo or null)
          (delegation.logsTo or null)
        ];
      in
      map (target: engine.edge "env:${ename}" "env:${target}") targets
    ) envNames
  );

  kinds = engine.mkKinds (
    map (name: engine.mkKind { inherit name; }) [
      "root"
      "environment"
      "host"
    ]
  );

  scope = engine.buildRoots {
    parentGraph = parentEdges;
    importGraph = importEdges;

    decls = lib.listToAttrs (
      [
        {
          name = "root";
          value = { };
        }
      ]
      ++ map (ename: {
        name = "env:${ename}";
        value = environments.${ename}.settings or { };
      }) envNames
      ++ map (hname: {
        name = "host:${hname}";
        value = hosts.${hname}.settings or { };
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

  attributes = {
    children = _self: id: lib.filterAttrs (_: n: n.parent == id) scope.nodes;
    imports = _self: id: (_self.node id).decls.__edges.I or [ ];

    setting = engine.paramAttr (
      self: id: key:
      engine.query { dataFilter = node: node.decls.${key} or null; } self id
    );

    resolvedSettings =
      self: id:
      let
        node = self.node id;
        local = builtins.removeAttrs node.decls [ "__edges" ];
        imports = node.decls.__edges.I or [ ];
        importedSettings = lib.foldl' (
          acc: imported: engine.shadow (self.get imported "resolvedSettings") acc
        ) { } imports;
        parentSettings = if node.parent != null then self.get node.parent "resolvedSettings" else { };
      in
      engine.shadow local (engine.shadow importedSettings parentSettings);

    overriddenKeys =
      self: id:
      let
        allResults = key: engine.queryAll { dataFilter = node: node.decls.${key} or null; } self id;
        localKeys = builtins.attrNames (builtins.removeAttrs (self.node id).decls [ "__edges" ]);
      in
      builtins.filter (key: builtins.length (allResults key) > 1) localKeys;

    settingSources =
      self: id:
      let
        node = self.node id;
        local = builtins.removeAttrs node.decls [ "__edges" ];
        imports = node.decls.__edges.I or [ ];
        resolved = self.get id "resolvedSettings";
      in
      lib.mapAttrs (
        key: _:
        if local ? ${key} then
          "local"
        else if builtins.any (imported: (self.get imported "resolvedSettings") ? ${key}) imports then
          "import"
        else
          "inherited"
      ) resolved;
  };
in
{
  options.fleet.settings = mkOption {
    type = types.raw;
    description = "Forward settings cascade graph (currently has no configuration consumers)";
    readOnly = true;
  };

  config.fleet.settings = engine.eval { inherit scope attributes; };
}
