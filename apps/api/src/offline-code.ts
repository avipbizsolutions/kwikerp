import { createHmac } from 'crypto';
import { config } from './config';

/**
 * Offline credit approval.
 *
 * Each device receives its own key at login (derived from APPROVAL_SECRET and
 * the device id). When a tablet without internet needs approval it shows a
 * request code; the manager's app (online) turns request code + amount into a
 * 6-digit approval code with the same key. The tablet checks it locally.
 * The code is bound to the device, the request and the amount, so it cannot be
 * reused for another bill.
 */
export function deviceKey(deviceId: string): string {
  return createHmac('sha256', config.approvalSecret).update(`device:${deviceId}`).digest('hex');
}

export function approvalCode(deviceKeyHex: string, requestCode: string, amountRupees: number): string {
  const msg = `${requestCode.trim().toUpperCase()}|${Math.round(amountRupees)}`;
  const digest = createHmac('sha256', Buffer.from(deviceKeyHex, 'hex')).update(msg).digest();
  const n = digest.readUInt32BE(0) % 1_000_000;
  return n.toString().padStart(6, '0');
}
