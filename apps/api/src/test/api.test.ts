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
  assert.equal(pulled.tables.price_level.length, 5);
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

