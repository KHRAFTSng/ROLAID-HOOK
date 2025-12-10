import dotenv from 'dotenv';
import { createWalletClient, http, parseEther } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { sepolia } from 'viem/chains';

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

async function main() {
  // Placeholder example settlement; replace with real payload from auction logic
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
