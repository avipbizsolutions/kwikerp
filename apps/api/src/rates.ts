import { BadRequestException, Body, Controller, Get, NotFoundException, Post, Req, UseGuards } from '@nestjs/common';
import { AuthGuard, Needs, Session } from './auth';
import { Db } from './db';

/** India date, since rates change at the start of an outlet's day. */
function todayIst(): string {
  return new Date(Date.now() + 5.5 * 3600 * 1000).toISOString().slice(0, 10);
}
function isDate(v?: string): boolean {
  if (!v || !/^\d{4}-\d{2}-\d{2}$/.test(v)) return false;
  const d = new Date(`${v}T00:00:00Z`);
  return !Number.isNaN(d.getTime()) && d.toISOString().slice(0, 10) === v;
}
const money = (v: unknown) => Math.round(Number(v) * 100) / 100;

interface TypeBody {
  id?: string;
  code: string;
  name: string;
  priceLevelId: string;
  creditAllowed: boolean;
  isActive?: boolean;
  maxOutstanding?: number | null; // type's credit limit; null = no amount limit
  maxDays?: number | null;
  capToSecurity?: boolean;
}

interface RatesBody {
  effectiveFrom: string;
  changes: { itemId: string; levelId: string; price: number }[];
  note?: string;
}

/**
 * Customer types and the rate chart, for owners and managers (rates.manage),
 * on the head-office page and the tablet. One column per rate list (price
 * level); one chart for all outlets; tray / box rates = piece rate x pack size.
 */
@Controller()
@UseGuards(AuthGuard)
export class RatesController {
  constructor(private readonly db: Db) {}

  @Get('customer-types')
  @Needs('rates.manage')
  types(@Req() req: any) {
    const s: Session = req.session;
    return this.db.tx(s.tenantId, async (c) => ({
      types: (await c.query(
        `SELECT cc.id, cc.code, cc.name, cc.default_price_level_id AS price_level_id, pl.name AS price_level,
                cc.credit_allowed, cc.is_active,
                (SELECT count(*)::int FROM customer cu WHERE cu.category_id = cc.id AND cu.deleted_at IS NULL) AS customers,
                l.id AS limit_id, l.max_outstanding::float AS max_outstanding, l.max_days, l.cap_to_security
           FROM customer_category cc
           JOIN price_level pl ON pl.id = cc.default_price_level_id
           LEFT JOIN LATERAL (
             SELECT * FROM credit_limit l WHERE l.customer_category_id = cc.id AND l.deleted_at IS NULL
                AND l.valid_from <= current_date AND (l.valid_to IS NULL OR l.valid_to >= current_date)
              ORDER BY l.valid_from DESC, l.created_at DESC LIMIT 1) l ON true
          WHERE cc.deleted_at IS NULL
          ORDER BY cc.is_active DESC, pl.sort_order, cc.name`)).rows,
      levels: (await c.query(
        `SELECT id, code, name, sort_order FROM price_level WHERE deleted_at IS NULL AND is_active ORDER BY sort_order, name`)).rows,
    }));
  }

