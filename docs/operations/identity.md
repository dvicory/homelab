# Identity operations

Kanidm runs in the `identity` namespace. The Gateway protects administrator
routes with OIDC from Kanidm.

## Bootstrap

Administrator routes remain disabled during `initial` and `provisioning`.
Confirm TLS certificates are Ready before recovering accounts.

1. Run Kanidm `recover-account` for the stock accounts through a private
   interactive `kubectl exec` session. Immediately encrypt or escrow
   the output; do not save it in ordinary files.
2. Encrypt and track the `idm_admin` credential. Select `provisioning`
   before running agenix-rekey. Commit the host-rekeyed ciphertext and
   generated manifests, then activate the host to stage the runtime
   Secret. Wait for the `kanidm-provision` PostSync Job to complete.
3. Enroll credentials for a new administrator through Kanidm's
   enrollment flow: password-plus-MFA or an optional passkey.
   Verify native login over the private canonical identity route
   before selecting `normal`. Already-enrolled accounts need no repeat.
4. Select `normal`, wait for provisioning to complete, and verify
   protected administrator access.

## Upgrade

Run `kanidmd domain upgrade-check` and take a restorable backup before
upgrading. Upgrade minor releases sequentially; successful database
migrations cannot be downgraded. Match the CLI version to the server.

## Gateway authentication failures

Start with the Gateway access logs. Find the request by timestamp and
`request_id`; check `status`, `response_flags`, and `upstream`. Check
Kanidm's pod health and logs for the same time window.

Inspect the OAuth success and failure counters on the private
`/stats/prometheus` endpoint. Counters show OAuth outcomes, not the cause
of a failure. The declared stack does not configure a scraper or alerts;
inspect these counters manually.

Keep the OAuth2 text logger at `critical`. Do not enable verbose OAuth2
logging or add `%RESPONSE_CODE_DETAILS%` to access logs: both can expose
credential material. Other warning logs and queryless access logs remain
available.
