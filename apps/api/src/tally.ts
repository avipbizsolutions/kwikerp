import {
  BadRequestException, Body, Controller, Get, Post, Query, Req, Res, UseGuards,
} from '@nestjs/common';
import type { Response } from 'express';
import { AuthGuard, Needs, Session } from './auth';
import { Db } from './db';

/**
 * Tally export (TallyPrime XML, Gateway of Tally > Import > Transactions).
 *  - one Sales voucher per outlet per day for bills paid in full (cash / UPI / card)
 *  - one Sales voucher per credit bill against the customer's ledger (bill-wise)
 *  - a Receipt voucher for any part of a credit bill paid at the counter
 * Cancelled bills and bills still waiting for approval are left out.
 * Ledger names come from the company's settings; {outlet} and {rate} in a name
 * are replaced by the outlet code and the GST rate.
 */

export interface TallySettings {
  company: string;          // Tally company name; empty = whichever company is open
  salesVoucherType: string;
  receiptVoucherType: string;
  cash: string;
  upi: string;
  card: string;
  other: string;            // cheque / bank
  sales: string;            // e.g. "Sales @{rate}%"
  salesExempt: string;      // 0% items
  cgst: string;
  sgst: string;
  igst: string;
  roundOff: string;
  debtorsGroup: string;     // for the customer ledger file
}

export const DEFAULT_TALLY: TallySettings = {
  company: '',
  salesVoucherType: 'Sales',
  receiptVoucherType: 'Receipt',
  cash: 'Cash',
  upi: 'UPI Collections',
  card: 'Card Collections',
  other: 'Bank',
  sales: 'Sales @{rate}%',
  salesExempt: 'Sales Exempt',
  cgst: 'Output CGST',
  sgst: 'Output SGST',
  igst: 'Output IGST',
  roundOff: 'Round Off',
  debtorsGroup: 'Sundry Debtors',
};

export interface Entry { ledger: string; amount: number; party?: boolean; billRef?: string } // + debit, - credit
export interface Voucher {
  key: string;              // stable id, sent as REMOTEID
  type: 'sales' | 'receipt';
  date: string;             // YYYY-MM-DD
  number: string;
  party: string;
  narration: string;
  entries: Entry[];
}

const r2 = (v: number) => Math.round(v * 100) / 100;
const fill = (name: string, outlet: string, rate?: number) =>
  name.replace(/\{outlet\}/g, outlet).replace(/\{rate\}/g, rate === undefined ? '' : String(+rate.toFixed(2)));

interface InvoiceRow {
  id: string; doc_no: string; doc_date: string; outlet: string; customer: string | null;
  total: number; paid: number; balance: number; round_off: number;
}
interface LineRow { invoice_id: string; gst_rate: number; taxable: number; cgst: number; sgst: number; igst: number }
interface ReceiptRow { invoice_id: string; mode: string; amount: number }

/** Credits for sales and taxes from bill lines (negative amounts). */
function taxCredits(lines: LineRow[], outlet: string, st: TallySettings): Entry[] {
  const byRate = new Map<number, number>();
  let cgst = 0, sgst = 0, igst = 0;
  for (const l of lines) {
    byRate.set(l.gst_rate, (byRate.get(l.gst_rate) ?? 0) + l.taxable);
    cgst += l.cgst; sgst += l.sgst; igst += l.igst;
  }
  const out: Entry[] = [];
  for (const [rate, taxable] of [...byRate.entries()].sort((a, b) => a[0] - b[0])) {
    out.push({ ledger: fill(rate === 0 ? st.salesExempt : st.sales, outlet, rate), amount: -r2(taxable) });
  }
  if (r2(cgst)) out.push({ ledger: fill(st.cgst, outlet), amount: -r2(cgst) });
  if (r2(sgst)) out.push({ ledger: fill(st.sgst, outlet), amount: -r2(sgst) });
  if (r2(igst)) out.push({ ledger: fill(st.igst, outlet), amount: -r2(igst) });
  return out;
}

/** Makes the voucher balance exactly by putting the difference on round off. */
function balance(entries: Entry[], outlet: string, st: TallySettings): Entry[] {
  const diff = r2(entries.reduce((a, e) => a + e.amount, 0));
  if (diff !== 0) entries.push({ ledger: fill(st.roundOff, outlet), amount: -diff });
  return entries.filter((e) => e.amount !== 0);
}

