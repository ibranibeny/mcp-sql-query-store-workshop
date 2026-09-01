# Workshop screenshot policy

No fake or illustrative screenshot belongs in this directory. Capture a screenshot only after its milestone is positively verified. Until then, the static site renders **Screenshot pending verified milestone** instead of a broken image.

The screenshot manifest is authoritative. `LocalVerified` requires an existing file and matching lowercase SHA-256. Azure captures remain `AzurePending` until a real deployment milestone passes; then update classification and hash in the same reviewed change.

Before capture, hide or redact credentials, tokens, connection strings, tenant/subscription IDs, public IPs, user names, local profile paths, certificate thumbprints/private material, unrelated resources, notifications, and browser/account chrome. Crop to the relevant product output. Never alter performance values or failure status.

Expected files:

- `local-home.png`
- `local-architecture.png`
- `local-memory-target.png`
- `azure-01-preflight.png`
- `azure-02-network.png`
- `azure-03-vms.png`
- `azure-04-sql-readiness.png`
- `azure-05-admin-readiness.png`
- `azure-06-workload.png`
- `azure-07-pages.png`