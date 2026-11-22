const express = require('express');
const client = require('prom-client');

const app = express();
app.use(express.json());

// ---- Prometheus metrics ----
client.collectDefaultMetrics();
const httpRequests = new client.Counter({
  name: 'http_requests_total',
  help: 'Total HTTP requests',
  labelNames: ['method', 'route', 'status'],
});
const httpDuration = new client.Histogram({
  name: 'http_request_duration_seconds',
  help: 'HTTP request duration in seconds',
  labelNames: ['method', 'route', 'status'],
  buckets: [0.005, 0.01, 0.05, 0.1, 0.5, 1, 2],
});

app.use((req, res, next) => {
  const end = httpDuration.startTimer();
  res.on('finish', () => {
    const route = req.route ? req.route.path : req.path;
    const labels = { method: req.method, route, status: res.statusCode };
    httpRequests.inc(labels);
    end(labels);
  });
  next();
});

// ---- In-memory task store (swap for RDS/DynamoDB later) ----
let tasks = [];
let nextId = 1;

app.get('/', (_req, res) =>
  res.json({ service: 'sample-app', version: process.env.APP_VERSION || 'dev', status: 'running' })
);

app.get('/health', (_req, res) => res.json({ status: 'ok' }));

app.get('/api/tasks', (_req, res) => res.json(tasks));

app.post('/api/tasks', (req, res) => {
  const title = (req.body && req.body.title || '').toString().trim();
  if (!title) return res.status(400).json({ error: 'title is required' });
  const task = { id: nextId++, title, done: false };
  tasks.push(task);
  res.status(201).json(task);
});

app.put('/api/tasks/:id', (req, res) => {
  const task = tasks.find((t) => t.id === Number(req.params.id));
  if (!task) return res.status(404).json({ error: 'not found' });
  if (typeof req.body.done === 'boolean') task.done = req.body.done;
  if (req.body.title) task.title = String(req.body.title);
  res.json(task);
});

app.delete('/api/tasks/:id', (req, res) => {
  const before = tasks.length;
  tasks = tasks.filter((t) => t.id !== Number(req.params.id));
  res.status(before === tasks.length ? 404 : 204).end();
});

app.get('/metrics', async (_req, res) => {
  res.set('Content-Type', client.register.contentType);
  res.end(await client.register.metrics());
});

if (require.main === module) {
  const port = process.env.PORT || 3000;
  const server = app.listen(port, () => console.log(`Listening on ${port}`));
  process.on('SIGTERM', () => server.close(() => process.exit(0)));
}

module.exports = app;
