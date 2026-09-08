{ pkgs, lib }:
let
  # nixpkgs pins oddlama/kanidm-provision v1.3.0. Only its supported,
  # unpatched REST API is used; recovery credentials are never reset here.
  runner = pkgs.writeShellApplication {
    name = "provision-identity";
    runtimeInputs = [
      pkgs.kanidm-provision
      pkgs.curl
      pkgs.jq
      pkgs.coreutils
      pkgs.kubectl
    ];
    text = ''
      umask 077
      cd /work
      test -s /credentials/idm-admin-password
      test -s /desired/state.json
      test -s /desired/members.json
      trap 'rm -f auth.json headers response request.json provision.log client.json client-secret.json secret-publish.log' EXIT

      # Authenticate using runtime body files. The upstream provisioner calls
      # this password a TOKEN, but it is the idm_admin recovery password.
      api() {
        local method="$1" path="$2"
        shift 2
        curl --silent --show-error --fail --connect-timeout 10 --max-time 60 \
          --request "$method" --header @auth.json --header 'Content-Type: application/json' \
          --dump-header headers --output response "$KANIDM_URL$path" "$@"
      }
      : > auth.json
      printf '%s' '{"step":{"init":"idm_admin"}}' > request.json
      api POST /v1/auth --data-binary @request.json
      # HTTP header names are case insensitive. Never print the session/token.
      while IFS= read -r line; do
        case "''${line,,}" in
          x-kanidm-auth-session-id:*) printf '%s\n' "''${line%$'\r'}" > auth.json ;;
        esac
      done < headers
      test -s auth.json
      printf '%s' '{"step":{"begin":"password"}}' > request.json
      api POST /v1/auth --data-binary @request.json
      jq -n --rawfile password /credentials/idm-admin-password \
        '{step:{cred:{password:($password | rtrimstr("\n"))}}}' > request.json
      api POST /v1/auth --data-binary @request.json
      jq -er '"Authorization: Bearer " + (.state.success | select(type == "string" and length > 0))' response > auth.json

      # Revoke before fallible person/client reconciliation. The provisioner
      # updates group membership last; a failure there must not retain grants.
      api GET "/v1/group/$KANIDM_ADMIN_GROUP"
      jq -e --arg group "$KANIDM_ADMIN_GROUP" '. == null or .attrs.name == [$group]' response > /dev/null
      if jq -e '. != null' response > /dev/null; then
        printf '%s' '[]' > request.json
        api PUT "/v1/group/$KANIDM_ADMIN_GROUP/_attr/member" --data-binary @request.json
      fi

      # Bootstrap only the declared people/group/client. Removing someone from
      # Nix revokes membership, not their account, credentials or app history.
      export KANIDM_PROVISION_IDM_ADMIN_TOKEN
      KANIDM_PROVISION_IDM_ADMIN_TOKEN=$(cat /credentials/idm-admin-password)
      if ! kanidm-provision --url "$KANIDM_URL" --state /desired/state.json --no-auto-remove > provision.log 2>&1; then
        echo 'Kanidm entity provisioning failed (credential-bearing diagnostics withheld)' >&2
        exit 1
      fi
      unset KANIDM_PROVISION_IDM_ADMIN_TOKEN

      # The first phase leaves this group empty. Grant membership only after
      # passkey policy and the dedicated client's exhaustive grants are applied.
      printf '%s' '["account_policy"]' > request.json
      api POST "/v1/group/$KANIDM_ADMIN_GROUP/_attr/class" --data-binary @request.json
      printf '%s' '["passkey"]' > request.json
      api PUT "/v1/group/$KANIDM_ADMIN_GROUP/_attr/credential_type_minimum" --data-binary @request.json
      printf '%s' '{"attrs":{"oauth2_strict_redirect_uri":["true"]}}' > request.json
      api PATCH "/v1/oauth2/$KANIDM_OIDC_CLIENT" --data-binary @request.json

      # v1.3.0 only merges scope maps. Remove every existing normal and
      # supplemental map before granting the one authorized group. These are
      # Kanidm v1.10's native OAuth endpoints, not a private provisioning API.
      api GET "/v1/oauth2/$KANIDM_OIDC_CLIENT"
      cp response client.json
      for mapping in 'oauth2_rs_scope_map:_scopemap' 'oauth2_rs_sup_scope_map:_sup_scopemap'; do
        attribute="''${mapping%%:*}"
        endpoint="''${mapping#*:}"
        jq -r --arg attr "$attribute" '.attrs[$attr][]? | split(": ")[0] | split("@")[0]' client.json > groups
        while IFS= read -r group; do
          [[ "$group" =~ ^[a-zA-Z0-9_.-]+$ ]]
          api DELETE "/v1/oauth2/$KANIDM_OIDC_CLIENT/$endpoint/$group"
        done < groups
      done
      printf '%s' '["openid","profile","email","homelab_admin"]' > request.json
      api POST "/v1/oauth2/$KANIDM_OIDC_CLIENT/_scopemap/$KANIDM_ADMIN_GROUP" --data-binary @request.json
      # Unpatched Kanidm generates this secret; the Job is its only Kubernetes
      # publisher. Never put a configured basicSecretFile into the state.
      api GET "/v1/oauth2/$KANIDM_OIDC_CLIENT/_basic_secret"
      jq -e --arg name "$KANIDM_CLIENT_SECRET" '{apiVersion:"v1",kind:"Secret",metadata:{name:$name,namespace:"gateway"},
        type:"Opaque",data:{"client-secret":(. | select(type == "string" and length > 0) | @base64)}}' response > client-secret.json
      if ! kubectl apply --server-side --field-manager=identity-provisioner -f client-secret.json > secret-publish.log 2>&1; then
        echo 'Kanidm client Secret publication failed (credential-bearing diagnostics withheld)' >&2
        exit 1
      fi
      api PUT "/v1/group/$KANIDM_ADMIN_GROUP/_attr/member" --data-binary @/desired/members.json
      echo 'Kanidm household administrator policy applied'
    '';
  };
  image = pkgs.dockerTools.buildLayeredImage {
    name = "homelab/kanidm-provision";
    compressor = "none";
    contents = [
      runner
      pkgs.cacert
    ];
    config = {
      Entrypoint = [ "${runner}/bin/provision-identity" ];
      Env = [ "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt" ];
      User = "1000:1000";
    };
  };
  imageRef = "${image.imageName}:${image.imageTag}";
in
{
  inherit imageRef;
  image = image.overrideAttrs (old: {
    passthru = (old.passthru or { }) // {
      imageReference = imageRef;
    };
  });
}