const modeLedger = (mode: string, outlet: string, st: TallySettings) =>
  fill(mode === 'cash' ? st.cash : mode === 'upi' ? st.upi : mode === 'card' ? st.card : st.other, outlet);

export function buildVouchers(invoices: InvoiceRow[], lines: LineRow[], receipts: ReceiptRow[],
                              st: TallySettings): Voucher[] {
  const linesBy = new Map<string, LineRow[]>();
  for (const l of lines) linesBy.set(l.invoice_id, [...(linesBy.get(l.invoice_id) ?? []), l]);
  const rcBy = new Map<string, ReceiptRow[]>();
  for (const r of receipts) rcBy.set(r.invoice_id, [...(rcBy.get(r.invoice_id) ?? []), r]);
  const vouchers: Voucher[] = [];

  // Paid in full: one summary per outlet per day
  const groups = new Map<string, InvoiceRow[]>();
  for (const i of invoices.filter((x) => !(x.balance > 0))) {
    const k = `${i.outlet}|${i.doc_date}`;
    groups.set(k, [...(groups.get(k) ?? []), i]);
  }
  for (const [k, invs] of [...groups.entries()].sort()) {
    const [outlet, date] = k.split('|');
    const debits = new Map<string, number>();
    for (const i of invs) {
      for (const r of rcBy.get(i.id) ?? []) {
        const led = modeLedger(r.mode, outlet, st);
        debits.set(led, (debits.get(led) ?? 0) + r.amount);
      }
    }
    const entries: Entry[] = [...debits.entries()].map(([ledger, amount]) => ({ ledger, amount: r2(amount) }));
    entries.push(...taxCredits(invs.flatMap((i) => linesBy.get(i.id) ?? []), outlet, st));
    const nos = invs.map((i) => i.doc_no).sort();
    vouchers.push({
      key: `kwik-day-${outlet}-${date}`, type: 'sales', date, number: `${outlet}-${date.replace(/-/g, '')}`,
      party: entries[0]?.ledger ?? fill(st.cash, outlet),
      narration: `${outlet} counter sales, ${invs.length} bills ${nos[0]} to ${nos[nos.length - 1]}`,
      entries: balance(entries, outlet, st),
    });
  }

  // Credit bills: one each, against the customer, then a receipt for any part paid
  for (const i of invoices.filter((x) => x.balance > 0).sort((a, b) => a.doc_no.localeCompare(b.doc_no))) {
    const party = i.customer ?? 'Walk-in credit';
    const entries: Entry[] = [{ ledger: party, amount: r2(i.total), party: true, billRef: i.doc_no },
      ...taxCredits(linesBy.get(i.id) ?? [], i.outlet, st)];
    vouchers.push({
      key: `kwik-inv-${i.id}`, type: 'sales', date: i.doc_date, number: i.doc_no, party,
      narration: `${i.outlet} credit bill ${i.doc_no}`, entries: balance(entries, i.outlet, st),
    });
    for (const r of rcBy.get(i.id) ?? []) {
      vouchers.push({
        key: `kwik-rc-${i.id}-${r.mode}`, type: 'receipt', date: i.doc_date, number: `${i.doc_no}-R`, party,
        narration: `Paid at counter against ${i.doc_no}`,
        entries: [{ ledger: modeLedger(r.mode, i.outlet, st), amount: r2(r.amount) },
          { ledger: party, amount: -r2(r.amount), party: true, billRef: i.doc_no }],
      });
    }
  }
  return vouchers;
}

