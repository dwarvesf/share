# Spikes O1 and O2 for multi-member tenants (2026-11-13)

Run live on the Console Labs Cloudflare account (Workers Free plan) from the Mac Mini. Scripts: `share-design/spike-vpc/` in the session scratchpad (not committed; they read credentials from 1Password).

## O1: a Worker reaches a loopback server through a VPC Service

| Step | Result |
|---|---|
| Origin | Python HTTP server on `127.0.0.1:18765`, plain HTTP, echoes the Host header and request headers, `/stream` writes 5 chunks 0.5 s apart |
| Tunnel | `share-spike-vpc`, remote-managed, config = only the `http_status:404` catch-all (no public hostname, no DNS record); `cloudflared tunnel run` with the connector token; 4 connections registered |
| VPC Service | `wrangler vpc service create share-spike-vpc --type http --tunnel-id <id> --ipv4 127.0.0.1 --http-port 18765` (wrangler OAuth, account Super Admin) |
| Worker | `share-spike-vpc` on workers.dev, binding `vpc_services = [{binding = "MEMBER", service_id, remote = true}]`, fetches `http://s.console.so<path>` through the binding |
| GET `/hello?x=1` | `200`; origin saw `Host: s.console.so`, path and query intact, every request header passed through unchanged (including a test `cf-access-jwt-assertion`) |
| GET `/stream` | first byte 0.49 s, total 3.0 s: the body streams |
| Latency (5 requests, Worker-measured fetch time) | 151, 354, 328, 155, 197 ms |
| `warp-routing` | enabled in the first run; disabled in a second run: still `200`. Not needed |

Not tested: WebSocket upgrade through the binding (live port shares stay behind a later check); a member on a different machine and network (the origin ran on the same Mini as the tunnel; the path is the same).

Design consequences: the VPC Service object is required (one per member tunnel); the tunnel needs no ingress rule and no `warp-routing`; the Worker must strip Access headers itself because the binding forwards them.

## O2: the tool can mint member tokens

| Check | Result |
|---|---|
| Account-owned tokens (`/accounts/<a>/tokens`) | 403 with every stored token: none holds Account API Tokens rights on Console Labs |
| User tokens (`/user/tokens`) with `cf-tokens-admin` | list `200`; mint `200` (a Zone Read token on console.so, 1-day expiry) |
| Secret | returned only in the mint response; a later GET does not include it |
| Minted token | `/user/tokens/verify` = `active` |
| Extend expiry in place | `PUT /user/tokens/<id>` with the same policies and a new `expires_on`: `200`, expiry moved +1 day, secret unchanged |
| Find by name | the list shows `share-spike-mint`, so a rerun can find a half-made token |
| Bucket scope | permission group "Workers R2 Storage Bucket Item Write" exists with scope `com.cloudflare.edge.r2.bucket`; a bucket-scoped grant was not minted (Console Labs has no share bucket yet) |

Design consequences: v1 mints user-owned tokens with a separate minter token (`cf-tokens-admin` shape: API Tokens Read and Write only); account-owned tokens are the upgrade once a token with Account API Tokens Write exists. Member tokens die if the minting user leaves the account; recorded as a risk.

## Left in place for review

- Tunnel `share-spike-vpc`, VPC Service `share-spike-vpc`, Worker `share-spike-vpc` (Console Labs). The local cloudflared and echo server were stopped after the spike.
- User token `share-spike-mint` (Zone Read on console.so), expires 2026-11-15.
