/**
 * End-to-end API test against a real PostgreSQL database that has the
 * migrations and Troika seed applied.
 *
 * Needs: DATABASE_URL (kwik_api role), ADMIN_DATABASE_URL (owner),
 *        JWT_SECRET, APPROVAL_SECRET.
 */
import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'crypto';
import { execFileSync } from 'child_process';
import * as path from 'path';
import { Client } from 'pg';
import { clearLoginFailures } from '../auth';
import { createApp } from '../main';
import { approvalCode } from '../offline-code';
import { buildVouchers, DEFAULT_TALLY, vouchersXml } from '../tally';

let base = '';
let app: any;
let deviceId = '';
let cashierToken = '';
let ownerToken = '';
let approvalKey = '';
// A fresh tablet per run, so bill numbers never collide with earlier runs
const deviceCode = `T${Math.random().toString(36).slice(2, 6).toUpperCase()}`;
const admin = new Client({ connectionString: process.env.ADMIN_DATABASE_URL });

async function call(method: string, url: string, token: string, body?: unknown) {
  const res = await fetch(base + url, {
    method,
    headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}) },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  return { status: res.status, body: text ? JSON.parse(text) : null };
}

function cli(...args: string[]) {
  return execFileSync('node', [path.join(__dirname, '..', 'cli.js'), ...args], { encoding: 'utf8' });
}

before(async () => {
  await admin.connect();
  await admin.query('SET search_path = kwik, public');
  cli('user:add', '--tenant', 'TROIKA', '--name', 'Test Cashier', '--phone', '9111111111', '--pin', '1234',
    '--role', 'CASHIER', '--location', 'DD3');
  cli('user:add', '--tenant', 'TROIKA', '--name', 'Test Owner', '--phone', '9222222222', '--pin', '5678', '--role', 'OWNER');
  const out = cli('device:add', '--tenant', 'TROIKA', '--location', 'DD3', '--code', deviceCode);
  deviceId = out.trim().split(' ').pop()!;
  app = await createApp();
  await app.listen(0);
  base = `http://127.0.0.1:${app.getHttpServer().address().port}/api`;
});

after(async () => {
  await app?.close();
  await admin.end();
});

test('health', async () => {
  const r = await call('GET', '/health', '');
  assert.equal(r.status, 200);
});

test('wrong PIN is refused', async () => {
  const r = await call('POST', '/auth/login', '', { tenantCode: 'troika', phone: '9111111111', pin: '0000', deviceId });
  assert.equal(r.status, 401);
});

test('cashier logs in on the tablet', async () => {
  const r = await call('POST', '/auth/login', '', { tenantCode: 'troika', phone: '9111111111', pin: '1234', deviceId });
  assert.equal(r.status, 201, JSON.stringify(r.body));
  assert.equal(r.body.device.locationCode, 'DD3');
  assert.ok(r.body.device.approvalKey);
  cashierToken = r.body.token;
  approvalKey = r.body.device.approvalKey;
});

test('tablet can be set up with the short code DD3-<tablet>', async () => {
  const r = await call('POST', '/auth/login', '', {
    tenantCode: 'troika', phone: '9111111111', pin: '1234', deviceId: ` dd3-${deviceCode.toLowerCase()} ` });
  assert.equal(r.status, 201, JSON.stringify(r.body));
  assert.equal(r.body.device.id, deviceId);
  const bad = await call('POST', '/auth/login', '', { tenantCode: 'troika', phone: '9111111111', pin: '1234', deviceId: 'DD9-T1' });
  assert.equal(bad.status, 401);
});

test('owner logs in on the manager app', async () => {
  const r = await call('POST', '/auth/login', '', { tenantCode: 'TROIKA', phone: '9222222222', pin: '5678' });
  assert.equal(r.status, 201);
  ownerToken = r.body.token;
});

let pulled: any;
test('first pull brings the full item master and prices', async () => {
  const r = await call('GET', '/sync/pull?since=0', cashierToken);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  pulled = r.body;
  assert.equal(pulled.tables.item.length, 107);
  assert.ok(pulled.tables.price_level.length >= 5);
  assert.ok(pulled.tables.item_price.length >= 615);
  assert.ok(pulled.cursor > 0);
  // users are sent without PIN hashes
  assert.equal(pulled.tables.app_user[0].pin_hash, undefined);
});

