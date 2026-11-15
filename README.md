# KwikERP

Offline-first ERP for dairy, sweets and food businesses. Owned by AVIP Business
Solutions LLP. First customer (tenant #1): Troika Dairy Products Pvt Ltd,
brand Dugdh Dhara.

## Phases

| Phase | Scope | Status |
| --- | --- | --- |
| 0 | Core data model, item master import, POS screen mockups | In progress |
| 1a | Lean offline POS for company outlets (pilot DD3, then DD2, DD4, DD5, DD1 last) | Next |
| 1b | Plant-to-outlet transfers, indent, expiry, stock count, advance orders, dashboard | Planned |
| 2 | Distributor / dealer order management + salesman app | Planned |
| 3 | Milk procurement app (Samudra centres first) | Planned |
| 4 | Tally export, BOM and costing | Planned |

## Stack

- `apps/pos` – Flutter tablet app (Android first), local SQLite, works fully offline.
- `apps/api` – NestJS API on Node.js, PostgreSQL 16, hosted on the Hostinger VPS.
- `db/` – SQL migrations and seed data. `tools/` – data import scripts.
- APKs are built by GitHub Actions (added with the Flutter app).

## Repository layout

```
db/migrations/      schema, applied in order
db/seed/            tenant setup + Troika item master and prices
db/seed/source/     raw exports the seed is built from
tools/              scripts that build seed files from the raw exports
docs/               design notes and decisions
```

## Try the database locally

```bash
createdb kwikerp
psql -d kwikerp -f db/migrations/0001_core.sql
psql -d kwikerp -f db/seed/0001_troika_setup.sql
psql -d kwikerp -f db/seed/0002_troika_items.sql   # run from the repo root
```

Rebuild the item master after the pricing sheet changes:

```bash
python3 tools/build_item_master.py
```

See `docs/data-model.md` for how tenants, price levels, credit control and
offline sync work.
