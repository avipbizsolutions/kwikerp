import 'reflect-metadata';
import { Controller, Get, Module, NotFoundException, Res } from '@nestjs/common';
import { NestFactory } from '@nestjs/core';
import { NestExpressApplication } from '@nestjs/platform-express';
import type { Response } from 'express';
import { existsSync } from 'node:fs';
import { join } from 'node:path';
import { ApprovalsController } from './approvals';
import { AuthController, AuthGuard } from './auth';
import { config } from './config';
import { Db } from './db';
import { ReportsController } from './reports';
import { SyncController } from './sync';

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
}

@Module({
  controllers: [HealthController, DownloadController, ReportsController, AuthController, SyncController, ApprovalsController],
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