test('a credit bill over the limit is pushed, approved by the manager, then finalised', async () => {
  const t = pulled.tables;
  const level = (code: string) => t.price_level.find((p: any) => p.code === code).id;
  const retailCat = t.customer_category.find((c: any) => c.code === 'RETAILER');
  const item = t.item.find((i: any) => i.code === '2'); // Gold milk
  const pc = t.unit.find((u: any) => u.code === 'PC');
  const me = (await call('GET', '/auth/me', cashierToken)).body;

  const customerId = randomUUID();
  const shiftId = randomUUID();
  const invoiceId = randomUUID();
  const approvalId = randomUUID();
  // The tablet always sends whole rows; later pushes resend the full row.
  const invoice = {
    id: invoiceId, company_id: t.company[0].id, shift_id: shiftId, doc_type: 'INV', doc_date: '2026-11-15',
    status: 'pending_approval', customer_id: customerId, price_level_id: level('RETAILER'), place_of_supply: '10',
    subtotal: 336.5, taxable: 336.5, total: 337, round_off: 0.5, paid: 0, balance: 337, created_by: me.userId,
  };
  const push1 = await call('POST', '/sync/push', cashierToken, {
    customer: [{ id: customerId, name: 'Test Kirana', category_id: retailCat.id, phone: '9333333333' }],
    shift: [{ id: shiftId, user_id: me.userId, opened_at: new Date().toISOString(), opening_cash: 1000 }],
    sales_invoice: [invoice],
    sales_invoice_line: [{
      id: randomUUID(), invoice_id: invoiceId, line_no: 1, item_id: item.id, unit_id: pc.id, qty: 10, factor: 1,
      rate: 33.65, list_rate: 33.65, gst_rate: 0, taxable: 336.5, amount: 336.5,
    }],
    credit_approval: [{
      id: approvalId, invoice_id: invoiceId, customer_id: customerId, requested_by: me.userId,
      reasons: ['amount'], outstanding: 0, bill_amount: 337, limit_amount: 0, status: 'pending',
    }],
  });
  assert.equal(push1.status, 201, JSON.stringify(push1.body));

  // Pushing the same payload again changes nothing (idempotent retry)
  const again = await call('POST', '/sync/push', cashierToken, {
    shift: [{ id: shiftId, user_id: me.userId, opened_at: new Date().toISOString(), opening_cash: 1000 }],
  });
  assert.equal(again.status, 201);
  const shifts = (await admin.query('SELECT count(*)::int AS n FROM shift WHERE id = $1', [shiftId])).rows[0].n;
  assert.equal(shifts, 1);

  // Cashier may not approve
  const denied = await call('POST', `/approvals/${approvalId}/decide`, cashierToken, { decision: 'once' });
  assert.equal(denied.status, 403);

  const list = await call('GET', '/approvals?status=pending', ownerToken);
  assert.ok(list.body.some((a: any) => a.id === approvalId && a.customer_name === 'Test Kirana'));

  const ok = await call('POST', `/approvals/${approvalId}/decide`, ownerToken,
    { decision: 'raise_limit', newLimit: 5000, validDays: 7, note: 'Festival stock' });
  assert.equal(ok.status, 201, JSON.stringify(ok.body));

  // Tablet sees the decision and the new limit on its next pull
  const p2 = (await call('GET', `/sync/pull?since=${pulled.cursor}`, cashierToken)).body;
  assert.equal(p2.tables.credit_approval.find((a: any) => a.id === approvalId).status, 'approved');
  assert.ok(p2.tables.credit_limit.some((l: any) => l.customer_id === customerId && Number(l.max_outstanding) === 5000));

  // Tablet finalises the bill with its number
  const fin = await call('POST', '/sync/push', cashierToken, {
    sales_invoice: [{ ...invoice, status: 'final', doc_no: `DD3-${deviceCode}-2627-000001`, finalised_at: new Date().toISOString() }],
  });
  assert.equal(fin.status, 201, JSON.stringify(fin.body));
  const p3 = (await call('GET', `/sync/pull?since=${p2.cursor}`, cashierToken)).body;
  assert.equal(p3.outstanding.find((o: any) => o.customer_id === customerId).outstanding, 337);
  assert.equal(p3.tables.doc_series[0].last_no, 1);

  // A final bill cannot be edited back to draft
  await call('POST', '/sync/push', cashierToken, { sales_invoice: [{ ...invoice, status: 'draft', total: 1 }] });
  const row = (await admin.query('SELECT status, total FROM sales_invoice WHERE id = $1', [invoiceId])).rows[0];
  assert.equal(row.status, 'final');
  assert.equal(Number(row.total), 337);
});

test('offline approval code matches what the tablet computes', async () => {
  const r = await call('POST', '/approvals/offline-code', ownerToken,
    { locationCode: 'dd3', deviceCode: deviceCode.toLowerCase(), requestCode: 'k74q', amount: 421 });
  assert.equal(r.status, 201, JSON.stringify(r.body));
  assert.equal(r.body.approvalCode, approvalCode(approvalKey, 'K74Q', 421));
  assert.notEqual(r.body.approvalCode, approvalCode(approvalKey, 'K74Q', 422));
});

test('another tenant sees nothing', async () => {
  // Row-level security: a query with a different tenant id returns no items
  const c = new Client({ connectionString: process.env.DATABASE_URL });
  await c.connect();
  await c.query('BEGIN');
  await c.query("SELECT set_config('app.tenant_id', $1, true)", [randomUUID()]);
  const n = (await c.query('SELECT count(*)::int AS n FROM kwik.item')).rows[0].n;
  await c.query('ROLLBACK');
  await c.end();
  assert.equal(n, 0);
});

test('sales report by outlet, for head office only', async () => {
  const r = await call('GET', '/reports/sales?from=2000-01-01&to=2099-12-31', ownerToken);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  const dd3 = r.body.outlets.find((o: any) => o.code === 'DD3');
  assert.ok(dd3 && dd3.bills >= 1 && dd3.sales > 0, JSON.stringify(dd3));
  assert.ok(r.body.total.sales >= dd3.sales);
  assert.ok(Array.isArray(r.body.topItems) && r.body.topItems.length > 0);
  assert.equal((await call('GET', '/reports/sales', cashierToken)).status, 403);
  assert.equal((await call('GET', '/reports/sales?from=2026-13-01', ownerToken)).status, 400);
});

