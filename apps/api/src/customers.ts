import {
  BadRequestException, Body, Controller, Get, NotFoundException, Post, Query, Req, UseGuards,
} from '@nestjs/common';
import { AuthGuard, Needs, Session } from './auth';
import { Db } from './db';

interface CustomerBody {
  id?: string;
  code?: string;
  name: string;
  categoryId: string;
  priceLevelId?: string | null; // null = category default
  phone?: string;
  gstin?: string;
  stateCode?: string;
  address?: string;
  homeLocationId?: string | null;
  securityAmount?: number;
  openingBalance?: number;
  isActive?: boolean;
  allowDuplicatePhone?: boolean;
}

interface LimitBody {
  categoryId?: string;
  customerId?: string;
  maxOutstanding?: number | null; // null = no amount limit
  maxDays?: number | null;        // null = no age limit
  capToSecurity?: boolean;
  validDays?: number | null;      // temporary raise; null = permanent
  note?: string;
  remove?: boolean;               // customer only: go back to the category limit
}

const num = (v: unknown) => (v === null || v === undefined || v === '' ? null : Number(v));

@Controller()
@UseGuards(AuthGuard)
export class CustomersController {
  constructor(private readonly db: Db) {}

  /** Lists for the head-office forms. */
  @Get('customers/meta')
  @Needs('customer.edit')
  meta(@Req() req: any) {
    const s: Session = req.session;
    return this.db.tx(s.tenantId, async (c) => ({
      categories: (await c.query(
        `SELECT cc.id, cc.code, cc.name, cc.credit_allowed, pl.name AS default_level, l.id AS limit_id,
                l.max_outstanding::float AS max_outstanding, l.max_days, l.cap_to_security, l.valid_to,
                (SELECT count(*)::int FROM customer cu WHERE cu.category_id = cc.id AND cu.deleted_at IS NULL) AS customers
           FROM customer_category cc
           JOIN price_level pl ON pl.id = cc.default_price_level_id
           LEFT JOIN LATERAL (
             SELECT * FROM credit_limit l WHERE l.customer_category_id = cc.id AND l.deleted_at IS NULL
                AND l.valid_from <= current_date AND (l.valid_to IS NULL OR l.valid_to >= current_date)
              ORDER BY l.valid_from DESC, l.created_at DESC LIMIT 1) l ON true
          WHERE cc.deleted_at IS NULL ORDER BY cc.name`)).rows,
      priceLevels: (await c.query(
        'SELECT id, code, name FROM price_level WHERE deleted_at IS NULL ORDER BY name')).rows,
      locations: (await c.query(
        `SELECT id, code, name FROM location WHERE deleted_at IS NULL AND kind IN ('outlet','franchise','plant')
          ORDER BY code`)).rows,
    }));
  }

  /** Search customers with their outstanding and the limit that applies. */
  @Get('customers')
  @Needs('customer.edit')
  list(@Req() req: any, @Query('q') q = '', @Query('category') category = '') {
    const s: Session = req.session;
    const like = `%${q.trim().toLowerCase()}%`;
    return this.db.tx(s.tenantId, async (c) => (await c.query(
      `SELECT cu.id, cu.code, cu.name, cu.phone, cu.gstin, cu.state_code, cu.address, cu.is_active,
              cu.category_id, cc.name AS category, cu.price_level_id, pl.name AS price_level,
              cu.home_location_id, hl.code AS home_location,
              cu.security_amount::float AS security_amount, cu.opening_balance::float AS opening_balance,
              coalesce(o.outstanding, 0)::float AS outstanding,
              ccl.max_outstanding::float AS limit_amount, ccl.max_days AS limit_days, ccl.source AS limit_source,
              own.valid_to AS own_limit_until
         FROM customer cu
         JOIN customer_category cc ON cc.id = cu.category_id
         LEFT JOIN price_level pl ON pl.id = cu.price_level_id
         LEFT JOIN location hl ON hl.id = cu.home_location_id
         LEFT JOIN customer_outstanding o ON o.customer_id = cu.id
         LEFT JOIN customer_credit_limit ccl ON ccl.customer_id = cu.id
         LEFT JOIN LATERAL (
           SELECT valid_to FROM credit_limit l WHERE l.customer_id = cu.id AND l.deleted_at IS NULL
              AND l.valid_from <= current_date AND (l.valid_to IS NULL OR l.valid_to >= current_date)
            ORDER BY l.valid_from DESC, l.created_at DESC LIMIT 1) own ON true
        WHERE cu.deleted_at IS NULL
          AND ($1 = '%%' OR lower(cu.name) LIKE $1 OR coalesce(cu.phone, '') LIKE $1 OR lower(coalesce(cu.code, '')) LIKE $1)
          AND ($2 = '' OR cu.category_id::text = $2)
        ORDER BY cu.is_active DESC, coalesce(o.outstanding, 0) DESC, cu.name
        LIMIT 300`, [like, category])).rows);
  }

