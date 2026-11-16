import {
  BadRequestException, Body, Controller, Get, NotFoundException, Param, Post, Req, UseGuards,
} from '@nestjs/common';
import * as bcrypt from 'bcryptjs';
import { AuthGuard, forgetActive, Needs, Session } from './auth';
import { Db } from './db';

interface UserBody {
  id?: string;
  name: string;
  phone: string;
  pin?: string;                 // required for a new user; set to reset
  isActive?: boolean;
  roles: { role: string; location?: string | null }[]; // role code, outlet code (empty = all outlets)
}

interface DeviceBody {
  location: string;  // outlet code
  code: string;      // T1, T2…
  name?: string;
  isActive?: boolean;
}

const cleanPhone = (p: string) => (p ?? '').replace(/\D/g, '').replace(/^91(?=\d{10}$)/, '');

/** Staff logins and outlet tablets, for the head-office page. */
@Controller('admin')
@UseGuards(AuthGuard)
export class AdminController {
  constructor(private readonly db: Db) {}

  @Get('users')
  @Needs('users.manage')
  users(@Req() req: any) {
    const s: Session = req.session;
    return this.db.tx(s.tenantId, async (c) => ({
      users: (await c.query(
        `SELECT u.id, u.name, u.phone, u.is_active, u.pin_hash IS NOT NULL AS has_pin,
                coalesce(json_agg(json_build_object('role', r.code, 'roleName', r.name, 'location', l.code))
                  FILTER (WHERE ur.id IS NOT NULL), '[]') AS roles
           FROM app_user u
           LEFT JOIN user_role ur ON ur.user_id = u.id AND ur.deleted_at IS NULL
           LEFT JOIN role r ON r.id = ur.role_id
           LEFT JOIN location l ON l.id = ur.location_id
          WHERE u.deleted_at IS NULL
          GROUP BY u.id ORDER BY u.is_active DESC, u.name`)).rows,
      roles: (await c.query(
        `SELECT code, name, permissions FROM role WHERE deleted_at IS NULL
          ORDER BY array_position(ARRAY['OWNER','MANAGER','OUTLET','CASHIER'], code), name`)).rows,
      locations: (await c.query(
        `SELECT code, name FROM location WHERE deleted_at IS NULL AND kind IN ('outlet','franchise','plant') ORDER BY code`)).rows,
      devices: (await c.query(
        `SELECT d.id, l.code AS location, d.code, d.name, d.is_active, d.last_seen_at
           FROM device d JOIN location l ON l.id = d.location_id
          WHERE d.deleted_at IS NULL ORDER BY l.code, d.code`)).rows,
    }));
  }

