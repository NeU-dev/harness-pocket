import { Store } from './store.mjs';
import { Harness } from './harness.mjs';
import { APNs, NotificationWorker } from './apns.mjs';
import { createGateway } from './server.mjs';

const store = new Store(process.env.DATA_DIR || './data');
const harness = new Harness({ url: process.env.DSH_URL || 'http://127.0.0.1:3080', token: process.env.DSH_TOKEN, store });
const apns = new APNs(store.directory);
const worker = new NotificationWorker(store, apns);
const port = Number(process.env.PORT || 8787);
const server = createGateway({ store, harness, apns, worker, publicURL: process.env.PUBLIC_URL || '' });
server.listen(port, process.env.HOST || '127.0.0.1', () => { console.log(`Harness Pocket gateway listening on loopback port ${port}`); harness.start(); });
server.on('error', error => { console.error(error.code || 'server-error'); process.exitCode = 1; harness.stop(); });
for (const signal of ['SIGTERM', 'SIGINT']) process.on(signal, () => { harness.stop(); server.close(); setTimeout(() => process.exit(), 1000).unref(); });
