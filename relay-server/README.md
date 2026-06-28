# Acquire relay server

Game-agnostic WebSocket relay that lets two `bcquire` (Acquire clone) players
on different networks find each other via a short join code, without either
side port-forwarding. It never inspects the Action/Event payloads the game
sends — it only tracks rooms/peer ids and forwards opaque blobs. See
`net/relay_transport.gd` for the Godot-side client and `server.js` for the
wire protocol.

## Run locally

```
npm install
npm start          # listens on PORT env var, default 8080
```

Point the game at it with `ws://127.0.0.1:8080` (the default in
`net/net_config.gd`'s `DEFAULT_RELAY_URL`).

## Deploy

Any Node.js PaaS works — the server only needs outbound-reachable WebSocket
support and reads `PORT` from the environment. For example, on Render:

1. New "Web Service" → point at this repo, root directory `relay-server/`.
2. Build command: `npm install`. Start command: `npm start`.
3. Once deployed, note the `https://...onrender.com` URL and use the `wss://`
   scheme (TLS) when setting `DEFAULT_RELAY_URL` in `net/net_config.gd`.

Fly.io/Railway work the same way — Node.js buildpack/Dockerfile auto-detect,
`npm start` as the run command, `PORT` read from the platform-injected env var.

## Notes

- Rooms live in memory only; restarting the server drops all active rooms.
- No persistence, auth, or game-state awareness by design — see
  `net/session.gd` for where the actual host-authoritative game logic lives.
