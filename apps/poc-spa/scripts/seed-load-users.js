#!/usr/bin/env node
/**
 * Seed user-0..user-N in poc-realm for Gatling / HPA load tests.
 */
import { readFileSync, existsSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execSync } from 'node:child_process';
import KcAdminClient from '@keycloak/keycloak-admin-client';

const __dirname = dirname(fileURLToPath(import.meta.url));
const root = resolve(__dirname, '..');
const repoRoot = resolve(root, '../..');
const cfg = JSON.parse(readFileSync(resolve(root, 'config/config.json'), 'utf8'));

function argValue(name, fallback) {
  const idx = process.argv.indexOf(name);
  if (idx >= 0 && process.argv[idx + 1]) return process.argv[idx + 1];
  return fallback;
}

const count = Number(argValue('--count', process.env.SEED_COUNT || '1000'));
const batchSize = Number(argValue('--batch', '50'));
const start = Number(argValue('--start', '0'));

function loadAdminEnv() {
  const out = {};
  if (process.env.KC_ADMIN_USER) out.user = process.env.KC_ADMIN_USER.trim();
  if (process.env.KC_ADMIN_PASSWORD) out.password = process.env.KC_ADMIN_PASSWORD.trim();
  const envFile = resolve(repoRoot, 'secrets/keycloak-admin.env');
  if (existsSync(envFile)) {
    const text = readFileSync(envFile, 'utf8');
    const user = text.match(/^KC_ADMIN_USER=(.*)$/m);
    const pass = text.match(/^KC_ADMIN_PASSWORD=(.*)$/m);
    if (!out.user && user) out.user = user[1].trim();
    if (!out.password && pass) out.password = pass[1].trim();
  }
  if (!out.password) {
    const b64 = execSync(
      "oc get secret keycloak-initial-admin -n rhbk-mc -o jsonpath='{.data.password}'",
      { encoding: 'utf8' }
    ).trim();
    out.password = Buffer.from(b64, 'base64').toString('utf8');
  }
  out.user = out.user || 'temp-admin';
  return out;
}

const { user: adminUser, password: adminPassword } = loadAdminEnv();
const baseUrl = cfg.keycloak.url;
const realm = cfg.keycloak.realm;
const admin = new KcAdminClient({ baseUrl, realmName: 'master' });

async function adminLogin() {
  admin.setConfig({ realmName: 'master' });
  await admin.auth({
    username: adminUser,
    password: adminPassword,
    grantType: 'password',
    clientId: 'admin-cli',
  });
  admin.setConfig({ realmName: realm });
}

await adminLogin();

const userRole = await admin.roles.findOneByName({ name: 'user' });
const rolePayload = userRole ? [{ id: userRole.id, name: userRole.name }] : [];

let created = 0;
let skipped = 0;

for (let i = start; i < start + count; i++) {
  if (i > start && i % batchSize === 0) {
    await adminLogin();
  }
  const username = `user-${i}`;
  const found = await admin.users.find({ username, exact: true });
  if (found.length > 0) {
    skipped += 1;
    continue;
  }
  const { id } = await admin.users.create({
    username,
    enabled: true,
    email: `${username}@poc-realm.local`,
    firstName: 'Load',
    lastName: `User${i}`,
    emailVerified: true,
  });
  await admin.users.resetPassword({
    id,
    credential: { type: 'password', value: `${username}-password`, temporary: false },
  });
  if (rolePayload.length) {
    await admin.users.addRealmRoleMappings({ id, roles: rolePayload });
  }
  created += 1;
  if (created % batchSize === 0) {
    console.log(`Created ${created} users (last: ${username})`);
  }
}

console.log(
  `Seed complete: created=${created} skipped=${skipped} range=user-${start}..user-${start + count - 1}`
);
