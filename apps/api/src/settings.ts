import { BadRequestException, Body, Controller, Get, Post, Req, UseGuards } from '@nestjs/common';
import { AuthGuard, Needs, Session } from './auth';
import { Db } from './db';
import { DEFAULT_STOCK, stockSettings } from './util';

/**
 * Receipt layout, set on the head-office page and sent to every tablet.
 * Header and footer lines may use {company} {outlet} {outlet_address} {address}
 * {gstin} {phone} {email} {fssai}; a line whose fields are all empty is left out.
 */
export interface ReceiptSettings {
  title: string;            // big line at the top
  header: string;           // lines under the title
  footer: string;
  showTime: boolean;
  showCustomer: boolean;
  itemTable: boolean;       // Item / Qty / Rate / Total columns
  showCounts: boolean;      // total items and quantity
  splitGst: boolean;        // CGST and SGST lines instead of one GST line
  showSavings: boolean;     // saving against MRP when billed below it
  showPhotos: boolean;      // product photos on tablet tiles (company-wide switch)
  logo: { width: number; height: number; data: string } | null; // 1-bit rows, base64
  // Blank paper, in printer lines (about 4 mm each), 0 to 10
  billTop: number;
  billBottom: number;
  tokenTop: number;
  tokenBottom: number;
}

export const DEFAULT_RECEIPT: ReceiptSettings = {
  title: 'Dugdh Dhara',
  header: '{outlet}\n{outlet_address}\nGSTIN: {gstin}\nPhone: {phone}\n{email}',
  footer: 'Thank You! Visit Again!',
  showTime: true,
  showCustomer: true,
  itemTable: true,
  showCounts: true,
  splitGst: true,
  showSavings: true,
  showPhotos: true,
  logo: null,
  billTop: 0,
  billBottom: 4,
  tokenTop: 0,
  tokenBottom: 4,
};

export async function receiptSettings(c: any): Promise<{ value: ReceiptSettings; version: string }> {
  const row = (await c.query("SELECT value, updated_at FROM tenant_setting WHERE key = 'receipt'")).rows[0];
  return { value: { ...DEFAULT_RECEIPT, ...(row?.value ?? {}) }, version: row ? new Date(row.updated_at).toISOString() : 'default' };
}

const BOOL_KEYS = ['showTime', 'showCustomer', 'itemTable', 'showCounts', 'splitGst', 'showSavings', 'showPhotos'] as const;

interface BusinessBody {
  company?: { gstin?: string; phone?: string; email?: string; address?: string; fssai?: string };
  outlets?: { code: string; name?: string; address?: string; phone?: string; fssai?: string }[];
}

@Controller('settings')
@UseGuards(AuthGuard)
export class SettingsController {
  constructor(private readonly db: Db) {}

  /** Company name and logo for the head-office page's menu (any login). */
  @Get('brand')
  brand(@Req() req: any) {
    const s: Session = req.session;
    return this.db.tx(s.tenantId, async (c) => {
      const r = await receiptSettings(c);
      const co = (await c.query(
        'SELECT legal_name, brand_name FROM company WHERE deleted_at IS NULL ORDER BY code LIMIT 1')).rows[0];
      return { name: co?.brand_name || co?.legal_name || '', company: co?.legal_name || '', logo: r.value?.logo ?? null };
    });
  }

  @Get('receipt')
  @Needs('settings.manage')
  async get(@Req() req: any) {
    const s: Session = req.session;
    return this.db.tx(s.tenantId, async (c) => {
      const r = await receiptSettings(c);
      const company = (await c.query(
        'SELECT legal_name, gstin, phone, email, address, fssai_no FROM company WHERE deleted_at IS NULL ORDER BY code LIMIT 1')).rows[0];
      const outlets = (await c.query(
        `SELECT code, name, address, phone, fssai_no FROM location
          WHERE deleted_at IS NULL AND kind IN ('outlet','franchise') ORDER BY code`)).rows;
      return { receipt: r.value, company, outlets };
    });
  }