test('five wrong PINs lock that phone for a while', async () => {
  clearLoginFailures();
  for (let i = 0; i < 5; i++) {
    const r = await call('POST', '/auth/login', '', { tenantCode: 'TROIKA', phone: '9222222222', pin: '0000' });
    assert.equal(r.status, 401);
  }
  const locked = await call('POST', '/auth/login', '', { tenantCode: 'TROIKA', phone: '9222222222', pin: '5678' });
  assert.equal(locked.status, 429, 'even the right PIN waits');
  // Other phones are not affected
  const other = await call('POST', '/auth/login', '', { tenantCode: 'TROIKA', phone: '9111111111', pin: '1234' });
  assert.equal(other.status, 201);
  clearLoginFailures();
});

test('head-office page is served at the site root', async () => {
  const res = await fetch(base.replace(/\/api$/, '/'));
  assert.equal(res.status, 200);
  assert.match(await res.text(), /KwikERP Head Office/);
});

test('head office adds a customer and sets category and own limits', async () => {
  const meta = (await call('GET', '/customers/meta', ownerToken)).body;
  const retailer = meta.categories.find((c: any) => c.code === 'RETAILER');
  assert.ok(retailer);
  const phone = `9${Math.floor(Math.random() * 1e9).toString().padStart(9, '0')}`;
  const add = await call('POST', '/customers', ownerToken,
    { name: 'Test Retailer', categoryId: retailer.id, phone: `+91 ${phone}`, gstin: '10aafct0798q1zv' });
  assert.equal(add.status, 201, JSON.stringify(add.body));
  const id = add.body.id;
  const dup = await call('POST', '/customers', ownerToken, { name: 'Copy', categoryId: retailer.id, phone });
  assert.equal(dup.status, 400, 'same mobile twice is refused');

  const find = async () => (await call('GET', `/customers?q=${phone}`, ownerToken)).body[0];
  let c = await find();
  assert.equal(c.state_code, '10', 'state from GSTIN');
  assert.equal(c.phone, phone);

  // Category limit applies...
  assert.equal((await call('POST', '/credit-limits', ownerToken, { categoryId: retailer.id, maxOutstanding: 5000 })).status, 201);
  c = await find();
  assert.equal(c.limit_amount, 5000);
  assert.equal(c.limit_source, 'category');
  // ...until the customer gets their own, set twice on the same day: the last one wins
  await call('POST', '/credit-limits', ownerToken, { customerId: id, maxOutstanding: 8000 });
  await call('POST', '/credit-limits', ownerToken, { customerId: id, maxOutstanding: 12000 });
  c = await find();
  assert.equal(c.limit_amount, 12000);
  assert.equal(c.limit_source, 'customer');
  // A temporary raise sits on top, and removing it all goes back to the category
  await call('POST', '/credit-limits', ownerToken, { customerId: id, maxOutstanding: 20000, validDays: 7 });
  c = await find();
  assert.equal(c.limit_amount, 20000);
  assert.ok(c.own_limit_until);
  await call('POST', '/credit-limits', ownerToken, { customerId: id, remove: true });
  c = await find();
  assert.equal(c.limit_source, 'category');
  // Put the category back to 0 for other tests
  await call('POST', '/credit-limits', ownerToken, { categoryId: retailer.id, maxOutstanding: 0 });

  // Cashiers cannot do any of this
  assert.equal((await call('POST', '/credit-limits', cashierToken, { customerId: id, maxOutstanding: 1 })).status, 403);
  assert.equal((await call('GET', '/customers', cashierToken)).status, 403);
});

