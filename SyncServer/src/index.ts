#!/usr/bin/env node
import { loadConfig } from "./config.js";
import { startServer } from "./server.js";

async function main(): Promise<void> {
  const config = loadConfig();
  const running = await startServer(config);
  const address = running.address();
  // Machine-readable line for test runners that start the server on port 0.
  process.stdout.write(`OPEN_SYNC_LISTENING ${JSON.stringify({ host: address.host, port: address.port })}\n`);
  process.stderr.write(`[open-sync] listening on http://${address.host}:${address.port} (data: ${config.dataDir})\n`);

  let shuttingDown = false;
  const shutdown = (signal: string): void => {
    if (shuttingDown) return;
    shuttingDown = true;
    process.stderr.write(`[open-sync] ${signal} received, shutting down\n`);
    const force = setTimeout(() => process.exit(1), 10_000);
    force.unref();
    running.stop().then(
      () => process.exit(0),
      (error: unknown) => {
        process.stderr.write(`[open-sync] shutdown error: ${String(error)}\n`);
        process.exit(1);
      },
    );
  };
  process.on("SIGINT", () => shutdown("SIGINT"));
  process.on("SIGTERM", () => shutdown("SIGTERM"));
}

main().catch((error: unknown) => {
  process.stderr.write(`[open-sync] fatal: ${error instanceof Error ? error.message : String(error)}\n`);
  process.exit(1);
});
