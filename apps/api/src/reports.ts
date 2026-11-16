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
}
