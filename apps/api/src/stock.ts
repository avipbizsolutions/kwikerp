import {
  BadRequestException, Body, Controller, ForbiddenException, Get, NotFoundException, Param, Post, Query, Req, UseGuards,
} from '@nestjs/common';
import { PoolClient } from 'pg';
import { AuthGuard, can, inScope, Needs, scopeOf, Session } from './auth';
import { Db } from './db';
import { finYear, localDate, mrpMap, needUuid, num, stockSettings } from './util';

/**
 * Stock between locations. All quantities are in the item's base unit
 * (pieces, or kg for loose items); trays and boxes are only for entry.
 *
 *   dispatch  plant/godown -> counter: stock leaves the sender when sent and
 *             reaches the counter with what the counter says it received.
 *   return    counter -> plant/godown: leaves the counter when sent, reaches
 *             the plant with what the plant confirms.
 *   adjustment  wastage, expiry, breakage, count difference...: changes stock
 *             only once a manager (or the owner, above the limit) approves.
 *   count     blind count; each difference becomes an adjustment request.
 */
const RECEIVE_REASONS = ['short', 'damaged', 'extra', 'wrong'];
export const ADJUST_REASONS: Record<string, string> = {
  wastage: 'Wastage / spoilt', expired: 'Expired', broken: 'Broken / leaked', count: 'Count is different',
  sample: 'Free sample / staff', other: 'Other',
};

interface Line { itemId: string; qty: number; reason?: string }
interface DispatchBody {
  id: string; from: string; to: string; vehicle?: string; driver?: string; note?: string; send: boolean; lines: Line[];
}

function cleanLines(lines: Line[] | undefined, allowReason = false): Line[] {
  if (!Array.isArray(lines) || !lines.length) throw new BadRequestException('Add at least one item');
  const merged = new Map<string, Line>();
  for (const l of lines) {
    const itemId = needUuid(l?.itemId, 'Item');
    const qty = num(l?.qty, 'Quantity');
    if (qty < 0) throw new BadRequestException('Quantities cannot be negative');
    if (qty === 0) continue;
    const prev = merged.get(itemId);
    merged.set(itemId, { itemId, qty: (prev?.qty ?? 0) + qty, reason: allowReason ? l.reason ?? prev?.reason : undefined });
  }
  if (!merged.size) throw new BadRequestException('Add at least one item');
  return [...merged.values()];
}

async function location(c: PoolClient, id: string) {
  const l = (await c.query('SELECT * FROM location WHERE id = $1 AND deleted_at IS NULL', [needUuid(id, 'Location')])).rows[0];
  if (!l) throw new BadRequestException('Unknown location');
  return l;
}

/** Location the request acts for: the tablet's outlet, or the one chosen on the page. */
async function actingLocation(c: PoolClient, s: Session, chosen?: string) {
  const id = s.locationId ?? chosen;
  if (!id) throw new BadRequestException('Choose the location');
  const l = await location(c, id);
  if (!inScope(s, l.id)) throw new ForbiddenException(`You cannot do this for ${l.name}`);
  return l;
}

async function deviceCode(c: PoolClient, s: Session): Promise<string> {
  if (!s.deviceId) return 'W1'; // head-office page / phone
  return (await c.query('SELECT code FROM device WHERE id = $1', [s.deviceId])).rows[0]?.code ?? 'W1';
}

/** <LOCATION>-<DEVICE>-<FY>-<seq>, a separate series per location, device and kind. */
async function nextDocNo(c: PoolClient, locCode: string, dev: string, kind: 'dispatch' | 'return') {
  const prefix = `${locCode}-${dev}-${finYear(localDate())}-${kind === 'return' ? 'R' : ''}`;
  await c.query('SELECT pg_advisory_xact_lock(hashtext($1))', [prefix]);
  const last = (await c.query(
    `SELECT max(substring(doc_no from '([0-9]+)$')::int) AS n FROM stock_transfer
      WHERE doc_no LIKE $1 || '%' AND substring(doc_no from length($1) + 1) ~ '^[0-9]+$'`, [prefix])).rows[0]?.n ?? 0;
  return `${prefix}${String(Number(last) + 1).padStart(4, '0')}`;
}

async function move(c: PoolClient, s: Session, locationId: string, itemId: string, qty: number, type: string,
                    docId: string | null, reason: string | null = null) {
  await c.query(
    `INSERT INTO stock_move (id, tenant_id, location_id, item_id, qty, move_type, doc_id, move_date, reason, created_by)
     VALUES (gen_random_uuid(), $1, $2, $3, $4, $5, $6, $7, $8, $9)`,
    [s.tenantId, locationId, itemId, qty, type, docId, localDate(), reason, s.userId]);
}