test('a cashier cancels a bill with the manager\'s PIN; payment and stock are reversed', async () => {
  const t = pulled.tables;
  const me = (await call('GET', '/auth/me', cashierToken)).body;
  const item = t.item.find((i: any) => i.code === '2');
  const pc = t.unit.find((u: any) => u.code === 'PC');
  const shiftId = randomUUID();
  const id = randomUUID();
  const push = await call('POST', '/sync/push', cashierToken, {
    shift: [{ id: shiftId, user_id: me.userId, opened_at: new Date().toISOString(), opening_cash: 0 }],
    sales_invoice: [{
      id, company_id: t.company[0].id, shift_id: shiftId, doc_type: 'INV', doc_no: `DD3-${deviceCode}-2627-000002`,
      doc_date: '2026-11-16', status: 'final', price_level_id: t.price_level[0].id, place_of_supply: '10',
      subtotal: 72, taxable: 72, total: 72, paid: 72, balance: 0, created_by: me.userId,
      finalised_at: new Date().toISOString() }],
    sales_invoice_line: [{ id: randomUUID(), invoice_id: id, line_no: 1, item_id: item.id, unit_id: pc.id, qty: 2,
      factor: 1, rate: 36, list_rate: 36, gst_rate: 0, taxable: 72, amount: 72 }],
    receipt: [{ id: randomUUID(), doc_date: '2026-11-16', invoice_id: id, mode: 'cash', amount: 72,
      created_by: me.userId, status: 'final', shift_id: shiftId }],
    stock_move: [{ id: randomUUID(), item_id: item.id, qty: -2, move_type: 'sale', doc_id: id, move_date: '2026-11-16',
      created_by: me.userId }],
  });
  assert.equal(push.status, 201, JSON.stringify(push.body));

  const noReason = await call('POST', `/bills/${id}/cancel`, cashierToken, { reason: '' });
  assert.equal(noReason.status, 400);
  const noManager = await call('POST', `/bills/${id}/cancel`, cashierToken, { reason: 'Wrong item' });
  assert.equal(noManager.status, 403, 'a cashier alone cannot cancel');
  const ok = await call('POST', `/bills/${id}/cancel`, cashierToken,
    { reason: 'Wrong item', approverPhone: '9222222222', approverPin: '5678' });
  assert.equal(ok.status, 201, JSON.stringify(ok.body));
  assert.equal(ok.body.cancelledByName, 'Test Owner');

  const inv = (await admin.query('SELECT status, cancel_reason FROM sales_invoice WHERE id = $1', [id])).rows[0];
  assert.deepEqual(inv, { status: 'cancelled', cancel_reason: 'Wrong item' });
  const rc = (await admin.query('SELECT status FROM receipt WHERE invoice_id = $1', [id])).rows;
  assert.ok(rc.every((r) => r.status === 'cancelled'));
  const net = (await admin.query('SELECT sum(qty)::float AS q FROM stock_move WHERE doc_id = $1', [id])).rows[0].q;
  assert.equal(net, 0, 'stock back to where it was');

  assert.equal((await call('POST', `/bills/${id}/cancel`, cashierToken, { reason: 'again' })).status, 400);
  assert.equal((await call('POST', `/bills/${randomUUID()}/cancel`, cashierToken, { reason: 'Wrong item' })).status, 404);
  // A tablet resending the old final copy does not bring the bill back
  await call('POST', '/sync/push', cashierToken, { sales_invoice: [{ ...push && {}, id, company_id: t.company[0].id,
    shift_id: shiftId, doc_type: 'INV', doc_no: `DD3-${deviceCode}-2627-000002`, doc_date: '2026-11-16', status: 'final',
    price_level_id: t.price_level[0].id, place_of_supply: '10', total: 72, created_by: me.userId }] });
  assert.equal((await admin.query('SELECT status FROM sales_invoice WHERE id = $1', [id])).rows[0].status, 'cancelled');
});

test('tablets can ask for the newest app build', async () => {
  const r = await call('GET', '/download/pos/version', '');
  assert.equal(r.status, 200);
  assert.equal(typeof r.body.versionCode, 'number');
});

test('day-end report for an outlet', async () => {
  const r = await call('GET', '/reports/dayend?date=2026-11-16&location=dd3', ownerToken);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.outlet.code, 'DD3');
  for (const k of ['totals', 'modes', 'shifts', 'gst', 'items', 'credit', 'cancelled']) assert.ok(k in r.body, k);
  assert.ok(r.body.cancelled.some((x: any) => x.cancel_reason === 'Wrong item' && x.cancelled_by === 'Test Owner'));
  assert.equal((await call('GET', '/reports/dayend?date=2026-11-16', ownerToken)).status, 400);
  assert.equal((await call('GET', '/reports/dayend?date=2026-11-16&location=DD3', cashierToken)).status, 403);
});

test('Tally vouchers balance and follow the ledger names', () => {
  const st = { ...DEFAULT_TALLY, cash: 'Cash - {outlet}' };
  const inv = (id: string, doc: string, total: number, balance: number, customer: string | null = null) =>
    ({ id, doc_no: doc, doc_date: '2026-11-16', outlet: 'DD3', customer, total, paid: total - balance, balance, round_off: 0 });
  const v = buildVouchers(
    [inv('a', 'DD3-T1-2627-000001', 105, 0), inv('b', 'DD3-T1-2627-000002', 36, 0),
      inv('c', 'DD3-T1-2627-000003', 525, 425, 'Gupta Kirana')],
    [{ invoice_id: 'a', gst_rate: 5, taxable: 100, cgst: 2.5, sgst: 2.5, igst: 0 },
      { invoice_id: 'b', gst_rate: 0, taxable: 35.6, cgst: 0, sgst: 0, igst: 0 },
      { invoice_id: 'c', gst_rate: 5, taxable: 500, cgst: 12.5, sgst: 12.5, igst: 0 }],
    [{ invoice_id: 'a', mode: 'cash', amount: 105 }, { invoice_id: 'b', mode: 'upi', amount: 36 },
      { invoice_id: 'c', mode: 'cash', amount: 100 }], st);
  assert.equal(v.length, 3, 'day summary + credit bill + its part payment');
  for (const x of v) assert.equal(Math.round(x.entries.reduce((a, e) => a + e.amount, 0) * 100), 0, x.key);
  const day = v[0];
  assert.deepEqual(day.entries.find((e) => e.ledger === 'Cash - DD3')?.amount, 105);
  assert.ok(day.entries.some((e) => e.ledger === 'Sales Exempt' && e.amount === -35.6));
  assert.ok(day.entries.some((e) => e.ledger === 'Round Off' && e.amount === -0.4));
  assert.ok(v[1].entries.some((e) => e.ledger === 'Gupta Kirana' && e.amount === 525 && e.billRef));
  const xml = vouchersXml(v, st);
  assert.match(xml, /<LEDGERNAME>Sales @5%<\/LEDGERNAME>/);
  assert.match(xml, /<BILLTYPE>New Ref<\/BILLTYPE>/);
  assert.match(xml, /REMOTEID="kwik-day-DD3-2026-11-16"/);
});

