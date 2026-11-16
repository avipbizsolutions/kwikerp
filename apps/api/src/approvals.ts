import {
  BadRequestException, Body, Controller, Get, NotFoundException, Param, Post, Query, Req, UseGuards,
} from '@nestjs/common';
import { AuthGuard, Needs, Session } from './auth';
import { Db } from './db';
import { approvalCode, deviceKey } from './offline-code';

interface Decision {
  decision: 'once' | 'raise_limit' | 'reject';
  note?: string;
  newLimit?: number;      // for raise_limit
  validDays?: number;     // temporary raise; omit for permanent
}

@Controller('approvals')
@UseGuards(AuthGuard)
export class ApprovalsController {
  constructor(private readonly db: Db) {}

  /** Requests for the manager app, newest first. */
  @Get()
  @Needs('credit.approve')
  list(@Req() req: any, @Query('status') status = 'pending') {
    const s: Session = req.session;
    return this.db.tx(s.tenantId, async (c) => (await c.query(
      `SELECT a.*, c.name AS customer_name, l.code AS location_code, l.name AS location_name,
              u.name AS requested_by_name, cl.max_outstanding AS current_limit, cl.source AS limit_source,
              d.code AS device_code,
              (SELECT string_agg(i.name || ' ×' || to_char(sl.qty, 'FM999990.###'), ', ' ORDER BY sl.line_no)
                 FROM sales_invoice_line sl JOIN item i ON i.id = sl.item_id
                WHERE sl.invoice_id = a.invoice_id AND sl.deleted_at IS NULL) AS items
         FROM credit_approval a
         LEFT JOIN sales_invoice si ON si.id = a.invoice_id
         LEFT JOIN device d ON d.id = si.device_id
         JOIN customer c ON c.id = a.customer_id
         JOIN location l ON l.id = a.location_id
         JOIN app_user u ON u.id = a.requested_by
         LEFT JOIN customer_credit_limit cl ON cl.customer_id = a.customer_id
        WHERE a.status = $1 AND a.deleted_at IS NULL
        ORDER BY a.requested_at DESC LIMIT 200`, [status])).rows);
  }

  @Post(':id/decide')
  @Needs('credit.approve')
  async decide(@Req() req: any, @Param('id') id: string, @Body() body: Decision) {
    const s: Session = req.session;
    if (!['once', 'raise_limit', 'reject'].includes(body?.decision)) {
      throw new BadRequestException('decision must be once, raise_limit or reject');
    }
    return this.db.tx(s.tenantId, async (c) => {
      const a = (await c.query('SELECT * FROM credit_approval WHERE id = $1 FOR UPDATE', [id])).rows[0];
      if (!a) throw new NotFoundException('Request not found');
      if (a.status !== 'pending') throw new BadRequestException(`Already ${a.status}`);

      if (body.decision === 'raise_limit') {
        if (!(Number(body.newLimit) > 0)) throw new BadRequestException('newLimit is required');
        await c.query(
          `INSERT INTO credit_limit (tenant_id, customer_id, max_outstanding, max_days, valid_from, valid_to, set_by, note)
           SELECT $1, $2, $3, l.max_days, current_date,
                  CASE WHEN $4::int IS NULL THEN NULL ELSE current_date + $4::int END, $5, $6
             FROM customer_credit_limit l WHERE l.customer_id = $2`,
          [s.tenantId, a.customer_id, body.newLimit, body.validDays ?? null, s.userId,
            body.note ?? 'Raised while approving a bill']);
      }
      const status = body.decision === 'reject' ? 'rejected' : 'approved';
      await c.query(
        `UPDATE credit_approval SET status = $2, decision = $3, decided_by = $4, decided_at = now(), decision_note = $5
          WHERE id = $1`,
        [id, status, body.decision === 'reject' ? null : body.decision, s.userId, body.note ?? null]);
      await c.query(
        `INSERT INTO audit_log (tenant_id, user_id, action, entity, entity_id, detail)
         VALUES ($1, $2, 'credit.decide', 'credit_approval', $3, $4)`,
        [s.tenantId, s.userId, id, JSON.stringify(body)]);
      return { id, status };
    });
  }

  /**
   * Manager app, for an outlet with no internet: the cashier reads out the
   * outlet + tablet, the request code and the bill amount; this returns the
   * 6-digit code the cashier types in.
   */
  @Post('offline-code')
  @Needs('credit.approve')
  async offlineCode(@Req() req: any,
                    @Body() body: { locationCode: string; deviceCode: string; requestCode: string; amount: number }) {
    const s: Session = req.session;
    if (!body?.locationCode || !body?.deviceCode || !body?.requestCode || !(Number(body.amount) > 0)) {
      throw new BadRequestException('locationCode, deviceCode, requestCode and amount are required');
    }
    return this.db.tx(s.tenantId, async (c) => {
      const d = (await c.query(
        `SELECT d.id FROM device d JOIN location l ON l.id = d.location_id
          WHERE l.code = $1 AND d.code = $2 AND d.deleted_at IS NULL`,
        [body.locationCode.trim().toUpperCase(), body.deviceCode.trim().toUpperCase()])).rows[0];
      if (!d) throw new NotFoundException('No such tablet');
      const code = approvalCode(deviceKey(d.id), body.requestCode, Number(body.amount));
      await c.query(
        `INSERT INTO audit_log (tenant_id, user_id, device_id, action, entity, detail)
         VALUES ($1, $2, $3, 'credit.offline_code', 'credit_approval', $4)`,
        [s.tenantId, s.userId, d.id, JSON.stringify(body)]);
      return { approvalCode: code };
    });
  }
}
