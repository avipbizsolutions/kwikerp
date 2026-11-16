import { BadRequestException, Controller, Get, Query, Req, UseGuards } from '@nestjs/common';
import { AuthGuard, Needs, Session } from './auth';
import { Db } from './db';

function isDate(v: string): boolean {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(v)) return false;
  const d = new Date(`${v}T00:00:00Z`);
  return !Number.isNaN(d.getTime()) && d.toISOString().slice(0, 10) === v;
}

/** India time, since bills are dated by the outlet's day. */
function todayIst(): string {
  return new Date(Date.now() + 5.5 * 3600 * 1000).toISOString().slice(0, 10);
}

@Controller('reports')
@UseGuards(AuthGuard)
export class ReportsController {
  constructor(private readonly db: Db) {}

  /** Sales by outlet for a date range (default today), for the head-office page. */
  @Get('sales')
  @Needs('report.all')
  sales(@Req() req: any, @Query('from') from?: string, @Query('to') to?: string) {
    const s: Session = req.session;
    const f = from ?? todayIst();
    const t = to ?? f;
    if (!isDate(f) || !isDate(t) || f > t) throw new BadRequestException('from/to must be YYYY-MM-DD, from <= to');
    return this.db.tx(s.tenantId, async (c) => {
      const outlets = (await c.query(
        `WITH inv AS (
           SELECT location_id, count(*) AS bills, sum(total) AS sales, sum(balance) AS credit,
                  max(finalised_at) AS last_bill_at
             FROM sales_invoice
            WHERE status = 'final' AND doc_type = 'INV' AND deleted_at IS NULL AND doc_date BETWEEN $1 AND $2
            GROUP BY 1),
         rc AS (
           SELECT location_id,
                  sum(amount) FILTER (WHERE mode = 'cash') AS cash,
                  sum(amount) FILTER (WHERE mode = 'upi') AS upi,
                  sum(amount) FILTER (WHERE mode = 'card') AS card,
                  sum(amount) FILTER (WHERE mode NOT IN ('cash','upi','card')) AS other
             FROM receipt
            WHERE status = 'final' AND deleted_at IS NULL AND doc_date BETWEEN $1 AND $2
            GROUP BY 1),
         cx AS (
           SELECT location_id, count(*) AS n FROM sales_invoice
            WHERE status = 'cancelled' AND deleted_at IS NULL AND doc_date BETWEEN $1 AND $2 GROUP BY 1),
         pa AS (
           SELECT location_id, count(*) AS n FROM credit_approval
            WHERE status = 'pending' AND deleted_at IS NULL GROUP BY 1),
         dev AS (
           SELECT location_id, max(last_seen_at) AS last_seen FROM device WHERE deleted_at IS NULL GROUP BY 1)
         SELECT l.code, l.name,
                coalesce(inv.bills, 0)::int AS bills, coalesce(inv.sales, 0)::float AS sales,
                coalesce(rc.cash, 0)::float AS cash, coalesce(rc.upi, 0)::float AS upi,
                coalesce(rc.card, 0)::float AS card, coalesce(rc.other, 0)::float AS other,
                coalesce(inv.credit, 0)::float AS credit, coalesce(cx.n, 0)::int AS cancelled,
                coalesce(pa.n, 0)::int AS pending_approvals, inv.last_bill_at, dev.last_seen AS tablet_last_seen
           FROM location l
           LEFT JOIN inv ON inv.location_id = l.id
           LEFT JOIN rc  ON rc.location_id = l.id
           LEFT JOIN cx  ON cx.location_id = l.id
           LEFT JOIN pa  ON pa.location_id = l.id
           LEFT JOIN dev ON dev.location_id = l.id
          WHERE l.deleted_at IS NULL
            AND (l.kind IN ('outlet', 'franchise') OR inv.bills IS NOT NULL)
          ORDER BY l.code`, [f, t])).rows;

      const topItems = (await c.query(
        `SELECT i.name, sum(sl.qty * sl.factor)::float AS qty, sum(sl.amount)::float AS amount
           FROM sales_invoice_line sl
           JOIN sales_invoice si ON si.id = sl.invoice_id
           JOIN item i ON i.id = sl.item_id
          WHERE si.status = 'final' AND si.doc_type = 'INV' AND si.deleted_at IS NULL AND sl.deleted_at IS NULL
            AND si.doc_date BETWEEN $1 AND $2
          GROUP BY i.name ORDER BY amount DESC LIMIT 15`, [f, t])).rows;

      const total = outlets.reduce(
        (a: any, o: any) => {
          for (const k of ['bills', 'sales', 'cash', 'upi', 'card', 'other', 'credit']) a[k] += o[k];
          return a;
        },
        { bills: 0, sales: 0, cash: 0, upi: 0, card: 0, other: 0, credit: 0 });
      return { from: f, to: t, total, outlets, topItems };
    });
  }

