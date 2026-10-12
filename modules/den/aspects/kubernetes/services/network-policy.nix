# NetworkPolicy enforcement for the compute cluster.
#
# K3s's embedded controller (kube-router) cannot work in the unprivileged
# guest: it rewrites the whole iptables filter table as one netlink batch,
# and iptables cannot raise its socket buffer there, so every sync fails once
# the cluster has more than about 14 Pods. The guest's K3s therefore runs with
# --disable-network-policy (services.kubernetes aspect) and
# kube-network-policies enforces NetworkPolicy instead. Its nftables table
# holds only Pod address sets; each new connection to or from a Pod is decided
# in userspace through nfqueue.
#
# Start-up depends on nothing it enforces: the Pod uses the host network, so
# it reaches the API server, the image registry and the node's resolver
# without passing its own rules, and the kubelet restarts it without Argo.
#
# Fail-closed: while its rules are installed and the process is not reading
# the queue (a crash, before the kubelet restarts it, or a broken dataplane),
# new Pod connections are dropped instead of admitted unchecked. A graceful
# stop (DaemonSet deletion or update) removes its rules first, so connections
# are admitted unchecked until the next instance is ready.
{ ... }:
{
  den.aspects.kubernetes.services.network-policy.k8s-manifests =
    { ... }:
    let
      name = "kube-network-policies";
      namespace = "kube-system";
      labels."app.kubernetes.io/name" = name;
      metricsPort = 9080;
    in
    {
      applications.network-policy = {
        inherit namespace;
        # Before every workload, including Argo's own: a later wave waits for
        # this DaemonSet to be Ready.
        annotations."argocd.argoproj.io/sync-wave" = "-3";
        createNamespace = false;
        objects = [
          {
            apiVersion = "v1";
            kind = "ServiceAccount";
            metadata = {
              inherit name namespace labels;
            };
          }
          {
            apiVersion = "rbac.authorization.k8s.io/v1";
            kind = "ClusterRole";
            metadata = {
              inherit name labels;
            };
            rules = [
              {
                apiGroups = [ "" ];
                resources = [
                  "pods"
                  "namespaces"
                ];
                verbs = [
                  "list"
                  "watch"
                ];
              }
              {
                apiGroups = [ "networking.k8s.io" ];
                resources = [ "networkpolicies" ];
                verbs = [
                  "list"
                  "watch"
                ];
              }
            ];
          }
          {
            apiVersion = "rbac.authorization.k8s.io/v1";
            kind = "ClusterRoleBinding";
            metadata = {
              inherit name labels;
            };
            roleRef = {
              apiGroup = "rbac.authorization.k8s.io";
              kind = "ClusterRole";
              inherit name;
            };
            subjects = [
              {
                kind = "ServiceAccount";
                inherit name namespace;
              }
            ];
          }
          {
            apiVersion = "apps/v1";
            kind = "DaemonSet";
            metadata = {
              inherit name namespace labels;
            };
            spec = {
              selector.matchLabels = labels;
              template = {
                metadata = {
                  inherit labels;
                };
                spec = {
                  hostNetwork = true;
                  priorityClassName = "system-node-critical";
                  serviceAccountName = name;
                  # Run on the node whatever its taints, like the CNI.
                  tolerations = [ { operator = "Exists"; } ];
                  containers = [
                    {
                      inherit name;
                      image = "registry.k8s.io/networking/kube-network-policies:v1.1.2@sha256:c671f98e444825d57c590c92da1b5e66070917c4d3dff1f9279775e6b73254fe";
                      args = [
                        "/bin/netpol"
                        "--hostname-override=$(NODE_NAME)"
                        "--fail-open=false"
                        "--nfqueue-id=98"
                        "--metrics-bind-address=:${toString metricsPort}"
                        # Verbosity 2 logs every new connection's verdict.
                        # Raise it only while investigating a denial; the
                        # packet_count metric counts verdicts at any level.
                        "--v=0"
                      ];
                      env = [
                        {
                          name = "NODE_NAME";
                          valueFrom.fieldRef.fieldPath = "spec.nodeName";
                        }
                      ];
                      ports = [
                        {
                          name = "metrics";
                          containerPort = metricsPort;
                          protocol = "TCP";
                        }
                      ];
                      # The metrics server starts with the process; Argo
                      # reports the DaemonSet healthy only once it answers.
                      readinessProbe = {
                        httpGet = {
                          path = "/metrics";
                          port = metricsPort;
                        };
                        periodSeconds = 10;
                      };
                      resources.requests = {
                        cpu = "100m";
                        memory = "50Mi";
                      };
                      # Not privileged: NET_ADMIN covers nftables, nfqueue and
                      # conntrack in the guest's network namespace. A
                      # privileged container would also see every guest
                      # device, the delegated render node included (ADR-0010).
                      securityContext = {
                        allowPrivilegeEscalation = false;
                        capabilities = {
                          drop = [ "ALL" ];
                          add = [ "NET_ADMIN" ];
                        };
                      };
                      volumeMounts = [
                        {
                          name = "nri-plugin";
                          mountPath = "/var/run/nri";
                        }
                        {
                          name = "netns";
                          mountPath = "/var/run/netns";
                          mountPropagation = "HostToContainer";
                        }
                      ];
                    }
                  ];
                  volumes = [
                    {
                      # containerd's NRI socket: Pod addresses at sandbox
                      # creation, before the API server reports them.
                      name = "nri-plugin";
                      hostPath.path = "/var/run/nri";
                    }
                    {
                      name = "netns";
                      hostPath.path = "/var/run/netns";
                    }
                  ];
                };
              };
            };
          }
        ];
      };
    };
}