async function log(c: PoolClient, s: Session, action: string, entity: string, id: string | null, detail: unknown) {
  await c.query(
    `INSERT INTO audit_log (tenant_id, user_id, device_id, action, entity, entity_id, detail)
     VALUES ($1, $2, $3, $4, $5, $6, $7)`,
    [s.tenantId, s.userId, s.deviceId, action, entity, id, JSON.stringify(detail ?? {})]);
}

async function onHand(c: PoolClient, locationId: string): Promise<Map<string, number>> {
  const rows = (await c.query(
    `SELECT item_id, sum(qty)::float AS qty FROM stock_move
      WHERE location_id = $1 AND deleted_at IS NULL GROUP BY item_id`, [locationId])).rows;
  return new Map(rows.map((r: any) => [r.item_id, r.qty]));
}

@Controller('stock')
@UseGuards(AuthGuard)
export class StockController {
  constructor(private readonly db: Db) {}

  /** Locations and items for the stock screens. */
  @Get('meta')
  meta(@Req() req: any) {
    const s: Session = req.session;
    return this.db.tx(s.tenantId, async (c) => {
      const mrp = await mrpMap(c);
      const items = (await c.query(
        `SELECT i.id, i.code, i.name, ic.name AS category, i.sold_by_weight, i.reorder_level::float AS reorder_level,
                pk.factor::float AS pack_factor, u.name AS pack_name
           FROM item i
           LEFT JOIN item_category ic ON ic.id = i.category_id
           LEFT JOIN LATERAL (SELECT p.factor, p.unit_id FROM item_pack p
                               WHERE p.item_id = i.id AND p.deleted_at IS NULL AND p.factor > 1
                               ORDER BY p.is_default_trade DESC, p.factor DESC LIMIT 1) pk ON true
           LEFT JOIN unit u ON u.id = pk.unit_id
          WHERE i.deleted_at IS NULL AND i.is_active
          ORDER BY ic.name NULLS LAST, i.pos_sort, i.name`)).rows;
      for (const i of items) i.mrp = mrp.get(i.id) ?? 0;
      return {
        locations: (await c.query(
          `SELECT id, code, name, kind, sends_goods, supply_from_id, is_active FROM location
            WHERE deleted_at IS NULL ORDER BY kind <> 'plant', kind <> 'godown', code`)).rows,
        scope: scopeOf(s),
        reasons: ADJUST_REASONS,
        settings: await stockSettings(c),
        items,
      };
    });
  }

  // ------------------------------------------------------------------ dispatch

  @Post('dispatch')
  @Needs('stock.dispatch')
  dispatch(@Req() req: any, @Body() b: DispatchBody) {
    const s: Session = req.session;
    const id = needUuid(b?.id, 'Dispatch');
    const lines = cleanLines(b?.lines);
    return this.db.tx(s.tenantId, async (c) => {
      const from = await location(c, b.from);
      const to = await location(c, b.to);
      if (!from.sends_goods) throw new BadRequestException(`${from.name} is not set to send goods`);
      if (!inScope(s, from.id)) throw new ForbiddenException(`You cannot send goods from ${from.name}`);
      if (from.id === to.id) throw new BadRequestException('Choose a different location to send to');
      if (!to.is_active) throw new BadRequestException(`${to.name} is switched off`);

      const old = (await c.query('SELECT * FROM stock_transfer WHERE id = $1 FOR UPDATE', [id])).rows[0];
      if (old && old.status !== 'draft') return { id, docNo: old.doc_no, status: old.status }; // retry
      const status = b.send ? 'dispatched' : 'draft';
      const docNo = b.send ? await nextDocNo(c, from.code, await deviceCode(c, s), 'dispatch') : null;
      const vals = [id, s.tenantId, from.id, to.id, docNo, localDate(), status, s.userId,
        b.vehicle?.trim() || null, b.driver?.trim() || null, b.note?.trim() || null, b.send ? new Date() : null];
      if (old) {
        await c.query(
          `UPDATE stock_transfer SET from_location_id = $3, to_location_id = $4, doc_no = $5, doc_date = $6, status = $7,
                  dispatched_by = $8, vehicle = $9, driver = $10, note = $11, sent_at = $12 WHERE id = $1 AND tenant_id = $2`, vals);
        await c.query('UPDATE stock_transfer_line SET deleted_at = now() WHERE transfer_id = $1 AND deleted_at IS NULL', [id]);
      } else {
        await c.query(
          `INSERT INTO stock_transfer (id, tenant_id, from_location_id, to_location_id, doc_no, doc_date, status,
                  dispatched_by, vehicle, driver, note, sent_at, kind)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, 'dispatch')`, vals);
      }
      await this.writeLines(c, s, id, lines);
      if (b.send) {
        for (const l of lines) await move(c, s, from.id, l.itemId, -l.qty, 'transfer_out', id);
        await log(c, s, 'stock.dispatch', 'stock_transfer', id, { docNo, from: from.code, to: to.code, lines });
      }
      return { id, docNo, status };
    });
  }

