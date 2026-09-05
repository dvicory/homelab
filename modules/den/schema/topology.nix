# Entity topology via parent collections.
  # Declares parent-child nesting between kinds for gen-scope graph generation.
# gen-schema derives _meta.topology from these declarations.
_: {
  den.schema.host.parent = "environment";
  den.schema.user.parent = "host";
}
