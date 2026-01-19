// Web Worker for sending session heartbeats
// Runs on background thread - NOT throttled by browser when tab is unfocused

let sessionIds = [];
let intervalId = null;
const HEARTBEAT_INTERVAL = 15000; // 15 seconds

// Send heartbeat to server
async function sendHeartbeat() {
  if (sessionIds.length === 0) {
    return;
  }

  try {
    const response = await fetch('/api/sessions/heartbeat', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ sessionIds }),
    });

    if (!response.ok) {
      console.error('[Heartbeat Worker] Failed to send heartbeat:', response.status);
    }
  } catch (error) {
    console.error('[Heartbeat Worker] Error sending heartbeat:', error);
  }
}

// Start heartbeat interval
function startHeartbeat() {
  if (intervalId) {
    return;
  }

  intervalId = setInterval(sendHeartbeat, HEARTBEAT_INTERVAL);
  // Send initial heartbeat immediately
  sendHeartbeat();
}

// Stop heartbeat interval
function stopHeartbeat() {
  if (intervalId) {
    clearInterval(intervalId);
    intervalId = null;
  }
}

// Handle messages from main thread
self.addEventListener('message', (event) => {
  const { type, sessionId } = event.data;

  switch (type) {
    case 'add':
      if (sessionId && !sessionIds.includes(sessionId)) {
        sessionIds.push(sessionId);
        startHeartbeat();
      }
      break;

    case 'remove':
      if (sessionId) {
        sessionIds = sessionIds.filter(id => id !== sessionId);
        if (sessionIds.length === 0) {
          stopHeartbeat();
        }
      }
      break;

    case 'stop':
      stopHeartbeat();
      sessionIds = [];
      break;

    default:
      console.warn('[Heartbeat Worker] Unknown message type:', type);
  }
});
