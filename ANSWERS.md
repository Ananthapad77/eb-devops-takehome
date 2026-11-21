# Q1: Migrating ~40 Ingresses from ingress-nginx to Gateway API

**Approach:** run both side by side and move traffic slowly. ingress-nginx stays up as the fallback until the end.

**Order:**
1. List all 40 Ingresses and note what each one uses: annotations, rewrites, auth, timeouts, TLS, snippets. Pick a Gateway API implementation and check it covers those.
2. Install the Gateway API CRDs and the new controller next to ingress-nginx, with its own load balancer address.
3. Convert the least important Ingress first, and test it by calling the new address directly, without changing DNS.
4. Convert the rest in small batches. Compare the responses on old and new for each one.
5. Switch traffic per host with DNS (low TTL), or weighted if possible. Start with a small share, watch error rates and latency, then increase.
6. Keep ingress-nginx for a while after 100%, then remove it.

**What I expect to break:**
- Annotations and configuration snippets have no direct equivalent. Rewrites, auth, rate limits and timeouts will need different config.
- TLS and cert-manager need new setup.
- Path matching and header behaviour can differ slightly.
- Dashboards, alerts, logs and any WAF rules tied to nginx.

**Risk control:** one service at a time, a rollback that only needs a DNS change, and a stop rule (for example error rate above normal).
