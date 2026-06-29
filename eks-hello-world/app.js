const express = require('express');
const app = express();
const PORT = 3000;

const podName = process.env.POD_NAME || 'unknown-pod';

const themes = {
  'phoenix':  { emoji: '🔥', color: '#FF6B35', bg: '#1a0a00' },
  'nebula':   { emoji: '🌌', color: '#A855F7', bg: '#0a0014' },
  'falcon':   { emoji: '🦅', color: '#3B82F6', bg: '#00071a' },
  'titan':    { emoji: '⚡', color: '#EAB308', bg: '#1a1400' },
  'aurora':   { emoji: '🌠', color: '#10B981', bg: '#001a0e' },
  'vortex':   { emoji: '🌀', color: '#06B6D4', bg: '#001a1f' },
  'cosmos':   { emoji: '🪐', color: '#F472B6', bg: '#1a0010' },
  'shadow':   { emoji: '🐺', color: '#94A3B8', bg: '#0a0a0a' },
  'inferno':  { emoji: '🌋', color: '#EF4444', bg: '#1a0000' },
  'glacier':  { emoji: '🧊', color: '#67E8F9', bg: '#001a1a' },
};

function getTheme(name) {
  for (const key of Object.keys(themes)) {
    if (name.toLowerCase().includes(key)) return { ...themes[key], name: key };
  }
  return { emoji: '🚀', color: '#ffffff', bg: '#111111', name: name };
}

app.get('/', (req, res) => {
  const theme = getTheme(podName);
  res.send(`<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8"/>
  <meta name="viewport" content="width=device-width, initial-scale=1.0"/>
  <title>Hello from ${podName}</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
      background: ${theme.bg};
      display: flex; align-items: center; justify-content: center;
      min-height: 100vh;
      font-family: 'Segoe UI', sans-serif;
    }
    .card {
      text-align: center;
      padding: 60px 80px;
      border: 2px solid ${theme.color};
      border-radius: 20px;
      box-shadow: 0 0 60px ${theme.color}44;
      max-width: 600px;
    }
    .emoji { font-size: 80px; margin-bottom: 20px; }
    h1 { color: ${theme.color}; font-size: 2.8rem; margin-bottom: 12px; }
    .pod { color: #ffffff99; font-size: 1rem; margin-top: 20px; }
    .dot { display: inline-block; width: 10px; height: 10px;
           background: ${theme.color}; border-radius: 50%; margin-right: 8px;
           animation: pulse 1.5s infinite; }
    @keyframes pulse {
      0%, 100% { opacity: 1; } 50% { opacity: 0.3; }
    }
  </style>
</head>
<body>
  <div class="card">
    <div class="emoji">${theme.emoji}</div>
    <h1>Hello from ${theme.name.charAt(0).toUpperCase() + theme.name.slice(1)}!</h1>
    <p style="color:${theme.color}99; font-size:1.1rem; margin-top:10px;">
      You've been routed to this pod by the load balancer.
    </p>
    <p class="pod"><span class="dot"></span>Pod: <strong style="color:${theme.color}">${podName}</strong></p>
  </div>
</body>
</html>`);
});

app.get('/health', (req, res) => res.json({ status: 'ok', pod: podName }));

app.listen(PORT, () => console.log(`Running on port ${PORT} — Pod: ${podName}`));
