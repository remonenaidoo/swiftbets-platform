// Fails on any high or critical runtime advisory unless .audit-allowlist.json lists it with a reason and an unexpired date.
import { execSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';

const allowlist = existsSync('.audit-allowlist.json') ? JSON.parse(readFileSync('.audit-allowlist.json', 'utf8')) : [];
const today = new Date().toISOString().slice(0, 10);
let report;
try {
  report = JSON.parse(execSync('npm audit --omit=dev --json', { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }));
} catch (error) {
  report = JSON.parse(error.stdout);
}

const advisories = new Map();
for (const vulnerability of Object.values(report.vulnerabilities ?? {})) {
  for (const via of vulnerability.via) {
    if (typeof via === 'object' && ['high', 'critical'].includes(via.severity)) {
      advisories.set(via.url.split('/').pop(), `${via.severity}: ${via.name} - ${via.title}`);
    }
  }
}

const problems = [];
for (const entry of allowlist) {
  if (!entry.id || !entry.reason || !entry.expires) problems.push(`allowlist entry ${JSON.stringify(entry)} needs id, reason and expires`);
  else if (entry.expires < today) problems.push(`allowlist entry ${entry.id} expired on ${entry.expires}; review it again`);
}
for (const [id, summary] of advisories) {
  const allowed = allowlist.find((e) => e.id === id && e.expires >= today);
  console.log(`${allowed ? 'allowed' : 'BLOCKED'} ${id} ${summary}${allowed ? ` (${allowed.reason}; until ${allowed.expires})` : ''}`);
  if (!allowed) problems.push(`${id} is not allowlisted`);
}

if (problems.length > 0) {
  console.error(problems.join('\n'));
  process.exit(1);
}
console.log(`npm audit gate passed: ${advisories.size} high or critical advisories, all allowlisted`);
