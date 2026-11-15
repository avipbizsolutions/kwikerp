import 'reflect-metadata';
import { Controller, Get, Module } from '@nestjs/common';
import { NestFactory } from '@nestjs/core';
import { NestExpressApplication } from '@nestjs/platform-express';
import { ApprovalsController } from './approvals';
import { AuthController, AuthGuard } from './auth';
import { config } from './config';
import { Db } from './db';
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

@Module({
  controllers: [HealthController, AuthController, SyncController, ApprovalsController],
  providers: [Db, AuthGuard],
})
export class AppModule {}

export async function createApp() {
  const app = await NestFactory.create<NestExpressApplication>(AppModule, { logger: ['error', 'warn', 'log'] });
  app.useBodyParser('json', { limit: '20mb' }); // a day's bills from an offline tablet
  app.enableCors();
  app.setGlobalPrefix('api');
  return app;
}

if (require.main === module) {
  createApp().then((app) => app.listen(config.port)).then(() => {
    console.log(`KwikERP API listening on ${config.port}`);
  });
}
