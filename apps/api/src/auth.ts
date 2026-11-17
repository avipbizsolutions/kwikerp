import {
  Body, CanActivate, Controller, ExecutionContext, ForbiddenException, Get, Injectable,
  Post, Req, SetMetadata, UnauthorizedException, UseGuards, BadRequestException, HttpException, HttpStatus,
} from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import * as bcrypt from 'bcryptjs';
import * as jwt from 'jsonwebtoken';
import { config } from './config';
import { Db } from './db';
import { deviceKey } from './offline-code';

export interface Session {
  tenantId: string;
  userId: string;
  userName: string;
  deviceId: string | null;
  locationId: string | null;
  permissions: string[];
  /** Locations this login may act for: null = all of them. A tablet is its own outlet. */
  locations?: string[] | null;
}

/** Locations a session may act for (null = all). Older tokens carry no list. */
export function scopeOf(s: Session): string[] | null {
  if (s.locations !== undefined) return s.locations;
  return s.locationId ? [s.locationId] : null;
}

export function inScope(s: Session, locationId: string): boolean {
  const sc = scopeOf(s);
  return sc === null || sc.includes(locationId);
}

export function can(s: Session, perm: string): boolean {
  return s.permissions.includes('*') || s.permissions.includes(perm);
}

export const NEEDS = 'needs-permission';
/** Mark a route as needing one permission (OWNER's '*' passes everything). */
export const Needs = (perm: string) => SetMetadata(NEEDS, perm);

// Recently checked users/tablets, so a deactivated one is locked out within a minute.
const activeCache = new Map<string, { ok: boolean; at: number }>();
export function forgetActive(id: string) {
  for (const k of activeCache.keys()) if (k.includes(id)) activeCache.delete(k);
}

@Injectable()
export class AuthGuard implements CanActivate {
  constructor(private readonly reflector: Reflector, private readonly db: Db) {}

  private async stillActive(s: Session): Promise<boolean> {
    const key = `${s.userId}|${s.deviceId ?? ''}`;
    const hit = activeCache.get(key);
    if (hit && Date.now() - hit.at < 60_000) return hit.ok;
    const ok = await this.db.tx(s.tenantId, async (c) => {
      const u = (await c.query('SELECT 1 FROM app_user WHERE id = $1 AND is_active AND deleted_at IS NULL', [s.userId])).rowCount;
      if (!u) return false;
      if (!s.deviceId) return true;
      return !!(await c.query('SELECT 1 FROM device WHERE id = $1 AND is_active AND deleted_at IS NULL', [s.deviceId])).rowCount;
    });
    activeCache.set(key, { ok, at: Date.now() });
    return ok;
  }

  async canActivate(ctx: ExecutionContext): Promise<boolean> {
    const req = ctx.switchToHttp().getRequest();
    const header: string = req.headers['authorization'] ?? '';
    const token = header.startsWith('Bearer ') ? header.slice(7) : '';
    if (!token) throw new UnauthorizedException('Login required');
    let session: Session;
    try {
      session = jwt.verify(token, config.jwtSecret) as Session;
    } catch {
      throw new UnauthorizedException('Session expired, log in again');
    }
    const perm = this.reflector.get<string>(NEEDS, ctx.getHandler());
    if (perm && !session.permissions.includes('*') && !session.permissions.includes(perm)) {
      throw new ForbiddenException(`Needs permission ${perm}`);
    }
    if (!(await this.stillActive(session))) throw new UnauthorizedException('This login or tablet has been switched off');
    req.session = session;
    return true;
  }
}

/**
 * Wrong-PIN lock-out. A 4-digit PIN is guessable, and the login is reachable
 * from the internet, so 5 wrong tries lock that phone (and 20 lock that
 * network address) for 15 minutes. Kept in memory: a restart clears it.
 */
const LOCK_MS = 15 * 60 * 1000;
const failures = new Map<string, { n: number; first: number }>();

function lockedFor(key: string, limit: number): number {
  const f = failures.get(key);
  if (!f) return 0;
  if (Date.now() - f.first > LOCK_MS) {
    failures.delete(key);
    return 0;
  }
  return f.n >= limit ? Math.ceil((f.first + LOCK_MS - Date.now()) / 60000) : 0;
}

function recordFailure(key: string) {
  const f = failures.get(key);
  if (!f || Date.now() - f.first > LOCK_MS) failures.set(key, { n: 1, first: Date.now() });
  else f.n += 1;
}

/**
 * A manager approving something on a cashier's tablet (for example a bill
 * cancellation): checks their mobile + PIN and that they hold `perm` at that
 * outlet. Same lock-out as login. Returns the approver's id and name.
 */
export async function verifyApprover(c: any, tenantId: string, phone: string, pin: string,
                                     locationId: string | null, perm: string) {
  const key = `p:${tenantId}:${(phone ?? '').trim()}`;
  const wait = lockedFor(key, 5);
  if (wait > 0) throw new HttpException(`Too many wrong PINs. Try again in ${wait} min.`, HttpStatus.TOO_MANY_REQUESTS);
  const u = (await c.query(
    `SELECT id, name, pin_hash FROM app_user WHERE phone = $1 AND is_active AND deleted_at IS NULL`,
    [(phone ?? '').trim()])).rows[0];
  if (!u?.pin_hash || !(await bcrypt.compare(String(pin ?? ''), u.pin_hash))) {
    recordFailure(key);
    throw new ForbiddenException("Manager's mobile or PIN is wrong");
  }
  failures.delete(key);
  const perms = (await c.query(
    `SELECT DISTINCT unnest(r.permissions) AS p FROM user_role ur JOIN role r ON r.id = ur.role_id
      WHERE ur.user_id = $1 AND ur.deleted_at IS NULL AND r.is_active AND r.deleted_at IS NULL
        AND (ur.location_id IS NULL OR r.all_locations OR ur.location_id = $2)`,
    [u.id, locationId])).rows.map((r: any) => r.p as string);
  if (!perms.includes('*') && !perms.includes(perm)) throw new ForbiddenException(`${u.name} cannot approve this`);
  return { id: u.id as string, name: u.name as string };
}

