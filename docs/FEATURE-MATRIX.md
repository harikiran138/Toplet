# Feature matrix

The matrix is split by area to keep each file readable. **Status of every feature (PASS / PARTIAL / BLOCKED / FAIL / NOT IMPLEMENTED) is in `FINAL-DELIVERY-REPORT.md` §C.**

| Part | Areas | File |
|---|---|---|
| A–D | Dynamic Island interface, media, system monitoring, live activities | [FEATURE-MATRIX-A.md](FEATURE-MATRIX-A.md) |
| E–G | Productivity tools, lock-screen widgets, settings; also AI-usage readers, extensions, weather, updates and the full Defaults-key table | [FEATURE-MATRIX-B.md](FEATURE-MATRIX-B.md) |

Every row in those files records: source file and entry point, owning component, UI entry point, underlying service/API, required permission, third-party app or account, offline availability, payment/account requirement, public vs private API, and the settings key. They describe the **code**. Nothing in them says a feature works; the only runtime evidence is in `TEST-RESULTS.md`.

Related: `FREE-LOCAL-OPERATION.md` (offline/payment classification), `MACOS-PERMISSIONS.md`, `DEPENDENCY-AND-LICENSE-AUDIT.md`.
