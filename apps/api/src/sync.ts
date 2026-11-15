import { BadRequestException, Body, Controller, Get, Post, Query, Req, UseGuards } from '@nestjs/common';
import { PoolClient } from 'pg';
import { AuthGuard, Session } from './auth';
import { Db } from './db';

/**
 * Offline sync for tablets.
 *
 * Pull: everything changed since the device's cursor (server_seq). A small
 * overlap is re-sent on purpose, because a transaction that started earlier can
 * commit after a later one; re-sent rows are harmless (the tablet upserts).
 *
 * Push: documents created on the tablet, upserted by their UUID, so a retry
 * after a dropped connection never creates duplicates. The tablet always sends
 * whole rows (not partial updates).
 */
const PULL_OVERLAP = 500;

// Masters a tablet needs, with an optional extra filter: 'location' compares
// with the device's outlet, 'device' with the device itself (both as $2).
const PULL_TABLES: Record<string, { where?: string; by?: 'location' | 'device' }> = {
  company: {},
  location: {},
  price_level: {},
  unit: {},
  item_category: {},
  item: {},
  item_pack: {},
  item_price: { where: 'AND (location_id IS NULL OR location_id = $2)', by: 'location' },
  customer_category: {},
  customer: {},
  credit_limit: {},
  credit_approval: { where: 'AND location_id = $2', by: 'location' },
  doc_series: { where: 'AND device_id = $2', by: 'device' },
  app_user: {},
};

// Columns a device may write, per table. tenant_id is always forced from the session.
const PUSH_COLUMNS: Record<string, string[]> = {
  customer: ['id', 'code', 'name', 'category_id', 'phone', 'gstin', 'state_code', 'address', 'home_location_id'],
  shift: ['id', 'location_id', 'device_id', 'user_id', 'opened_at', 'opening_cash', 'closed_at',
    'counted_cash', 'expected_cash', 'note'],
  sales_invoice: ['id', 'company_id', 'location_id', 'device_id', 'shift_id', 'doc_type', 'doc_no', 'doc_date',
    'status', 'customer_id', 'price_level_id', 'place_of_supply', 'against_invoice_id', 'subtotal', 'discount',
    'taxable', 'cgst', 'sgst', 'igst', 'cess', 'round_off', 'total', 'paid', 'balance', 'created_by',
    'finalised_at', 'cancelled_by', 'cancel_reason', 'note'],
  sales_invoice_line: ['id', 'invoice_id', 'line_no', 'item_id', 'unit_id', 'qty', 'factor', 'rate', 'list_rate',
    'rate_overridden_by', 'discount', 'hsn', 'gst_rate', 'taxable', 'cgst', 'sgst', 'igst', 'cess', 'amount',
    'batch_id'],
  receipt: ['id', 'location_id', 'device_id', 'shift_id', 'doc_no', 'doc_date', 'customer_id', 'invoice_id', 'mode',
    'amount', 'reference', 'created_by', 'status'],
  stock_move: ['id', 'location_id', 'item_id', 'batch_id', 'qty', 'move_type', 'doc_id', 'move_date', 'reason',
    'created_by'],
  credit_approval: ['id', 'invoice_id', 'customer_id', 'location_id', 'requested_by', 'requested_at', 'reasons',
    'outstanding', 'bill_amount', 'limit_amount', 'oldest_due_days', 'status', 'decision', 'decided_by',
    'decided_at', 'decision_note', 'offline_request_code'],
};

// Push order matters for foreign keys.
const PUSH_ORDER = ['customer', 'shift', 'sales_invoice', 'sales_invoice_line', 'receipt', 'stock_move', 'credit_approval'];

// Tables whose rows belong to the pushing device's outlet.
const LOCATION_BOUND = new Set(['shift', 'sales_invoice', 'receipt', 'stock_move', 'credit_approval']);
const DEVICE_BOUND = new Set(['shift', 'sales_invoice', 'receipt']);

// A finalised or cancelled bill is never overwritten, except to cancel it.
const UPDATE_GUARD: Record<string, string> = {
  sales_invoice: `WHERE sales_invoice.status IN ('draft','held','pending_approval')
                     OR (sales_invoice.status = 'final' AND EXCLUDED.status = 'cancelled')`,
  sales_invoice_line: `WHERE (SELECT status FROM sales_invoice WHERE id = EXCLUDED.invoice_id)
                         IN ('draft','held','pending_approval','final')`,
  receipt: `WHERE receipt.status = 'final' AND EXCLUDED.status = 'cancelled'`,
  stock_move: 'WHERE false',
  credit_approval: `WHERE credit_approval.status = 'pending'`,
};