  private async writeLines(c: PoolClient, s: Session, transferId: string, lines: Line[]) {
    let n = 0;
    for (const l of lines) {
      const it = (await c.query('SELECT base_unit_id FROM item WHERE id = $1 AND deleted_at IS NULL', [l.itemId])).rows[0];
      if (!it) throw new BadRequestException('Unknown item');
      await c.query(
        `INSERT INTO stock_transfer_line (id, tenant_id, transfer_id, item_id, unit_id, factor, qty_sent, line_no, reason)
         VALUES (gen_random_uuid(), $1, $2, $3, $4, 1, $5, $6, $7)`,
        [s.tenantId, transferId, l.itemId, it.base_unit_id, l.qty, ++n, l.reason ?? null]);
    }
  }

  /** Counter sends goods back to where it gets them from (plant or godown). */
  @Post('returns')
  @Needs('stock.receive')
  sendReturn(@Req() req: any, @Body() b: { id: string; location?: string; note?: string; lines: Line[] }) {
    const s: Session = req.session;
    const id = needUuid(b?.id, 'Return');
    const lines = cleanLines(b?.lines, true);
    return this.db.tx(s.tenantId, async (c) => {
      const old = (await c.query('SELECT doc_no, status FROM stock_transfer WHERE id = $1', [id])).rows[0];
      if (old) return { id, docNo: old.doc_no, status: old.status }; // sent before (offline retry)
      const from = await actingLocation(c, s, b.location);
      if (!from.supply_from_id) throw new BadRequestException(`Set where ${from.name} gets goods from (Settings › Locations)`);
      const docNo = await nextDocNo(c, from.code, await deviceCode(c, s), 'return');
      await c.query(
        `INSERT INTO stock_transfer (id, tenant_id, from_location_id, to_location_id, doc_no, doc_date, status,
                dispatched_by, note, sent_at, kind)
         VALUES ($1, $2, $3, $4, $5, $6, 'dispatched', $7, $8, now(), 'return')`,
        [id, s.tenantId, from.id, from.supply_from_id, docNo, localDate(), s.userId, b.note?.trim() || null]);
      await this.writeLines(c, s, id, lines);
      for (const l of lines) await move(c, s, from.id, l.itemId, -l.qty, 'transfer_out', id, l.reason ?? 'return');
      await log(c, s, 'stock.return', 'stock_transfer', id, { docNo, lines });
      return { id, docNo, status: 'dispatched' };
    });
  }

  /**
   * Dispatches and returns. Without stock.view.all only those to or from the
   * user's own locations. incoming=1: on the way to the tablet's outlet.
   */
  @Get('transfers')
  transfers(@Req() req: any, @Query('kind') kind?: string, @Query('status') status?: string,
            @Query('days') days = '7', @Query('incoming') incoming?: string) {
    const s: Session = req.session;
    const all = can(s, 'stock.view.all');
    const scope = scopeOf(s);
    return this.db.tx(s.tenantId, async (c) => (await c.query(
      `SELECT t.id, t.kind, t.doc_no, t.doc_date, t.status, t.sent_at, t.received_at, t.vehicle, t.driver, t.note,
              t.has_difference, f.id AS from_id, f.code AS from_code, f.name AS from_name,
              tl.id AS to_id, tl.code AS to_code, tl.name AS to_name, du.name AS sent_by, ru.name AS received_by,
              (SELECT count(*) FROM stock_transfer_line x WHERE x.transfer_id = t.id AND x.deleted_at IS NULL)::int AS lines,
              (SELECT coalesce(sum(qty_sent), 0) FROM stock_transfer_line x WHERE x.transfer_id = t.id AND x.deleted_at IS NULL)::float AS sent,
              (SELECT sum(qty_received) FROM stock_transfer_line x WHERE x.transfer_id = t.id AND x.deleted_at IS NULL)::float AS received
         FROM stock_transfer t
         JOIN location f ON f.id = t.from_location_id
         JOIN location tl ON tl.id = t.to_location_id
         LEFT JOIN app_user du ON du.id = t.dispatched_by
         LEFT JOIN app_user ru ON ru.id = t.received_by
        WHERE t.deleted_at IS NULL
          AND ($1::text IS NULL OR t.kind = $1)
          AND ($2::text IS NULL OR t.status = $2)
          AND (t.doc_date >= current_date - $3::int OR t.status IN ('draft','dispatched'))
          AND ($4 OR t.from_location_id = ANY($5::uuid[]) OR t.to_location_id = ANY($5::uuid[]))
          AND ($6::uuid IS NULL OR (t.to_location_id = $6 AND t.status = 'dispatched'))
        ORDER BY t.created_at DESC LIMIT 300`,
      [kind || null, status || null, Math.min(Math.max(Number(days) || 7, 1), 366),
        all || scope === null, scope ?? [], incoming ? s.locationId ?? (scope?.length === 1 ? scope[0] : null) : null])).rows);
  }