  @Post('users')
  @Needs('users.manage')
  saveUser(@Req() req: any, @Body() b: UserBody) {
    const s: Session = req.session;
    const name = (b?.name ?? '').trim();
    const phone = cleanPhone(b?.phone);
    const pin = (b?.pin ?? '').trim();
    if (!name) throw new BadRequestException('Name is required');
    if (phone.length !== 10) throw new BadRequestException('Mobile number must have 10 digits');
    if (!b.id && !pin) throw new BadRequestException('Set a PIN for the new login');
    if (pin && !/^\d{4,6}$/.test(pin)) throw new BadRequestException('PIN must be 4 to 6 digits');
    if (pin && /^(\d)\1+$|^(0123|1234|2345|3456|4567|5678|6789|9876|4321)/.test(pin)) {
      throw new BadRequestException('Choose a PIN that is harder to guess than repeated or running digits');
    }
    if (!Array.isArray(b.roles) || !b.roles.length) throw new BadRequestException('Give at least one role');
    const active = b.isActive ?? true;
    if (b.id === s.userId && !active) throw new BadRequestException('You cannot switch off your own login');

    return this.db.tx(s.tenantId, async (c) => {
      // Resolve roles and outlets
      const wanted: { roleId: string; code: string; locationId: string | null }[] = [];
      for (const r of b.roles) {
        const role = (await c.query('SELECT id, code FROM role WHERE code = $1 AND deleted_at IS NULL',
          [(r.role ?? '').toUpperCase()])).rows[0];
        if (!role) throw new BadRequestException(`Unknown role ${r.role}`);
        let locationId: string | null = null;
        if (r.location) {
          const l = (await c.query('SELECT id FROM location WHERE upper(code) = upper($1) AND deleted_at IS NULL',
            [r.location])).rows[0];
          if (!l) throw new BadRequestException(`Unknown outlet ${r.location}`);
          locationId = l.id;
        }
        if (role.code !== 'OWNER' && role.code !== 'MANAGER' && !locationId) {
          throw new BadRequestException('Choose the outlet for cashier and outlet manager logins');
        }
        wanted.push({ roleId: role.id, code: role.code, locationId });
      }
      if (b.id === s.userId && !wanted.some((w) => w.code === 'OWNER') && s.permissions.includes('*')) {
        throw new BadRequestException('You cannot remove your own owner role');
      }
      const dup = (await c.query(
        'SELECT name FROM app_user WHERE phone = $1 AND deleted_at IS NULL AND id IS DISTINCT FROM $2::uuid',
        [phone, b.id ?? null])).rows[0];
      if (dup) throw new BadRequestException(`Mobile ${phone} already belongs to ${dup.name}`);

      const hash = pin ? await bcrypt.hash(pin, 10) : null;
      let id = b.id;
      if (id) {
        const r = await c.query(
          `UPDATE app_user SET name = $2, phone = $3, is_active = $4, pin_hash = coalesce($5, pin_hash)
            WHERE id = $1 AND deleted_at IS NULL`, [id, name, phone, active, hash]);
        if (!r.rowCount) throw new NotFoundException('User not found');
        await c.query('UPDATE user_role SET deleted_at = now() WHERE user_id = $1 AND deleted_at IS NULL', [id]);
      } else {
        id = (await c.query(
          'INSERT INTO app_user (tenant_id, name, phone, pin_hash) VALUES ($1, $2, $3, $4) RETURNING id',
          [s.tenantId, name, phone, hash])).rows[0].id;
      }
      for (const w of wanted) {
        await c.query('INSERT INTO user_role (tenant_id, user_id, role_id, location_id) VALUES ($1, $2, $3, $4)',
          [s.tenantId, id, w.roleId, w.locationId]);
      }
      await c.query(
        `INSERT INTO audit_log (tenant_id, user_id, action, entity, entity_id, detail)
         VALUES ($1, $2, $3, 'app_user', $4, $5)`,
        [s.tenantId, s.userId, b.id ? 'user.edit' : 'user.add', id,
          JSON.stringify({ name, phone, isActive: active, roles: b.roles, pinChanged: !!pin })]);
      forgetActive(id!);
      return { id };
    });
  }

  @Post('devices')
  @Needs('users.manage')
  addDevice(@Req() req: any, @Body() b: DeviceBody) {
    const s: Session = req.session;
    const code = (b?.code ?? '').trim().toUpperCase();
    if (!/^[A-Z0-9]{1,8}$/.test(code)) throw new BadRequestException('Tablet code: letters and digits, e.g. T2');
    return this.db.tx(s.tenantId, async (c) => {
      const l = (await c.query('SELECT id, code FROM location WHERE upper(code) = upper($1) AND deleted_at IS NULL',
        [b.location ?? ''])).rows[0];
      if (!l) throw new BadRequestException('Choose the outlet');
      const d = (await c.query(
        `INSERT INTO device (tenant_id, location_id, code, name) VALUES ($1, $2, $3, $4)
         ON CONFLICT (location_id, code) DO UPDATE SET is_active = true, deleted_at = NULL,
                name = coalesce(EXCLUDED.name, device.name)
         RETURNING id`,
        [s.tenantId, l.id, code, b.name?.trim() || `${l.code} tablet ${code}`])).rows[0];
      await c.query(
        `INSERT INTO audit_log (tenant_id, user_id, action, entity, entity_id, detail)
         VALUES ($1, $2, 'device.add', 'device', $3, $4)`, [s.tenantId, s.userId, d.id, JSON.stringify(b)]);
      return { id: d.id, setupCode: `${l.code}-${code}` };
    });
  }

  /** Switch a tablet off (lost or replaced) or back on. */
  @Post('devices/:id')
  @Needs('users.manage')
  setDevice(@Req() req: any, @Param('id') id: string, @Body() b: { isActive: boolean }) {
    const s: Session = req.session;
    return this.db.tx(s.tenantId, async (c) => {
      const r = await c.query('UPDATE device SET is_active = $2 WHERE id = $1 AND deleted_at IS NULL', [id, !!b?.isActive]);
      if (!r.rowCount) throw new NotFoundException('Tablet not found');
      await c.query(
        `INSERT INTO audit_log (tenant_id, user_id, action, entity, entity_id, detail)
         VALUES ($1, $2, 'device.active', 'device', $3, $4)`, [s.tenantId, s.userId, id, JSON.stringify(b)]);
      forgetActive(id);
      return { id, isActive: !!b?.isActive };
    });
  }
}
