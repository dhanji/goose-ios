#!/usr/bin/env node

/**
 * Cloudflare Tunnel Client
 * Super simple localhost proxy that connects to Cloudflare Worker via WebSocket
 */

const WebSocket = require('ws');
const http = require('http');

// Configuration from command line or environment
const config = {
  workerUrl: process.env.WORKER_URL || process.argv[2],
  agentId: process.env.AGENT_ID || process.argv[3],
  target: process.env.TARGET || process.argv[4] || 'http://127.0.0.1:8000'
};

if (!config.workerUrl || !config.agentId) {
  console.log('Usage: node client.js <worker-url> <agent-id> [target]');
  console.log('   OR: WORKER_URL=... AGENT_ID=... node client.js');
  console.log('\nExample:');
  console.log('  node client.js https://my-worker.workers.dev my-laptop-a1b2c3d4 http://127.0.0.1:8000');
  console.log('\nSecurity: Use a long random agent-id. Anyone who knows it can access your tunnel!');
  process.exit(1);
}

let ws;
let reconnectTimeout;
let pingInterval;

function connect() {
  const wsUrl = config.workerUrl
    .replace('https://', 'wss://')
    .replace('http://', 'ws://');
  
  const url = `${wsUrl}/connect?agent_id=${encodeURIComponent(config.agentId)}`;
  
  console.log(`Connecting to ${url}...`);
  
  ws = new WebSocket(url);

  ws.on('open', () => {
    console.log(`✓ Connected as agent: ${config.agentId}`);
    console.log(`✓ Proxying to: ${config.target}`);
    
    // Build and display the public URL (without trailing slash)
    const publicUrl = config.workerUrl.replace(/\/$/, '') + `/tunnel/${config.agentId}`;
    console.log(`✓ Public URL: ${publicUrl}`);
    
    // Send keepalive ping every 20 seconds to prevent DO hibernation
    clearInterval(pingInterval);
    pingInterval = setInterval(() => {
      if (ws && ws.readyState === WebSocket.OPEN) {
        ws.ping();
      }
    }, 20000);
  });

  ws.on('message', async (data) => {
    const message = JSON.parse(data.toString());
    await handleRequest(message);
  });

  ws.on('close', () => {
    console.log('✗ Connection closed, reconnecting immediately...');
    clearInterval(pingInterval);
    // Reconnect immediately, not after 5 seconds
    reconnectTimeout = setTimeout(connect, 100);
  });

  ws.on('error', (err) => {
    console.error('✗ WebSocket error:', err.message);
  });
}

async function handleRequest(message) {
  const { requestId, method, path, headers, body } = message;
  
  console.log(`→ ${method} ${path} [${requestId}]`);

  const targetUrl = new URL(path, config.target);
  
  const options = {
    method,
    headers: headers || {},
    hostname: targetUrl.hostname,
    port: targetUrl.port,
    path: targetUrl.pathname + targetUrl.search
  };

  const req = http.request(options, (res) => {
    const responseHeaders = res.headers;
    
    // Check if this is a streaming response (SSE, etc.)
    const isStreamingResponse = responseHeaders['content-type']?.includes('text/event-stream');
    
    if (isStreamingResponse) {
      // Real-time streaming: send each chunk as it arrives
      console.log(`← ${res.statusCode} ${path} [${requestId}] (streaming)`);
      let isFirstChunk = true;
      let chunkIndex = 0;
      
      res.on('data', chunk => {
        const chunkStr = chunk.toString();
        
        const response = {
          requestId,
          status: res.statusCode,
          headers: isFirstChunk ? responseHeaders : undefined,
          body: chunkStr,
          chunkIndex: chunkIndex++,
          isStreaming: true,
          isFirstChunk: isFirstChunk,
          isLastChunk: false
        };
        
        isFirstChunk = false;
        ws.send(JSON.stringify(response));
      });
      
      res.on('end', () => {
        // Send final chunk marker
        const response = {
          requestId,
          status: res.statusCode,
          body: '',
          chunkIndex: chunkIndex,
          isStreaming: true,
          isFirstChunk: false,
          isLastChunk: true
        };
        
        ws.send(JSON.stringify(response));
        console.log(`← ${res.statusCode} ${path} [${requestId}] (complete, ${chunkIndex} chunks)`);
      });
    } else {
      // Regular response: buffer and potentially split if too large
      const chunks = [];
      
      res.on('data', chunk => chunks.push(chunk));
      
      res.on('end', () => {
        const responseBody = Buffer.concat(chunks).toString();
        
        // Check if response is too large for single WebSocket message (1MB limit)
        const MAX_WS_SIZE = 900000; // 900KB to be safe
        
        if (responseBody.length > MAX_WS_SIZE) {
          // Send in chunks
          const totalChunks = Math.ceil(responseBody.length / MAX_WS_SIZE);
          console.log(`← ${res.statusCode} ${path} [${requestId}] (${responseBody.length} bytes, ${totalChunks} chunks)`);
          
          for (let i = 0; i < totalChunks; i++) {
            const start = i * MAX_WS_SIZE;
            const end = Math.min(start + MAX_WS_SIZE, responseBody.length);
            const chunk = responseBody.substring(start, end);
            
            const response = {
              requestId,
              status: res.statusCode,
              headers: i === 0 ? responseHeaders : undefined, // Only send headers in first chunk
              body: chunk,
              chunkIndex: i,
              totalChunks: totalChunks,
              isChunked: true
            };
            
            ws.send(JSON.stringify(response));
          }
        } else {
          // Send as single message
          const response = {
            requestId,
            status: res.statusCode,
            headers: responseHeaders,
            body: responseBody
          };
          
          ws.send(JSON.stringify(response));
          console.log(`← ${res.statusCode} ${path} [${requestId}]`);
        }
      });
    }
  });

  req.on('error', (err) => {
    console.error(`✗ Request error [${requestId}]:`, err.message);
    const errorResponse = {
      requestId,
      status: 500,
      error: err.message
    };
    ws.send(JSON.stringify(errorResponse));
  });

  if (body && method !== 'GET' && method !== 'HEAD') {
    req.write(body);
  }
  
  req.end();
}

// Handle graceful shutdown
process.on('SIGINT', () => {
  console.log('\nShutting down...');
  clearTimeout(reconnectTimeout);
  if (ws) ws.close();
  process.exit(0);
});

// Start
connect();
