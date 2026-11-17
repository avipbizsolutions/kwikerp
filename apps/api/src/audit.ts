import {
  BadRequestException, Body, Controller, ForbiddenException, Get, Post, Query, Req, UseGuards,
} from '@nestjs/common';
import { PoolClient } from 'pg';
import { AuthGuard, can, inScope, Needs, scopeOf, Session } from './auth';
import { config } from './config';
import { Db } from './db';
import { ADJUST_REASONS } from './stock';
import { isDate, localDate, mrpMap, needUuid } from './util';

/**
 * Accounts' audit: one outlet, one day, on one screen (money, stock,
 * exceptions), marked Verified or Query; and the audit reports Owners and
 * Managers read. Accounts sends the WhatsApp summary by hand.
 */
function canSee(s: Session) {
  if (!can(s, 'audit.view') && !can(s, 'audit.verify')) throw new ForbiddenException('Needs permission audit.view');
}

const r2 = (n: number) => Math.round((Number(n) || 0) * 100) / 100;
const r3 = (n: number) => Math.round((Number(n) || 0) * 1000) / 1000;
const inr = (n: number) => `Rs ${r2(n).toLocaleString('en-IN')}`;

function range(from?: string, to?: string) {
  const t = isDate(to) ? to! : localDate();
  const f = isDate(from) ? from! : t;
  if (f > t) throw new BadRequestException('From date is after To date');
  return { from: f, to: t };
}

@Controller('audit')
@UseGuards(AuthGuard)
export class AuditController {
  constructor(private readonly db: Db) {}

  @Get('day')
  day(@Req() req: any, @Query('location') loc: string, @Query('date') date: string) {
    const s: Session = req.session;
    canSee(s);
    if (!isDate(date)) throw new BadRequestException('Choose the date');
    return this.db.tx(s.tenantId, async (c) => {
      const l = (await c.query('SELECT id, code, name FROM location WHERE id = $1 AND deleted_at IS NULL',
        [needUuid(loc, 'Outlet')])).rows[0];
      if (!l) throw new BadRequestException('Unknown outlet');
      if (!inScope(s, l.id)) throw new ForbiddenException('Not your location');
      return { location: l, date, ...(await this.dayData(c, l.id, date)) };
    });
  }

