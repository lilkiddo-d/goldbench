/**
 * Daily price recorder. Safe to run from cron every few minutes after 16:00 New York:
 * it only broadcasts when a completed session has not been recorded yet and we are inside the record window.
 *   pnpm --filter scripts record
 */
import { recordIfDue } from "./record.js";

recordIfDue().catch((e) => {
  console.error(e);
  process.exit(1);
});