  @Post('customer-types')
  @Needs('rates.manage')
  saveType(@Req() req: any, @Body() b: TypeBody) {
    const s: Session = req.session;
    const name = (b?.name ?? '').trim();
    const code = (b?.code ?? '').trim().toUpperCase().replace(/[^A-Z0-9_]/g, '_');
    if (!name) throw new BadRequestException('Name is required');
    if (!code) throw new BadRequestException('Short code is required');
    const max = b.maxOutstanding === null || b.maxOutstanding === undefined || (b.maxOutstanding as any) === '' ? null : Number(b.maxOutstanding);
    const days = b.maxDays === null || b.maxDays === undefined || (b.maxDays as any) === '' ? null : Number(b.maxDays);
    if (max !== null && !(max >= 0)) throw new BadRequestException('Credit limit must be 0 or more');
    if (days !== null && !(days >= 1 && days <= 3650)) throw new BadRequestException('Days must be 1 to 3650');

    return this.db.tx(s.tenantId, async (c) => {
      if (!(await c.query('SELECT 1 FROM price_level WHERE id = $1 AND deleted_at IS NULL', [b.priceLevelId])).rowCount) {
        throw new BadRequestException('Choose the rates this type bills at');
      }
      const dup = (await c.query(
        `SELECT name FROM customer_category WHERE (upper(code) = $1 OR lower(name) = lower($2)) AND deleted_at IS NULL
            AND id IS DISTINCT FROM $3::uuid`, [code, name, b.id ?? null])).rows[0];
      if (dup) throw new BadRequestException(`A customer type "${dup.name}" already uses that name or code`);
      let id = b.id;
      if (id) {
        const r = await c.query(
          `UPDATE customer_category SET code = $2, name = $3, default_price_level_id = $4, credit_allowed = $5, is_active = $6
            WHERE id = $1 AND deleted_at IS NULL`, [id, code, name, b.priceLevelId, !!b.creditAllowed, b.isActive ?? true]);
        if (!r.rowCount) throw new NotFoundException('Customer type not found');
      } else {
        id = (await c.query(
          `INSERT INTO customer_category (tenant_id, code, name, default_price_level_id, credit_allowed, is_active)
           VALUES ($1, $2, $3, $4, $5, $6) RETURNING id`,
          [s.tenantId, code, name, b.priceLevelId, !!b.creditAllowed, b.isActive ?? true])).rows[0].id;
      }
      // The type's credit limit: replace the current one when it changed
      const cur = (await c.query(
        `SELECT max_outstanding::float AS m, max_days AS d, cap_to_security AS k FROM credit_limit
          WHERE customer_category_id = $1 AND deleted_at IS NULL AND valid_from <= current_date
            AND (valid_to IS NULL OR valid_to >= current_date) ORDER BY valid_from DESC, created_at DESC LIMIT 1`, [id])).rows[0];
      const want = { m: b.creditAllowed ? max : 0, d: b.creditAllowed ? days : null, k: !!b.capToSecurity };
      if (!cur || cur.m !== want.m || cur.d !== want.d || cur.k !== want.k) {
        await c.query(
          `UPDATE credit_limit SET deleted_at = now()
            WHERE customer_category_id = $1 AND deleted_at IS NULL AND (valid_to IS NULL OR valid_to >= current_date)`, [id]);
        await c.query(
          `INSERT INTO credit_limit (tenant_id, customer_category_id, max_outstanding, max_days, cap_to_security, valid_from, set_by, note)
           VALUES ($1, $2, $3, $4, $5, current_date, $6, 'Customer type settings')`,
          [s.tenantId, id, want.m, want.d, want.k, s.userId]);
      }
      await c.query(
        `INSERT INTO audit_log (tenant_id, user_id, action, entity, entity_id, detail)
         VALUES ($1, $2, $3, 'customer_category', $4, $5)`,
        [s.tenantId, s.userId, b.id ? 'customer_type.edit' : 'customer_type.add', id, JSON.stringify(b)]);
      return { id };
    });
  }

  /** The whole rate chart: base-unit rates per item and rate list, today's and any coming. */
  @Get('rates')
  @Needs('rates.manage')
  rates(@Req() req: any) {
    const s: Session = req.session;
    const today = todayIst();
    return this.db.tx(s.tenantId, async (c) => {
      const levels = (await c.query(
        `SELECT pl.id, pl.code, pl.name, pl.sort_order,
                coalesce((SELECT string_agg(cc.name, ', ' ORDER BY cc.name) FROM customer_category cc
                           WHERE cc.default_price_level_id = pl.id AND cc.deleted_at IS NULL AND cc.is_active), '') AS used_by
           FROM price_level pl WHERE pl.deleted_at IS NULL AND pl.is_active ORDER BY pl.sort_order, pl.name`)).rows;
      const items = (await c.query(
        `SELECT i.id, i.code, i.name, i.pack_size, u.code AS unit, i.sold_by_weight, ic.name AS category, ic.id AS category_id,
                (SELECT string_agg(pu.code || ' of ' || trim(to_char(p.factor, 'FM999990.###')), ', ')
                   FROM item_pack p JOIN unit pu ON pu.id = p.unit_id
                  WHERE p.item_id = i.id AND p.unit_id <> i.base_unit_id AND p.deleted_at IS NULL) AS packs
           FROM item i JOIN unit u ON u.id = i.base_unit_id LEFT JOIN item_category ic ON ic.id = i.category_id
          WHERE i.deleted_at IS NULL AND i.is_active
          ORDER BY ic.name NULLS LAST, i.pos_sort, i.name`)).rows;
      // Latest rate on or before today, and the next one after today, per item x rate list (all outlets)
      const prices = (await c.query(
        `SELECT p.item_id, p.price_level_id,
                (array_agg(p.price::float ORDER BY p.valid_from DESC) FILTER (WHERE p.valid_from <= $1))[1] AS price,
                (array_agg(p.price::float ORDER BY p.valid_from) FILTER (WHERE p.valid_from > $1))[1] AS next_price,
                min(p.valid_from) FILTER (WHERE p.valid_from > $1)::text AS next_from
           FROM item_price p JOIN item i ON i.id = p.item_id AND p.unit_id = i.base_unit_id
          WHERE p.location_id IS NULL AND p.deleted_at IS NULL
          GROUP BY p.item_id, p.price_level_id`, [today])).rows;
      return { today, levels, items, prices };
    });
  }