  /**
   * Day-end report for one outlet and day: shifts and cash, payment modes,
   * GST by rate, items sold, credit bills and cancellations.
   */
  @Get('dayend')
  @Needs('report.all')
  dayEnd(@Req() req: any, @Query('date') date?: string, @Query('location') location?: string) {
    const s: Session = req.session;
    const d = date ?? todayIst();
    if (!isDate(d)) throw new BadRequestException('date must be YYYY-MM-DD');
    if (!location) throw new BadRequestException('location is required');
    return this.db.tx(s.tenantId, async (c) => {
      const loc = (await c.query(
        'SELECT id, code, name FROM location WHERE upper(code) = upper($1) AND deleted_at IS NULL', [location])).rows[0];
      if (!loc) throw new BadRequestException('Unknown outlet');
      const args = [loc.id, d];
      const q = async (sql: string) => (await c.query(sql, args)).rows;
      const finalInv = `si.location_id = $1 AND si.doc_date = $2 AND si.status = 'final' AND si.doc_type = 'INV'
                        AND si.deleted_at IS NULL`;

      const shifts = await q(
        `SELECT sh.id, u.name AS cashier, dv.code AS tablet, sh.opened_at, sh.closed_at,
                sh.opening_cash::float AS opening_cash, sh.expected_cash::float AS expected_cash,
                sh.counted_cash::float AS counted_cash,
                (sh.counted_cash - sh.expected_cash)::float AS difference, sh.note,
                (SELECT coalesce(sum(r.amount), 0)::float FROM receipt r
                  WHERE r.shift_id = sh.id AND r.mode = 'cash' AND r.status = 'final' AND r.deleted_at IS NULL) AS cash_sales
           FROM shift sh JOIN app_user u ON u.id = sh.user_id JOIN device dv ON dv.id = sh.device_id
          WHERE sh.location_id = $1 AND sh.deleted_at IS NULL
            AND (sh.opened_at AT TIME ZONE 'Asia/Kolkata')::date = $2
          ORDER BY sh.opened_at`);
      const modes = await q(
        `SELECT r.mode, count(*)::int AS n, sum(r.amount)::float AS amount
           FROM receipt r WHERE r.location_id = $1 AND r.doc_date = $2 AND r.status = 'final' AND r.deleted_at IS NULL
          GROUP BY r.mode ORDER BY r.mode`);
      const totals = (await q(
        `SELECT count(*)::int AS bills, coalesce(sum(si.total), 0)::float AS sales,
                coalesce(sum(si.taxable), 0)::float AS taxable, coalesce(sum(si.cgst), 0)::float AS cgst,
                coalesce(sum(si.sgst), 0)::float AS sgst, coalesce(sum(si.igst), 0)::float AS igst,
                coalesce(sum(si.round_off), 0)::float AS round_off, coalesce(sum(si.balance), 0)::float AS credit,
                min(si.doc_no) AS first_bill, max(si.doc_no) AS last_bill
           FROM sales_invoice si WHERE ${finalInv}`))[0];
      const gst = await q(
        `SELECT sl.gst_rate::float AS rate, sum(sl.taxable)::float AS taxable, sum(sl.cgst)::float AS cgst,
                sum(sl.sgst)::float AS sgst, sum(sl.igst)::float AS igst, sum(sl.amount)::float AS amount
           FROM sales_invoice_line sl JOIN sales_invoice si ON si.id = sl.invoice_id
          WHERE ${finalInv} AND sl.deleted_at IS NULL GROUP BY sl.gst_rate ORDER BY sl.gst_rate`);
      const items = await q(
        `SELECT i.code, i.name, i.pack_size, u.code AS unit, sum(sl.qty * sl.factor)::float AS qty,
                sum(sl.amount)::float AS amount
           FROM sales_invoice_line sl JOIN sales_invoice si ON si.id = sl.invoice_id
           JOIN item i ON i.id = sl.item_id JOIN unit u ON u.id = i.base_unit_id
          WHERE ${finalInv} AND sl.deleted_at IS NULL
          GROUP BY i.code, i.name, i.pack_size, u.code ORDER BY amount DESC`);
      const credit = await q(
        `SELECT si.doc_no, cu.name AS customer, si.total::float AS total, si.balance::float AS balance
           FROM sales_invoice si JOIN customer cu ON cu.id = si.customer_id
          WHERE ${finalInv} AND si.balance > 0 ORDER BY si.doc_no`);
      const cancelled = await q(
        `SELECT si.doc_no, si.total::float AS total, si.cancel_reason, u.name AS cancelled_by
           FROM sales_invoice si LEFT JOIN app_user u ON u.id = si.cancelled_by
          WHERE si.location_id = $1 AND si.doc_date = $2 AND si.status = 'cancelled' AND si.deleted_at IS NULL
          ORDER BY si.doc_no`);
      const waiting = await q(
        `SELECT count(*)::int AS n, coalesce(sum(total), 0)::float AS amount FROM sales_invoice si
          WHERE si.location_id = $1 AND si.doc_date = $2 AND si.status = 'pending_approval' AND si.deleted_at IS NULL`);
      return { date: d, outlet: { code: loc.code, name: loc.name }, totals, modes, shifts, gst, items, credit,
        cancelled, waitingApproval: waiting[0] };
    });
  }
}

