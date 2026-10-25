import { Database } from "bun:sqlite";
import { mkdirSync } from "node:fs";
import { dirname } from "node:path";

/** Counts requests per person per day, so one tester can't run up the bill. */
export class Usage {
  private db: Database;

  constructor(path: string) {
    if (path !== ":memory:") mkdirSync(dirname(path), { recursive: true });
    this.db = new Database(path, { create: true });
    this.db.run("PRAGMA journal_mode = WAL");
    this.db.run(`CREATE TABLE IF NOT EXISTS usage (
      day TEXT NOT NULL, person TEXT NOT NULL, model TEXT NOT NULL, count INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (day, person, model))`);
  }

  static today(now = new Date()): string {
    return now.toISOString().slice(0, 10);
  }

  used(person: string, day = Usage.today()): number {
    const row = this.db
      .query("SELECT COALESCE(SUM(count), 0) AS n FROM usage WHERE day = ? AND person = ?")
      .get(day, person) as { n: number };
    return row.n;
  }

  /** Records one request if the person is under their limit. Returns false when they're over. */
  take(person: string, model: string, limit: number, day = Usage.today()): boolean {
    const tx = this.db.transaction(() => {
      if (this.used(person, day) >= limit) return false;
      this.db
        .query(`INSERT INTO usage (day, person, model, count) VALUES (?, ?, ?, 1)
                ON CONFLICT(day, person, model) DO UPDATE SET count = count + 1`)
        .run(day, person, model);
      return true;
    });
    return tx();
  }

  /** Requests per person and model over the last few days, for a quick look at who uses what. */
  report(days = 7): { day: string; person: string; model: string; count: number }[] {
    return this.db
      .query("SELECT day, person, model, count FROM usage WHERE day >= ? ORDER BY day DESC, person, model")
      .all(Usage.today(new Date(Date.now() - (days - 1) * 86_400_000))) as any;
  }
}
