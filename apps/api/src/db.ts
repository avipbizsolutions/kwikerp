import { Injectable, OnModuleDestroy } from '@nestjs/common';
import { Pool, PoolClient, types } from 'pg';
import { config } from './config';

// Keep DATE columns as 'YYYY-MM-DD' text. Converting them to JavaScript Date
// objects would shift them by the server's time zone (a bill dated 15 Nov
// could arrive at the tablet as 14 Nov).
types.setTypeParser(1082, (v: string) => v);

@Injectable()
export class Db implements OnModuleDestroy {
  readonly pool = new Pool({ connectionString: config.databaseUrl, max: 10 });

  /**
   * Run work inside one transaction with the tenant set for row-level
   * security. Everything a request does goes through here.
   */
  async tx<T>(tenantId: string | null, work: (c: PoolClient) => Promise<T>): Promise<T> {
    const client = await this.pool.connect();
    try {
      await client.query('BEGIN');
      await client.query("SELECT set_config('search_path', 'kwik, public', true)");
      if (tenantId) await client.query("SELECT set_config('app.tenant_id', $1, true)", [tenantId]);
      const result = await work(client);
      await client.query('COMMIT');
      return result;
    } catch (e) {
      await client.query('ROLLBACK').catch(() => undefined);
      throw e;
    } finally {
      client.release();
    }
  }

  async onModuleDestroy() {
    await this.pool.end();
  }
}
