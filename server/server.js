const express = require('express');
const fs = require('fs');
const path = require('path');

const app = express();
const PORT = process.env.PORT || 3847;
const FEEDBACK_FILE = path.join(__dirname, 'feedback.jsonl');

app.use(express.json());

// Health check
app.get('/', (req, res) => {
  res.json({ status: 'ok', service: 'command-feedback' });
});

// Receive feedback
app.post('/api/feedback', (req, res) => {
  const { message, app: appName, version, timestamp, os_version } = req.body;

  if (!message) {
    return res.status(400).json({ error: 'message is required' });
  }

  const entry = {
    message,
    app: appName || 'Command',
    version: version || 'unknown',
    os_version: os_version || 'unknown',
    timestamp: timestamp || new Date().toISOString(),
    received_at: new Date().toISOString(),
    ip: req.ip,
  };

  // Append to JSONL file
  fs.appendFileSync(FEEDBACK_FILE, JSON.stringify(entry) + '\n');
  console.log(`[feedback] ${entry.message.substring(0, 80)}`);

  res.json({ success: true });
});

// View feedback (simple admin)
app.get('/api/feedback', (req, res) => {
  try {
    const data = fs.readFileSync(FEEDBACK_FILE, 'utf-8');
    const entries = data.trim().split('\n').filter(Boolean).map(JSON.parse);
    res.json(entries.reverse()); // newest first
  } catch {
    res.json([]);
  }
});

app.listen(PORT, () => {
  console.log(`Command feedback server running on port ${PORT}`);
  console.log(`POST /api/feedback to submit`);
  console.log(`GET /api/feedback to view`);
});
