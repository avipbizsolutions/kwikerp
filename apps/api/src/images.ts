import {
  BadRequestException, Body, Controller, Get, NotFoundException, Param, Post, Req, Res, UseGuards,
} from '@nestjs/common';
import { createHash } from 'node:crypto';
import type { Response } from 'express';
import { AuthGuard, Needs, Session } from './auth';
import { Db } from './db';

const MAX_BYTES = 300 * 1024; // the page shrinks photos to ~20 KB; this is a safety cap

function sniff(b: Buffer): string | null {
  if (b.length > 3 && b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff) return 'image/jpeg';
  if (b.length > 8 && b.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))) return 'image/png';
  if (b.length > 12 && b.subarray(0, 4).toString() === 'RIFF' && b.subarray(8, 12).toString() === 'WEBP') return 'image/webp';
  return null;
}

/** Company product photos: set on the head-office page, downloaded by tablets. */
@Controller()
@UseGuards(AuthGuard)
export class ImagesController {
  constructor(private readonly db: Db) {}

  @Get('items/photos')
  @Needs('rates.manage')
  list(@Req() req: any) {
    const s: Session = req.session;
    return this.db.tx(s.tenantId, async (c) => (await c.query(
      `SELECT i.id, i.code, i.name, i.pack_size, i.image_version, ic.id AS category_id, ic.name AS category
         FROM item i LEFT JOIN item_category ic ON ic.id = i.category_id
        WHERE i.deleted_at IS NULL AND i.is_active
        ORDER BY ic.name NULLS LAST, i.pos_sort, i.name`)).rows);
  }

  @Post('items/:id/photo')
  @Needs('rates.manage')
  save(@Req() req: any, @Param('id') id: string, @Body() b: { data: string }) {
    const s: Session = req.session;
    let bytes: Buffer;
    try {
      bytes = Buffer.from(String(b?.data ?? ''), 'base64');
    } catch {
      throw new BadRequestException('Not a photo');
    }
    const mime = sniff(bytes);
    if (!mime) throw new BadRequestException('Use a JPEG, PNG or WebP photo');
    if (bytes.length > MAX_BYTES) throw new BadRequestException('Photo too large');
    const version = createHash('sha256').update(bytes).digest('hex').slice(0, 16);
    return this.db.tx(s.tenantId, async (c) => {
      if (!(await c.query('SELECT 1 FROM item WHERE id = $1 AND deleted_at IS NULL', [id])).rowCount) {
        throw new NotFoundException('Item not found');
      }
      await c.query(
        `INSERT INTO item_image (item_id, tenant_id, mime, data, updated_by) VALUES ($1, $2, $3, $4, $5)
         ON CONFLICT (item_id) DO UPDATE SET mime = EXCLUDED.mime, data = EXCLUDED.data,
                updated_by = EXCLUDED.updated_by, updated_at = now()`,
        [id, s.tenantId, mime, bytes, s.userId]);
      await c.query('UPDATE item SET image_version = $2 WHERE id = $1', [id, version]); // tablets see it at next sync
      return { id, version, bytes: bytes.length };
    });
  }

  @Post('items/:id/photo/remove')
  @Needs('rates.manage')
  remove(@Req() req: any, @Param('id') id: string) {
    const s: Session = req.session;
    return this.db.tx(s.tenantId, async (c) => {
      await c.query('DELETE FROM item_image WHERE item_id = $1', [id]);
      await c.query('UPDATE item SET image_version = NULL WHERE id = $1', [id]);
      return { id, removed: true };
    });
  }

  /** The photo itself, for tablets and the head-office page (any logged-in user of the company). */
  @Get('items/:id/photo')
  async get(@Req() req: any, @Res() res: Response, @Param('id') id: string) {
    const s: Session = req.session;
    const row = await this.db.tx(s.tenantId, async (c) =>
      (await c.query('SELECT mime, data FROM item_image WHERE item_id = $1', [id])).rows[0]);
    if (!row) throw new NotFoundException('No photo');
    res.setHeader('Content-Type', row.mime);
    res.setHeader('Cache-Control', 'private, max-age=86400');
    res.send(row.data);
  }
}
