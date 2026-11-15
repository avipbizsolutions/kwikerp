import {
  Body, CanActivate, Controller, ExecutionContext, ForbiddenException, Get, Injectable,
  Post, Req, SetMetadata, UnauthorizedException, UseGuards, BadRequestException,
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
}

export const NEEDS = 'needs-permission';
/** Mark a route as needing one permission (OWNER's '*' passes everything). */
export const Needs = (perm: string) => SetMetadata(NEEDS, perm);

@Injectable()
export class AuthGuard implements CanActivate {
  constructor(private readonly reflector: Reflector) {}

  canActivate(ctx: ExecutionContext): boolean {
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
    req.session = session;
    return true;
  }
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
  async login(@Body() body: LoginBody) {
    if (!body?.tenantCode || !body?.phone || !body?.pin) {
      throw new BadRequestException('tenantCode, phone and pin are required');
    }
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

      // Permissions from roles valid everywhere or at this device's location
      const perms = (await c.query(
        `SELECT DISTINCT unnest(r.permissions) AS p
           FROM user_role ur JOIN role r ON r.id = ur.role_id
          WHERE ur.user_id = $1 AND ur.deleted_at IS NULL
            AND (ur.location_id IS NULL OR ur.location_id = $2)`,
        [user.id, device?.location_id ?? null])).rows.map((r) => r.p as string);
      if (device && !perms.includes('*') && !perms.includes('bill.create')) {
        throw new ForbiddenException('No billing permission at this outlet');
      }

      const session: Session = {
        tenantId: tenant.id, userId: user.id, userName: user.name,
        deviceId: device?.id ?? null, locationId: device?.location_id ?? null, permissions: perms,
      };
      const token = jwt.sign(session, config.jwtSecret, { expiresIn: `${config.tokenHours}h` });
      if (device) await c.query('UPDATE device SET last_seen_at = now() WHERE id = $1', [device.id]);
      return {
        token,
        user: { id: user.id, name: user.name, permissions: perms },
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
