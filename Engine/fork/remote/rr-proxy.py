#!/usr/bin/env python3
"""Round-robin TCP proxy for the Open remote build.

Siso opens several gRPC connections to one address. Each SSH tunnel is a single
long-haul TCP stream (about 6 MB/s at 150 ms RTT), so this proxy spreads new
connections over N tunnel ports. Usage: rr-proxy.py LISTEN_PORT UPSTREAM_PORT...
"""
import asyncio
import itertools
import sys


async def pipe(reader, writer):
    try:
        while data := await reader.read(1 << 20):
            writer.write(data)
            await writer.drain()
    except (ConnectionError, asyncio.CancelledError):
        pass
    finally:
        try:
            writer.close()
        except Exception:
            pass


async def main():
    listen = int(sys.argv[1])
    ports = itertools.cycle(int(p) for p in sys.argv[2:])

    async def handle(cr, cw):
        try:
            ur, uw = await asyncio.open_connection("127.0.0.1", next(ports))
        except OSError:
            cw.close()
            return
        await asyncio.gather(pipe(cr, uw), pipe(ur, cw))

    server = await asyncio.start_server(handle, "127.0.0.1", listen, limit=1 << 22)
    async with server:
        await server.serve_forever()


asyncio.run(main())