test('Tally export from the server', async () => {
  const pre = await call('GET', '/tally/preview?from=2026-11-01&to=2026-11-30', ownerToken);
  assert.equal(pre.status, 200, JSON.stringify(pre.body));
  for (const v of pre.body.vouchers) {
    assert.equal(Math.round(v.entries.reduce((a: number, e: any) => a + e.amount, 0) * 100), 0, v.key);
  }
  const res = await fetch(`${base}/tally/vouchers.xml?from=2026-11-01&to=2026-11-30`, { headers: { authorization: `Bearer ${ownerToken}` } });
  assert.equal(res.status, 200);
  assert.match(res.headers.get('content-disposition') ?? '', /kwikerp-tally-2026-11-01_2026-11-30\.xml/);
  assert.match(await res.text(), /<ENVELOPE>/);
  const saved = await call('POST', '/tally/settings', ownerToken, { upi: 'PhonePe Collections' });
  assert.equal(saved.body.upi, 'PhonePe Collections');
  assert.equal((await call('POST', '/tally/settings', ownerToken, { cash: ' ' })).status, 400);
  assert.equal((await call('GET', '/tally/preview?from=2026-11-01&to=2026-11-30', cashierToken)).status, 403);
  const led = await fetch(`${base}/tally/ledgers.xml`, { headers: { authorization: `Bearer ${ownerToken}` } });
  assert.match(await led.text(), /<PARENT>Sundry Debtors<\/PARENT>/);
});

test('head office manages logins and tablets; switched-off ones stop working', async () => {
  const me = (await call('GET', '/auth/me', ownerToken)).body;
  const list = (await call('GET', '/admin/users', ownerToken)).body;
  assert.ok(list.roles.some((r: any) => r.code === 'OUTLET'));
  const code = `X${Math.random().toString(36).slice(2, 5).toUpperCase()}`;
  const dev = await call('POST', '/admin/devices', ownerToken, { location: 'dd3', code });
  assert.equal(dev.status, 201, JSON.stringify(dev.body));
  assert.equal(dev.body.setupCode, `DD3-${code}`);

  const phone = `8${Math.floor(Math.random() * 1e9).toString().padStart(9, '0')}`;
  assert.equal((await call('POST', '/admin/users', ownerToken,
    { name: 'Weak', phone, pin: '1111', roles: [{ role: 'CASHIER', location: 'DD3' }] })).status, 400, 'weak PIN refused');
  assert.equal((await call('POST', '/admin/users', ownerToken,
    { name: 'No outlet', phone, pin: '2580', roles: [{ role: 'CASHIER' }] })).status, 400, 'cashier needs an outlet');
  const add = await call('POST', '/admin/users', ownerToken,
    { name: 'DD3 In-charge', phone, pin: '2580', roles: [{ role: 'OUTLET', location: 'DD3' }] });
  assert.equal(add.status, 201, JSON.stringify(add.body));
  const login = await call('POST', '/auth/login', '', { tenantCode: 'TROIKA', phone, pin: '2580', deviceId: `DD3-${code}` });
  assert.equal(login.status, 201, JSON.stringify(login.body));
  assert.ok(login.body.user.permissions.includes('bill.cancel'));
  const tok = login.body.token;
  assert.equal((await call('GET', '/auth/me', tok)).status, 200);

  // Switch the tablet off: its session stops at once
  await call('POST', `/admin/devices/${dev.body.id}`, ownerToken, { isActive: false });
  assert.equal((await call('GET', '/sync/pull?since=0', tok)).status, 401);
  await call('POST', `/admin/devices/${dev.body.id}`, ownerToken, { isActive: true });
  assert.equal((await call('GET', '/auth/me', tok)).status, 200);

  // Switch the person off
  await call('POST', '/admin/users', ownerToken,
    { id: add.body.id, name: 'DD3 In-charge', phone, isActive: false, roles: [{ role: 'OUTLET', location: 'DD3' }] });
  assert.equal((await call('GET', '/auth/me', tok)).status, 401);

  // The owner cannot lock themselves out; cashiers cannot manage users
  assert.equal((await call('POST', '/admin/users', ownerToken,
    { id: me.userId, name: 'Test Owner', phone: '9222222222', isActive: false, roles: [{ role: 'OWNER' }] })).status, 400);
  assert.equal((await call('GET', '/admin/users', cashierToken)).status, 403);
});

test('receipt layout is set at head office and reaches the tablet once', async () => {
  const logo = { width: 16, height: 2, data: Buffer.from([0xff, 0x00, 0x0f, 0xf0]).toString('base64') };
  const saved = await call('POST', '/settings/receipt', ownerToken, { footer: 'Visit again', showSavings: false, logo });
  assert.equal(saved.status, 201, JSON.stringify(saved.body));
  assert.equal(saved.body.footer, 'Visit again');
  assert.equal((await call('POST', '/settings/receipt', ownerToken, { logo: { width: 10, height: 2, data: 'AA==' } })).status, 400);
  assert.equal((await call('POST', '/settings/business', ownerToken,
    { company: { gstin: '10AAFCT0798Q1ZV', phone: '9507305999' }, outlets: [{ code: 'DD3', address: 'Opp. Dr Lalit Mohan Sharma, Bihta' }] })).status, 201);
  assert.equal((await call('POST', '/settings/business', ownerToken, { company: { gstin: 'BAD' } })).status, 400);
  assert.equal((await call('GET', '/settings/receipt', cashierToken)).status, 403);

  const p1 = (await call('GET', '/sync/pull?since=0', cashierToken)).body;
  assert.equal(p1.settings.receipt.footer, 'Visit again');
  assert.equal(p1.settings.receipt.logo.width, 16);
  assert.ok(p1.tables.company.some((c: any) => c.gstin === '10AAFCT0798Q1ZV'));
  const p2 = (await call('GET', `/sync/pull?since=${p1.cursor}&sv=${encodeURIComponent(p1.settings.version)}`, cashierToken)).body;
  assert.equal(p2.settings, undefined, 'not sent again when unchanged');
  const sp = await call('POST', '/settings/receipt', ownerToken, { billTop: 2, billBottom: 5, tokenTop: 0, tokenBottom: 3 });
  assert.equal(sp.body.billTop, 2);
  assert.equal(sp.body.tokenBottom, 3);
  assert.equal((await call('POST', '/settings/receipt', ownerToken, { billTop: 11 })).status, 400);
  await call('POST', '/settings/receipt', ownerToken, { logo: null, showSavings: true, billTop: 0, billBottom: 4, tokenTop: 0, tokenBottom: 4 });
});

