import dotenv from 'dotenv';
import { createWalletClient, http, parseEther } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { sepolia } from 'viem/chains';
import * as http from 'http';

dotenv.config();

type SettlementRequest = {
  auctionId: bigint;
  appId: `0x${string}`;
  imageDigest: `0x${string}`;
  bidder: `0x${string}`;
  bidAmountWei: bigint;
  settlementData: `0x${string}`;
};

async function buildClient() {
  const pk = process.env.PRIVATE_KEY;
  const rpc = process.env.L1_RPC_URL || process.env.SEPOLIA_RPC_URL;
  if (!pk) throw new Error('PRIVATE_KEY is not set');
  if (!rpc) throw new Error('L1_RPC_URL or SEPOLIA_RPC_URL is required');
  const account = privateKeyToAccount(pk.startsWith('0x') ? (pk as `0x${string}`) : (`0x${pk}` as `0x${string}`));
  const client = createWalletClient({
    chain: sepolia,
    transport: http(rpc),
    account,
  });
  return { client, account };
}

async function submitSettlement(req: SettlementRequest) {
  const { client, account } = await buildClient();
  const auctionService = process.env.AUCTION_SERVICE_ADDRESS as `0x${string}`;
  if (!auctionService) throw new Error('AUCTION_SERVICE_ADDRESS is required');

  // submitSettlement(uint256 id, bytes32 appId, bytes32 imageDigest, address bidder, uint96 bidAmount, bytes settlementData)
  const data = client.encodeFunctionData({
    abi: [
      {
        name: 'submitSettlement',
        type: 'function',
        stateMutability: 'payable',
        inputs: [
          { name: 'id', type: 'uint256' },
          { name: 'appId', type: 'bytes32' },
          { name: 'imageDigest', type: 'bytes32' },
          { name: 'bidder', type: 'address' },
          { name: 'bidAmount', type: 'uint96' },
          { name: 'settlementData', type: 'bytes' },
        ],
        outputs: [],
      },
    ],
    functionName: 'submitSettlement',
    args: [
      req.auctionId,
      req.appId,
      req.imageDigest,
      req.bidder,
      req.bidAmountWei,
      req.settlementData,
    ],
  });

  const hash = await client.sendTransaction({
    to: auctionService,
    data,
    value: req.bidAmountWei,
    account,
  });
  console.log('Submitted settlement tx hash:', hash);
}

async function handleSettlement(req: SettlementRequest) {
  try {
    await submitSettlement(req);
    return { success: true, message: 'Settlement submitted' };
  } catch (err: any) {
    return { success: false, error: err.message };
  }
}

// HTTP server for E2E testing
const PORT = Number(process.env.APP_PORT || 8001);

function startServer() {
  const server = http.createServer(async (req, res) => {
    const url = new URL(req.url || '/', `http://${req.headers.host}`);
    
    // CORS headers
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
    res.setHeader('Content-Type', 'application/json');

    if (req.method === 'OPTIONS') {
      res.writeHead(200);
      res.end();
      return;
    }
    
    if (url.pathname === '/health') {
      res.writeHead(200);
      res.end(JSON.stringify({ status: 'ok', service: 'auctioneer' }));
      return;
    }
    
    if (url.pathname === '/settle' && req.method === 'POST') {
      try {
        let body = '';
        for await (const chunk of req) {
          body += chunk.toString();
        }
        const data = JSON.parse(body);
        
        const appId = (data.appId || process.env.APP_ID) as `0x${string}`;
        const imageDigest = (data.imageDigest || process.env.IMAGE_DIGEST) as `0x${string}`;
        
        if (!appId || !imageDigest) {
          res.writeHead(400);
          res.end(JSON.stringify({ error: 'APP_ID and IMAGE_DIGEST required' }));
          return;
        }

        const settlement: SettlementRequest = {
          auctionId: BigInt(data.auctionId || 1),
          appId,
          imageDigest,
          bidder: (data.bidder || process.env.BIDDER_ADDRESS || (await buildClient()).account.address) as `0x${string}`,
          bidAmountWei: parseEther(data.bidAmountEth || process.env.BID_AMOUNT_ETH || '0.001'),
          settlementData: (data.settlementData || process.env.SETTLEMENT_DATA_HEX || '0x') as `0x${string}`,
        };

        const result = await handleSettlement(settlement);
        res.writeHead(200);
        res.end(JSON.stringify(result));
      } catch (err: any) {
        res.writeHead(500);
        res.end(JSON.stringify({ error: err.message }));
      }
      return;
    }

    res.writeHead(404);
    res.end(JSON.stringify({ error: 'Not found' }));
  });

  server.listen(PORT, () => {
    console.log(`Auctioneer server running on port ${PORT}`);
  });

  return server;
}

// Run as HTTP server if APP_PORT is set, otherwise run as one-off script
if (process.env.APP_PORT) {
  startServer().catch((err) => {
    console.error('Server error:', err);
    process.exit(1);
  });
} else {
  // One-off mode for backward compatibility
  async function main() {
    const appId = process.env.APP_ID as `0x${string}`;
    const imageDigest = process.env.IMAGE_DIGEST as `0x${string}`;
    if (!appId || !imageDigest) throw new Error('APP_ID and IMAGE_DIGEST are required for attestation binding');

    const settlement: SettlementRequest = {
      auctionId: 1n,
      appId,
      imageDigest,
      bidder: process.env.BIDDER_ADDRESS as `0x${string}` || (await buildClient()).account.address,
      bidAmountWei: parseEther(process.env.BID_AMOUNT_ETH || '0.001'),
      settlementData: (process.env.SETTLEMENT_DATA_HEX as `0x${string}`) || '0x',
    };

    await submitSettlement(settlement);
  }

  main().catch((err) => {
    console.error(err);
    process.exit(1);
  });
}