  @Get('transfers/:id')
  async transfer(@Req() req: any, @Param('id') id: string) {
    const s: Session = req.session;
    return this.db.tx(s.tenantId, async (c) => {
      const t = await this.loadTransfer(c, s, id);
      return t;
    });
  }

  private async loadTransfer(c: PoolClient, s: Session, id: string, lock = false) {
    const t = (await c.query(
      `SELECT t.*, f.code AS from_code, f.name AS from_name, tl.code AS to_code, tl.name AS to_name,
              du.name AS sent_by, ru.name AS received_by_name
         FROM stock_transfer t JOIN location f ON f.id = t.from_location_id JOIN location tl ON tl.id = t.to_location_id
         LEFT JOIN app_user du ON du.id = t.dispatched_by LEFT JOIN app_user ru ON ru.id = t.received_by
        WHERE t.id = $1 AND t.deleted_at IS NULL ${lock ? 'FOR UPDATE OF t' : ''}`, [needUuid(id, 'Transfer')])).rows[0];
    if (!t) throw new NotFoundException('Not found');
    if (!can(s, 'stock.view.all') && !inScope(s, t.from_location_id) && !inScope(s, t.to_location_id)) {
      throw new ForbiddenException('Not your location');
    }
    t.lines = (await c.query(
      `SELECT l.id, l.item_id, i.code, i.name, l.qty_sent::float AS qty_sent, l.qty_received::float AS qty_received, l.reason,
              pk.factor::float AS pack_factor, u.name AS pack_name
         FROM stock_transfer_line l JOIN item i ON i.id = l.item_id
         LEFT JOIN LATERAL (SELECT p.factor, p.unit_id FROM item_pack p WHERE p.item_id = i.id AND p.deleted_at IS NULL
                             AND p.factor > 1 ORDER BY p.is_default_trade DESC, p.factor DESC LIMIT 1) pk ON true
         LEFT JOIN unit u ON u.id = pk.unit_id
        WHERE l.transfer_id = $1 AND l.deleted_at IS NULL ORDER BY l.line_no`, [t.id])).rows;
    return t;
  }

  /** Counter receives a dispatch, or the plant confirms a return. */
  @Post('transfers/:id/receive')
  receive(@Req() req: any, @Param('id') id: string,
          @Body() b: { lines?: { id: string; received: number; reason?: string }[]; note?: string }) {
    const s: Session = req.session;
    return this.db.tx(s.tenantId, async (c) => {
      const t = await this.loadTransfer(c, s, id, true);
      if (t.status === 'received') return { id: t.id, status: t.status, hasDifference: t.has_difference }; // retry
      if (t.status !== 'dispatched') throw new BadRequestException(`This is ${t.status}`);
      const perm = t.kind === 'return' ? 'stock.return.confirm' : 'stock.receive';
      if (!can(s, perm)) throw new ForbiddenException(`Needs permission ${perm}`);
      if (!inScope(s, t.to_location_id)) throw new ForbiddenException(`Only ${t.to_name} can receive this`);
      const given = new Map((b?.lines ?? []).map((l) => [l.id, l]));
      let diff = false;
      const changes: unknown[] = [];
      for (const l of t.lines) {
        const g = given.get(l.id);
        const got = g && g.received !== undefined && g.received !== null ? num(g.received, 'Received') : l.qty_sent;
        if (got < 0) throw new BadRequestException('Received cannot be negative');
        let reason: string | null = null;
        if (Math.abs(got - l.qty_sent) > 0.0005) {
          diff = true;
          reason = (g?.reason ?? '').toLowerCase();
          if (!RECEIVE_REASONS.includes(reason)) throw new BadRequestException(`Say why ${l.name} differs`);
          changes.push({ item: l.name, sent: l.qty_sent, received: got, reason });
        }
        await c.query('UPDATE stock_transfer_line SET qty_received = $2, reason = $3 WHERE id = $1', [l.id, got, reason]);
        if (got > 0) await move(c, s, t.to_location_id, l.item_id, got, 'transfer_in', t.id);
      }
      await c.query(
        `UPDATE stock_transfer SET status = 'received', received_by = $2, received_at = now(), has_difference = $3,
                note = coalesce(note || E'\\n', '') || coalesce($4, '') WHERE id = $1`,
        [t.id, s.userId, diff, b?.note?.trim() ? `Received: ${b.note.trim()}` : null]);
      await log(c, s, t.kind === 'return' ? 'stock.return.confirm' : 'stock.receive', 'stock_transfer', t.id,
        { docNo: t.doc_no, differences: changes });
      return { id: t.id, status: 'received', hasDifference: diff };
    });
  }

