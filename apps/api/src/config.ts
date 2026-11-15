// All settings come from environment variables. Never commit real values.
function required(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`Missing environment variable ${name}`);
  return v;
}

export const config = {
  port: Number(process.env.PORT ?? 3000),
  // Connect as a role that does NOT own the tables, so row-level security applies.
  databaseUrl: required('DATABASE_URL'),
  jwtSecret: required('JWT_SECRET'),
  // Secret behind offline approval codes. Each device gets a key derived from it.
  approvalSecret: required('APPROVAL_SECRET'),
  tokenHours: Number(process.env.TOKEN_HOURS ?? 24 * 30),
};