test('customer types and the rate chart (owners and managers only)', async () => {
  const t = (await call('GET', '/customer-types', ownerToken)).body;
  const retail = t.levels.find((l: any) => l.code === 'RETAILER');
  const code = `T${Math.random().toString(36).slice(2, 6).toUpperCase()}`;
  const add = await call('POST', '/customer-types', ownerToken,
    { code, name: `Type ${code}`, priceLevelId: retail.id, creditAllowed: true, maxOutstanding: 3000, maxDays: 10 });
  assert.equal(add.status, 201, JSON.stringify(add.body));
  let mine = (await call('GET', '/customer-types', ownerToken)).body.types.find((x: any) => x.id === add.body.id);
  assert.equal(mine.max_outstanding, 3000);
  assert.equal(mine.max_days, 10);
  assert.equal((await call('POST', '/customer-types', ownerToken,
    { code, name: 'Other', priceLevelId: retail.id, creditAllowed: true })).status, 400, 'code must be unique');
  await call('POST', '/customer-types', ownerToken,
    { id: add.body.id, code, name: `Type ${code}`, priceLevelId: retail.id, creditAllowed: false, isActive: false });
  mine = (await call('GET', '/customer-types', ownerToken)).body.types.find((x: any) => x.id === add.body.id);
  assert.equal(mine.is_active, false);
  assert.equal(mine.max_outstanding, 0, 'no credit = limit 0');

  // Rate chart: change Gold milk retailer rate from tomorrow; trays/boxes follow piece x pack
  const chart = (await call('GET', '/rates', ownerToken)).body;
  const tomorrow = new Date(Date.now() + 5.5 * 3600e3 + 864e5).toISOString().slice(0, 10);
  const dahiTray = chart.items.find((i: any) => i.code === '8');   // Dahi 200g Tray: cups, tray of 6
  assert.ok(dahiTray.packs);
  const save = await call('POST', '/rates', ownerToken,
    { effectiveFrom: tomorrow, changes: [{ itemId: dahiTray.id, levelId: retail.id, price: 27 }] });
  assert.equal(save.status, 201, JSON.stringify(save.body));
  assert.ok(save.body.rows >= 2, 'cup and tray');
  const after = (await call('GET', '/rates', ownerToken)).body.prices
    .find((p: any) => p.item_id === dahiTray.id && p.price_level_id === retail.id);
  assert.equal(after.next_price, 27);
  assert.equal(after.next_from, tomorrow);
  assert.notEqual(after.price, 27, "today's rate is unchanged");
  const tray = (await admin.query(
    `SELECT p.price::float AS price FROM item_price p JOIN unit u ON u.id = p.unit_id
      WHERE p.item_id = $1 AND p.price_level_id = $2 AND p.valid_from = $3 AND u.code = 'TRAY'`,
    [dahiTray.id, retail.id, tomorrow])).rows[0];
  assert.equal(tray.price, 162, '6 x 27');
  assert.equal((await call('POST', '/rates', ownerToken,
    { effectiveFrom: '2020-01-01', changes: [{ itemId: dahiTray.id, levelId: retail.id, price: 1 }] })).status, 400);

  const lvl = await call('POST', '/price-levels', ownerToken, { name: `Event ${code}`, copyFromId: retail.id });
  assert.equal(lvl.status, 201, JSON.stringify(lvl.body));
  assert.ok((await call('GET', '/rates', ownerToken)).body.prices.some((p: any) => p.price_level_id === lvl.body.id));

  assert.equal((await call('GET', '/rates', cashierToken)).status, 403);
  assert.equal((await call('GET', '/customer-types', cashierToken)).status, 403);
});

test('product photos: head office uploads, tablets download', async () => {
  const items = (await call('GET', '/items/photos', ownerToken)).body;
  const it = items.find((i: any) => i.code === '2');
  // a 1x1 JPEG
  const jpg = '/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////wgALCAABAAEBAREA/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPxA=';
  const up = await call('POST', `/items/${it.id}/photo`, ownerToken, { data: jpg });
  assert.equal(up.status, 201, JSON.stringify(up.body));
  assert.equal((await call('POST', `/items/${it.id}/photo`, ownerToken, { data: Buffer.from('hello').toString('base64') })).status, 400);
  assert.equal((await call('POST', `/items/${it.id}/photo`, cashierToken, { data: jpg })).status, 403);
  const pull = (await call('GET', '/sync/pull?since=0', cashierToken)).body;
  assert.equal(pull.tables.item.find((i: any) => i.id === it.id).image_version, up.body.version);
  const img = await fetch(`${base}/items/${it.id}/photo`, { headers: { authorization: `Bearer ${cashierToken}` } });
  assert.equal(img.status, 200);
  assert.equal(img.headers.get('content-type'), 'image/jpeg');
  await call('POST', `/items/${it.id}/photo/remove`, ownerToken);
  assert.equal((await fetch(`${base}/items/${it.id}/photo`, { headers: { authorization: `Bearer ${cashierToken}` } })).status, 404);
});