  /** Cancel a dispatch or return that has not been received yet; its stock goes back. */
  @Post('transfers/:id/cancel')
  cancel(@Req() req: any, @Param('id') id: string, @Body() b: { reason?: string }) {
    const s: Session = req.session;
    return this.db.tx(s.tenantId, async (c) => {
      const t = await this.loadTransfer(c, s, id, true);
      if (!['draft', 'dispatched'].includes(t.status)) throw new BadRequestException(`This is already ${t.status}`);
      const perm = t.kind === 'return' ? 'stock.receive' : 'stock.dispatch';
      if (!can(s, perm) || !inScope(s, t.from_location_id)) throw new ForbiddenException('Only the sender can cancel this');
      await c.query("UPDATE stock_move SET deleted_at = now() WHERE doc_id = $1 AND move_type = 'transfer_out' AND deleted_at IS NULL", [t.id]);
      await c.query("UPDATE stock_transfer SET status = 'cancelled', note = coalesce(note || E'\\n', '') || $2 WHERE id = $1",
        [t.id, `Cancelled: ${b?.reason?.trim() || 'no reason given'}`]);
      await log(c, s, 'stock.transfer.cancel', 'stock_transfer', t.id, { docNo: t.doc_no, reason: b?.reason });
      return { id: t.id, status: 'cancelled' };
    });
  }

  // --------------------------------------------------------------- adjustments

  @Post('adjustments')
  @Needs('stock.adjust.request')
  requestAdjustment(@Req() req: any, @Body() b: { id: string; location?: string; itemId: string; qty: number; reason: string; note?: string }) {
    const s: Session = req.session;
    const id = needUuid(b?.id, 'Request');
    const itemId = needUuid(b?.itemId, 'Item');
    const qty = num(b?.qty, 'Quantity');
    if (qty === 0) throw new BadRequestException('Quantity cannot be zero');
    const reason = String(b?.reason ?? '');
    if (!ADJUST_REASONS[reason]) throw new BadRequestException('Choose why stock is changing');
    if (reason === 'other' && !b.note?.trim()) throw new BadRequestException('Write a note for "Other"');
    return this.db.tx(s.tenantId, async (c) => {
      const old = (await c.query('SELECT id, status FROM stock_adjustment WHERE id = $1', [id])).rows[0];
      if (old) return old;
      const loc = await actingLocation(c, s, b.location);
      return this.createAdjustment(c, s, { id, locationId: loc.id, itemId, qty, reason, note: b.note?.trim() || null });
    });
  }

  private async createAdjustment(c: PoolClient, s: Session,
                                 a: { id: string; locationId: string; itemId: string; qty: number; reason: string; note: string | null; countId?: string }) {
    const st = await stockSettings(c);
    const mrp = (await mrpMap(c)).get(a.itemId);
    if (mrp === undefined) throw new BadRequestException('Unknown item');
    const value = Math.round(Math.abs(a.qty) * mrp * 100) / 100;
    const needsOwner = value > st.ownerAbove;
    await c.query(
      `INSERT INTO stock_adjustment (id, tenant_id, location_id, item_id, qty, reason, note, value, needs_owner,
              count_id, device_id, requested_by)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)`,
      [a.id, s.tenantId, a.locationId, a.itemId, a.qty, a.reason, a.note, value, needsOwner, a.countId ?? null,
        s.deviceId, s.userId]);
    await log(c, s, 'stock.adjust.request', 'stock_adjustment', a.id, { ...a, value, needsOwner });
    return { id: a.id, status: 'pending', value, needsOwner };
  }

