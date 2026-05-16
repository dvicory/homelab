{ inputs, ... }:
{
  imports = [
    (inputs.den.namespace "dlab" false)
  ];
}