export async function outstandingSnapshot(c: PoolClient) {
  // Outstanding per customer and the age of the oldest unpaid credit bill (FIFO).
  const rows = (await c.query(
    `SELECT o.customer_id, o.outstanding::float AS outstanding
       FROM customer_outstanding o WHERE o.outstanding <> 0`)).rows;
  const bills = (await c.query(
    `SELECT customer_id, doc_date, balance::float AS balance
       FROM sales_invoice
      WHERE status = 'final' AND doc_type = 'INV' AND balance > 0 AND deleted_at IS NULL
      ORDER BY customer_id, doc_date DESC`)).rows;
  const byCustomer = new Map<string, { doc_date: Date; balance: number }[]>();
  for (const b of bills) {
    const list = byCustomer.get(b.customer_id) ?? [];
    list.push(b);
    byCustomer.set(b.customer_id, list);
  }
  const today = Date.now();
  return rows.map((r) => {
    let left = r.outstanding;
    let oldest: Date | null = null;
    for (const b of byCustomer.get(r.customer_id) ?? []) {
      if (left <= 0) break;
      oldest = b.doc_date;
      left -= b.balance;
    }
    const oldestDays = oldest ? Math.floor((today - new Date(oldest).getTime()) / 86_400_000) : 0;
    return { customer_id: r.customer_id, outstanding: r.outstanding, oldest_due_days: oldestDays };
  });
}

@Controller('sync')
@UseGuards(AuthGuard)
export class SyncController {
  constructor(private readonly db: Db) {}

  @Get('pull')
  async pull(@Req() req: any, @Query('since') sinceRaw?: string) {
    const s: Session = req.session;
    if (!s.deviceId) throw new BadRequestException('Only registered tablets can sync');
    const since = Math.max(0, Number(sinceRaw ?? 0) - PULL_OVERLAP);
    return this.db.tx(s.tenantId, async (c) => {
      const tables: Record<string, any[]> = {};
      let cursor = Number(sinceRaw ?? 0);
      for (const [table, f] of Object.entries(PULL_TABLES)) {
        const cols = table === 'app_user' ? 'id, name, phone, is_active, server_seq, deleted_at' : '*';
        const params: unknown[] = [since];
        if (f.by === 'location') params.push(s.locationId);
        if (f.by === 'device') params.push(s.deviceId);
        const { rows } = await c.query(
          `SELECT ${cols} FROM ${table} WHERE server_seq > $1 ${f.where ?? ''} ORDER BY server_seq`, params);
        tables[table] = rows;
        for (const r of rows) cursor = Math.max(cursor, Number(r.server_seq));
      }
      await c.query('UPDATE device SET last_seen_at = now(), last_pull_seq = $2 WHERE id = $1', [s.deviceId, cursor]);
      return { cursor, tables, outstanding: await outstandingSnapshot(c), serverTime: new Date().toISOString() };
    });
  }

  @Post('push')
  async push(@Req() req: any, @Body() body: Record<string, any[]>) {
    const s: Session = req.session;
    if (!s.deviceId || !s.locationId) throw new BadRequestException('Only registered tablets can sync');
    const counts: Record<string, number> = {};
    await this.db.tx(s.tenantId, async (c) => {
      for (const table of PUSH_ORDER) {
        const rows = body?.[table];
        if (!Array.isArray(rows) || rows.length === 0) continue;
        const cols = PUSH_COLUMNS[table];
        let n = 0;
        for (const raw of rows) {
          if (!raw?.id) throw new BadRequestException(`${table}: every row needs an id`);
          const row: Record<string, any> = { ...raw };
          if (LOCATION_BOUND.has(table)) row.location_id = s.locationId;
          if (DEVICE_BOUND.has(table)) row.device_id = s.deviceId;
          const present = cols.filter((k) => k in row);
          const names = ['tenant_id', ...present];
          const values = [s.tenantId, ...present.map((k) => row[k])];
          const placeholders = values.map((_, i) => `$${i + 1}`).join(', ');
          const updates = present.filter((k) => k !== 'id').map((k) => `${k} = EXCLUDED.${k}`).join(', ');
          const guard = UPDATE_GUARD[table] ?? '';
          const sql = `INSERT INTO ${table} (${names.join(', ')}) VALUES (${placeholders})
                       ON CONFLICT (id) DO ${updates ? `UPDATE SET ${updates} ${guard}` : 'NOTHING'}`;
          const res = await c.query(sql, values);
          n += res.rowCount ?? 0;
        }
        counts[table] = n;
      }

      // Keep the server's view of each device's numbering up to date.
      await c.query(
        `INSERT INTO doc_series (tenant_id, device_id, doc_type, fin_year, prefix, last_no)
         SELECT $1, $2, i.doc_type, split_part(i.doc_no, '-', 3),
                regexp_replace(i.doc_no, '[0-9]+$', ''), max(substring(i.doc_no from '([0-9]+)$')::int)
           FROM sales_invoice i
          WHERE i.device_id = $2 AND i.doc_no IS NOT NULL
          GROUP BY i.doc_type, split_part(i.doc_no, '-', 3), regexp_replace(i.doc_no, '[0-9]+$', '')
         ON CONFLICT (device_id, doc_type, fin_year)
         DO UPDATE SET last_no = GREATEST(doc_series.last_no, EXCLUDED.last_no), prefix = EXCLUDED.prefix`,
        [s.tenantId, s.deviceId]);
    });
    return { ok: true, applied: counts };
  }
}