// ---------------------------------------------------------------- stock & audit

async function newLogin(role: string, location: string | null, name: string) {
  const phone = `7${Math.floor(Math.random() * 1e9).toString().padStart(9, '0')}`;
  const add = await call('POST', '/admin/users', ownerToken,
    { name, phone, pin: '2580', roles: [{ role, location }] });
  assert.equal(add.status, 201, JSON.stringify(add.body));
  const r = await call('POST', '/auth/login', '', { tenantCode: 'TROIKA', phone, pin: '2580' });
  assert.equal(r.status, 201, JSON.stringify(r.body));
  return r.body.token as string;
}

test('user types: listed with the permission groups, editable, Owner locked', async () => {
  const list = await call('GET', '/admin/roles', ownerToken);
  assert.equal(list.status, 200);
  assert.ok(list.body.groups.some((g: any) => g.name === 'Stock'));
  for (const code of ['DISPATCH', 'ACCOUNTS', 'OUTLET']) assert.ok(list.body.roles.some((r: any) => r.code === code), code);
  assert.equal(list.body.roles.find((r: any) => r.code === 'OUTLET').name, 'Store Manager');
  const add = await call('POST', '/admin/roles', ownerToken,
    { name: `Helper ${Math.random().toString(36).slice(2, 5)}`, allLocations: false, permissions: ['bill.create'] });
  assert.equal(add.status, 201, JSON.stringify(add.body));
  assert.equal((await call('POST', '/admin/roles', ownerToken,
    { code: add.body.code, name: 'Helper', allLocations: false, permissions: ['bill.create', 'nonsense'] })).status, 400);
  assert.equal((await call('POST', '/admin/roles', ownerToken,
    { code: 'OWNER', name: 'Boss', allLocations: true, permissions: [] })).status, 400);
  assert.equal((await call('POST', '/admin/roles', ownerToken,
    { code: add.body.code, name: 'Helper off', allLocations: false, permissions: [], isActive: false })).status, 201);
  assert.equal((await call('GET', '/admin/roles', cashierToken)).status, 403);
});

