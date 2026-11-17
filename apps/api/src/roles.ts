import { BadRequestException, Body, Controller, Get, NotFoundException, Post, Req, UseGuards } from '@nestjs/common';
import { AuthGuard, Needs, Session } from './auth';
import { Db } from './db';

/**
 * Everything a user type can be allowed to do, grouped as on the head-office
 * page. The page builds its tick boxes from this list.
 */
export const PERMISSION_GROUPS: { name: string; perms: { code: string; label: string }[] }[] = [
  { name: 'Billing', perms: [
    { code: 'bill.create', label: 'Make bills (needed to use a tablet)' },
    { code: 'bill.cancel', label: 'Cancel bills' },
    { code: 'price.override', label: 'Change the rate on a bill' },
    { code: 'discount.small', label: 'Small discounts' },
    { code: 'discount.any', label: 'Any discount' },
    { code: 'customer.create', label: 'Add customers' },
    { code: 'customer.edit', label: 'Edit customers' },
    { code: 'shift.close.any', label: "Close another person's shift" },
  ] },
  { name: 'Stock', perms: [
    { code: 'stock.dispatch', label: 'Send goods to counters' },
    { code: 'stock.return.confirm', label: 'Confirm returns from counters' },
    { code: 'stock.receive', label: 'Receive goods at counter, send returns' },
    { code: 'stock.count', label: 'Count stock' },
    { code: 'stock.adjust.request', label: 'Request stock adjustment' },
    { code: 'stock.adjust', label: 'Approve stock adjustment (up to the limit)' },
    { code: 'stock.adjust.any', label: 'Approve stock adjustment above the limit' },
    { code: 'stock.view.all', label: 'See stock of all locations' },
  ] },
  { name: 'Credit', perms: [
    { code: 'credit.approve', label: 'Approve over-limit bills' },
    { code: 'credit.limit.set', label: 'Set credit limits' },
  ] },
  { name: 'Reports & audit', perms: [
    { code: 'report.own_shift', label: 'Own shift report' },
    { code: 'report.outlet', label: 'Own outlet reports' },
    { code: 'report.all', label: 'All outlets reports' },
    { code: 'audit.verify', label: 'Audit: check and mark verified' },
    { code: 'audit.view', label: 'See audit reports' },
  ] },
  { name: 'Rates & items', perms: [
    { code: 'rates.manage', label: 'Rates, customer types and item photos' },
  ] },
  { name: 'Admin', perms: [
    { code: 'users.manage', label: 'Users, user types and tablets' },
    { code: 'settings.manage', label: 'Company, locations, receipt and limits' },
    { code: 'accounts.export', label: 'Tally export' },
  ] },
];
const KNOWN = new Set(PERMISSION_GROUPS.flatMap((g) => g.perms.map((p) => p.code)));

interface RoleBody {
  code?: string;          // missing = new user type
  name: string;
  description?: string;
  allLocations: boolean;  // false: each login is tied to one location
  permissions: string[];
  isActive?: boolean;
}

/** User types (roles), for the head-office page. The Owner type is locked. */
@Controller('admin/roles')
@UseGuards(AuthGuard)
export class RolesController {
  constructor(private readonly db: Db) {}

  @Get()
  @Needs('users.manage')
  list(@Req() req: any) {
    const s: Session = req.session;
    return this.db.tx(s.tenantId, async (c) => ({
      groups: PERMISSION_GROUPS,
      roles: (await c.query(
        `SELECT r.code, r.name, r.description, r.permissions, r.all_locations, r.is_active,
                r.code = 'OWNER' AS locked,
                (SELECT count(DISTINCT ur.user_id) FROM user_role ur JOIN app_user u ON u.id = ur.user_id
                  WHERE ur.role_id = r.id AND ur.deleted_at IS NULL AND u.deleted_at IS NULL)::int AS users
           FROM role r WHERE r.deleted_at IS NULL
          ORDER BY r.code = 'OWNER' DESC, r.is_active DESC, r.created_at, r.name`)).rows,
    }));
  }

  @Post()
  @Needs('users.manage')
  save(@Req() req: any, @Body() b: RoleBody) {
    const s: Session = req.session;
    const name = (b?.name ?? '').trim();
    if (!name || name.length > 40) throw new BadRequestException('Give the user type a name (up to 40 letters)');
    const perms = [...new Set((b?.permissions ?? []).map(String))];
    const bad = perms.filter((p) => !KNOWN.has(p));
    if (bad.length) throw new BadRequestException(`Unknown permission ${bad.join(', ')}`);
    const active = b?.isActive ?? true;
    return this.db.tx(s.tenantId, async (c) => {
      let code = (b?.code ?? '').trim().toUpperCase();
      if (code) {
        const r = (await c.query('SELECT id FROM role WHERE code = $1 AND deleted_at IS NULL', [code])).rows[0];
        if (!r) throw new NotFoundException('User type not found');
        if (code === 'OWNER') throw new BadRequestException('The Owner type is locked');
        await c.query(
          `UPDATE role SET name = $2, description = $3, permissions = $4, all_locations = $5, is_active = $6
            WHERE id = $1`, [r.id, name, b.description?.trim() || null, perms, !!b.allLocations, active]);
      } else {
        code = name.toUpperCase().replace(/[^A-Z0-9]+/g, '_').replace(/^_|_$/g, '').slice(0, 20) || 'TYPE';
        let n = 1;
        const baseCode = code;
        while ((await c.query('SELECT 1 FROM role WHERE code = $1', [code])).rowCount) code = `${baseCode}_${++n}`;
        await c.query(
          `INSERT INTO role (tenant_id, code, name, description, permissions, all_locations, is_active)
           VALUES ($1, $2, $3, $4, $5, $6, $7)`,
          [s.tenantId, code, name, b.description?.trim() || null, perms, !!b.allLocations, active]);
      }
      await c.query(
        `INSERT INTO audit_log (tenant_id, user_id, action, entity, detail) VALUES ($1, $2, $3, 'role', $4)`,
        [s.tenantId, s.userId, b?.code ? 'role.edit' : 'role.add',
          JSON.stringify({ code, name, permissions: perms, allLocations: !!b.allLocations, isActive: active })]);
      return { code };
    });
  }
}
