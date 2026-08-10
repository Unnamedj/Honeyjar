import "dotenv/config";
import { migrate, pool } from "./db.js";

await migrate();
await pool.end();