  /** Approvers see every pending request they may decide; a counter sees its own outlet's. */
  @Get('adjustments')
  adjustments(@Req() req: any, @Query('status') status = 'pending', @Query('days') days = '30') {
    const s: Session = req.session;
    if (!can(s, 'stock.adjust') && !can(s, 'stock.adjust.request') && !can(s, 'audit.view')) {
      throw new ForbiddenException('Needs permission stock.adjust');
    }
    const scope = scopeOf(s);
    return this.db.tx(s.tenantId, async (c) => (await c.query(
      `SELECT a.id, a.qty::float AS qty, a.reason, a.note, a.value::float AS value, a.needs_owner, a.status,
              a.requested_at, a.decided_at, a.decision_note, a.count_id,
              l.id AS location_id, l.code AS location_code, l.name AS location_name,
              i.id AS item_id, i.code AS item_code, i.name AS item_name,
              ru.name AS requested_by, du.name AS decided_by, d.code AS device_code, a.requested_by = $4 AS mine,
              (SELECT coalesce(sum(x.value), 0) FROM stock_adjustment x
                WHERE x.location_id = a.location_id AND x.status = 'approved' AND x.qty < 0
                  AND x.requested_at >= date_trunc('month', now()))::float AS location_month_value,
              (SELECT count(*) FROM stock_adjustment x
                WHERE x.location_id = a.location_id AND x.reason = a.reason AND x.deleted_at IS NULL
                  AND x.requested_at >= now() - interval '7 days')::int AS same_reason_week
         FROM stock_adjustment a
         JOIN location l ON l.id = a.location_id
         JOIN item i ON i.id = a.item_id
         JOIN app_user ru ON ru.id = a.requested_by
         LEFT JOIN app_user du ON du.id = a.decided_by
         LEFT JOIN device d ON d.id = a.device_id
        WHERE a.deleted_at IS NULL AND ($1 = 'all' OR a.status = $1)
          AND (a.status = 'pending' OR a.requested_at >= now() - make_interval(days => $2::int))
          AND ($3::uuid[] IS NULL OR a.location_id = ANY($3::uuid[]))
        ORDER BY a.requested_at DESC LIMIT 300`,
      [status, Math.min(Math.max(Number(days) || 30, 1), 366), scope, s.userId])).rows);
  }

  @Post('adjustments/:id/decide')
  @Needs('stock.adjust')
  decide(@Req() req: any, @Param('id') id: string, @Body() b: { approve: boolean; note?: string }) {
    const s: Session = req.session;
    return this.db.tx(s.tenantId, async (c) => {
      const a = (await c.query('SELECT * FROM stock_adjustment WHERE id = $1 AND deleted_at IS NULL FOR UPDATE',
        [needUuid(id, 'Request')])).rows[0];
      if (!a) throw new NotFoundException('Request not found');
      if (a.status !== 'pending') throw new BadRequestException(`Already ${a.status}`);
      if (!inScope(s, a.location_id)) throw new ForbiddenException('Not your location');
      if (a.needs_owner && !can(s, 'stock.adjust.any')) {
        const st = await stockSettings(c);
        throw new ForbiddenException(`Above Rs ${st.ownerAbove}: needs the Owner's approval`);
      }
      if (a.requested_by === s.userId && !s.permissions.includes('*')) {
        throw new ForbiddenException('Someone else must approve your own request');
      }
      if (!b?.approve && !b?.note?.trim()) throw new BadRequestException('Give a reason for rejecting');
      const status = b?.approve ? 'approved' : 'rejected';
      await c.query(
        `UPDATE stock_adjustment SET status = $2, decided_by = $3, decided_at = now(), decision_note = $4 WHERE id = $1`,
        [a.id, status, s.userId, b?.note?.trim() || null]);
      if (b?.approve) {
        await move(c, s, a.location_id, a.item_id, Number(a.qty), a.reason === 'count' ? 'count' : 'adjustment', a.id, a.reason);
      }
      await log(c, s, `stock.adjust.${status}`, 'stock_adjustment', a.id, { note: b?.note, value: a.value });
      return { id: a.id, status };
    });
  }

  // -------------------------------------------------------------------- counts