  @Post('receipt')
  @Needs('settings.manage')
  save(@Req() req: any, @Body() b: Partial<ReceiptSettings>) {
    const s: Session = req.session;
    const clean: Partial<ReceiptSettings> = {};
    for (const k of ['title', 'header', 'footer'] as const) {
      if (typeof b?.[k] === 'string') clean[k] = (b[k] as string).slice(0, 600);
    }
    for (const k of BOOL_KEYS) if (typeof b?.[k] === 'boolean') clean[k] = b[k] as boolean;
    for (const k of ['billTop', 'billBottom', 'tokenTop', 'tokenBottom'] as const) {
      if (b?.[k] === undefined) continue;
      const n = Number(b[k]);
      if (!Number.isInteger(n) || n < 0 || n > 10) throw new BadRequestException('Spacing must be 0 to 10 lines');
      clean[k] = n;
    }
    if (b && 'logo' in b) {
      if (b.logo === null) clean.logo = null;
      else {
        const l = b.logo as any;
        const w = Number(l?.width), h = Number(l?.height);
        if (!(w > 0 && w <= 576 && w % 8 === 0 && h > 0 && h <= 400) || typeof l.data !== 'string') {
          throw new BadRequestException('Logo must be at most 576 x 400 dots');
        }
        if (Buffer.from(l.data, 'base64').length !== (w / 8) * h) throw new BadRequestException('Logo data does not match its size');
        clean.logo = { width: w, height: h, data: l.data };
      }
    }
    return this.db.tx(s.tenantId, async (c) => {
      const merged = { ...(await receiptSettings(c)).value, ...clean };
      await c.query(
        `INSERT INTO tenant_setting (tenant_id, key, value, updated_by) VALUES ($1, 'receipt', $2, $3)
         ON CONFLICT (tenant_id, key) DO UPDATE SET value = EXCLUDED.value, updated_by = EXCLUDED.updated_by, updated_at = now()`,
        [s.tenantId, JSON.stringify(merged), s.userId]);
      return merged;
    });
  }

  /** Company and outlet details printed on receipts (they reach tablets with the next sync). */
  @Post('business')
  @Needs('settings.manage')
  business(@Req() req: any, @Body() b: BusinessBody) {
    const s: Session = req.session;
    const t = (v?: string) => (v ?? '').trim() || null;
    return this.db.tx(s.tenantId, async (c) => {
      if (b?.company) {
        const g = t(b.company.gstin)?.toUpperCase() ?? null;
        if (g && !/^\d{2}[A-Z0-9]{13}$/.test(g)) throw new BadRequestException('GSTIN must be 15 characters');
        await c.query(
          `UPDATE company SET gstin = $1, phone = $2, email = $3, address = coalesce($4, address), fssai_no = $5
            WHERE id = (SELECT id FROM company WHERE deleted_at IS NULL ORDER BY code LIMIT 1)`,
          [g, t(b.company.phone), t(b.company.email), t(b.company.address), t(b.company.fssai)]);
      }
      for (const o of b?.outlets ?? []) {
        await c.query(
          `UPDATE location SET name = coalesce($2, name), address = $3, phone = $4, fssai_no = $5
            WHERE upper(code) = upper($1) AND deleted_at IS NULL`,
          [o.code, t(o.name), t(o.address), t(o.phone), t(o.fssai)]);
      }
      await c.query(
        `INSERT INTO audit_log (tenant_id, user_id, action, entity, detail) VALUES ($1, $2, 'settings.business', 'company', $3)`,
        [s.tenantId, s.userId, JSON.stringify(b)]);
      return { ok: true };
    });
  }

  // ------------------------------------------------ approval limits (stock)

  @Get('stock')
  async stock(@Req() req: any) {
    const s: Session = req.session;
    return this.db.tx(s.tenantId, async (c) => ({
      ...(await stockSettings(c)),
      levels: (await c.query('SELECT code, name FROM price_level WHERE deleted_at IS NULL ORDER BY sort_order')).rows,
    }));
  }

