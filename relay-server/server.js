// Game-agnostic relay for Acquire's online play. This server never looks at
// the inner Action/Event payload Godot sends — it only tracks rooms/peer ids
// and forwards opaque "payload" strings to the right socket(s). All game
// rules and validation stay host-authoritative inside the Godot client (see
// net/session.gd); this is just the pipe that lets peers on different
// networks reach each other without port-forwarding.
'use strict';

const http = require('http');
const crypto = require('crypto');
const { WebSocketServer } = require('ws');

const PORT = process.env.PORT || 8080;
const MAX_PEERS_PER_ROOM = 6; // matches ui/game/game.gd's MAX_NETWORK_PLAYERS
const CODE_LENGTH = 6;
const CODE_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; // no 0/O, 1/I/L

/** @type {Map<string, Room>} */
const rooms = new Map();

class Room {
  constructor(code, hostSocket) {
    this.code = code;
    this.peers = new Map(); // peerId -> WebSocket
    this.nextPeerId = 2; // peer id 1 is always the host
    this.peers.set(1, hostSocket);
  }
}

function generateRoomCode() {
  let code;
  do {
    code = '';
    for (let i = 0; i < CODE_LENGTH; i++) {
      code += CODE_ALPHABET[crypto.randomInt(CODE_ALPHABET.length)];
    }
  } while (rooms.has(code));
  return code;
}

function send(ws, msg) {
  if (ws.readyState === ws.OPEN) {
    ws.send(JSON.stringify(msg));
  }
}

function broadcastToRoom(room, msg, exceptPeerId = null) {
  for (const [peerId, sock] of room.peers) {
    if (peerId !== exceptPeerId) send(sock, msg);
  }
}

function handleCreateRoom(ws) {
  if (ws.roomCode) return; // already in a room
  const code = generateRoomCode();
  const room = new Room(code, ws);
  rooms.set(code, room);
  ws.roomCode = code;
  ws.peerId = 1;
  send(ws, { type: 'room_created', code, peer_id: 1 });
}

function handleJoinRoom(ws, msg) {
  if (ws.roomCode) return;
  const code = typeof msg.code === 'string' ? msg.code.toUpperCase() : '';
  const room = rooms.get(code);
  if (!room) {
    send(ws, { type: 'join_failed', reason: 'Room not found.' });
    return;
  }
  if (room.peers.size >= MAX_PEERS_PER_ROOM) {
    send(ws, { type: 'join_failed', reason: 'Room is full.' });
    return;
  }
  const peerId = room.nextPeerId++;
  room.peers.set(peerId, ws);
  ws.roomCode = code;
  ws.peerId = peerId;
  send(ws, { type: 'joined', peer_id: peerId });
  broadcastToRoom(room, { type: 'peer_joined', peer_id: peerId }, peerId);
}

function handleSend(ws, msg) {
  const room = rooms.get(ws.roomCode);
  if (!room) return;
  const envelope = { type: 'deliver', from: ws.peerId, kind: msg.kind, payload: msg.payload };
  if (msg.to === 'all') {
    broadcastToRoom(room, envelope, ws.peerId);
  } else if (msg.to === 'host') {
    const hostSock = room.peers.get(1);
    if (hostSock && hostSock !== ws) send(hostSock, envelope);
  } else {
    const targetSock = room.peers.get(msg.to);
    if (targetSock) send(targetSock, envelope);
  }
}

function handleKick(ws, msg) {
  if (ws.peerId !== 1) return; // only the host may kick
  const room = rooms.get(ws.roomCode);
  if (!room) return;
  const target = room.peers.get(msg.peer_id);
  if (target) target.close();
}

function handleClose(ws) {
  const room = rooms.get(ws.roomCode);
  if (!room) return;
  room.peers.delete(ws.peerId);
  if (ws.peerId === 1) {
    // Host left: the game is host-authoritative, so the room can't continue.
    // Tear it down and tell everyone, mirroring EnetTransport's existing
    // peer_left(1) semantics for a lost host.
    broadcastToRoom(room, { type: 'peer_left', peer_id: 1 });
    rooms.delete(ws.roomCode);
  } else {
    broadcastToRoom(room, { type: 'peer_left', peer_id: ws.peerId });
    if (room.peers.size === 0) rooms.delete(ws.roomCode);
  }
}

const httpServer = http.createServer((req, res) => {
  res.writeHead(200, { 'Content-Type': 'text/plain' });
  res.end('ok');
});

const wss = new WebSocketServer({ server: httpServer });

wss.on('connection', (ws) => {
  ws.on('message', (data) => {
    let msg;
    try {
      msg = JSON.parse(data);
    } catch {
      return;
    }
    switch (msg.type) {
      case 'create_room':
        handleCreateRoom(ws);
        break;
      case 'join_room':
        handleJoinRoom(ws, msg);
        break;
      case 'send':
        handleSend(ws, msg);
        break;
      case 'kick':
        handleKick(ws, msg);
        break;
    }
  });

  ws.on('close', () => handleClose(ws));
});

httpServer.listen(PORT, () => {
  console.log(`Relay server listening on port ${PORT}`);
});
