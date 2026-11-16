import 'reflect-metadata';
import { Controller, Get, Module, NotFoundException, Res } from '@nestjs/common';
import { NestFactory } from '@nestjs/core';
import { NestExpressApplication } from '@nestjs/platform-express';
import type { Response } from 'express';
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { AdminController } from './admin';
import { ApprovalsController } from './approvals';
import { AuthController, AuthGuard } from './auth';
import { config } from './config';
import { Db } from './db';
import { BillsController } from './bills';
import { CustomersController } from './customers';
import { ImagesController } from './images';
import { RatesController } from './rates';
import { ReportsController } from './reports';
import { SettingsController } from './settings';
import { SyncController } from './sync';
import { TallyController } from './tally';

@Controller()
class HealthController {
  constructor(private readonly db: Db) {}

  @Get('health')
  async health() {
    await this.db.pool.query('SELECT 1');
    return { ok: true, time: new Date().toISOString() };
  }
}

// The tablet app, so outlets can install it without a GitHub login.
@Controller('download')
class DownloadController {
  @Get('pos.apk')
  apk(@Res() res: Response) {
    const file = join(config.downloadDir, 'kwikerp-pos.apk');
    if (!existsSync(file)) throw new NotFoundException('App file not uploaded yet');
    res.download(file, 'kwikerp-pos.apk', { headers: { 'Content-Type': 'application/vnd.android.package-archive' } });
  }

  /** Newest tablet app build. Tablets with a lower build number must update. */
  @Get('pos/version')
  version() {
    const file = join(config.downloadDir, 'kwikerp-pos.json');
    const apk = join(config.downloadDir, 'kwikerp-pos.apk');
    if (!existsSync(file) || !existsSync(apk)) return { versionCode: 0 };
    try {
      const v = JSON.parse(readFileSync(file, 'utf8'));
      return { versionCode: Number(v.versionCode) || 0, commit: v.commit ?? null, builtAt: v.builtAt ?? null,
        path: '/download/pos.apk' };
    } catch {
      return { versionCode: 0 };
    }
  }
}

@Module({
  controllers: [HealthController, DownloadController, ReportsController, CustomersController, BillsController, TallyController, AdminController, SettingsController, RatesController, ImagesController, AuthController, SyncController, ApprovalsController],
  providers: [Db, AuthGuard],
})
export class AppModule {}

export async function createApp() {
  const app = await NestFactory.create<NestExpressApplication>(AppModule, { logger: ['error', 'warn', 'log'] });
  app.useBodyParser('json', { limit: '20mb' }); // a day's bills from an offline tablet
  app.enableCors();
  app.setGlobalPrefix('api');
  // Head-office web page at the site root (apps/api/public).
  app.useStaticAssets(join(__dirname, '..', 'public'), { index: 'index.html', maxAge: '5m' });
  return app;
}

if (require.main === module) {
  createApp().then((app) => app.listen(config.port)).then(() => {
    console.log(`KwikERP API listening on ${config.port}`);
  });
}