  @Post('stock')
  @Needs('settings.manage')
  saveStock(@Req() req: any, @Body() b: { ownerAbove?: number; mrpLevel?: string }) {
    const s: Session = req.session;
    return this.db.tx(s.tenantId, async (c) => {
      const cur = await stockSettings(c);
      if (b?.ownerAbove !== undefined) {
        const n = Number(b.ownerAbove);
        if (!Number.isFinite(n) || n < 0) throw new BadRequestException('Limit must be 0 or more');
        cur.ownerAbove = Math.round(n * 100) / 100;
      }
      if (b?.mrpLevel) {
        if (!(await c.query('SELECT 1 FROM price_level WHERE code = $1 AND deleted_at IS NULL', [b.mrpLevel])).rowCount) {
          throw new BadRequestException('Unknown rate list');
        }
        cur.mrpLevel = b.mrpLevel;
      }
      await c.query(
        `INSERT INTO tenant_setting (tenant_id, key, value, updated_by) VALUES ($1, 'stock', $2, $3)
         ON CONFLICT (tenant_id, key) DO UPDATE SET value = EXCLUDED.value, updated_by = EXCLUDED.updated_by, updated_at = now()`,
        [s.tenantId, JSON.stringify({ ...DEFAULT_STOCK, ...cur }), s.userId]);
      await c.query(
        `INSERT INTO audit_log (tenant_id, user_id, action, entity, detail) VALUES ($1, $2, 'settings.stock', 'tenant_setting', $3)`,
        [s.tenantId, s.userId, JSON.stringify(cur)]);
      return cur;
    });
  }

  // ------------------------------------------------ companies and locations

  @Get('org')
  @Needs('settings.manage')
  org(@Req() req: any) {
    const s: Session = req.session;
    return this.db.tx(s.tenantId, async (c) => ({
      companies: (await c.query(
        `SELECT id, code, legal_name, brand_name, gstin, pan, fssai_no, address, phone, email, state_code
           FROM company WHERE deleted_at IS NULL ORDER BY code`)).rows,
      locations: (await c.query(
        `SELECT l.id, l.code, l.name, l.kind, l.company_id, l.address, l.phone, l.fssai_no, l.sends_goods,
                l.is_active, sf.code AS supply_from, pl.code AS price_level,
                EXISTS (SELECT 1 FROM device d WHERE d.location_id = l.id)
                  OR EXISTS (SELECT 1 FROM stock_move m WHERE m.location_id = l.id) AS in_use
           FROM location l LEFT JOIN location sf ON sf.id = l.supply_from_id
           LEFT JOIN price_level pl ON pl.id = l.default_price_level_id
          WHERE l.deleted_at IS NULL ORDER BY l.kind <> 'plant', l.kind <> 'godown', l.code`)).rows,
      levels: (await c.query('SELECT code, name FROM price_level WHERE deleted_at IS NULL ORDER BY sort_order')).rows,
    }));
  }

  @Post('company')
  @Needs('settings.manage')
  saveCompany(@Req() req: any, @Body() b: Record<string, string>) {
    const s: Session = req.session;
    const t = (v?: string) => (v ?? '').trim() || null;
    const code = (b?.code ?? '').trim().toUpperCase();
    const legal = t(b?.legalName);
    if (!/^[A-Z0-9]{2,10}$/.test(code)) throw new BadRequestException('Short code: 2 to 10 letters or digits');
    if (!legal) throw new BadRequestException('Legal name is required');
    const gstin = t(b?.gstin)?.toUpperCase() ?? null;
    if (gstin && !/^\d{2}[A-Z0-9]{13}$/.test(gstin)) throw new BadRequestException('GSTIN must be 15 characters');
    const pan = t(b?.pan)?.toUpperCase() ?? null;
    if (pan && !/^[A-Z]{5}\d{4}[A-Z]$/.test(pan)) throw new BadRequestException('PAN must look like ABCDE1234F');
    const state = (t(b?.stateCode) ?? gstin?.slice(0, 2) ?? '').padStart(2, '0');
    if (!/^\d{2}$/.test(state) || state === '00') throw new BadRequestException('GST state code (Bihar is 10) is required');
    return this.db.tx(s.tenantId, async (c) => {
      const vals = [code, legal, t(b?.brandName), gstin, pan, t(b?.fssai), t(b?.address), t(b?.phone), t(b?.email), state];
      let id = b?.id;
      if (id) {
        const r = await c.query(
          `UPDATE company SET code = $2, legal_name = $3, brand_name = $4, gstin = $5, pan = $6, fssai_no = $7,
                  address = $8, phone = $9, email = $10, state_code = $11 WHERE id = $1 AND deleted_at IS NULL`, [id, ...vals]);
        if (!r.rowCount) throw new BadRequestException('Company not found');
      } else {
        id = (await c.query(
          `INSERT INTO company (tenant_id, code, legal_name, brand_name, gstin, pan, fssai_no, address, phone, email, state_code)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11) RETURNING id`, [s.tenantId, ...vals])).rows[0].id;
      }
      await c.query(
        `INSERT INTO audit_log (tenant_id, user_id, action, entity, entity_id, detail) VALUES ($1, $2, 'settings.company', 'company', $3, $4)`,
        [s.tenantId, s.userId, id, JSON.stringify(b)]);
      return { id };
    });
  }

