import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
const patch = readFileSync(new URL('../patches/vesktop-discord-deep-links.patch', import.meta.url), 'utf8');
const added = patch.split('+++ b/src/main/utils/discordLinks.ts\n')[1].split('\n').filter(l => l.startsWith('+')).map(l => l.slice(1)).join('\n');
const dir = mkdtempSync(join(tmpdir(), 'vesktop-links-test-'));
try {
 const modulePath = join(dir, 'discordLinks.ts'); writeFileSync(modulePath, added);
 const { discordNavigationUrl: route, oauthDeepLink: rpc } = await import(pathToFileURL(modulePath));
 assert.equal(route(undefined), 'https://discord.com/app');
 assert.equal(route('discord://-/channels/123/456?jump=789#message', 'ptb'), 'https://ptb.discord.com/channels/123/456?jump=789#message');
 const search = '?client_id=123&scope=bot%20applications.commands&permissions=117809&state=some%2Bstate&redirect_uri=https%3A%2F%2Fexample.com%2Fcallback';
 const result = new URL(rpc({type:'OAUTH2',params:{search}}));
 const original = new URLSearchParams(search);
 for (const [key,value] of original) assert.equal(result.searchParams.get(key),value);
 assert.equal(result.origin, 'https://discord.com');
 assert.equal(result.pathname, '/oauth2/authorize');
 assert.equal(result.searchParams.get('response_type'), null);
 assert.equal(result.searchParams.get('vesktop_response_type'), 'bot');
 assert.equal(route(result.href), result.href, 'retry must be idempotent');
 const codeFlow=new URL(route('discord://action/oauth2/authorize?client_id=123&response_type=code&code_challenge=abc'));
 assert.equal(codeFlow.searchParams.get('response_type'),'code');
 assert.equal(codeFlow.searchParams.get('code_challenge'),'abc');
 for(const input of ['https://evil.example/oauth2/authorize','javascript:alert(1)','file:///etc/passwd','https://discord.com.evil.example/','https://user:pass@discord.com/','https://discord.com:8443/']) assert.throws(()=>route(input));
 for(const data of [null,{}, {type:'OAUTH2'}, {type:'OAUTH2',params:{search:123}}, {type:'OAUTH2',params:{search:'https://evil.example'}}, {type:'OTHER',params:{search}}]) assert.equal(rpc(data),undefined);
 console.log('Discord URL and RPC routing regression checks passed');
} finally { rmSync(dir, {recursive:true,force:true}); }
