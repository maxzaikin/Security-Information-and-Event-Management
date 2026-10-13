# Security Information and Event Management

A working repository for everything SIEM: tooling, scripts, analytics and notes for operating commercial
SIEM platforms, vendor-agnostic security monitoring knowledge, and the development of an own SIEM.

The goal is to keep practical engineering work in one place: keeping platforms healthy, understanding
the data that flows through them, improving detection, and documenting procedures so that operations
do not depend on a single person or a single product.

## Structure

The repository is organised by platform. Each platform has its own top-level directory with independent
subprojects inside; vendor-agnostic material lives separately.

```
siem/
├── maxpatrol/          # MaxPatrol SIEM (Positive Technologies)
│   └── <subproject>/
├── <platform>/         # other SIEM platforms, one directory each
│   └── <subproject>/
├── <own-siem>/         # own SIEM development
└── common/             # vendor-agnostic: concepts, data models, detection logic, methodology
```

Each subproject is self-contained:

```
<subproject>/
├── README.md           # what it is, how to run it
├── ...                 # scripts, notebooks, rules, docs
└── requirements.txt    # if it has Python dependencies
```

## Scope

Areas covered across platforms:

| Area | Examples |
|---|---|
| **Platform operations** | Storage health and capacity, retention and rotation, backup and restore, service monitoring |
| **Data & analytics** | Event flow statistics, source coverage, normalization quality, capacity forecasting |
| **Detection engineering** | Normalization and correlation rules, detection gap analysis, testing on real attack data |
| **Log sources** | Onboarding and hardening of sources, audit policy, collection troubleshooting |
| **Automation** | Collection scripts, scheduled checks, reporting, integrations |
| **Runbooks** | Step-by-step procedures for routine and incident-time tasks |
| **SIEM development** | Architecture, ingestion, storage, correlation engine and UI of an own SIEM |

## Contents

| Platform | Subproject | Description | Status |
|---|---|---|---|
| MaxPatrol SIEM | [`maxpatrol/logspace-capacity/`](maxpatrol/logspace-capacity/) | LogSpace storage capacity: metrics collection, disk usage forecasting, rotation monitoring | active |

## Conventions

- Code comments and READMEs are in English; operational methodology may be in the team's language.
- Scripts that run on production servers are read-only by default and state explicitly when they change anything.
- Vendor documentation is referenced, not copied.
- Notebooks are committed without outputs.

After cloning, enable the repository git hooks once:

```bash
git config core.hooksPath .githooks
```

## Requirements

Requirements differ per subproject and are listed in each subproject's README.

## Disclaimer

This is an independent project and is not affiliated with or endorsed by any SIEM vendor.
Product names and trademarks belong to their respective owners.
Use the tools at your own risk and verify behaviour against the official documentation for your product version.

## License

See [LICENSE](LICENSE).