  /**
   * A finished blind count. The system quantity is taken now, so tablets send
   * their bills first. Each difference becomes an adjustment request.
   */
  @Post('counts')
  @Needs('stock.count')
  count(@Req() req: any, @Body() b: { id: string; location?: string; startedAt?: string; note?: string; lines: { itemId: string; counted: number }[] }) {
    const s: Session = req.session;
    const id = needUuid(b?.id, 'Count');
    if (!Array.isArray(b?.lines) || !b.lines.length) throw new BadRequestException('Count at least one item');
    const lines = new Map<string, number>();
    for (const l of b.lines) {
      const q = num(l?.counted, 'Counted');
      if (q < 0) throw new BadRequestException('Counted cannot be negative');
      lines.set(needUuid(l?.itemId, 'Item'), q);
    }
    return this.db.tx(s.tenantId, async (c) => {
      if (!(await c.query('SELECT 1 FROM stock_count WHERE id = $1', [id])).rowCount) {
        const loc = await actingLocation(c, s, b.location);
        const started = b.startedAt && !Number.isNaN(Date.parse(b.startedAt)) ? new Date(b.startedAt) : new Date();
        await c.query(
          `INSERT INTO stock_count (id, tenant_id, location_id, device_id, counted_by, started_at, finished_at, note)
           VALUES ($1, $2, $3, $4, $5, $6, now(), $7)`,
          [id, s.tenantId, loc.id, s.deviceId, s.userId, started, b.note?.trim() || null]);
        const have = await onHand(c, loc.id);
        for (const [itemId, counted] of lines) {
          const sys = Math.round((have.get(itemId) ?? 0) * 1000) / 1000;
          await c.query(
            `INSERT INTO stock_count_line (tenant_id, count_id, item_id, counted, system_qty) VALUES ($1, $2, $3, $4, $5)`,
            [s.tenantId, id, itemId, counted, sys]);
          const diff = Math.round((counted - sys) * 1000) / 1000;
          if (diff !== 0) {
            await this.createAdjustment(c, s, {
              id: (await c.query('SELECT gen_random_uuid() AS id')).rows[0].id, locationId: loc.id, itemId, qty: diff,
              reason: 'count', note: 'Stock count', countId: id,
            });
          }
        }
        await log(c, s, 'stock.count', 'stock_count', id, { location: loc.code, items: lines.size });
      }
      return this.countResult(c, s, id);
    });
  }

  private async countResult(c: PoolClient, s: Session, id: string) {
    const head = (await c.query(
      `SELECT k.id, k.started_at, k.finished_at, k.note, l.id AS location_id, l.code AS location_code, l.name AS location_name,
              u.name AS counted_by
         FROM stock_count k JOIN location l ON l.id = k.location_id JOIN app_user u ON u.id = k.counted_by
        WHERE k.id = $1`, [id])).rows[0];
    if (!head) throw new NotFoundException('Count not found');
    if (!can(s, 'stock.view.all') && !inScope(s, head.location_id)) throw new ForbiddenException('Not your location');
    const mrp = await mrpMap(c);
    head.lines = (await c.query(
      `SELECT cl.item_id, i.code, i.name, cl.counted::float AS counted, cl.system_qty::float AS system_qty
         FROM stock_count_line cl JOIN item i ON i.id = cl.item_id
        WHERE cl.count_id = $1 ORDER BY (cl.counted - cl.system_qty) = 0, i.name`, [id])).rows
      .map((l: any) => {
        const diff = Math.round((l.counted - l.system_qty) * 1000) / 1000;
        return { ...l, diff, value: Math.round(diff * (mrp.get(l.item_id) ?? 0) * 100) / 100 };
      });
    head.totalValue = Math.round(head.lines.reduce((t: number, l: any) => t + l.value, 0) * 100) / 100;
    return head;
  }

  @Get('counts/:id')
  countGet(@Req() req: any, @Param('id') id: string) {
    const s: Session = req.session;
    return this.db.tx(s.tenantId, (c) => this.countResult(c, s, needUuid(id, 'Count')));
  }

  @Get('counts')
  counts(@Req() req: any, @Query('days') days = '30') {
    const s: Session = req.session;
    const scope = can(s, 'stock.view.all') ? null : scopeOf(s);
    return this.db.tx(s.tenantId, async (c) => (await c.query(
      `SELECT k.id, k.finished_at, l.code AS location_code, l.name AS location_name, u.name AS counted_by,
              count(cl.*)::int AS items,
              count(*) FILTER (WHERE cl.counted <> cl.system_qty)::int AS differences
         FROM stock_count k JOIN location l ON l.id = k.location_id JOIN app_user u ON u.id = k.counted_by
         LEFT JOIN stock_count_line cl ON cl.count_id = k.id
        WHERE k.deleted_at IS NULL AND k.finished_at >= now() - make_interval(days => $1::int)
          AND ($2::uuid[] IS NULL OR k.location_id = ANY($2::uuid[]))
        GROUP BY k.id, l.code, l.name, u.name ORDER BY k.finished_at DESC LIMIT 200`,
      [Math.min(Math.max(Number(days) || 30, 1), 366), scope])).rows);
  }