  private async dayData(c: PoolClient, loc: string, date: string) {
    const modes = Object.fromEntries((await c.query(
      `SELECT mode, sum(amount)::float AS amount FROM receipt
        WHERE location_id = $1 AND doc_date = $2 AND status = 'final' AND deleted_at IS NULL GROUP BY mode`,
      [loc, date])).rows.map((r: any) => [r.mode, r2(r.amount)]));
    const sales = (await c.query(
      `SELECT count(*)::int AS bills, coalesce(sum(total), 0)::float AS total,
              coalesce(sum(balance) FILTER (WHERE balance > 0), 0)::float AS credit,
              count(*) FILTER (WHERE balance > 0)::int AS credit_bills
         FROM sales_invoice WHERE location_id = $1 AND doc_date = $2 AND status = 'final' AND doc_type = 'INV'
          AND deleted_at IS NULL`, [loc, date])).rows[0];
    const shifts = (await c.query(
      `SELECT sh.opened_at, sh.closed_at, sh.opening_cash::float AS opening, sh.expected_cash::float AS expected,
              sh.counted_cash::float AS counted, u.name AS cashier, d.code AS device
         FROM shift sh JOIN app_user u ON u.id = sh.user_id JOIN device d ON d.id = sh.device_id
        WHERE sh.location_id = $1 AND (sh.opened_at AT TIME ZONE $3)::date = $2 AND sh.deleted_at IS NULL
        ORDER BY sh.opened_at`, [loc, date, config.timeZone])).rows;

    const mrp = await mrpMap(c);
    const stock = (await c.query(
      `SELECT m.item_id, i.code, i.name,
              coalesce(sum(m.qty) FILTER (WHERE m.move_date < $2), 0)::float AS opening,
              coalesce(sum(m.qty) FILTER (WHERE m.move_date = $2 AND m.move_type = 'transfer_in'), 0)::float AS received,
              coalesce(-sum(m.qty) FILTER (WHERE m.move_date = $2 AND m.move_type IN ('sale','sale_return')), 0)::float AS sold,
              coalesce(-sum(m.qty) FILTER (WHERE m.move_date = $2 AND m.move_type = 'transfer_out'), 0)::float AS returned,
              coalesce(sum(m.qty) FILTER (WHERE m.move_date = $2 AND m.move_type NOT IN
                ('transfer_in','transfer_out','sale','sale_return')), 0)::float AS adjusted,
              coalesce(sum(m.qty), 0)::float AS closing
         FROM stock_move m JOIN item i ON i.id = m.item_id
        WHERE m.location_id = $1 AND m.move_date <= $2 AND m.deleted_at IS NULL
        GROUP BY m.item_id, i.code, i.name, i.pos_sort
       HAVING sum(m.qty) <> 0 OR bool_or(m.move_date = $2)
        ORDER BY i.pos_sort, i.name`, [loc, date])).rows;
    const counted = new Map((await c.query(
      `SELECT DISTINCT ON (cl.item_id) cl.item_id, cl.counted::float AS counted, cl.system_qty::float AS system_qty
         FROM stock_count_line cl JOIN stock_count k ON k.id = cl.count_id
        WHERE k.location_id = $1 AND (k.finished_at AT TIME ZONE $3)::date = $2 AND k.deleted_at IS NULL
        ORDER BY cl.item_id, k.finished_at DESC`, [loc, date, config.timeZone])).rows.map((r: any) => [r.item_id, r]));
    let diffValue = 0;
    for (const r of stock) {
      for (const k of ['opening', 'received', 'sold', 'returned', 'adjusted', 'closing']) r[k] = r3(r[k]);
      const k = counted.get(r.item_id);
      r.counted = k ? k.counted : null;
      r.diff = k ? r3(k.counted - k.system_qty) : null;
      r.value = k ? r2(r.diff * (mrp.get(r.item_id) ?? 0)) : null;
      if (r.value) diffValue += r.value;
    }

    const cancelled = (await c.query(
      `SELECT si.doc_no, si.total::float AS total, si.cancel_reason, u.name AS by
         FROM sales_invoice si LEFT JOIN app_user u ON u.id = si.cancelled_by
        WHERE si.location_id = $1 AND si.doc_date = $2 AND si.status = 'cancelled' AND si.deleted_at IS NULL`, [loc, date])).rows;
    const belowRate = (await c.query(
      `SELECT count(*)::int AS n FROM sales_invoice_line sl JOIN sales_invoice si ON si.id = sl.invoice_id
        WHERE si.location_id = $1 AND si.doc_date = $2 AND si.status = 'final' AND sl.deleted_at IS NULL
          AND sl.list_rate IS NOT NULL AND sl.rate < sl.list_rate`, [loc, date])).rows[0].n;
    const overLimit = (await c.query(
      `SELECT count(*)::int AS n FROM credit_approval a JOIN sales_invoice si ON si.id = a.invoice_id
        WHERE a.location_id = $1 AND si.doc_date = $2 AND a.status = 'approved' AND a.deleted_at IS NULL`, [loc, date])).rows[0].n;
    const transfers = (await c.query(
      `SELECT t.doc_no, t.kind, t.status, t.has_difference, f.code AS from_code, tl.code AS to_code,
              (SELECT string_agg(i.name || ' ' || to_char(x.qty_sent, 'FM999990.###') || '→' ||
                                 to_char(x.qty_received, 'FM999990.###') || ' (' || x.reason || ')', ', ')
                 FROM stock_transfer_line x JOIN item i ON i.id = x.item_id
                WHERE x.transfer_id = t.id AND x.reason IS NOT NULL AND x.deleted_at IS NULL AND x.qty_received IS NOT NULL) AS differences
         FROM stock_transfer t JOIN location f ON f.id = t.from_location_id JOIN location tl ON tl.id = t.to_location_id
        WHERE (t.to_location_id = $1 OR t.from_location_id = $1) AND t.deleted_at IS NULL
          AND (t.doc_date = $2 OR (t.received_at AT TIME ZONE $3)::date = $2)`, [loc, date, config.timeZone])).rows;
    const adjustments = (await c.query(
      `SELECT a.status, a.reason, a.qty::float AS qty, a.value::float AS value, i.name AS item
         FROM stock_adjustment a JOIN item i ON i.id = a.item_id
        WHERE a.location_id = $1 AND (a.requested_at AT TIME ZONE $3)::date = $2 AND a.deleted_at IS NULL`,
      [loc, date, config.timeZone])).rows;
    const status = (await c.query(
      `SELECT a.status, a.upi_matched, a.note, a.checked_at, u.name AS checked_by
         FROM audit_day a JOIN app_user u ON u.id = a.checked_by WHERE a.location_id = $1 AND a.day = $2`, [loc, date])).rows[0] ?? null;

    const exceptions: { count: number; text: string; level: 'warn' | 'info' | 'ok' }[] = [];
    const cancelledSum = r2(cancelled.reduce((t: number, x: any) => t + x.total, 0));
    exceptions.push({ count: cancelled.length, level: cancelled.length ? 'warn' : 'ok',
      text: cancelled.length ? `Bills cancelled (${inr(cancelledSum)}): ${cancelled.map((x: any) =>
        `${x.doc_no ?? ''} by ${x.by ?? '?'}${x.cancel_reason ? ` – ${x.cancel_reason}` : ''}`).join('; ')}` : 'Bills cancelled' });
    exceptions.push({ count: belowRate, level: belowRate ? 'warn' : 'ok', text: 'Bill lines below the rate list' });
    exceptions.push({ count: overLimit, level: overLimit ? 'info' : 'ok', text: 'Credit bills approved over the limit' });
    const short = transfers.filter((t: any) => t.has_difference);
    exceptions.push({ count: short.length, level: short.length ? 'warn' : 'ok',
      text: short.length ? `Receipt differences: ${short.map((t: any) => `${t.doc_no} ${t.differences ?? ''}`).join('; ')}` : 'Dispatch / return differences' });
    const pend = adjustments.filter((a: any) => a.status === 'pending');
    exceptions.push({ count: adjustments.length, level: pend.length ? 'warn' : adjustments.length ? 'info' : 'ok',
      text: adjustments.length ? `Stock adjustments asked: ${adjustments.map((a: any) =>
        `${a.item} ${a.qty > 0 ? '+' : ''}${a.qty} ${ADJUST_REASONS[a.reason] ?? a.reason} (${a.status})`).join('; ')}` : 'Stock adjustments asked' });
    const cashDiff = shifts.filter((x: any) => x.counted !== null && x.expected !== null && Math.abs(x.counted - x.expected) >= 1);
    exceptions.push({ count: cashDiff.length, level: cashDiff.length ? 'warn' : 'ok', text: 'Shifts with cash short or extra' });

    return {
      money: {
        sales: r2(sales.total), bills: sales.bills, cash: modes.cash ?? 0, upi: modes.upi ?? 0, card: modes.card ?? 0,
        other: r2(Object.entries(modes).filter(([m]) => !['cash', 'upi', 'card'].includes(m)).reduce((t, [, v]) => t + Number(v), 0)),
        credit: r2(sales.credit), creditBills: sales.credit_bills,
        shifts: shifts.map((x: any) => ({ ...x, diff: x.counted === null || x.expected === null ? null : r2(x.counted - x.expected) })),
      },
      stock, stockDiffValue: r2(diffValue), exceptions, transfers, status,
    };
  }