const x = (s: string) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
  .replace(/"/g, '&quot;').replace(/'/g, '&apos;');
const amt = (v: number) => v.toFixed(2);

export function vouchersXml(vouchers: Voucher[], st: TallySettings): string {
  const body = vouchers.map((v) => {
    const vt = v.type === 'sales' ? st.salesVoucherType : st.receiptVoucherType;
    const entries = v.entries.map((e) => {
      // Tally: debit = deemed positive with a negative amount; credit = positive amount.
      const dr = e.amount > 0;
      const tallyAmt = amt(-e.amount);
      const bill = e.billRef
        ? `\n          <BILLALLOCATIONS.LIST><NAME>${x(e.billRef)}</NAME><BILLTYPE>${v.type === 'sales' ? 'New Ref' : 'Agst Ref'}</BILLTYPE><AMOUNT>${tallyAmt}</AMOUNT></BILLALLOCATIONS.LIST>`
        : '';
      return `
        <ALLLEDGERENTRIES.LIST>
          <LEDGERNAME>${x(e.ledger)}</LEDGERNAME>
          <ISDEEMEDPOSITIVE>${dr ? 'Yes' : 'No'}</ISDEEMEDPOSITIVE>
          <ISPARTYLEDGER>${e.party ? 'Yes' : 'No'}</ISPARTYLEDGER>
          <AMOUNT>${tallyAmt}</AMOUNT>${bill}
        </ALLLEDGERENTRIES.LIST>`;
    }).join('');
    return `
    <TALLYMESSAGE xmlns:UDF="TallyUDF">
      <VOUCHER REMOTEID="${x(v.key)}" VCHTYPE="${x(vt)}" ACTION="Create" OBJVIEW="Accounting Voucher View">
        <DATE>${v.date.replace(/-/g, '')}</DATE>
        <VOUCHERTYPENAME>${x(vt)}</VOUCHERTYPENAME>
        <VOUCHERNUMBER>${x(v.number)}</VOUCHERNUMBER>
        <PARTYLEDGERNAME>${x(v.party)}</PARTYLEDGERNAME>
        <NARRATION>${x(v.narration)}</NARRATION>
        <PERSISTEDVIEW>Accounting Voucher View</PERSISTEDVIEW>${entries}
      </VOUCHER>
    </TALLYMESSAGE>`;
  }).join('');
  return envelope(body, st);
}

function envelope(messages: string, st: TallySettings, report = 'Vouchers') {
  const company = st.company.trim()
    ? `<STATICVARIABLES><SVCURRENTCOMPANY>${x(st.company.trim())}</SVCURRENTCOMPANY></STATICVARIABLES>` : '';
  return `<?xml version="1.0" encoding="UTF-8"?>
<ENVELOPE>
  <HEADER><TALLYREQUEST>Import Data</TALLYREQUEST></HEADER>
  <BODY>
    <IMPORTDATA>
      <REQUESTDESC><REPORTNAME>${report}</REPORTNAME>${company}</REQUESTDESC>
      <REQUESTDATA>${messages}
      </REQUESTDATA>
    </IMPORTDATA>
  </BODY>
</ENVELOPE>
`;
}

/** Customer ledgers under Sundry Debtors, for first-time setup in Tally. */
export function ledgersXml(customers: { name: string; gstin: string | null; state: string | null; address: string | null;
  phone: string | null }[], st: TallySettings): string {
  const body = customers.map((c) => `
    <TALLYMESSAGE xmlns:UDF="TallyUDF">
      <LEDGER NAME="${x(c.name)}" ACTION="Create">
        <NAME>${x(c.name)}</NAME>
        <PARENT>${x(st.debtorsGroup)}</PARENT>
        <ISBILLWISEON>Yes</ISBILLWISEON>${c.gstin ? `
        <PARTYGSTIN>${x(c.gstin)}</PARTYGSTIN>
        <GSTREGISTRATIONTYPE>Regular</GSTREGISTRATIONTYPE>` : ''}${c.state ? `
        <LEDSTATENAME>${x(c.state)}</LEDSTATENAME>` : ''}${c.phone ? `
        <LEDGERMOBILE>${x(c.phone)}</LEDGERMOBILE>` : ''}${c.address ? `
        <ADDRESS.LIST TYPE="String"><ADDRESS>${x(c.address)}</ADDRESS></ADDRESS.LIST>` : ''}
      </LEDGER>
    </TALLYMESSAGE>`).join('');
  return envelope(body, st, 'All Masters');
}

const STATES: Record<string, string> = {
  '10': 'Bihar', '09': 'Uttar Pradesh', '20': 'Jharkhand', '19': 'West Bengal', '07': 'Delhi',
  '27': 'Maharashtra', '24': 'Gujarat', '29': 'Karnataka', '33': 'Tamil Nadu', '36': 'Telangana',
};

const isDate = (v?: string) => !!v && /^\d{4}-\d{2}-\d{2}$/.test(v) && !Number.isNaN(Date.parse(v + 'T00:00:00Z'))
  && new Date(v + 'T00:00:00Z').toISOString().startsWith(v);

@Controller('tally')
@UseGuards(AuthGuard)
export class TallyController {
  constructor(private readonly db: Db) {}

  private async settings(c: any): Promise<TallySettings> {
    const row = (await c.query("SELECT value FROM tenant_setting WHERE key = 'tally'")).rows[0];
    return { ...DEFAULT_TALLY, ...(row?.value ?? {}) };
  }

  @Get('settings')
  @Needs('accounts.export')
  getSettings(@Req() req: any) {
    const s: Session = req.session;
    return this.db.tx(s.tenantId, (c) => this.settings(c));
  }

  @Post('settings')
  @Needs('accounts.export')
  saveSettings(@Req() req: any, @Body() b: Partial<TallySettings>) {
    const s: Session = req.session;
    const clean: Partial<TallySettings> = {};
    for (const k of Object.keys(DEFAULT_TALLY) as (keyof TallySettings)[]) {
      if (typeof b?.[k] === 'string') {
        const v = (b[k] as string).trim();
        if (!v && k !== 'company') throw new BadRequestException(`${k} cannot be empty`);
        clean[k] = v;
      }
    }
    return this.db.tx(s.tenantId, async (c) => {
      const merged = { ...(await this.settings(c)), ...clean };
      await c.query(
        `INSERT INTO tenant_setting (tenant_id, key, value, updated_by) VALUES ($1, 'tally', $2, $3)
         ON CONFLICT (tenant_id, key) DO UPDATE SET value = EXCLUDED.value, updated_by = EXCLUDED.updated_by,
                                                    updated_at = now()`,
        [s.tenantId, JSON.stringify(merged), s.userId]);
      return merged;
    });
  }

  private async load(c: any, from: string, to: string, location?: string) {
    const loc = location ? (await c.query('SELECT id FROM location WHERE upper(code) = upper($1)', [location])).rows[0] : null;
    if (location && !loc) throw new BadRequestException('Unknown outlet');
    const where = `si.status = 'final' AND si.doc_type = 'INV' AND si.deleted_at IS NULL
                   AND si.doc_date BETWEEN $1 AND $2 AND ($3::uuid IS NULL OR si.location_id = $3)`;
    const args = [from, to, loc?.id ?? null];
    const invoices = (await c.query(
      `SELECT si.id, si.doc_no, to_char(si.doc_date, 'YYYY-MM-DD') AS doc_date, l.code AS outlet, cu.name AS customer,
              si.total::float AS total, si.paid::float AS paid, si.balance::float AS balance,
              si.round_off::float AS round_off
         FROM sales_invoice si JOIN location l ON l.id = si.location_id
         LEFT JOIN customer cu ON cu.id = si.customer_id WHERE ${where}`, args)).rows;
    const lines = (await c.query(
      `SELECT sl.invoice_id, sl.gst_rate::float AS gst_rate, sl.taxable::float AS taxable, sl.cgst::float AS cgst,
              sl.sgst::float AS sgst, sl.igst::float AS igst
         FROM sales_invoice_line sl JOIN sales_invoice si ON si.id = sl.invoice_id
        WHERE ${where} AND sl.deleted_at IS NULL`, args)).rows;
    const receipts = (await c.query(
      `SELECT r.invoice_id, r.mode, sum(r.amount)::float AS amount
         FROM receipt r JOIN sales_invoice si ON si.id = r.invoice_id
        WHERE ${where} AND r.status = 'final' AND r.deleted_at IS NULL GROUP BY r.invoice_id, r.mode`, args)).rows;
    const st = await this.settings(c);
    const previous = (await c.query(
      `SELECT from_date::text, to_date::text, exported_at, vouchers FROM tally_export
        WHERE from_date <= $2 AND to_date >= $1 ORDER BY exported_at DESC LIMIT 5`, [from, to])).rows;
    return { vouchers: buildVouchers(invoices, lines, receipts, st), st, invoices, loc, previous };
  }

  /** What the export would contain, for the head-office page. */
  @Get('preview')
  @Needs('accounts.export')
  preview(@Req() req: any, @Query('from') from: string, @Query('to') to: string, @Query('location') location?: string) {
    const s: Session = req.session;
    if (!isDate(from) || !isDate(to) || from > to) throw new BadRequestException('from/to must be YYYY-MM-DD');
    return this.db.tx(s.tenantId, async (c) => {
      const { vouchers, invoices, previous } = await this.load(c, from, to, location);
      const creditCustomers = new Set(invoices.filter((i: any) => i.balance > 0).map((i: any) => i.customer));
      return {
        vouchers: vouchers.map((v) => ({ ...v, total: r2(v.entries.filter((e) => e.amount > 0).reduce((a, e) => a + e.amount, 0)) })),
        bills: invoices.length,
        total: r2(invoices.reduce((a: number, i: any) => a + i.total, 0)),
        ledgers: [...new Set(vouchers.flatMap((v) => v.entries.map((e) => e.ledger)))].sort(),
        creditCustomers: creditCustomers.size,
        duplicateNames: (await c.query(
          `SELECT name, count(*)::int AS n FROM customer WHERE deleted_at IS NULL AND is_active
            GROUP BY lower(trim(name)), name HAVING count(*) > 1 ORDER BY name LIMIT 20`)).rows,
        previous,
      };
    });
  }

  /** The XML file to import in TallyPrime. Each download is logged. */
  @Get('vouchers.xml')
  @Needs('accounts.export')
  async download(@Req() req: any, @Res() res: Response, @Query('from') from: string, @Query('to') to: string,
                 @Query('location') location?: string) {
    const s: Session = req.session;
    if (!isDate(from) || !isDate(to) || from > to) throw new BadRequestException('from/to must be YYYY-MM-DD');
    const xml = await this.db.tx(s.tenantId, async (c) => {
      const { vouchers, st, invoices, loc } = await this.load(c, from, to, location);
      await c.query(
        `INSERT INTO tally_export (tenant_id, from_date, to_date, location_ids, vouchers, total, exported_by)
         VALUES ($1, $2, $3, $4, $5, $6, $7)`,
        [s.tenantId, from, to, loc ? [loc.id] : null, vouchers.length,
          r2(invoices.reduce((a: number, i: any) => a + i.total, 0)), s.userId]);
      return vouchersXml(vouchers, st);
    });
    res.setHeader('Content-Type', 'application/xml; charset=utf-8');
    res.setHeader('Content-Disposition',
      `attachment; filename="kwikerp-tally-${location ? location.toUpperCase() + '-' : ''}${from}${to !== from ? '_' + to : ''}.xml"`);
    res.send(xml);
  }

  /** Customer ledgers (Sundry Debtors) to create once in Tally before the first import. */
  @Get('ledgers.xml')
  @Needs('accounts.export')
  async ledgers(@Req() req: any, @Res() res: Response) {
    const s: Session = req.session;
    const xml = await this.db.tx(s.tenantId, async (c) => {
      const st = await this.settings(c);
      const customers = (await c.query(
        `SELECT cu.name, cu.gstin, cu.state_code, cu.address, cu.phone FROM customer cu
           JOIN customer_category cc ON cc.id = cu.category_id
          WHERE cu.deleted_at IS NULL AND cu.is_active AND cc.credit_allowed ORDER BY cu.name`)).rows;
      // Tally ledger names are unique: one ledger per customer name
      const seen = new Set<string>();
      const unique = customers.filter((cu: any) => {
        const k = cu.name.trim().toLowerCase();
        if (seen.has(k)) return false;
        seen.add(k);
        return true;
      });
      return ledgersXml(unique.map((cu: any) => ({ ...cu, state: STATES[cu.state_code] ?? null })), st);
    });
    res.setHeader('Content-Type', 'application/xml; charset=utf-8');
    res.setHeader('Content-Disposition', 'attachment; filename="kwikerp-tally-customer-ledgers.xml"');
    res.send(xml);
  }
}
