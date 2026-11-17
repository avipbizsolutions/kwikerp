import { BadRequestException } from '@nestjs/common';
import { config } from './config';

/** Today's date (YYYY-MM-DD) in the business time zone. */
export function localDate(d = new Date()): string {
  return new Intl.DateTimeFormat('en-CA', { timeZone: config.timeZone, year: 'numeric', month: '2-digit', day: '2-digit' })
    .format(d);
}

/** Indian financial year code: Apr 2026 – Mar 2027 => "2627". */
export function finYear(date: string): string {
  const [y, m] = date.split('-').map(Number);
  const start = m >= 4 ? y : y - 1;
  return `${String(start % 100).padStart(2, '0')}${String((start + 1) % 100).padStart(2, '0')}`;
}

export function isDate(v?: string): boolean {
  if (!v || !/^\d{4}-\d{2}-\d{2}$/.test(v)) return false;
  const d = new Date(`${v}T00:00:00Z`);
  return !Number.isNaN(d.getTime()) && d.toISOString().slice(0, 10) === v;
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export function needUuid(v: unknown, what: string): string {
  if (typeof v !== 'string' || !UUID.test(v)) throw new BadRequestException(`${what} must be an id`);
  return v.toLowerCase();
}

export function num(v: unknown, what: string): number {
  const n = Number(v);
  if (!Number.isFinite(n)) throw new BadRequestException(`${what} must be a number`);
  return Math.round(n * 1000) / 1000;
}

/** Stock settings: who approves which adjustments, and which rate list is MRP. */
export interface StockSettings { ownerAbove: number; mrpLevel: string }
export const DEFAULT_STOCK: StockSettings = { ownerAbove: 500, mrpLevel: 'CONSUMER' };

export async function stockSettings(c: any): Promise<StockSettings> {
  const row = (await c.query("SELECT value FROM tenant_setting WHERE key = 'stock'")).rows[0];
  return { ...DEFAULT_STOCK, ...(row?.value ?? {}) };
}

/** MRP (price per base unit at the MRP rate list) for each item. */
export async function mrpMap(c: any): Promise<Map<string, number>> {
  const st = await stockSettings(c);
  const rows = (await c.query(
    `SELECT i.id, coalesce(p.price, 0)::float AS mrp
       FROM item i
       LEFT JOIN price_level pl ON pl.code = $1 AND pl.deleted_at IS NULL
       LEFT JOIN item_price_current p ON p.item_id = i.id AND p.unit_id = i.base_unit_id AND p.price_level_id = pl.id
      WHERE i.deleted_at IS NULL`, [st.mrpLevel])).rows;
  return new Map(rows.map((r: any) => [r.id, r.mrp]));
}
