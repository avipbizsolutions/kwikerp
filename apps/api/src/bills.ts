import { BadRequestException, Body, Controller, NotFoundException, Param, Post, Req, UseGuards } from '@nestjs/common';
import { AuthGuard, Needs, Session, verifyApprover } from './auth';
import { Db } from './db';

interface CancelBody {
  reason: string;
  approverPhone?: string; // needed when the logged-in cashier cannot cancel bills
  approverPin?: string;
}

@Controller('bills')
@UseGuards(AuthGuard)
export class BillsController {
  constructor(private readonly db: Db) {}

  /**
   * Cancel a final bill from the outlet tablet. Done on the server (needs
   * internet) so the approving manager's PIN is really checked. The bill keeps
   * its number; its payments are cancelled and the stock goes back.
   */
  @Post(':id/cancel')
  @Needs('bill.create')
  cancel(@Req() req: any, @Param('id') id: string, @Body() b: CancelBody) {
    const s: Session = req.session;
    const reason = (b?.reason ?? '').trim();
    if (reason.length < 3) throw new BadRequestException('Give a reason for cancelling');
    return this.db.tx(s.tenantId, async (c) => {
      const inv = (await c.query(
        `SELECT id, status, doc_no, location_id, doc_date FROM sales_invoice
          WHERE id = $1 AND deleted_at IS NULL FOR UPDATE`, [id])).rows[0];
      if (!inv) throw new NotFoundException('This bill has not reached the server yet. Wait for "All synced" and try again.');
      if (s.locationId && inv.location_id !== s.locationId) throw new NotFoundException('Bill belongs to another outlet');
      if (inv.status === 'cancelled') throw new BadRequestException('Bill is already cancelled');
      if (inv.status !== 'final') throw new BadRequestException(`A ${inv.status.replace('_', ' ')} bill cannot be cancelled here`);

      const own = s.permissions.includes('*') || s.permissions.includes('bill.cancel');
      const approver = own
        ? { id: s.userId, name: s.userName }
        : await verifyApprover(c, s.tenantId, b.approverPhone ?? '', b.approverPin ?? '', inv.location_id, 'bill.cancel');

      await c.query(
        `UPDATE sales_invoice SET status = 'cancelled', cancelled_by = $2, cancel_reason = $3 WHERE id = $1`,
        [id, approver.id, reason]);
      const receipts = await c.query(
        `UPDATE receipt SET status = 'cancelled' WHERE invoice_id = $1 AND status = 'final' RETURNING id`, [id]);
      // Stock back: the opposite of each sale movement of this bill
      await c.query(
        `INSERT INTO stock_move (id, tenant_id, location_id, item_id, batch_id, qty, move_type, doc_id, move_date, reason, created_by)
         SELECT gen_random_uuid(), tenant_id, location_id, item_id, batch_id, -qty, 'sale_return', doc_id, current_date,
                'Bill cancelled: ' || $2, $3
           FROM stock_move WHERE doc_id = $1 AND move_type = 'sale' AND deleted_at IS NULL`,
        [id, reason, approver.id]);
      await c.query(
        `INSERT INTO audit_log (tenant_id, user_id, device_id, action, entity, entity_id, detail)
         VALUES ($1, $2, $3, 'bill.cancel', 'sales_invoice', $4, $5)`,
        [s.tenantId, approver.id, s.deviceId, id,
          JSON.stringify({ docNo: inv.doc_no, reason, requestedBy: s.userName, approvedBy: approver.name })]);
      return { id, status: 'cancelled', cancelledBy: approver.id, cancelledByName: approver.name, reason,
        receiptIds: receipts.rows.map((r) => r.id) };
    });
  }
}