  /**
   * Save changed rates from a date. Each change is the base-unit (piece / kg)
   * rate; trays and boxes are set to piece rate x pack size on the same date.
   */
  @Post('rates')
  @Needs('rates.manage')
  saveRates(@Req() req: any, @Body() b: RatesBody) {
    const s: Session = req.session;
    const from = b?.effectiveFrom;
    if (!isDate(from)) throw new BadRequestException('Choose the date the new rates apply from');
    if (from < todayIst()) throw new BadRequestException('New rates cannot start in the past');
    if (!Array.isArray(b.changes) || !b.changes.length) throw new BadRequestException('No rates changed');
    if (b.changes.length > 5000) throw new BadRequestException('Too many changes at once');
    for (const ch of b.changes) {
      const p = Number(ch?.price);
      if (!(p >= 0 && p < 10_000_000)) throw new BadRequestException('Rates must be 0 or more');
    }
    return this.db.tx(s.tenantId, async (c) => {
      let rows = 0;
      for (const ch of b.changes) {
        const item = (await c.query('SELECT base_unit_id FROM item WHERE id = $1 AND deleted_at IS NULL', [ch.itemId])).rows[0];
        if (!item) throw new BadRequestException('Unknown item');
        if (!(await c.query('SELECT 1 FROM price_level WHERE id = $1 AND deleted_at IS NULL', [ch.levelId])).rowCount) {
          throw new BadRequestException('Unknown rate list');
        }
        const units = [{ unit: item.base_unit_id, price: money(ch.price) },
          ...(await c.query(
            `SELECT unit_id, factor::float AS factor FROM item_pack
              WHERE item_id = $1 AND unit_id <> $2 AND deleted_at IS NULL`, [ch.itemId, item.base_unit_id])).rows
            .map((p: any) => ({ unit: p.unit_id, price: money(Number(ch.price) * p.factor) }))];
        for (const u of units) {
          await c.query(
            `INSERT INTO item_price (tenant_id, item_id, unit_id, price_level_id, location_id, price, valid_from, note)
             VALUES ($1, $2, $3, $4, NULL, $5, $6, $7)
             ON CONFLICT (item_id, unit_id, price_level_id, coalesce(location_id, '00000000-0000-0000-0000-000000000000'::uuid), valid_from)
               WHERE deleted_at IS NULL
             DO UPDATE SET price = EXCLUDED.price, note = EXCLUDED.note`,
            [s.tenantId, ch.itemId, u.unit, ch.levelId, u.price, from, b.note?.trim() || `Rate chart, set by ${s.userName}`]);
          rows += 1;
        }
      }
      await c.query(
        `INSERT INTO audit_log (tenant_id, user_id, device_id, action, entity, detail)
         VALUES ($1, $2, $3, 'rates.set', 'item_price', $4)`,
        [s.tenantId, s.userId, s.deviceId, JSON.stringify({ effectiveFrom: from, changes: b.changes })]);
      return { saved: b.changes.length, rows, effectiveFrom: from };
    });
  }

  /** A new rate list (a new column), optionally starting as a copy of another. */
  @Post('price-levels')
  @Needs('rates.manage')
  addLevel(@Req() req: any, @Body() b: { name: string; code?: string; copyFromId?: string }) {
    const s: Session = req.session;
    const name = (b?.name ?? '').trim();
    if (!name) throw new BadRequestException('Name the new rate list');
    const code = ((b.code ?? '').trim() || name).toUpperCase().replace(/[^A-Z0-9]+/g, '_').replace(/^_|_$/g, '').slice(0, 20);
    return this.db.tx(s.tenantId, async (c) => {
      if ((await c.query('SELECT 1 FROM price_level WHERE (upper(code) = $1 OR lower(name) = lower($2)) AND deleted_at IS NULL',
        [code, name])).rowCount) throw new BadRequestException('A rate list with that name already exists');
      const id = (await c.query(
        `INSERT INTO price_level (tenant_id, code, name, sort_order)
         VALUES ($1, $2, $3, (SELECT coalesce(max(sort_order), 0) + 1 FROM price_level)) RETURNING id`,
        [s.tenantId, code, name])).rows[0].id;
      if (b.copyFromId) {
        await c.query(
          `INSERT INTO item_price (tenant_id, item_id, unit_id, price_level_id, location_id, price, valid_from, note)
           SELECT DISTINCT ON (item_id, unit_id) tenant_id, item_id, unit_id, $1, NULL, price, current_date, 'Copied at creation'
             FROM item_price WHERE price_level_id = $2 AND location_id IS NULL AND deleted_at IS NULL AND valid_from <= current_date
            ORDER BY item_id, unit_id, valid_from DESC`, [id, b.copyFromId]);
      }
      await c.query(
        `INSERT INTO audit_log (tenant_id, user_id, action, entity, entity_id, detail)
         VALUES ($1, $2, 'price_level.add', 'price_level', $3, $4)`, [s.tenantId, s.userId, id, JSON.stringify(b)]);
      return { id, code };
    });
  }
}
