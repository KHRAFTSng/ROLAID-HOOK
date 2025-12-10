import dotenv from 'dotenv';
import { privateKeyToAccount } from 'viem/accounts';

dotenv.config();

// EigenAI endpoints per EigenCloud docs
const EIGENAI_ENV = (process.env.EIGENAI_ENV || 'sepolia').toLowerCase();
const BASE_URL =
  process.env.EIGENAI_BASE_URL ||
  (EIGENAI_ENV === 'mainnet'
    ? 'https://eigenai.eigencloud.xyz/v1'
    : 'https://eigenai-sepolia.eigencloud.xyz/v1');
const MODEL = process.env.EIGENAI_MODEL || 'gpt-oss-120b-f16';

// Grant-based auth (no API key) per deTERMinal instructions
const GRANT_SERVER = process.env.DETERMINAL_SERVER_URL || 'https://determinal-api.eigenarcade.com';
const PRIVATE_KEY = process.env.PRIVATE_KEY || process.env.EIGENAI_PRIVATE_KEY;

type ChatChoice = {
  message?: { content?: string };
};
type ChatResponse = { choices?: ChatChoice[] };

async function callEigenAIWithApiKey(prompt: string, seed: number): Promise<string> {
  const apiKey = process.env.EIGENAI_API_KEY;
  if (!apiKey) throw new Error('EIGENAI_API_KEY is not set');

  const body = {
    model: MODEL,
    max_tokens: 200,
    seed, // determinism lever per EigenAI docs
    messages: [{ role: 'user', content: prompt }],
  };

  const res = await fetch(`${BASE_URL}/chat/completions`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'x-api-key': apiKey, // per docs
    },
    body: JSON.stringify(body),
  });

  if (!res.ok) {
    const text = await res.text().catch(() => '');
    throw new Error(`EigenAI request failed: ${res.status} ${res.statusText} ${text}`);
  }

  const json = (await res.json()) as ChatResponse;
  const content = json.choices?.[0]?.message?.content;
  if (!content) throw new Error('No content returned from EigenAI');
  return content;
}

async function getGrantMessage(address: string): Promise<string> {
  const res = await fetch(`${GRANT_SERVER}/message?address=${address}`);
  if (!res.ok) {
    const text = await res.text().catch(() => '');
    throw new Error(`grant /message failed: ${res.status} ${res.statusText} ${text}`);
  }
  const json = await res.json();
  if (!json.message) throw new Error('grant message missing');
  return json.message;
}

async function callEigenAIWithGrant(prompt: string, seed: number): Promise<string> {
  if (!PRIVATE_KEY) throw new Error('PRIVATE_KEY is required for grant flow');
  const pk = PRIVATE_KEY.startsWith('0x') ? (PRIVATE_KEY as `0x${string}`) : (`0x${PRIVATE_KEY}` as `0x${string}`);
  const account = privateKeyToAccount(pk);
  const walletAddress = account.address;

  const grantMessage = await getGrantMessage(walletAddress);
  const grantSignature = await account.signMessage({ message: grantMessage });

  const body = {
    messages: [{ role: 'user', content: prompt }],
    model: MODEL,
    max_tokens: 200,
    seed,
    grantMessage,
    grantSignature,
    walletAddress,
  };

  const res = await fetch(`${GRANT_SERVER}/api/chat/completions`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(body),
  });

  if (!res.ok) {
    const text = await res.text().catch(() => '');
    throw new Error(`grant chat failed: ${res.status} ${res.statusText} ${text}`);
  }

  const json = (await res.json()) as ChatResponse;
  const content = json.choices?.[0]?.message?.content;
  if (!content) throw new Error('No content returned from EigenAI (grant)');
  return content;
}

async function verifyDeterminism(prompt: string, seed: number, useGrant: boolean) {
  const caller = useGrant ? callEigenAIWithGrant : callEigenAIWithApiKey;
  const first = await caller(prompt, seed);
  const second = await caller(prompt, seed);
  if (first !== second) {
    throw new Error('Determinism check failed: outputs differ for same seed');
  }
  console.log('Determinism verified for seed', seed);
}

async function main() {
  const seed = Number(process.env.EIGENAI_SEED || 42);
  const prompt =
    process.env.EIGENAI_PROMPT ||
    'Compute deterministic insurance payouts for a simple one-event claim.';

  const hasApiKey = !!process.env.EIGENAI_API_KEY;
  const useGrant = !hasApiKey;

  console.log(
    'Calling EigenAI',
    useGrant
      ? { mode: 'grant', server: GRANT_SERVER, model: MODEL, seed }
      : { mode: 'api-key', env: EIGENAI_ENV, model: MODEL, seed, baseUrl: BASE_URL }
  );

  const content = await (useGrant ? callEigenAIWithGrant : callEigenAIWithApiKey)(prompt, seed);
  console.log('EigenAI response:\n', content);

  if ((process.env.VERIFY_DETERMINISM || 'true').toLowerCase() === 'true') {
    await verifyDeterminism(prompt, seed, useGrant);
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
