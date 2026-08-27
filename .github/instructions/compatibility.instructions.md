---
applyTo: "**/*.{yaml,yml,sh,bash,md}"
---

# Compatibility workflow

Preserve existing fixtures and resource identities for additive changes. For a
breaking KRO schema, create a new Kind/RGD, run both versions, add migration and
rollback fixtures, and keep retirement out of the implementation change. Pin
all sources and record the first/last compatible controller versions.
