const express = require('express');
const promClient = require('prom-client');

const app = express();
// Don't advertise the framework (X-Powered-By: Express) – found by SonarQube (javascript:S5689)
app.disable('x-powered-by');
const port = process.env.PORT || 8080;

// Create a Registry to register the metrics
const register = new promClient.Registry();

// Enable the collection of default metrics
promClient.collectDefaultMetrics({ register });

const helloWorldCounter = new promClient.Counter({
    name: 'root_access_total',
    help: 'Total number of accesses to the root path',
});
register.registerMetric(helloWorldCounter);



// Define routes
app.get('/my-app', (req, res) => {
    helloWorldCounter.inc();
    res.send('Hello, World!');
});

app.get('/about', (req, res) => {
    res.send('This is a sample Node.js application for Kubernetes deployment testing.');
});

app.get('/ready', (req, res) => {
    res.status(200).send('Ready');
});

app.get('/live', (req, res) => {
    res.status(200).send('Alive');
});

app.get('/classified', (req, res) => {
    res.status(200).send('You should not be here!!!');
});

app.get('/metrics', async (req, res) => {
    res.set('Content-Type', register.contentType);
    res.end(await register.metrics());
});

const server = app.listen(port, () => {
    console.log(`Server running on port ${port}`);
});

// Graceful shutdown: Kubernetes sends SIGTERM before stopping a pod. Node has no default
// handler, and as PID 1 in a container the signal would be ignored until SIGKILL.
// Stop accepting new connections, let in-flight requests finish, then exit.
function shutdown(signal) {
    console.log(`${signal} received, shutting down`);
    server.close(() => process.exit(0));
    // Close idle keep-alive connections so close() doesn't wait for them
    server.closeIdleConnections();
    // Safety net if connections don't drain in time
    setTimeout(() => process.exit(1), 10000).unref();
}
process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