  @Post('location')
  @Needs('settings.manage')
  saveLocation(@Req() req: any, @Body() b: Record<string, any>) {
    const s: Session = req.session;
    const t = (v?: string) => (v ?? '').toString().trim() || null;
    const code = (b?.code ?? '').trim().toUpperCase();
    const name = t(b?.name);
    if (!/^[A-Z0-9]{2,10}$/.test(code)) throw new BadRequestException('Code: 2 to 10 letters or digits, e.g. GD1');
    if (!name) throw new BadRequestException('Name is required');
    if (!['plant', 'godown', 'outlet', 'franchise'].includes(b?.kind)) throw new BadRequestException('Choose the type');
    return this.db.tx(s.tenantId, async (c) => {
      const company = (await c.query('SELECT id FROM company WHERE id = $1 AND deleted_at IS NULL', [b?.companyId ?? null])).rows[0]
        ?? (await c.query('SELECT id FROM company WHERE deleted_at IS NULL ORDER BY code LIMIT 1')).rows[0];
      if (!company) throw new BadRequestException('Add the company first');
      let supplyFrom: string | null = null;
      if (b?.supplyFrom) {
        const f = (await c.query('SELECT id, sends_goods FROM location WHERE code = $1 AND deleted_at IS NULL', [b.supplyFrom])).rows[0];
        if (!f) throw new BadRequestException('Unknown "gets goods from" location');
        if (f.id === b?.id) throw new BadRequestException('A location cannot get goods from itself');
        supplyFrom = f.id;
      }
      const level = (await c.query('SELECT id FROM price_level WHERE code = $1 AND deleted_at IS NULL', [b?.priceLevel ?? ''])).rows[0]
        ?? (await c.query('SELECT id FROM price_level WHERE deleted_at IS NULL ORDER BY sort_order LIMIT 1')).rows[0];
      const vals = [code, name, b.kind, company.id, t(b?.address), t(b?.phone), t(b?.fssai), !!b?.sendsGoods, supplyFrom,
        b?.isActive ?? true, level?.id ?? null];
      let id = b?.id;
      if (id) {
        const old = (await c.query('SELECT code FROM location WHERE id = $1 AND deleted_at IS NULL', [id])).rows[0];
        if (!old) throw new BadRequestException('Location not found');
        if (old.code !== code && (await c.query(
          `SELECT 1 FROM device WHERE location_id = $1 UNION ALL SELECT 1 FROM stock_move WHERE location_id = $1
           UNION ALL SELECT 1 FROM stock_transfer WHERE from_location_id = $1 OR to_location_id = $1 LIMIT 1`, [id])).rowCount) {
          throw new BadRequestException('The code is used in document numbers and cannot change any more');
        }
        await c.query(
          `UPDATE location SET code = $2, name = $3, kind = $4, company_id = $5, address = $6, phone = $7, fssai_no = $8,
                  sends_goods = $9, supply_from_id = $10, is_active = $11, default_price_level_id = $12
            WHERE id = $1`, [id, ...vals]);
      } else {
        if ((await c.query('SELECT 1 FROM location WHERE code = $1', [code])).rowCount) {
          throw new BadRequestException(`Code ${code} is already used`);
        }
        id = (await c.query(
          `INSERT INTO location (tenant_id, code, name, kind, company_id, address, phone, fssai_no, sends_goods,
                  supply_from_id, is_active, default_price_level_id)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12) RETURNING id`, [s.tenantId, ...vals])).rows[0].id;
      }
      await c.query(
        `INSERT INTO audit_log (tenant_id, user_id, action, entity, entity_id, detail) VALUES ($1, $2, 'settings.location', 'location', $3, $4)`,
        [s.tenantId, s.userId, id, JSON.stringify(b)]);
      return { id };
    });
  }
}
