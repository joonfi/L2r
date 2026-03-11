# Upgrade Path & Known Issues

## Upgrade Path (1.x)
- New flags optional; no breaking changes without deprecation.
- Service topology preserved (Traefik→Nginx→Drupal; ProxySQL→MariaDB primary/replica).

## Known Issues (v1.0.0)
- First run can be slow (Composer + install).
- Traefik dashboard is dev‑only and bound to 127.0.0.1.
- Redis is mandatory; failures abort install by design.
- Port conflicts require `--ports` overrides.
