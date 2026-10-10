{
  writeShellApplication,
  kanidm-provision,
  curl,
  jq,
  coreutils,
  kubectl,
  dockerTools,
  cacert,
}:
let
  runner = writeShellApplication {
    name = "provision-identity";
    runtimeInputs = [
      kanidm-provision
      curl
      jq
      coreutils
      kubectl
    ];
    text = ''
      umask 077
      cd /work
      test -s /credentials/idm-admin-password
      test -s /desired/state.json
      test -s /desired/members.json
      test -s /desired/clients.json
      trap 'rm -f auth.json headers response request.json provision.log client.json client-spec.json client-secret.json groups secret-publish.log' EXIT

      # Authenticate using runtime body files. The upstream provisioner calls
      # this password a TOKEN, but it is the idm_admin recovery password.
      api() {
        local method="$1" path="$2"
        shift 2
        curl --silent --show-error --fail --connect-timeout 10 --max-time 60 \
          --request "$method" --header @auth.json --header 'Content-Type: application/json' \
          --dump-header headers --output response "$KANIDM_URL$path" "$@"
      }
      api_optional_get() {
        local path="$1" status
        status=$(curl --silent --show-error --connect-timeout 10 --max-time 60 \
          --request GET --header @auth.json --header 'Content-Type: application/json' \
          --dump-header headers --output response --write-out '%{http_code}' "$KANIDM_URL$path")
        case "$status" in
          200) ;;
          404) printf '%s' 'null' > response ;;
          *) echo 'Kanidm lookup failed' >&2; return 1 ;;
        esac
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
      api_optional_get "/v1/group/$KANIDM_ADMIN_GROUP"
      jq -e --arg group "$KANIDM_ADMIN_GROUP" '. == null or .attrs.name == [$group]' response > /dev/null
      if jq -e '. != null' response > /dev/null; then
        printf '%s' '[]' > request.json
        api PUT "/v1/group/$KANIDM_ADMIN_GROUP/_attr/member" --data-binary @request.json
      fi

      # Bootstrap only the declared people/group/clients. Removing someone from
      # Nix revokes membership, not their account, credentials or app history.
      export KANIDM_PROVISION_IDM_ADMIN_TOKEN
      KANIDM_PROVISION_IDM_ADMIN_TOKEN=$(cat /credentials/idm-admin-password)
      if ! kanidm-provision --url "$KANIDM_URL" --state /desired/state.json --no-auto-remove > provision.log 2>&1; then
        echo 'Kanidm entity provisioning failed (credential-bearing diagnostics withheld)' >&2
        exit 1
      fi
      unset KANIDM_PROVISION_IDM_ADMIN_TOKEN

      # The first phase leaves this group empty. Grant membership only after
      # MFA policy and every declared client's exhaustive grants are applied.
      printf '%s' '["account_policy"]' > request.json
      api POST "/v1/group/$KANIDM_ADMIN_GROUP/_attr/class" --data-binary @request.json
      printf '%s' '["mfa"]' > request.json
      api PUT "/v1/group/$KANIDM_ADMIN_GROUP/_attr/credential_type_minimum" --data-binary @request.json

      # clients.json lists each OAuth2 client, the scopes the administrator
      # group receives, and the declared Secret that receives its credential.
      client_count=$(jq -er 'length' /desired/clients.json)
      for ((index = 0; index < client_count; index++)); do
        jq -e --argjson index "$index" '.[$index]' /desired/clients.json > client-spec.json
        client=$(jq -er '.name | select(test("^[a-z0-9_-]+$"))' client-spec.json)
        printf '%s' '{"attrs":{"oauth2_strict_redirect_uri":["true"]}}' > request.json
        api PATCH "/v1/oauth2/$client" --data-binary @request.json

        # v1.3.0 only merges scope maps. Remove every existing normal and
        # supplemental map before granting the one authorized group. These are
        # Kanidm v1.10's native OAuth endpoints, not a private provisioning API.
        api GET "/v1/oauth2/$client"
        cp response client.json
        for mapping in 'oauth2_rs_scope_map:_scopemap' 'oauth2_rs_sup_scope_map:_sup_scopemap'; do
          attribute="''${mapping%%:*}"
          endpoint="''${mapping#*:}"
          jq -r --arg attr "$attribute" '.attrs[$attr][]? | split(": ")[0] | split("@")[0]' client.json > groups
          while IFS= read -r group; do
            [[ "$group" =~ ^[a-zA-Z0-9_.-]+$ ]]
            api DELETE "/v1/oauth2/$client/$endpoint/$group"
          done < groups
        done
        jq -ce '.scopes | select(type == "array" and length > 0)' client-spec.json > request.json
        api POST "/v1/oauth2/$client/_scopemap/$KANIDM_ADMIN_GROUP" --data-binary @request.json

        # Unpatched Kanidm generates this secret; the Job is its only Kubernetes
        # publisher. Never put a configured basicSecretFile into the state.
        # The Secret is declared without data by GitOps. This apply sets only
        # `data`; RBAC allows patching that one Secret and creating none.
        api GET "/v1/oauth2/$client/_basic_secret"
        jq -e --slurpfile spec client-spec.json '($spec[0].secret) as $secret
          | {apiVersion:"v1",kind:"Secret",metadata:{name:$secret.name,namespace:$secret.namespace},
             data:{($secret.key):(. | select(type == "string" and length > 0) | @base64)}}' response > client-secret.json
        if ! kubectl apply --server-side --field-manager=identity-provisioner -f client-secret.json > secret-publish.log 2>&1; then
          echo "Kanidm client Secret publication for $client failed (credential-bearing diagnostics withheld)" >&2
          exit 1
        fi
      done
      api PUT "/v1/group/$KANIDM_ADMIN_GROUP/_attr/member" --data-binary @/desired/members.json
      echo 'Kanidm household administrator policy applied'
    '';
  };
  image = dockerTools.buildLayeredImage {
    name = "homelab/kanidm-provision";
    compressor = "none";
    contents = [
      runner
      cacert
    ];
    config = {
      Entrypoint = [ "${runner}/bin/provision-identity" ];
      Env = [ "SSL_CERT_FILE=${cacert}/etc/ssl/certs/ca-bundle.crt" ];
      User = "1000:1000";
    };
  };
  imageRef = "${image.imageName}:${image.imageTag}";
in
image.overrideAttrs (old: {
  passthru = (old.passthru or { }) // {
    imageReference = imageRef;
  };
})
