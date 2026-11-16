import { BadRequestException, Body, Controller, Get, Post, Req, UseGuards } from '@nestjs/common';
import { AuthGuard, Needs, Session } from './auth';
import { Db } from './db';

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
  logo: { width: number; height: number; data: string } | null; // 1-bit rows, base64
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
  logo: null,
};

export async function receiptSettings(c: any): Promise<{ value: ReceiptSettings; version: string }> {
  const row = (await c.query("SELECT value, updated_at FROM tenant_setting WHERE key = 'receipt'")).rows[0];
  return { value: { ...DEFAULT_RECEIPT, ...(row?.value ?? {}) }, version: row ? new Date(row.updated_at).toISOString() : 'default' };
}

const BOOL_KEYS = ['showTime', 'showCustomer', 'itemTable', 'showCounts', 'splitGst', 'showSavings'] as const;

interface BusinessBody {
  company?: { gstin?: string; phone?: string; email?: string; address?: string; fssai?: string };
  outlets?: { code: string; name?: string; address?: string; phone?: string; fssai?: string }[];
}

@Controller('settings')
@UseGuards(AuthGuard)
export class SettingsController {
  constructor(private readonly db: Db) {}

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
}
