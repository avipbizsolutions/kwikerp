# Data model (core + Phase 1)

Schema: `db/migrations/0001_core.sql` (PostgreSQL 16, schema `kwik`).

## Organisation

| Table | Purpose |
| --- | --- |
| `tenant` | One customer of KwikERP (Troika = tenant #1). |
| `company` | A legal entity with its own GSTIN; a tenant can have several. |
| `location` | Plant, outlet, franchise, milk centre or godown. Holds stock. |
| `device` | A registered tablet/phone at a location. Its code is part of every document number it issues. |
| `app_user`, `role`, `user_role` | Users with PIN login on tablets; roles carry permission strings; a role can be limited to one location. |

## Items and prices

- `unit`: PC, KG, L, TRAY, BOX (rows, not code).
- `item`: one product. `base_unit_id` is the smallest unit sold (a pouch, a cup, a kg of loose sweet). `sold_by_weight` items read the scale.
- `item_pack`: other units the item moves in, with `factor` = base units per pack. Dahi 200 g: base PC, TRAY factor 6. Gold milk: base PC (500 ml pouch), L factor 2.
- `price_level`: open-ended list (Consumer, Retailer, Distributor, Franchisee, Special today). A new channel is a new row. `derive_from_id` + `derive_pct` can fill a new level from an existing one.
- `item_price`: price of an item, in a unit, at a level, from a date (`valid_from`), optionally for one location. Price history is kept; the view `item_price_current` gives today's price.

Price lookup at billing: item + unit + the customer's level (customer override, else category default, else the outlet's default) + today; a location-specific row wins over the all-locations row.

## Customers and credit control

- `customer_category`: Consumer, Retailer, Distributor, Sahyogi, Franchisee (open-ended), each with a default price level.
- `customer`: optional own `price_level_id`, `security_amount` (deposit/cheques held), `opening_balance`.
- `credit_limit`: either for a category or for one customer. Checks: `max_outstanding`, `max_days` (age of oldest unpaid bill), `cap_to_security`. A valid customer row overrides the category row (view `customer_credit_limit`). Temporary raises use `valid_to`.
- Seeded category limits are Rs 0, so every credit bill needs approval until management sets real limits.
- `credit_approval`: created when a bill breaks a limit. Status `pending → approved/rejected/expired/withdrawn`; decision `once` or `raise_limit`; `offline_request_code` supports approval by phone with a one-time code.
- `customer_outstanding` view: opening balance + final bills − returns − receipts.

## Billing

- `shift`: cashier shift with opening cash, counted cash, expected cash.
- `sales_invoice` (+ `sales_invoice_line`): statuses `draft`, `held`, `pending_approval`, `final`, `cancelled`; doc types `INV`, `RET` (return), `EST`. Lines copy the rate, list rate, GST rate, HSN and pack factor at the time of sale, so later master changes never alter old bills.
- `receipt`: money in (cash, UPI, card, cheque, bank) against a bill or against dues.
- `doc_series`: per device + doc type + financial year. The device numbers bills itself (`DD3-T1-2627-000124`); the server records the highest number seen.

## Stock

- `stock_move`: every change in base units (+ in, − out). Stock on hand = sum (view `stock_on_hand`).
- `stock_transfer` (+ lines): plant to outlet, `dispatched → received`, with received quantities to capture shortages (Phase 1b).
- `batch`: batch number and expiry for short-life items (Phase 1b).

## Offline sync

1. The tablet keeps a local SQLite copy of the masters it needs and writes every bill, receipt and stock move locally first, with its own UUID.
2. **Push:** unsynced rows are sent in order; the server upserts by id (idempotent, so a retry after a dropped connection never duplicates a bill).
3. **Pull:** the tablet asks for every row with `server_seq` greater than its last cursor (prices, items, customers, limits, approvals), for its tenant and location.
4. Deletes are soft (`deleted_at`) so they sync like any other change.

## Multi-tenancy

Every table except `tenant` has `tenant_id` and a row-level-security policy on `app.tenant_id`. The API sets `app.tenant_id` per request and connects as a role that does not own the tables (owners bypass RLS).
