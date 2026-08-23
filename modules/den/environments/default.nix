# Environment entity registry for fleet grouping and shared context.
{
  den,
  inputs,
  ...
}:
let
  schemaLib = inputs.gen-schema.lib;
in
{
  options.den.environments = schemaLib.mkInstanceRegistry den.schema.environment {
    description = "Environment definitions for fleet grouping and shared context";
  };
}