/** Test hook. */
export function clearLoginFailures() {
  failures.clear();
}

interface LoginBody {
  tenantCode: string;
  phone: string;
  pin: string;
  deviceId?: string; // tablets send their tablet code (e.g. DD3-T1) or the full device id
}

@Controller('auth')
export class AuthController {
  constructor(private readonly db: Db) {}

  /** PIN login. Tablets pass deviceId; the manager phone app does not. */
  @Post('login')
  async login(@Body() body: LoginBody, @Req() req: any) {
    if (!body?.tenantCode || !body?.phone || !body?.pin) {
      throw new BadRequestException('tenantCode, phone and pin are required');
    }
    const ip = String(req.headers?.['x-forwarded-for'] ?? req.ip ?? '').split(',')[0].trim();
    const phoneKey = `p:${body.tenantCode.trim().toUpperCase()}:${body.phone.trim()}`;
    const ipKey = `i:${ip}`;
    const wait = Math.max(lockedFor(phoneKey, 5), lockedFor(ipKey, 20));
    if (wait > 0) {
      throw new HttpException(`Too many wrong PINs. Try again in ${wait} min.`, HttpStatus.TOO_MANY_REQUESTS);
    }
    try {
      const res = await this.doLogin(body);
      failures.delete(phoneKey);
      return res;
    } catch (e) {
      if (e instanceof UnauthorizedException && String(e.message).startsWith('Wrong')) {
        recordFailure(phoneKey);
        recordFailure(ipKey);
      }
      throw e;
    }
  }

  private async doLogin(body: LoginBody) {
    const tenant = await this.db.tx(null, async (c) =>
      (await c.query('SELECT id, name FROM tenant WHERE code = $1', [body.tenantCode.trim().toUpperCase()])).rows[0]);
    if (!tenant) throw new UnauthorizedException('Wrong company code, phone or PIN');

    return this.db.tx(tenant.id, async (c) => {
      const user = (await c.query(
        `SELECT id, name, pin_hash FROM app_user
          WHERE phone = $1 AND is_active AND deleted_at IS NULL`, [body.phone.trim()])).rows[0];
      if (!user?.pin_hash || !(await bcrypt.compare(body.pin, user.pin_hash))) {
        throw new UnauthorizedException('Wrong company code, phone or PIN');
      }

      let device: any = null;
      if (body.deviceId) {
        device = (await c.query(
          `SELECT d.id, d.code, d.location_id, l.code AS location_code, l.name AS location_name,
                  l.company_id, l.default_price_level_id
             FROM device d JOIN location l ON l.id = d.location_id
            WHERE (d.id::text = lower($1) OR upper(l.code || '-' || d.code) = upper($1))
              AND d.is_active AND d.deleted_at IS NULL AND l.deleted_at IS NULL`,
          [body.deviceId.trim().replace(/\s+/g, '')])).rows[0];
        if (!device) throw new UnauthorizedException('This tablet is not registered');
      }

      // Tablet: roles valid at its outlet. Head-office page / phone: every role
      // the user holds, limited to the locations those roles are for.
      const roles = (await c.query(
        `SELECT r.permissions, r.all_locations, ur.location_id
           FROM user_role ur JOIN role r ON r.id = ur.role_id
          WHERE ur.user_id = $1 AND ur.deleted_at IS NULL AND r.is_active AND r.deleted_at IS NULL
            AND ($2::uuid IS NULL OR ur.location_id IS NULL OR r.all_locations OR ur.location_id = $2)`,
        [user.id, device?.location_id ?? null])).rows;
      const perms = [...new Set(roles.flatMap((r) => r.permissions as string[]))];
      if (device && !perms.includes('*') && !perms.includes('bill.create')) {
        throw new ForbiddenException('No billing permission at this outlet');
      }
      let locations: string[] | null;
      if (device) locations = [device.location_id];
      else if (roles.some((r) => r.all_locations || !r.location_id)) locations = null;
      else locations = [...new Set(roles.map((r) => r.location_id as string))];

      const session: Session = {
        tenantId: tenant.id, userId: user.id, userName: user.name,
        deviceId: device?.id ?? null, locationId: device?.location_id ?? null, permissions: perms, locations,
      };
      const token = jwt.sign(session, config.jwtSecret, { expiresIn: `${config.tokenHours}h` });
      if (device) await c.query('UPDATE device SET last_seen_at = now() WHERE id = $1', [device.id]);
      return {
        token,
        user: { id: user.id, name: user.name, permissions: perms, locations },
        tenant: { id: tenant.id, name: tenant.name },
        device: device && {
          id: device.id, code: device.code, locationId: device.location_id,
          locationCode: device.location_code, locationName: device.location_name,
          companyId: device.company_id, defaultPriceLevelId: device.default_price_level_id,
          // Lets the tablet check offline approval codes without internet.
          approvalKey: deviceKey(device.id),
        },
      };
    });
  }

  @Get('me')
  @UseGuards(AuthGuard)
  me(@Req() req: any) {
    return req.session;
  }
}
