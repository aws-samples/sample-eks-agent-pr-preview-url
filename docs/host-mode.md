# Host mode

There are two **routing modes** for reaching a Preview Environment on the shared
ALB. **Path mode** (the default) needs no DNS: previews live at
`<alb>/pr-<n>/`, with the `basePath` baked into the build. **Host mode**
addresses each preview as `pr-<n>.<baseDomain>` and serves the app at `/`, which
means the same image can be reused across PRs.

You select host mode with `routing.mode=host` (chart) or `--routing host`
(onboarding), plus a `baseDomain`.

## How it works

The shared ALB routes on the HTTP **`Host` header**, not on DNS. Each preview's
Ingress adds a host rule for `pr-<n>.<baseDomain>`; the ALB matches the incoming
`Host` header against those rules and forwards to the right Service. DNS is only
how a *browser* discovers the ALB's address — it is not part of the routing
decision itself.

That distinction is the whole trick: **you can verify host-mode routing with no
public domain at all**, by pointing a client at the ALB directly and sending the
right `Host` header.

## Two audiences

- **Local-verify user (no public domain).** You want to prove the routing works
  — host rules, TLS/SNI mechanics, `/api/health` reachable — without owning a
  domain or a Route 53 zone. Use the verify script and `LOCAL_VERIFY=1`.
- **Public-domain user.** You want real, browser-friendly `https://pr-<n>...`
  URLs. Create a Route 53 hosted zone for your base domain and a
  publicly-trusted ACM cert, wire them to the shared IngressClass, and previews
  resolve and validate for anyone.

## Verifying with no public domain

`scripts/verify-host-mode.sh <pr-number> [base-domain]` does it in two checks:

1. **HTTP host-rule check** — the minimal bar. It discovers the ALB hostname the
   Ingress was assigned, then:

   ```bash
   curl -fsS -H "Host: pr-<n>.<baseDomain>" "http://<alb>/api/health"
   ```

   No cert needed; this proves the host rule routes.

2. **HTTPS (SNI + host) check** — through the real TLS + SNI + host path. It
   resolves one current ALB IP and pins the name to it:

   ```bash
   curl -fsSk --resolve "pr-<n>.<baseDomain>:443:<alb-ip>" "https://pr-<n>.<baseDomain>/api/health"
   ```

   `--resolve` fakes the DNS answer; `-k` tolerates a self-signed or
   name-mismatched cert.

In CI, `scripts/ci-wait-ready.sh` honors `LOCAL_VERIFY=1`: in host mode it does
exactly the same `--resolve` + `-k` pinning to poll readiness against a current
ALB IP. With a real public domain, leave `LOCAL_VERIFY` unset and it uses normal
DNS + a trusted cert.

## The honest TLS constraint

Routing and TLS *mechanics* need no public domain — you can prove both over HTTP
or over HTTPS with a self-signed cert and `curl -k`. The **one** thing that
genuinely requires a public domain is a **publicly-trusted ACM certificate**:
that's what lets a normal browser reach `https://pr-<n>.<baseDomain>` without a
security warning. If you don't have a domain, verify the routing locally as
above; when you get one, add the Route 53 zone + ACM cert and the same previews
become publicly reachable with no code change.
