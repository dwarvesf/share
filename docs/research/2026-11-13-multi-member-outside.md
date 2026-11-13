# Outside research: Workers VPC + tunnel + tokens (rid=multi-member-brief)

Date: 2026-11-13. Sources: developers.cloudflare.com unless noted. Doc pages were read through a summarizing fetcher; quotes are the fetcher's verbatim extracts. "Not documented" = the page I read was silent.

## 1. Workers VPC Services: create, bind, delete, limits

- REST create: `POST /accounts/{account_id}/connectivity/directory/services`. "Create Workers VPC connectivity service". https://developers.cloudflare.com/api/typescript/resources/connectivity/subresources/directory/subresources/services/methods/create/
- Body (documented contract): `type` (http|tcp), `name`, `host`, optional `http_port`, `https_port`, `tls_settings`. https://developers.cloudflare.com/workers-vpc/configuration/vpc-services/
  ```json
  {"type":"http","name":"share-member-x","http_port":8080,
   "host":{"ipv4":"127.0.0.1","network":{"tunnel_id":"<TUNNEL_UUID>"}}}
  ```
  Quote: "For `http` services, `http_port` and `https_port` default to 80 and 443." and "Setting only one of them restricts the service to that scheme." So set `http_port` only, omit `https_port` to be http-only (inferred from that sentence).