  @Post('day')
  @Needs('audit.verify')
  mark(@Req() req: any, @Body() b: { location: string; date: string; status: 'verified' | 'query'; upiMatched?: boolean; note?: string }) {
    const s: Session = req.session;
    if (!isDate(b?.date)) throw new BadRequestException('Choose the date');
    if (!['verified', 'query'].includes(b?.status)) throw new BadRequestException('Status must be verified or query');
    if (b.status === 'query' && !b.note?.trim()) throw new BadRequestException('Write what the query is about');
    return this.db.tx(s.tenantId, async (c) => {
      const loc = needUuid(b.location, 'Outlet');
      if (!inScope(s, loc)) throw new ForbiddenException('Not your location');
      await c.query(
        `INSERT INTO audit_day (tenant_id, location_id, day, status, upi_matched, note, checked_by)
         VALUES ($1, $2, $3, $4, $5, $6, $7)
         ON CONFLICT (location_id, day) DO UPDATE SET status = EXCLUDED.status, upi_matched = EXCLUDED.upi_matched,
                note = EXCLUDED.note, checked_by = EXCLUDED.checked_by, checked_at = now()`,
        [s.tenantId, loc, b.date, b.status, !!b.upiMatched, b.note?.trim() || null, s.userId]);
      await c.query(
        `INSERT INTO audit_log (tenant_id, user_id, action, entity, entity_id, detail) VALUES ($1, $2, $3, 'audit_day', $4, $5)`,
        [s.tenantId, s.userId, `audit.${b.status}`, loc, JSON.stringify(b)]);
      return { ok: true };
    });
  }