  // ------------------------------------------------------------------ position

  /** Every item at every location, for head office. */
  @Get('position')
  @Needs('stock.view.all')
  position(@Req() req: any) {
    const s: Session = req.session;
    return this.db.tx(s.tenantId, async (c) => {
      const mrp = await mrpMap(c);
      const locations = (await c.query(
        `SELECT id, code, name, kind FROM location WHERE deleted_at IS NULL AND is_active AND kind <> 'centre'
          ORDER BY kind <> 'plant', kind <> 'godown', code`)).rows;
      const qty = (await c.query(
        `SELECT item_id, location_id, sum(qty)::float AS qty FROM stock_move WHERE deleted_at IS NULL
          GROUP BY item_id, location_id HAVING sum(qty) <> 0`)).rows;
      const items = (await c.query(
        `SELECT i.id, i.code, i.name, ic.name AS category, i.reorder_level::float AS reorder_level
           FROM item i LEFT JOIN item_category ic ON ic.id = i.category_id
          WHERE i.deleted_at IS NULL AND i.is_active ORDER BY ic.name NULLS LAST, i.pos_sort, i.name`)).rows;
      const byItem = new Map<string, Record<string, number>>();
      for (const q of qty) {
        const m = byItem.get(q.item_id) ?? {};
        m[q.location_id] = Math.round(q.qty * 1000) / 1000;
        byItem.set(q.item_id, m);
      }
      const transit = (await c.query(
        `SELECT count(DISTINCT t.id)::int AS docs, coalesce(sum(l.qty_sent), 0)::float AS qty
           FROM stock_transfer t JOIN stock_transfer_line l ON l.transfer_id = t.id AND l.deleted_at IS NULL
          WHERE t.status = 'dispatched' AND t.deleted_at IS NULL`)).rows[0];
      return {
        locations,
        items: items.map((i: any) => ({ ...i, mrp: mrp.get(i.id) ?? 0, qty: byItem.get(i.id) ?? {} })),
        inTransit: transit,
      };
    });
  }

  /** Stock at one location with today's sales (tablet: its own outlet). */
  @Get('here')
  here(@Req() req: any, @Query('location') chosen?: string) {
    const s: Session = req.session;
    return this.db.tx(s.tenantId, async (c) => {
      const loc = await actingLocation(c, s, chosen);
      const rows = (await c.query(
        `SELECT m.item_id, sum(m.qty)::float AS qty,
                (-sum(m.qty) FILTER (WHERE m.move_type IN ('sale','sale_return') AND m.move_date = $2))::float AS sold_today
           FROM stock_move m WHERE m.location_id = $1 AND m.deleted_at IS NULL GROUP BY m.item_id`,
        [loc.id, localDate()])).rows;
      return { location: { id: loc.id, code: loc.code, name: loc.name }, asOf: new Date().toISOString(), items: rows };
    });
  }

  /** One item's movements at one location. */
  @Get('movements')
  movements(@Req() req: any, @Query('item') item: string, @Query('location') loc: string, @Query('days') days = '30') {
    const s: Session = req.session;
    return this.db.tx(s.tenantId, async (c) => {
      const l = await location(c, loc);
      if (!can(s, 'stock.view.all') && !inScope(s, l.id)) throw new ForbiddenException('Not your location');
      const n = Math.min(Math.max(Number(days) || 30, 1), 366);
      const opening = (await c.query(
        `SELECT coalesce(sum(qty), 0)::float AS q FROM stock_move WHERE location_id = $1 AND item_id = $2
            AND deleted_at IS NULL AND move_date < current_date - $3::int`, [l.id, needUuid(item, 'Item'), n])).rows[0].q;
      const moves = (await c.query(
        `SELECT m.move_date, m.move_type, m.qty::float AS qty, m.reason, u.name AS by,
                coalesce(t.doc_no, si.doc_no) AS doc_no
           FROM stock_move m LEFT JOIN app_user u ON u.id = m.created_by
           LEFT JOIN stock_transfer t ON t.id = m.doc_id
           LEFT JOIN sales_invoice si ON si.id = m.doc_id
          WHERE m.location_id = $1 AND m.item_id = $2 AND m.deleted_at IS NULL AND m.move_date >= current_date - $3::int
          ORDER BY m.move_date, m.created_at`, [l.id, item, n])).rows;
      return { opening, moves };
    });
  }
}