- Response: `result.service_id` (UUID), `type`, `name`, `created_at`, `updated_at`. Same create-method URL.
- Get/list/update: `GET .../services`, `GET .../services/{service_id}`, `PUT .../services/{service_id}`. Same family: https://developers.cloudflare.com/api/typescript/resources/connectivity/subresources/directory/subresources/services/methods/get/
- Delete: `DELETE /accounts/{account_id}/connectivity/directory/services/{service_id}`. https://developers.cloudflare.com/api/resources/connectivity/subresources/directory/subresources/services/methods/delete
- Wrangler: `npx wrangler vpc service create my-private-api --type http --tunnel-id <ID> --hostname <HOST>`; swap `--hostname` for `--ipv4`/`--ipv6`; add `--http-port <PORT>` and/or `--https-port <PORT>`. https://developers.cloudflare.com/workers-vpc/get-started/ . Wrangler delete command: not documented on pages read.
- Wrangler binding: `"vpc_services":[{"binding":"PRIVATE_API","service_id":"<uuid>","remote":true}]`. https://developers.cloudflare.com/workers-vpc/configuration/vpc-services/
- REST script-upload binding (multipart `metadata.bindings[]`): `type: "vpc_service"`, `name` ("A JavaScript variable name for the binding."), `service_id` ("Identifier of the VPC service to bind to."). Sibling `type: "vpc_network"` has `name` + optional `network_id`/`tunnel_id`/`identity`. https://developers.cloudflare.com/api/resources/workers/subresources/scripts/methods/update/
- Limit: "VPC Services per account | 1000". https://developers.cloudflare.com/workers-vpc/platform/limits/
- Bindings per Worker: not documented (Workers limits page lists only env vars: "64/Worker" Free, "128/Worker" Paid). https://developers.cloudflare.com/workers/platform/limits/
- Permissions: documented as ROLES, not token permission-group names. "Connectivity Directory Read" (view), "Connectivity Directory Bind" (list/read/bind in Workers), "Connectivity Directory Admin" ("create, update, and delete VPC Services"). "If you authenticate with CLOUDFLARE_API_TOKEN, the token's user must hold these roles." API-token permission-group names for the connectivity endpoints: not documented; the create-method page names none, and the permissions reference (https://developers.cloudflare.com/fundamentals/api/reference/permissions/) lists no Connectivity/VPC group. Needs a live probe (`GET /accounts/{id}/tokens/permission_groups`). Uploading the Worker itself needs "Workers Scripts Write" (same permissions page).
- Plan: "Available on Free and Paid plans." "While in beta, Workers VPC is available for free to all Workers plans." https://developers.cloudflare.com/workers-vpc/
- Beta caveat: "Features and APIs may change before general availability." Same page. TCP/VPC Network `connect()` is plaintext only.

## 2. Fetch semantics through a VPC Service binding

- URL host/port do NOT route: "The **host** provided in `fetch()` does not control routing. It only populates the `Host` header and, when using `https`, the Server Name Indication (SNI) value." And the port: "the port specified in the VPC Service configuration is always used." https://developers.cloudflare.com/workers-vpc/api/
- Host header: the fetch URL host populates it (quote above). So the Worker controls the Host header seen by Caddy via the URL host. Whether a manually set `Host` request header overrides: not documented.
- Absolute URL required: "must use absolute URLs including the protocol (`http`/`https`), host, and path." Same page. Scheme choice interacts with `http_port`/`https_port` being set (see section 1 quote); a service with only `http_port` plus an `https://` fetch: not documented.
- Streaming: not documented for `fetch()` on the binding (page says nothing). Returns a standard `Response`. Same page.
- WebSocket/Upgrade: not documented as supported. Troubleshooting lists error `http_upgrade_failed`: "An HTTP upgrade (for example, WebSocket) failed." with fix "confirm your service supports the requested protocol upgrade". Implies upgrade is attempted, not a support statement. https://developers.cloudflare.com/workers-vpc/reference/troubleshooting/
- Size/timeouts: "Standard Workers limits apply for request size, timeout, and subrequests." https://developers.cloudflare.com/workers-vpc/platform/limits/ . Workers numbers: Free 50 subrequests/invocation, 10 ms CPU (network waits excluded), "Individual subrequests have no set time limit"; request body cap is by the zone's CF plan (100 MB on Free). https://developers.cloudflare.com/workers/platform/limits/
- VPC-specific client errors: `connection_read_timeout` ("no data was received within the time limit"), `connection_limit_reached` ("maximum number of concurrent connections to your service"), `rate_limited` ("connection rate limit to this origin"). Thresholds: not documented. Troubleshooting URL above.

## 3. cloudflared with empty ingress

- Workers VPC does not use ingress. Quote (Cloudflare-owned repo, not docs site): "Workers VPC uses cloudflared's warp-routing service, not its ingress." and it "dials the Host:Port configured on the VPC Service". A public-hostname rule "does not catch VPC binding traffic". https://github.com/cloudflare/claude-managed-agents/blob/main/docs/connecting-to-private-services.md
- Docs site: ingress rules "are not required for Workers VPC as routing is handled by the VPC Service configuration." No public hostname needed. https://developers.cloudflare.com/workers-vpc/configuration/tunnel/
- Host resolved on the tunnel machine: "Cloudflared resolves the Host on the tunnel machine, not on Cloudflare's edge." The repo doc uses `localhost` ("this is what cloudflared dials on your machine"); get-started also uses `localhost` as a Host example. 127.0.0.1 literally: not documented anywhere I read, but implied. https://developers.cloudflare.com/workers-vpc/get-started/
- Private network route / WARP client: the Tunnel page says nothing on warp-routing or private network routes ("Not explicitly covered"). The repo doc says the `warp-routing` service is used, but says nothing about needing a Zero Trust route entry. Whether the tunnel config's `warp-routing.enabled` must be true: NOT documented. Config PUT schema lists only `ingress`/`originRequest`; `warp-routing` shows only in example responses. https://developers.cloudflare.com/api/resources/zero_trust/subresources/tunnels/subresources/cloudflared/subresources/configurations/methods/update/
- Config PUT quote: "At least one ingress rule needs to be defined for the tunnel." So an empty ingress is invalid; keep the `http_status:404` catch-all (same URL).
- Hard requirements: cloudflared "2025.7.0 or later", QUIC transport, outbound UDP 7844. HTTP/2 "prevents DNS resolution from Workers VPC". Tunnel page URL above.
- Risk signal: a community post reports a VPC Service to 127.0.0.1:8765 over a healthy QUIC tunnel where `fetch()` throws with no error code (could not open the page, 403; known only from the search snippet). https://community.cloudflare.com/t/workers-vpc-service-fetch-fails-without-error-code-or-metrics/975878 . Verdict: PROBE LIVE before the spec relies on 127.0.0.1.

## 4. Tunnel connectors

- `DELETE /accounts/{account_id}/cfd_tunnel/{tunnel_id}/connections[?client_id=<uuid>]`: "Removes a connection (aka Cloudflare Tunnel Connector) from a Cloudflare Tunnel independently of its current state." "If no connector id (client_id) is provided all connectors will be removed." "We recommend running this command after rotating tokens." Perms: "Cloudflare One Connectors Write" / "Cloudflare One Connector: cloudflared Write" / "Cloudflare Tunnel Write". https://developers.cloudflare.com/api/resources/zero_trust/subresources/tunnels/subresources/cloudflared/subresources/connections/methods/delete/
- Does it stop the running process? Docs call it "force-disconnect all existing connections" (compromise procedure). Whether cloudflared auto-reconnects with a still-valid token: not documented; the intended order is rotate first, then delete. https://developers.cloudflare.com/tunnel/advanced/tunnel-tokens/
- Token rotation: dashboard only ("Rotate token"). "After rotating the token, `cloudflared` cannot establish new connections with the old token." "Existing connectors remain active until restarted." No documented rotate API. Same tokens page. `PATCH /accounts/{id}/cfd_tunnel/{tunnel_id}` takes `tunnel_secret` ("password required to run a locally-managed tunnel"); whether it rotates the remote token: not documented (a community post says PATCHing a new secret kills the old token; not official). https://developers.cloudflare.com/api/resources/zero_trust/subresources/tunnels/subresources/cloudflared/methods/edit/
- Fetch token: `GET /accounts/{id}/cfd_tunnel/{tunnel_id}/token` ("Treat the token as a secret."). https://developers.cloudflare.com/api/resources/zero_trust/subresources/tunnels/subresources/cloudflared/subresources/token/methods/get/
- Count connectors: `GET /accounts/{id}/cfd_tunnel/{tunnel_id}/connections` returns an array of connector objects ("Lists the connections for a Cloudflare Tunnel, including connector IDs..."); count = `result | length` (inferred), each has `id`, `conns[]` (`origin_ip`, `colo_name`, `opened_at`). Single connector: `GET .../connectors/{connector_id}`. Tunnel-level state: `GET .../cfd_tunnel/{id}` gives `status` (inactive/degraded/healthy/down), `conns_active_at`. https://developers.cloudflare.com/api/resources/zero_trust/subresources/tunnels/subresources/cloudflared/subresources/connections/methods/get/

## 5. API tokens

- Account-owned create: `POST /accounts/{account_id}/tokens`, "Create a new Account Owned API token." Perm "Account API Tokens Write". Body: `name` (max 120), `policies`, `condition.request_ip`, `expires_on`, `not_before`. Response includes `value` ("The token value."). https://developers.cloudflare.com/api/resources/accounts/subresources/tokens/methods/create/
- User create: `POST /user/tokens`, perm "API Tokens Write". https://developers.cloudflare.com/api/resources/user/subresources/tokens/methods/create/
- Can a token mint tokens: yes. "you must create an API token in the Cloudflare dashboard that can create subsequent tokens." https://developers.cloudflare.com/fundamentals/api/how-to/create-via-api/ . Limit: "Account members may only grant account API tokens permissions which are a subset of their own account permissions." https://developers.cloudflare.com/fundamentals/api/get-started/account-owned-tokens/ . Creator needs "API Token Provisioning capabilities or Super Administrator status" (same page). A Terraform provider issue reports single-zone grants require the creator to hold them while all-zones and R2-bucket scopes do not (community, not official): https://github.com/cloudflare/terraform-provider-cloudflare/issues/7241
- R2 single-bucket resource: `"com.cloudflare.edge.r2.bucket.<ACCOUNT_ID>_<JURISDICTION>_<BUCKET_NAME>": "*"`; "For buckets outside a jurisdiction, this value will be `default`." Permission group `Workers R2 Storage Bucket Item Write` (or `... Read`). Object scoping only for "Object Read & Write"/"Object Read". https://developers.cloudflare.com/r2/api/tokens/ . The R2 page does not say whether the account-owned create endpoint accepts it; the Terraform issue suggests yes.
- Update in place: `PUT /accounts/{account_id}/tokens/{token_id}`, "Update an existing token."; body has `name`, `policies`, `condition`, `expires_on`, `not_before`, `status` (active|disabled|expired). Does the secret stay the same: not documented (inferred yes, since a separate roll endpoint exists). https://developers.cloudflare.com/api/resources/accounts/subresources/tokens/methods/update/
- Roll secret: `PUT /accounts/{id}/tokens/{token_id}/value`, "Roll the Account Owned API token secret." https://developers.cloudflare.com/api/resources/accounts/subresources/tokens/subresources/value/methods/update/
- Secret only at create: GET token "includes only a prefix and suffix, not the full token value" (`token_suffix` = "last 4 characters"). Inferred: value only at create/roll. https://developers.cloudflare.com/api/resources/accounts/subresources/tokens/methods/get/
- Find by name: `GET /accounts/{id}/tokens` supports only `direction`, `include_expired`, `page`, `per_page` (5-50); no name filter. Filter client-side on `name`. Perm "Account API Tokens Write" or "...Read". https://developers.cloudflare.com/api/resources/accounts/subresources/tokens/methods/list/

## 6. R2 S3 credentials from account-owned token

- Rule (not split by token type): "Access Key ID: The `id` of the API token." "Secret Access Key: The SHA-256 hash of the API token `value`." Account-owned tokens are described on the same page as a supported kind. https://developers.cloudflare.com/r2/api/tokens/
- Verify for account tokens: `GET /accounts/{account_id}/tokens/verify` returns `id`, `status`, `expires_on`. https://developers.cloudflare.com/api/resources/accounts/subresources/tokens/methods/verify/ . Also the create response carries the id directly, so verify is unnecessary at mint time (inferred).
- Endpoint: `https://<ACCOUNT_ID>.r2.cloudflarestorage.com` (R2 tokens page).

## Summary table

| Question | Answer (one line) | Confidence | Source URL |
|---|---|---|---|
| 1 create | POST /accounts/{a}/connectivity/directory/services {type:http,name,http_port,host:{ipv4,network:{tunnel_id}}} | documented | https://developers.cloudflare.com/workers-vpc/configuration/vpc-services/ |
| 1 wrangler | `wrangler vpc service create <n> --type http --tunnel-id <id> --ipv4 127.0.0.1 --http-port <p>` | documented (flags), composed | https://developers.cloudflare.com/workers-vpc/get-started/ |
| 1 upload binding | metadata.bindings entry `{type:"vpc_service",name,service_id}` | documented | https://developers.cloudflare.com/api/resources/workers/subresources/scripts/methods/update/ |
| 1 delete | DELETE .../connectivity/directory/services/{service_id} | documented | https://developers.cloudflare.com/api/resources/connectivity/subresources/directory/subresources/services/methods/delete |
| 1 limits | 1000 services/account; bindings/Worker not documented | documented / not documented | https://developers.cloudflare.com/workers-vpc/platform/limits/ |
| 1 token perms | Roles Connectivity Directory Admin/Bind/Read; token permission-group names not documented | not documented | https://developers.cloudflare.com/workers-vpc/configuration/vpc-services/ |
| 1 plan/beta | Free and Paid, free during beta, APIs may change | documented | https://developers.cloudflare.com/workers-vpc/ |
| 2 URL host/port | Host/port in URL ignored for routing; URL host fills Host header/SNI; service port always used | documented | https://developers.cloudflare.com/workers-vpc/api/ |
| 2 streaming/WS/limits | Not documented for fetch; only `http_upgrade_failed` error; standard Workers limits | not documented | https://developers.cloudflare.com/workers-vpc/reference/troubleshooting/ |
| 3 empty ingress | VPC uses warp-routing service, not ingress; ingress not required; catch-all still required by config API | documented (Cloudflare repo + docs) | https://github.com/cloudflare/claude-managed-agents/blob/main/docs/connecting-to-private-services.md |
| 3 127.0.0.1 / route | Host resolved on tunnel machine; no private route stated; `warp-routing.enabled` need unknown; community failure report | inferred / not documented | https://developers.cloudflare.com/workers-vpc/configuration/tunnel/ |
| 4 delete connections | Removes connectors, all if no client_id; docs pair it with token rotation | documented (process effect: inferred) | https://developers.cloudflare.com/tunnel/advanced/tunnel-tokens/ |
| 4 rotate token | Dashboard only; old token blocks NEW connections, running ones stay until restarted; no rotate API | documented | https://developers.cloudflare.com/tunnel/advanced/tunnel-tokens/ |
| 4 count connectors | GET .../connections, count result array | documented (count: inferred) | https://developers.cloudflare.com/api/resources/zero_trust/subresources/tunnels/subresources/cloudflared/subresources/connections/methods/get/ |
| 5 mint tokens | Yes; needs Account API Tokens Write (account) / API Tokens Write (user); subset-of-own-permissions rule | documented | https://developers.cloudflare.com/fundamentals/api/get-started/account-owned-tokens/ |
| 5 R2 one bucket | `com.cloudflare.edge.r2.bucket.<acct>_default_<bucket>`: "*" + group Workers R2 Storage Bucket Item Write | documented (format); account-token acceptance inferred | https://developers.cloudflare.com/r2/api/tokens/ |
| 5 PUT expires_on | PUT /accounts/{a}/tokens/{id} accepts expires_on; secret unchanged not stated | documented (field), inferred (secret) | https://developers.cloudflare.com/api/resources/accounts/subresources/tokens/methods/update/ |
| 5 secret at create / find by name | Value at create (and roll) only; list has no name filter | inferred / documented | https://developers.cloudflare.com/api/resources/accounts/subresources/tokens/methods/list/ |
| 6 S3 keys | key id = token id, secret = sha256(value); verify = GET /accounts/{a}/tokens/verify | documented | https://developers.cloudflare.com/r2/api/tokens/ |