  /** Last N days per outlet: verified, query, waiting (days with activity and no check). */
  @Get('overview')
  overview(@Req() req: any, @Query('days') days = '7') {
    const s: Session = req.session;
    canSee(s);
    const n = Math.min(Math.max(Number(days) || 7, 1), 62);
    return this.db.tx(s.tenantId, async (c) => (await c.query(
      `WITH d AS (SELECT generate_series(($2::date - ($1::int - 1)), $2::date, '1 day')::date AS day),
       act AS (SELECT DISTINCT location_id, doc_date AS day FROM sales_invoice WHERE deleted_at IS NULL AND status = 'final'
               UNION SELECT DISTINCT location_id, move_date FROM stock_move WHERE deleted_at IS NULL)
       SELECT l.id, l.code, l.name,
              count(*) FILTER (WHERE a.status = 'verified')::int AS verified,
              count(*) FILTER (WHERE a.status = 'query')::int AS query,
              count(*) FILTER (WHERE a.status IS NULL AND act.day IS NOT NULL)::int AS waiting,
              array_agg(d.day ORDER BY d.day) FILTER (WHERE a.status IS NULL AND act.day IS NOT NULL) AS waiting_days
         FROM location l CROSS JOIN d
         LEFT JOIN audit_day a ON a.location_id = l.id AND a.day = d.day
         LEFT JOIN act ON act.location_id = l.id AND act.day = d.day
        WHERE l.deleted_at IS NULL AND l.is_active AND l.kind IN ('outlet','franchise')
          AND ($3::uuid[] IS NULL OR l.id = ANY($3::uuid[]))
        GROUP BY l.id, l.code, l.name ORDER BY l.code`, [n, localDate(), scopeOf(s)])).rows);
  }