  /** Add or edit a customer. */
  @Post('customers')
  @Needs('customer.edit')
  save(@Req() req: any, @Body() b: CustomerBody) {
    const s: Session = req.session;
    const name = (b?.name ?? '').trim();
    if (!name) throw new BadRequestException('Name is required');
    if (!b.categoryId) throw new BadRequestException('Customer type is required');
    const phone = (b.phone ?? '').replace(/\D/g, '').replace(/^91(?=\d{10}$)/, '') || null;
    if (phone && phone.length !== 10) throw new BadRequestException('Mobile number must have 10 digits');
    const gstin = (b.gstin ?? '').trim().toUpperCase() || null;
    if (gstin && !/^\d{2}[A-Z0-9]{13}$/.test(gstin)) throw new BadRequestException('GSTIN must be 15 characters');
    // GSTIN starts with the state code; otherwise default to the company's state
    const state = gstin ? gstin.slice(0, 2) : ((b.stateCode ?? '').trim() || null);

    return this.db.tx(s.tenantId, async (c) => {
      if (!(await c.query('SELECT 1 FROM customer_category WHERE id = $1', [b.categoryId])).rowCount) {
        throw new BadRequestException('Unknown customer type');
      }
      if (phone && !b.allowDuplicatePhone) {
        const dup = (await c.query(
          `SELECT name FROM customer WHERE phone = $1 AND deleted_at IS NULL AND id IS DISTINCT FROM $2::uuid LIMIT 1`,
          [phone, b.id ?? null])).rows[0];
        if (dup) throw new BadRequestException(`Mobile ${phone} is already used by ${dup.name}`);
      }
      const vals = [s.tenantId, b.code?.trim() || null, name, b.categoryId, b.priceLevelId || null, phone, gstin,
        state, b.address?.trim() || null, b.homeLocationId || null, num(b.securityAmount) ?? 0,
        num(b.openingBalance) ?? 0, b.isActive ?? true];
      let row;
      if (b.id) {
        row = (await c.query(
          `UPDATE customer SET code = $2, name = $3, category_id = $4, price_level_id = $5, phone = $6, gstin = $7,
                  state_code = $8, address = $9, home_location_id = $10, security_amount = $11,
                  opening_balance = $12, is_active = $13
            WHERE id = $14 AND deleted_at IS NULL RETURNING id`, [...vals, b.id])).rows[0];
        if (!row) throw new NotFoundException('Customer not found');
      } else {
        row = (await c.query(
          `INSERT INTO customer (tenant_id, code, name, category_id, price_level_id, phone, gstin, state_code, address,
                                 home_location_id, security_amount, opening_balance, is_active)
           VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13) RETURNING id`, vals)).rows[0];
      }
      await c.query(
        `INSERT INTO audit_log (tenant_id, user_id, action, entity, entity_id, detail)
         VALUES ($1, $2, $3, 'customer', $4, $5)`,
        [s.tenantId, s.userId, b.id ? 'customer.edit' : 'customer.add', row.id, JSON.stringify({ ...b, phone, gstin })]);
      return { id: row.id };
    });
  }

  /**
   * Set a credit limit for a customer type or one customer.
   * Permanent: replaces the current limit. Temporary (validDays): applies on
   * top until it ends, then the permanent one is back.
   */
  @Post('credit-limits')
  @Needs('credit.limit.set')
  setLimit(@Req() req: any, @Body() b: LimitBody) {
    const s: Session = req.session;
    if (!b || (!b.categoryId) === (!b.customerId)) throw new BadRequestException('Give categoryId or customerId');
    const col = b.categoryId ? 'customer_category_id' : 'customer_id';
    const target = b.categoryId ?? b.customerId;
    const max = num(b.maxOutstanding);
    const days = num(b.maxDays);
    const valid = num(b.validDays);
    if (max !== null && (!(max >= 0) || max > 1e9)) throw new BadRequestException('Limit must be 0 or more');
    if (days !== null && !(days >= 1 && days <= 3650)) throw new BadRequestException('Days must be 1 to 3650');
    if (valid !== null && !(valid >= 1 && valid <= 365)) throw new BadRequestException('Temporary limit: 1 to 365 days');

    return this.db.tx(s.tenantId, async (c) => {
      const table = b.categoryId ? 'customer_category' : 'customer';
      if (!(await c.query(`SELECT 1 FROM ${table} WHERE id = $1 AND deleted_at IS NULL`, [target])).rowCount) {
        throw new NotFoundException('Not found');
      }
      if (b.remove) {
        if (!b.customerId) throw new BadRequestException('Only a customer limit can be removed');
        await c.query(
          `UPDATE credit_limit SET deleted_at = now() WHERE customer_id = $1 AND deleted_at IS NULL`, [target]);
      } else {
        if (valid === null) {
          // A new permanent limit replaces everything current or planned for this target.
          await c.query(
            `UPDATE credit_limit SET deleted_at = now()
              WHERE ${col} = $1 AND deleted_at IS NULL AND (valid_to IS NULL OR valid_to >= current_date)`, [target]);
        }
        await c.query(
          `INSERT INTO credit_limit (tenant_id, ${col}, max_outstanding, max_days, cap_to_security, valid_from,
                                     valid_to, set_by, note)
           VALUES ($1, $2, $3, $4, $5, current_date, CASE WHEN $6::int IS NULL THEN NULL ELSE current_date + $6::int END,
                   $7, $8)`,
          [s.tenantId, target, max, days, b.capToSecurity ?? false, valid, s.userId, b.note?.trim() || null]);
      }
      await c.query(
        `INSERT INTO audit_log (tenant_id, user_id, action, entity, entity_id, detail)
         VALUES ($1, $2, 'credit.limit.set', $3, $4, $5)`,
        [s.tenantId, s.userId, table, target, JSON.stringify(b)]);
      return { ok: true };
    });
  }
}
