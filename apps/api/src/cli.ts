/**
 * Admin commands, run on the server with the table owner's connection
 * (ADMIN_DATABASE_URL). Until the head-office screens exist, this is how users
 * are added and tablets registered.
 *
 *   node dist/cli.js user:add  --tenant TROIKA --name "Ravi" --phone 9000000001 --pin 1234 --role CASHIER --location DD3
 *   node dist/cli.js device:add --tenant TROIKA --location DD3 --code T1
 *   node dist/cli.js device:list --tenant TROIKA
 */
import * as bcrypt from 'bcryptjs';
import { Client } from 'pg';

function args(): Record<string, string> {
  const out: Record<string, string> = {};
  const a = process.argv.slice(3);
  for (let i = 0; i < a.length; i += 2) out[a[i].replace(/^--/, '')] = a[i + 1];
  return out;
}

async function main() {
  const cmd = process.argv[2];
  const p = args();
  const url = process.env.ADMIN_DATABASE_URL;
  if (!url) throw new Error('Set ADMIN_DATABASE_URL (table owner connection)');
  const c = new Client({ connectionString: url });
  await c.connect();
  await c.query('SET search_path = kwik, public');
  try {
    const tenant = (await c.query('SELECT id FROM tenant WHERE code = $1', [(p.tenant ?? '').toUpperCase()])).rows[0];
    if (!tenant) throw new Error(`Unknown tenant ${p.tenant}`);

    if (cmd === 'user:add') {
      if (!p.name || !p.phone || !p.pin || !p.role) throw new Error('--name --phone --pin --role are required');
      if (!/^\d{4,6}$/.test(p.pin)) throw new Error('PIN must be 4 to 6 digits');
      const role = (await c.query('SELECT id FROM role WHERE tenant_id = $1 AND code = $2',
        [tenant.id, p.role.toUpperCase()])).rows[0];
      if (!role) throw new Error(`Unknown role ${p.role}`);
      const loc = p.location
        ? (await c.query('SELECT id FROM location WHERE tenant_id = $1 AND code = $2', [tenant.id, p.location.toUpperCase()])).rows[0]
        : null;
      if (p.location && !loc) throw new Error(`Unknown location ${p.location}`);
      const hash = await bcrypt.hash(p.pin, 10);
      const user = (await c.query(
        `INSERT INTO app_user (tenant_id, name, phone, pin_hash) VALUES ($1, $2, $3, $4)
         ON CONFLICT (tenant_id, phone) DO UPDATE SET name = EXCLUDED.name, pin_hash = EXCLUDED.pin_hash
         RETURNING id`, [tenant.id, p.name, p.phone, hash])).rows[0];
      await c.query(
        `INSERT INTO user_role (tenant_id, user_id, role_id, location_id)
         SELECT $1, $2, $3, $4 WHERE NOT EXISTS (
           SELECT 1 FROM user_role WHERE user_id = $2 AND role_id = $3
             AND location_id IS NOT DISTINCT FROM $4 AND deleted_at IS NULL)`,
        [tenant.id, user.id, role.id, loc?.id ?? null]);
      console.log(`User ${p.name} (${p.phone}) ready with role ${p.role}${p.location ? ' at ' + p.location : ''}`);
    } else if (cmd === 'device:add') {
      const loc = (await c.query('SELECT id FROM location WHERE tenant_id = $1 AND code = $2',
        [tenant.id, (p.location ?? '').toUpperCase()])).rows[0];
      if (!loc || !p.code) throw new Error('--location and --code are required');
      const d = (await c.query(
        `INSERT INTO device (tenant_id, location_id, code, name) VALUES ($1, $2, $3, $4)
         ON CONFLICT (location_id, code) DO UPDATE SET is_active = true RETURNING id`,
        [tenant.id, loc.id, p.code.toUpperCase(), p.name ?? `${p.location} ${p.code}`])).rows[0];
      console.log(`Device ${p.location}-${p.code} id: ${d.id}`);
    } else if (cmd === 'device:list') {
      const rows = (await c.query(
        `SELECT l.code AS location, d.code, d.id, d.last_seen_at FROM device d JOIN location l ON l.id = d.location_id
          WHERE d.tenant_id = $1 ORDER BY 1, 2`, [tenant.id])).rows;
      console.table(rows);
    } else {
      throw new Error('Commands: user:add, device:add, device:list');
    }
  } finally {
    await c.end();
  }
}

main().catch((e) => {
  console.error(e.message);
  process.exit(1);
});