  /** Audit reports, as a table for the page (and Excel) plus a short summary to send on WhatsApp. */
  @Get('report')
  report(@Req() req: any, @Query('type') type: string, @Query('from') fromQ?: string, @Query('to') toQ?: string) {
    const s: Session = req.session;
    canSee(s);
    const { from, to } = range(fromQ, toQ);
    const scope = scopeOf(s);
    const tz = config.timeZone;
    return this.db.tx(s.tenantId, async (c) => {
      const when = from === to ? from : `${from} to ${to}`;
      if (type === 'daily') {
        const rows = (await c.query(
          `WITH d AS (SELECT generate_series($1::date, $2::date, '1 day')::date AS day)
           SELECT d.day::text AS date, l.code AS outlet,
                  (SELECT coalesce(sum(total), 0) FROM sales_invoice WHERE location_id = l.id AND doc_date = d.day
                     AND status = 'final' AND doc_type = 'INV' AND deleted_at IS NULL)::float AS sales,
                  (SELECT coalesce(sum(amount), 0) FROM receipt WHERE location_id = l.id AND doc_date = d.day
                     AND status = 'final' AND mode = 'cash' AND deleted_at IS NULL)::float AS cash,
                  (SELECT coalesce(sum(amount), 0) FROM receipt WHERE location_id = l.id AND doc_date = d.day
                     AND status = 'final' AND mode = 'upi' AND deleted_at IS NULL)::float AS upi,
                  (SELECT count(*) FROM sales_invoice WHERE location_id = l.id AND doc_date = d.day
                     AND status = 'cancelled' AND deleted_at IS NULL)::int AS cancelled,
                  coalesce(a.status, 'waiting') AS status, u.name AS checked_by, a.note
             FROM location l CROSS JOIN d
             LEFT JOIN audit_day a ON a.location_id = l.id AND a.day = d.day
             LEFT JOIN app_user u ON u.id = a.checked_by
            WHERE l.deleted_at IS NULL AND l.is_active AND l.kind IN ('outlet','franchise')
              AND ($3::uuid[] IS NULL OR l.id = ANY($3::uuid[]))
            ORDER BY d.day, l.code`, [from, to, scope])).rows;
        const sales = rows.reduce((t: number, r: any) => t + r.sales, 0);
        const v = rows.filter((r: any) => r.status === 'verified').length;
        const q = rows.filter((r: any) => r.status === 'query');
        return {
          title: `Daily outlet audit, ${when}`,
          columns: [['date', 'Date'], ['outlet', 'Outlet'], ['sales', 'Sales'], ['cash', 'Cash'], ['upi', 'UPI'],
            ['cancelled', 'Cancelled bills'], ['status', 'Audit'], ['checked_by', 'Checked by'], ['note', 'Note']],
          rows,
          summary: `*Outlet audit ${when}*\nSales ${inr(sales)}\nVerified ${v} of ${rows.length} outlet-days` +
            (q.length ? `\nQueries: ${q.map((r: any) => `${r.outlet} ${r.date}: ${r.note ?? ''}`).join('; ')}` : ''),
        };
      }
      if (type === 'stock_diff') {
        const mrp = await mrpMap(c);
        const rows = (await c.query(
          `SELECT (k.finished_at AT TIME ZONE $4)::date::text AS date, l.code AS outlet, i.id AS item_id, i.name AS item,
                  cl.counted::float AS counted, cl.system_qty::float AS system_qty,
                  (cl.counted - cl.system_qty)::float AS diff, u.name AS counted_by
             FROM stock_count_line cl JOIN stock_count k ON k.id = cl.count_id
             JOIN location l ON l.id = k.location_id JOIN item i ON i.id = cl.item_id JOIN app_user u ON u.id = k.counted_by
            WHERE (k.finished_at AT TIME ZONE $4)::date BETWEEN $1 AND $2 AND cl.counted <> cl.system_qty
              AND ($3::uuid[] IS NULL OR k.location_id = ANY($3::uuid[]))
            ORDER BY 1, 2, 4`, [from, to, scope, tz])).rows.map((r: any) => ({ ...r, value: r2(r.diff * (mrp.get(r.item_id) ?? 0)) }));
        const byOutlet = new Map<string, number>();
        for (const r of rows) byOutlet.set(r.outlet, (byOutlet.get(r.outlet) ?? 0) + r.value);
        return {
          title: `Stock count differences, ${when}`,
          columns: [['date', 'Date'], ['outlet', 'Outlet'], ['item', 'Item'], ['counted', 'Counted'], ['system_qty', 'System'],
            ['diff', 'Difference'], ['value', 'Value (MRP)'], ['counted_by', 'Counted by']],
          rows,
          summary: `*Stock count differences ${when}*\n` + (rows.length
            ? [...byOutlet].map(([o, v]) => `${o}: ${inr(v)}`).join('\n') : 'No differences'),
        };
      }
      if (type === 'adjustments') {
        const rows = (await c.query(
          `SELECT (a.requested_at AT TIME ZONE $4)::date::text AS date, l.code AS outlet, i.name AS item, a.reason,
                  a.qty::float AS qty, a.value::float AS value, a.status, ru.name AS requested_by, du.name AS decided_by, a.note
             FROM stock_adjustment a JOIN location l ON l.id = a.location_id JOIN item i ON i.id = a.item_id
             JOIN app_user ru ON ru.id = a.requested_by LEFT JOIN app_user du ON du.id = a.decided_by
            WHERE (a.requested_at AT TIME ZONE $4)::date BETWEEN $1 AND $2 AND a.deleted_at IS NULL
              AND ($3::uuid[] IS NULL OR a.location_id = ANY($3::uuid[]))
            ORDER BY 1, 2, 3`, [from, to, scope, tz])).rows.map((r: any) => ({ ...r, reason: ADJUST_REASONS[r.reason] ?? r.reason }));
        const byReason = new Map<string, number>();
        for (const r of rows.filter((x: any) => x.status === 'approved' && x.qty < 0)) byReason.set(r.reason, (byReason.get(r.reason) ?? 0) + r.value);
        return {
          title: `Stock adjustments, ${when}`,
          columns: [['date', 'Date'], ['outlet', 'Outlet'], ['item', 'Item'], ['reason', 'Reason'], ['qty', 'Qty'],
            ['value', 'Value (MRP)'], ['status', 'Status'], ['requested_by', 'Asked by'], ['decided_by', 'Decided by'], ['note', 'Note']],
          rows,
          summary: `*Stock written off ${when}* (approved)\n` + (byReason.size
            ? [...byReason].map(([k, v]) => `${k}: ${inr(v)}`).join('\n') : 'Nothing') +
            `\nWaiting for approval: ${rows.filter((r: any) => r.status === 'pending').length}`,
        };
      }
      if (type === 'dispatch') {
        const rows = (await c.query(
          `SELECT t.doc_date::text AS date, t.doc_no, CASE t.kind WHEN 'return' THEN 'Return' ELSE 'Dispatch' END AS kind,
                  f.code AS from_code, tl.code AS to_code, i.name AS item, x.qty_sent::float AS sent,
                  x.qty_received::float AS received, (coalesce(x.qty_received, 0) - x.qty_sent)::float AS diff,
                  coalesce(x.reason, CASE WHEN t.status = 'dispatched' THEN 'not received yet' END) AS reason
             FROM stock_transfer t JOIN stock_transfer_line x ON x.transfer_id = t.id AND x.deleted_at IS NULL
             JOIN location f ON f.id = t.from_location_id JOIN location tl ON tl.id = t.to_location_id
             JOIN item i ON i.id = x.item_id
            WHERE t.doc_date BETWEEN $1 AND $2 AND t.deleted_at IS NULL AND t.status IN ('dispatched','received')
              AND (x.reason IS NOT NULL OR t.status = 'dispatched')
              AND ($3::uuid[] IS NULL OR t.from_location_id = ANY($3::uuid[]) OR t.to_location_id = ANY($3::uuid[]))
            ORDER BY 1, 2`, [from, to, scope])).rows;
        const totals = (await c.query(
          `SELECT count(DISTINCT t.id)::int AS docs, coalesce(sum(x.qty_sent), 0)::float AS sent,
                  coalesce(sum(x.qty_received), 0)::float AS received
             FROM stock_transfer t JOIN stock_transfer_line x ON x.transfer_id = t.id AND x.deleted_at IS NULL
            WHERE t.doc_date BETWEEN $1 AND $2 AND t.deleted_at IS NULL AND t.status = 'received' AND t.kind = 'dispatch'
              AND ($3::uuid[] IS NULL OR t.from_location_id = ANY($3::uuid[]) OR t.to_location_id = ANY($3::uuid[]))`,
          [from, to, scope])).rows[0];
        return {
          title: `Dispatch vs receipt differences, ${when}`,
          columns: [['date', 'Date'], ['doc_no', 'No.'], ['kind', 'Type'], ['from_code', 'From'], ['to_code', 'To'],
            ['item', 'Item'], ['sent', 'Sent'], ['received', 'Received'], ['diff', 'Difference'], ['reason', 'Reason']],
          rows,
          summary: `*Dispatch vs receipt ${when}*\n${totals.docs} dispatches received: sent ${totals.sent}, received ${totals.received} pieces\n` +
            `${rows.filter((r: any) => r.reason !== 'not received yet').length} lines with a difference, ` +
            `${new Set(rows.filter((r: any) => r.reason === 'not received yet').map((r: any) => r.doc_no)).size} not received yet`,
        };
      }
      if (type === 'cash') {
        const rows = (await c.query(
          `SELECT (sh.opened_at AT TIME ZONE $4)::date::text AS date, l.code AS outlet, u.name AS cashier,
                  sh.opening_cash::float AS opening, sh.expected_cash::float AS expected, sh.counted_cash::float AS counted,
                  (sh.counted_cash - sh.expected_cash)::float AS diff,
                  (SELECT count(*) FROM sales_invoice si WHERE si.shift_id = sh.id AND si.status = 'cancelled')::int AS cancelled,
                  (SELECT coalesce(sum(total), 0) FROM sales_invoice si WHERE si.shift_id = sh.id AND si.status = 'cancelled')::float AS cancelled_value
             FROM shift sh JOIN location l ON l.id = sh.location_id JOIN app_user u ON u.id = sh.user_id
            WHERE (sh.opened_at AT TIME ZONE $4)::date BETWEEN $1 AND $2 AND sh.deleted_at IS NULL
              AND ($3::uuid[] IS NULL OR sh.location_id = ANY($3::uuid[]))
            ORDER BY 1, 2, 3`, [from, to, scope, tz])).rows;
        const byCashier = new Map<string, { diff: number; cancelled: number }>();
        for (const r of rows) {
          const k = byCashier.get(r.cashier) ?? { diff: 0, cancelled: 0 };
          k.diff += r.diff ?? 0;
          k.cancelled += r.cancelled;
          byCashier.set(r.cashier, k);
        }
        return {
          title: `Cash short/extra and cancelled bills by cashier, ${when}`,
          columns: [['date', 'Date'], ['outlet', 'Outlet'], ['cashier', 'Cashier'], ['opening', 'Opening'],
            ['expected', 'Expected'], ['counted', 'Counted'], ['diff', 'Short (-) / extra'], ['cancelled', 'Cancelled bills'],
            ['cancelled_value', 'Cancelled value']],
          rows,
          summary: `*Cash and cancellations ${when}*\n` + ([...byCashier].map(([n, k]) =>
            `${n}: cash ${k.diff < 0 ? 'short' : 'extra'} ${inr(Math.abs(k.diff))}, ${k.cancelled} cancelled`).join('\n') || 'No shifts'),
        };
      }
      throw new BadRequestException('Unknown report');
    });
  }
}