test('dispatch → counter receives (short) → adjustment approved → count → audit', async () => {
  const meta = (await call('GET', '/stock/meta', ownerToken)).body;
  const plant = meta.locations.find((l: any) => l.code === 'PLANT');
  const dd3 = meta.locations.find((l: any) => l.code === 'DD3');
  const item = meta.items.find((i: any) => i.mrp > 0);
  assert.ok(plant.sends_goods && item);
  const dispatcher = await newLogin('DISPATCH', 'PLANT', 'Test Dispatch');
  const accounts = await newLogin('ACCOUNTS', null, 'Test Accounts');
  const here0 = (await call('GET', '/stock/here', cashierToken)).body.items.find((x: any) => x.item_id === item.id)?.qty ?? 0;

  // Dispatch can only send from the plant
  const bad = await call('POST', '/stock/dispatch', dispatcher,
    { id: randomUUID(), from: dd3.id, to: plant.id, send: true, lines: [{ itemId: item.id, qty: 1 }] });
  assert.equal(bad.status, 400, JSON.stringify(bad.body)); // DD3 does not send goods
  const id = randomUUID();
  const sent = await call('POST', '/stock/dispatch', dispatcher,
    { id, from: plant.id, to: dd3.id, vehicle: 'BR01', send: true, lines: [{ itemId: item.id, qty: 10 }] });
  assert.equal(sent.status, 201, JSON.stringify(sent.body));
  assert.match(sent.body.docNo, /^PLANT-W1-\d{4}-\d{4}$/);
  const again = await call('POST', '/stock/dispatch', dispatcher,
    { id, from: plant.id, to: dd3.id, send: true, lines: [{ itemId: item.id, qty: 10 }] });
  assert.equal(again.body.docNo, sent.body.docNo, 'a retry does not send twice');

  // The DD3 tablet sees it as incoming and receives 8 (2 short)
  const incoming = (await call('GET', '/stock/transfers?incoming=1', cashierToken)).body;
  assert.ok(incoming.some((t: any) => t.id === id));
  const t = (await call('GET', `/stock/transfers/${id}`, cashierToken)).body;
  assert.equal((await call('POST', `/stock/transfers/${id}/receive`, cashierToken,
    { lines: [{ id: t.lines[0].id, received: 8 }] })).status, 400, 'a difference needs a reason');
  const rec = await call('POST', `/stock/transfers/${id}/receive`, cashierToken,
    { lines: [{ id: t.lines[0].id, received: 8, reason: 'short' }] });
  assert.equal(rec.status, 201, JSON.stringify(rec.body));
  assert.equal(rec.body.hasDifference, true);
  const here1 = (await call('GET', '/stock/here', cashierToken)).body.items.find((x: any) => x.item_id === item.id).qty;
  assert.equal(here1, here0 + 8);

  // Counter asks to write off 2 expired; the cashier cannot approve; the owner can
  const adj = randomUUID();
  const ask = await call('POST', '/stock/adjustments', cashierToken,
    { id: adj, itemId: item.id, qty: -2, reason: 'expired', note: 'test' });
  assert.equal(ask.status, 201, JSON.stringify(ask.body));
  assert.equal(ask.body.value, Math.round(2 * item.mrp * 100) / 100);
  assert.equal((await call('POST', `/stock/adjustments/${adj}/decide`, cashierToken, { approve: true })).status, 403);
  const here2a = (await call('GET', '/stock/here', cashierToken)).body.items.find((x: any) => x.item_id === item.id).qty;
  assert.equal(here2a, here1, 'stock unchanged until approved');
  const ok = await call('POST', `/stock/adjustments/${adj}/decide`, ownerToken, { approve: true });
  assert.equal(ok.status, 201, JSON.stringify(ok.body));
  const here2 = (await call('GET', '/stock/here', cashierToken)).body.items.find((x: any) => x.item_id === item.id).qty;
  assert.equal(here2, here1 - 2);

  // Above the limit a manager cannot approve
  await call('POST', '/settings/stock', ownerToken, { ownerAbove: 500 });
  const manager = await newLogin('MANAGER', null, 'Test Manager');
  const big = randomUUID();
  const bigQty = Math.ceil(501 / item.mrp) + 1;
  const askBig = await call('POST', '/stock/adjustments', cashierToken, { id: big, itemId: item.id, qty: -bigQty, reason: 'broken' });
  assert.equal(askBig.body.needsOwner, true);
  assert.equal((await call('POST', `/stock/adjustments/${big}/decide`, manager, { approve: true })).status, 403);
  assert.equal((await call('POST', `/stock/adjustments/${big}/decide`, manager, { approve: false })).status, 403);
  assert.equal((await call('POST', `/stock/adjustments/${big}/decide`, ownerToken, { approve: false, note: 'recount' })).status, 201);

  // Accounts counts DD3 from the web page: one more than the system
  const cnt = randomUUID();
  const counted = await call('POST', '/stock/counts', accounts, { id: cnt, location: dd3.id, lines: [{ itemId: item.id, counted: here2 + 1 }] });
  assert.equal(counted.status, 201, JSON.stringify(counted.body));
  assert.equal(counted.body.lines[0].diff, 1);
  const pending = (await call('GET', '/stock/adjustments', manager)).body;
  assert.ok(pending.some((a: any) => a.count_id === cnt && a.qty === 1));

  // Head-office views
  const pos = await call('GET', '/stock/position', accounts);
  assert.equal(pos.status, 200);
  assert.equal(pos.body.items.find((i: any) => i.id === item.id).qty[dd3.id], here2);
  assert.equal((await call('GET', '/stock/position', cashierToken)).status, 403);
  const today = new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Kolkata' }).format(new Date());
  const day = await call('GET', `/audit/day?location=${dd3.id}&date=${today}`, accounts);
  assert.equal(day.status, 200, JSON.stringify(day.body));
  const row = day.body.stock.find((r: any) => r.item_id === item.id);
  assert.equal(row.received >= 8, true);
  assert.equal(row.diff, 1);
  assert.equal((await call('POST', '/audit/day', accounts, { location: dd3.id, date: today, status: 'query' })).status, 400);
  assert.equal((await call('POST', '/audit/day', accounts, { location: dd3.id, date: today, status: 'verified', upiMatched: true })).status, 201);
  assert.equal((await call('POST', '/audit/day', dispatcher, { location: dd3.id, date: today, status: 'verified' })).status, 403);
  for (const type of ['daily', 'stock_diff', 'adjustments', 'dispatch', 'cash']) {
    const r = await call('GET', `/audit/report?type=${type}&from=${today}&to=${today}`, accounts);
    assert.equal(r.status, 200, `${type}: ${JSON.stringify(r.body)}`);
    assert.ok(r.body.summary && Array.isArray(r.body.rows));
  }
  assert.equal((await call('GET', '/audit/overview', accounts)).status, 200);
});

test('settings: companies and locations, a godown can send goods', async () => {
  const org = (await call('GET', '/settings/org', ownerToken)).body;
  assert.ok(org.companies.length >= 1);
  const code = `G${Math.random().toString(36).slice(2, 5).toUpperCase()}`;
  const add = await call('POST', '/settings/location', ownerToken,
    { code, name: 'Test godown', kind: 'godown', sendsGoods: true, supplyFrom: 'PLANT' });
  assert.equal(add.status, 201, JSON.stringify(add.body));
  assert.equal((await call('POST', '/settings/location', ownerToken,
    { code, name: 'Dup', kind: 'godown' })).status, 400);
  const c = org.companies[0];
  assert.equal((await call('POST', '/settings/company', ownerToken,
    { id: c.id, code: c.code, legalName: c.legal_name, stateCode: c.state_code, brandName: 'Dugdh Dhara', pan: 'bad' })).status, 400);
  assert.equal((await call('POST', '/settings/company', ownerToken,
    { id: c.id, code: c.code, legalName: c.legal_name, stateCode: c.state_code, brandName: 'Dugdh Dhara' })).status, 201);
});
