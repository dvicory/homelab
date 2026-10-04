# Reference constructors that spell out the API server's schema defaults.
#
# Argo CD applies these objects with server-side apply and owns parentRefs,
# rules and backendRefs as whole atomic lists. The API server adds CRD
# defaults inside those lists, but Argo's structured-merge diff does not know
# CRD defaults, so any default we omit shows up as a permanent OutOfSync
# difference. Each value below must equal the pinned CRD default exactly
# (generated/manifests/prod-home/gateway-crds); caller attributes win.
{
  # Gateway API v1.6.1 HTTPRoute v1 spec.parentRefs[] (group, kind).
  parentRef = ref: {
    group = "gateway.networking.k8s.io";
    kind = "Gateway";
  }
  // ref;

  # Gateway API v1.6.1 HTTPRoute v1 spec.rules[].backendRefs[] and Envoy
  # Gateway SecurityPolicy spec.oidc.provider.backendRefs[] share these
  # defaults (group, kind, weight).
  backendRef = ref: {
    group = "";
    kind = "Service";
    weight = 1;
  }
  // ref;
}
