#!/usr/bin/env node

import { readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';

const repositoryRoot = process.env.MYSCOUTEE_PACKAGING_PROJECT_ROOT || process.cwd();
const config = JSON.parse(await readFile(path.join(repositoryRoot, 'config/packaging/seeds/data/emails.json'), 'utf8'));
const seedFiles = config.files;

for (const relativePath of seedFiles) {
  const absolutePath = path.join(repositoryRoot, relativePath);
  const users = JSON.parse(await readFile(absolutePath, 'utf8'));
  const accounts = users.filter(user => !user.accountUserId && !user.workspaceGroupId);
  let memberNumber = 0;
  let adminNumber = 0;
  let operatorNumber = 0;

  for (const user of accounts) {
    const hostTier = `${user.hostTier ?? ''}`.trim().toLowerCase();
    if (user.operator === true || hostTier === 'operator') {
      operatorNumber += 1;
      user.email = `operator${operatorNumber}@${config.domain}`;
    } else if (hostTier === 'admin') {
      adminNumber += 1;
      user.email = `admin${adminNumber}@${config.domain}`;
    } else {
      memberNumber += 1;
      user.email = `member${memberNumber}@${config.domain}`;
    }
  }

  const emails = accounts.map(user => `${user.email ?? ''}`.trim().toLowerCase());
  if (emails.some(email => !email) || new Set(emails).size !== emails.length) {
    throw new Error(`${relativePath} did not receive a complete unique email set.`);
  }
  if (adminNumber !== config.adminCount || operatorNumber !== config.operatorCount || memberNumber < config.minimumMemberCount) {
    throw new Error(
      `${relativePath} has unexpected role cardinality: `
      + `${memberNumber} members, ${adminNumber} admins, ${operatorNumber} operators.`
    );
  }

  await writeFile(absolutePath, `${JSON.stringify(users, null, 2)}\n`, 'utf8');
  process.stdout.write(
    `${relativePath}: ${memberNumber} member, ${adminNumber} admin and `
    + `${operatorNumber} operator emails assigned uniquely.\n`
  );
}
