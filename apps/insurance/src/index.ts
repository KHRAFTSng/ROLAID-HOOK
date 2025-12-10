import dotenv from 'dotenv';

dotenv.config();

// EigenAI endpoints per EigenCloud docs
const EIGENAI_ENV = (process.env.EIGENAI_ENV || 'sepolia').toLowerCase();
const BASE_URL =
  process.env.EIGENAI_BASE_URL ||
  (EIGENAI_ENV === 'mainnet'
    ? 'https://eigenai.eigencloud.xyz/v1'
    : 'https://eigenai-sepolia.eigencloud.xyz/v1');
const MODEL = process.env.EIGENAI_MODEL || 'gpt-oss-120b-f16';

type ChatChoice = {
  message?: { content?: string };
};
type ChatResponse = { choices?: ChatChoice[] };

async function callEigenAI(prompt: string, seed: number): Promise<string> {
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

async function verifyDeterminism(prompt: string, seed: number) {
  const first = await callEigenAI(prompt, seed);
  const second = await callEigenAI(prompt, seed);
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

  console.log('Calling EigenAI', { env: EIGENAI_ENV, model: MODEL, seed, baseUrl: BASE_URL });

  const content = await callEigenAI(prompt, seed);
  console.log('EigenAI response:\n', content);

  if ((process.env.VERIFY_DETERMINISM || 'true').toLowerCase() === 'true') {
    await verifyDeterminism(prompt, seed);
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
