const { test, after } = require('node:test');
const assert = require('node:assert');
const app = require('../server');

const server = app.listen(0);
const base = () => `http://127.0.0.1:${server.address().port}`;
after(() => server.close());

test('health endpoint returns ok', async () => {
  const res = await fetch(`${base()}/health`);
  assert.strictEqual(res.status, 200);
  assert.deepStrictEqual(await res.json(), { status: 'ok' });
});

test('can create and list tasks', async () => {
  const create = await fetch(`${base()}/api/tasks`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ title: 'write docs' }),
  });
  assert.strictEqual(create.status, 201);
  const list = await (await fetch(`${base()}/api/tasks`)).json();
  assert.strictEqual(list.length, 1);
});

test('rejects empty title', async () => {
  const res = await fetch(`${base()}/api/tasks`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({}),
  });
  assert.strictEqual(res.status, 400);
});

test('metrics endpoint exposes prometheus data', async () => {
  const text = await (await fetch(`${base()}/metrics`)).text();
  assert.ok(text.includes('http_requests_total'));
});
