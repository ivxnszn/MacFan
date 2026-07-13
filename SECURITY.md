# Security and hardware safety

Please do not report private fan-control keys, helper credentials, or machine-specific telemetry in a public issue.

MacFan uses a deliberately narrow, local root helper. It accepts validated semantic fan requests, authenticates the local app and user, clamps requests to discovered hardware limits, and restores macOS/System control when its heartbeat expires.

Apple Silicon fan writes use private, unsupported interfaces. Hardware behavior can change across macOS and firmware releases. The helper is best-effort and may remain monitoring-only on some Macs.

For a suspected safety or security issue, open a private GitHub security advisory instead of posting reproduction details publicly. Include the macOS version, MacFan version, and a sanitized description; never include your telemetry database or administrator password.
