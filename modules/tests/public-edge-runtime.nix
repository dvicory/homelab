{ lib, ... }:
{
  perSystem =
    { pkgs, system, ... }:
    lib.optionalAttrs
      (lib.elem system [
        "x86_64-linux"
        "aarch64-linux"
      ])
      (
        let
          certificates =
            pkgs.runCommand "public-edge-runtime-certificates"
              {
                nativeBuildInputs = [ pkgs.openssl ];
              }
              ''
                mkdir -p "$out"
                openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
                  -keyout "$out/edge.key" -out "$out/edge.crt" \
                  -subj '/CN=primary.test' \
                  -addext 'subjectAltName=DNS:service.primary.test,DNS:service.backup.test,DNS:primary.test,DNS:backup.test'
                openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
                  -keyout "$out/origin.key" -out "$out/origin.crt" \
                  -subj '/CN=origin.test' \
                  -addext 'subjectAltName=DNS:origin.test'
                openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
                  -keyout "$out/untrusted.key" -out "$out/untrusted.crt" \
                  -subj '/CN=origin.test' -addext 'subjectAltName=DNS:origin.test'
                openssl req -new -newkey rsa:2048 -nodes \
                  -keyout "$out/wrong-name.key" -out "$out/wrong-name.csr" \
                  -subj '/CN=wrong.test' -addext 'subjectAltName=DNS:wrong.test'
                openssl x509 -req -in "$out/wrong-name.csr" \
                  -CA "$out/origin.crt" -CAkey "$out/origin.key" \
                  -set_serial 2 -days 3650 -copy_extensions copy -out "$out/wrong-name.crt"
              '';
          edge = import ../den/aspects/services/public-edge.nix {
            config = {
              den = {
                clusters."prod-home" = {
                  environment = "prod";
                  settings.kubernetes.services.identity.phase = "normal";
                  ingress.mode = "trustedEdges";
                  ingress.trustedProxyCIDRs = [
                    "10.0.0.11/32"
                    "10.0.0.12/32"
                  ];
                  routes.service = {
                    hostnames = [
                      "service.primary.test"
                      "service.backup.test"
                    ];
                    exposure = "public";
                    pathPrefix = "/";
                  };
                };
                environments.prod = {
                  domain = "primary.test";
                  backupDomain = "backup.test";
                };
              };
            };
            inherit lib;
          };
          tls = {
            primary = {
              certificate = "${certificates}/edge.crt";
              key = "${certificates}/edge.key";
            };
            backup = {
              certificate = "${certificates}/edge.crt";
              key = "${certificates}/edge.key";
            };
          };
          mkSettings = peerAddress: {
            enable = true;
            originHost = "10.0.0.10";
            originPort = 8443;
            originServerName = "origin.test";
            originCA = "${certificates}/origin.crt";
            inherit peerAddress tls;
            bareRoute = "service";
          };
          remoteHost = {
            settings.services."remote-edge" = mkSettings "10.0.0.11";
          };
          homeHost = {
            settings.services."home-edge" = mkSettings "10.0.0.12";
          };
          remoteRole = edge.den.aspects.services.remote-edge.nixos {
            host = remoteHost;
          };
          homeRole = edge.den.aspects.services.home-edge.nixos {
            host = homeHost;
          };
          test = pkgs.testers.runNixOSTest {
            name = "public-edge-runtime";
            nodes = {
              origin =
                { ... }:
                {
                  system.stateVersion = "26.05";
                  virtualisation.vlans = [ 1 ];
                  networking.useDHCP = false;
                  networking.interfaces.eth1.ipv4.addresses = [
                    {
                      address = "10.0.0.10";
                      prefixLength = 24;
                    }
                  ];
                  networking.extraHosts = "10.0.0.10 origin origin.test";
                  networking.firewall.enable = true;
                  networking.firewall.extraCommands = ''
                    iptables -I INPUT 1 -i eth1 -p tcp --dport 8443 -j REJECT
                    iptables -I INPUT 1 -i eth1 -p tcp --dport 8443 -s 10.0.0.12 -j ACCEPT
                    iptables -I INPUT 1 -i eth1 -p tcp --dport 8443 -s 10.0.0.11 -j ACCEPT
                  '';
                  environment.systemPackages = [ pkgs.curl ];
                  systemd.tmpfiles.rules = [
                    "d /run/origin-tls 0700 nginx nginx -"
                    "C /run/origin-tls/server.crt 0644 nginx nginx - ${certificates}/origin.crt"
                    "C /run/origin-tls/server.key 0600 nginx nginx - ${certificates}/origin.key"
                  ];
                  services.nginx = {
                    enable = true;
                    virtualHosts.origin = {
                      onlySSL = true;
                      listen = [
                        {
                          addr = "10.0.0.10";
                          port = 8443;
                          ssl = true;
                        }
                      ];
                      sslCertificate = "/run/origin-tls/server.crt";
                      sslCertificateKey = "/run/origin-tls/server.key";
                      locations."/".return = "200 origin";
                      locations."/headers".return =
                        "200 $remote_addr|$http_x_forwarded_for|$http_x_forwarded_host|$http_forwarded|$http_x_forwarded_user|$http_x_auth_request_user|$http_x_forwarded_email|$http_x_auth_request_email|$http_remote_user|$http_host|$http_x_forwarded_proto|$http_x_forwarded_port|$ssl_server_name";
                      locations."/privacy".return =
                        "200 $request_uri|$args|$http_authorization|$http_cookie|$http_x_request_id";
                    };
                  };
                };
              remote =
                { ... }:
                {
                  imports = [ remoteRole ];
                  system.stateVersion = "26.05";
                  virtualisation.vlans = [ 1 ];
                  networking.useDHCP = false;
                  networking.interfaces.eth1.ipv4.addresses = [
                    {
                      address = "10.0.0.11";
                      prefixLength = 24;
                    }
                  ];
                  networking.extraHosts = "10.0.0.10 origin origin.test";
                };
              home =
                { ... }:
                {
                  imports = [ homeRole ];
                  system.stateVersion = "26.05";
                  virtualisation.vlans = [ 1 ];
                  networking.useDHCP = false;
                  networking.interfaces.eth1.ipv4.addresses = [
                    {
                      address = "10.0.0.12";
                      prefixLength = 24;
                    }
                  ];
                  networking.extraHosts = "10.0.0.10 origin origin.test";
                };
              client =
                { ... }:
                {
                  system.stateVersion = "26.05";
                  virtualisation.vlans = [ 1 ];
                  networking.useDHCP = false;
                  networking.interfaces.eth1.ipv4.addresses = [
                    {
                      address = "10.0.0.13";
                      prefixLength = 24;
                    }
                  ];
                  networking.extraHosts = ''
                    10.0.0.10 origin origin.test
                    10.0.0.11 primary.test service.primary.test
                    10.0.0.12 backup.test service.backup.test
                  '';
                  environment.systemPackages = [ pkgs.curl ];
                };
            };
            testScript = ''
              import json
              import re
              import shlex
              import time

              def access_log(edge, path):
                  for _ in range(30):
                      logs = edge.succeed("cat /var/log/nginx/access.log")
                      for secret in ("query-secret-", "code-secret-", "credential-canary-", "cookie-secret-"):
                          assert secret not in logs, "sensitive request data reached the edge access log"
                      entries = [json.loads(line) for line in logs.splitlines()]
                      matches = [entry for entry in entries if entry.get("path") == path]
                      if matches:
                          assert len(matches) == 1, "expected one log entry for the unique request"
                          return matches[0]
                      time.sleep(1)
                  raise AssertionError(f"no queryless edge access log entry for {path}")

              start_all()
              origin.wait_for_unit("nginx.service")
              remote.wait_for_unit("nginx.service")
              home.wait_for_unit("nginx.service")
              remote.wait_for_open_port(443)
              home.wait_for_open_port(443)
              origin.wait_until_succeeds("curl -ksSf https://10.0.0.10:8443/ | grep -qx origin", timeout=30)

              client.succeed("curl --cacert ${certificates}/edge.crt -sSf --resolve service.primary.test:443:10.0.0.11 https://service.primary.test/ | grep -qx origin")
              client.succeed("curl --cacert ${certificates}/edge.crt -sSf --resolve service.backup.test:443:10.0.0.12 https://service.backup.test/ | grep -qx origin")
              client.succeed("curl --cacert ${certificates}/edge.crt -sI --resolve primary.test:443:10.0.0.11 https://primary.test/ | grep -iF 'location: https://service.primary.test/'")
              client.succeed("curl --cacert ${certificates}/edge.crt -sI --resolve backup.test:443:10.0.0.12 https://backup.test/ | grep -iF 'location: https://service.backup.test/'")
              # An SNI name with no matching vhost is rejected during the
              # handshake: curl exits 35 (CURLE_SSL_CONNECT_ERROR), before any
              # HTTP status exists.
              client.succeed(
                "if curl --cacert ${certificates}/edge.crt -sS -o /dev/null --connect-timeout 3 "
                "--resolve unmatched.primary.test:443:10.0.0.11 https://unmatched.primary.test/; "
                "then exit 1; else test $? -eq 35; fi"
              )
              client.succeed("test $(curl --cacert ${certificates}/edge.crt -sS -o /dev/null -w '%{http_code}' -H 'Host: unknown.primary.test' --resolve service.primary.test:443:10.0.0.11 https://service.primary.test/) = 404")
              for edge, role, hostname, address in (
                  (remote, "remote", "service.primary.test", "10.0.0.11"),
                  (home, "home", "service.backup.test", "10.0.0.12"),
              ):
                  with subtest(f"{role} edge replaces spoofed forwarding metadata and sends origin SNI"):
                      headers = client.succeed(
                          "curl --cacert ${certificates}/edge.crt -sSf -H 'X-Forwarded-For: 198.51.100.99' "
                          "-H 'X-Forwarded-Host: forged.test' -H 'X-Forwarded-Proto: http' -H 'X-Forwarded-Port: 81' "
                          "-H 'Forwarded: for=198.51.100.99' -H 'X-Forwarded-User: forged' "
                          "-H 'X-Auth-Request-User: forged' -H 'X-Forwarded-Email: forged@example.test' "
                          "-H 'X-Auth-Request-Email: forged@example.test' -H 'Remote-User: forged' "
                          f"--resolve {hostname}:443:{address} https://{hostname}/headers"
                      ).strip()
                      assert headers == f"{address}|10.0.0.13|{hostname}|||||||{hostname}|https|443|origin.test", headers

                  with subtest(f"{role} edge logs only paths and preserves its fresh request ID to the origin"):
                      request_ids = set()
                      for label, supplied_id in (
                          ("valid", "1234567890abcdef1234567890abcdef"),
                          ("malformed", 'forged"request-id'),
                          ("absent", None),
                      ):
                          path = f"/privacy-{role}-{label}"
                          query = f"token=query-secret-{role}-{label}&code=code-secret-{role}-{label}"
                          authorization = "Bearer " + f"credential-canary-{role}-{label}"
                          cookie = f"session=cookie-secret-{role}-{label}"
                          request_id_header = (
                              "-H " + shlex.quote(f"X-Request-ID: {supplied_id}") if supplied_id is not None else ""
                          )
                          response = client.succeed(
                              "curl --cacert ${certificates}/edge.crt -sSf "
                              f"-H {shlex.quote('Authorization: ' + authorization)} "
                              f"-H {shlex.quote('Cookie: ' + cookie)} {request_id_header} "
                              f"--resolve {hostname}:443:{address} {shlex.quote(f'https://{hostname}{path}?{query}')}"
                          ).strip().split("|")
                          assert response[:4] == [f"{path}?{query}", query, authorization, cookie], response
                          assert len(response) == 5, response
                          request_id = response[4]
                          assert re.fullmatch(r"[0-9a-f]{32}", request_id), "origin did not receive an edge-generated ID"
                          assert request_id != supplied_id, "client request ID was trusted"
                          assert request_id not in request_ids, "distinct requests reused an ID"
                          request_ids.add(request_id)
                          entry = access_log(edge, path)
                          assert entry["request_id"] == request_id, "edge log and upstream request IDs differ"
                          assert entry["client"] == "10.0.0.13", entry
                          assert entry["host"] == hostname and entry["method"] == "GET" and entry["status"] == 200, entry
              client.fail("curl -ksSf --connect-timeout 3 https://origin:8443/")

              for certificate in ("untrusted", "wrong-name", "origin"):
                  origin.succeed(
                      f"cp ${certificates}/{certificate}.crt /run/origin-tls/server.crt && "
                      f"cp ${certificates}/{certificate}.key /run/origin-tls/server.key && "
                      "systemctl restart nginx.service"
                  )
                  origin.wait_until_succeeds("curl -ksSf https://10.0.0.10:8443/ | grep -qx origin", timeout=30)
                  if certificate == "wrong-name":
                      origin.succeed("curl --cacert ${certificates}/origin.crt -sSf --resolve wrong.test:8443:10.0.0.10 https://wrong.test:8443/ | grep -qx origin")
                  expected = "200" if certificate == "origin" else "502"
                  for hostname, address in (("service.primary.test", "10.0.0.11"), ("service.backup.test", "10.0.0.12")):
                      client.succeed(
                          "test $(curl --cacert ${certificates}/edge.crt -sS -o /dev/null "
                          f"-w '%{{http_code}}' --resolve {hostname}:443:{address} https://{hostname}/) = {expected}"
                      )

              remote.succeed("systemctl stop nginx.service")
              client.fail(
                "curl --cacert ${certificates}/edge.crt -sSf --connect-timeout 3 "
                "--resolve service.primary.test:443:10.0.0.11 https://service.primary.test/"
              )
              client.succeed("curl --cacert ${certificates}/edge.crt -sSf --resolve service.backup.test:443:10.0.0.12 https://service.backup.test/ | grep -qx origin")
            '';
          };
        in
        {
          legacyPackages.public-edge-runtime-test = test;
          checks.public-edge-runtime = test // {
            meta = test.meta // {
              hestia.group = "${system}-public-edge-runtime";
            };
          };
        }
      );
}
