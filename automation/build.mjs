import {readFile,writeFile} from 'node:fs/promises';
const parts=await Promise.all(['mail.js','email-check.js','engine.js','self-test.js','edge-entry.js'].map(f=>readFile(new URL(f,import.meta.url),'utf8')));
const code="import { createClient } from 'npm:@supabase/supabase-js@2.57.4';\n"+parts.map(s=>s.replace(/^import .*\n/gm,'').replace(/^export /gm,'')).join('\n');
await writeFile(new URL('../supabase/functions/hvac-worker/index.ts',import.meta.url),code);
