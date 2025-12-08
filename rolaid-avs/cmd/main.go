package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"time"

	"github.com/Layr-Labs/hourglass-avs-template/contracts/bindings/l1/helloworldl1"
	"github.com/Layr-Labs/hourglass-avs-template/contracts/bindings/l1/taskavsregistrar"
	"github.com/Layr-Labs/hourglass-monorepo/ponos/pkg/performer/contracts"
	"github.com/Layr-Labs/hourglass-monorepo/ponos/pkg/performer/server"
	performerV1 "github.com/Layr-Labs/protocol-apis/gen/protos/eigenlayer/hourglass/v1/performer"
	"github.com/ethereum/go-ethereum/ethclient"
	"go.uber.org/zap"
)

// This offchain binary is run by Operators running the Hourglass Executor. It contains
// the business logic of the AVS and performs worked based on the tasked sent to it.
// The Hourglass Aggregator ingests tasks from the TaskMailbox and distributes work
// to Executors configured to run the AVS Performer. Performers execute the work and
// return the result to the Executor where the result is signed and return to the
// Aggregator to place in the outbox once the signing threshold is met.

type TaskWorker struct {
	logger        *zap.Logger
	contractStore *contracts.ContractStore
	l1Client      *ethclient.Client
	l2Client      *ethclient.Client
}

func NewTaskWorker(logger *zap.Logger) *TaskWorker {
	// Initialize contract store from environment variables
	contractStore, err := contracts.NewContractStore()
	if err != nil {
		logger.Warn("Failed to load contract store", zap.Error(err))
	}

	// Initialize Ethereum clients if RPC URLs are provided
	var l1Client, l2Client *ethclient.Client

	if l1RpcUrl := os.Getenv("L1_RPC_URL"); l1RpcUrl != "" {
		l1Client, err = ethclient.Dial(l1RpcUrl)
		if err != nil {
			logger.Error("Failed to connect to L1 RPC", zap.Error(err))
		}
	}

	if l2RpcUrl := os.Getenv("L2_RPC_URL"); l2RpcUrl != "" {
		l2Client, err = ethclient.Dial(l2RpcUrl)
		if err != nil {
			logger.Error("Failed to connect to L2 RPC", zap.Error(err))
		}
	}

	return &TaskWorker{
		logger:        logger,
		contractStore: contractStore,
		l1Client:      l1Client,
		l2Client:      l2Client,
	}
}

func (tw *TaskWorker) ValidateTask(t *performerV1.TaskRequest) error {
	tw.logger.Sugar().Infow("Validating task",
		zap.Any("task", t),
	)

	// LVR/insurance context: require a task payload and task id.
	if len(t.GetTaskId()) == 0 {
		return fmt.Errorf("missing task id")
	}
	if len(t.GetData()) == 0 {
		return fmt.Errorf("missing task payload")
	}

	if _, err := decodeTaskEnvelope(t.GetData()); err != nil {
		return fmt.Errorf("invalid task payload: %w", err)
	}

	return nil
}

func (tw *TaskWorker) HandleTask(t *performerV1.TaskRequest) (*performerV1.TaskResponse, error) {
	tw.logger.Sugar().Infow("Handling task",
		zap.Any("task", t),
	)

	env, err := decodeTaskEnvelope(t.GetData())
	if err != nil {
		return nil, fmt.Errorf("decode envelope: %w", err)
	}

	var resultBytes []byte
	switch env.Kind {
	case "auction_settlement":
		resultBytes, err = tw.handleAuctionSettlement(env.Auction)
	case "insurance_payout":
		resultBytes, err = tw.handleInsurancePayout(env.Insurance)
	default:
		err = fmt.Errorf("unsupported task kind: %s", env.Kind)
	}
	if err != nil {
		return nil, err
	}

	// Example: interact with onchain components if configured
	if tw.contractStore != nil {

		taskRegistrarAddr, err := tw.contractStore.GetTaskAVSRegistrar()
		if err != nil {
			tw.logger.Warn("TaskAVSRegistrar not found", zap.Error(err))
		} else {
			tw.logger.Info("TaskAVSRegistrar", zap.String("address", taskRegistrarAddr.Hex()))

			// TaskAVSRegistrar contract binding
			if tw.l1Client != nil {
				registrar, err := taskavsregistrar.NewTaskAVSRegistrar(taskRegistrarAddr, tw.l1Client)
				if err == nil {
					// Call the registrar contract
					_ = registrar
				}
			}
		}

		// Example 2: Get custom contract addresses
		// Replace this with your deployed contract addresses (e.g., AuctionService / SettlementVault).
		_ = helloworldl1.NewHelloWorldL1

		// Example 3: List available contracts
		tw.logger.Info("Available contracts", zap.Strings("contracts", tw.contractStore.ListContracts()))
	}

	return &performerV1.TaskResponse{
		TaskId: t.TaskId,
		Result: resultBytes,
	}, nil
}

// Task envelope schema (JSON over TaskRequest.Data) to route auction vs insurance work.
type TaskEnvelope struct {
	Kind      string            `json:"kind"` // "auction_settlement" | "insurance_payout"
	Auction   *AuctionTask      `json:"auction,omitempty"`
	Insurance *InsuranceTask    `json:"insurance,omitempty"`
	Metadata  map[string]string `json:"meta,omitempty"`
}

type AuctionTask struct {
	AuctionId       uint64 `json:"auction_id"`
	PoolId          string `json:"pool_id"`           // bytes32 hex
	OracleUpdateId  string `json:"oracle_update_id"`  // bytes32 hex
	SettlementData  string `json:"settlement_data"`   // hex-encoded payload to submit onchain
	ExpectedBidWei  string `json:"expected_bid_wei"`  // hex or decimal string
	AppId           string `json:"app_id"`            // EigenCompute appId (hex)
	ImageDigest     string `json:"image_digest"`      // Docker digest (hex)
	SubmissionNonce uint64 `json:"submission_nonce"`  // optional replay guard
}

type InsuranceTask struct {
	PolicyBatchId string   `json:"policy_batch_id"`
	Events        []string `json:"events"`        // descriptions / ids
	Seed          uint64   `json:"seed"`          // for deterministic EigenAI call
	AmountWei     string   `json:"amount_wei"`    // total pot to allocate
	AppId         string   `json:"app_id"`        // EigenCompute appId (hex)
	ImageDigest   string   `json:"image_digest"`  // Docker digest (hex)
}

func decodeTaskEnvelope(data []byte) (*TaskEnvelope, error) {
	var env TaskEnvelope
	if err := json.Unmarshal(data, &env); err != nil {
		return nil, err
	}
	return &env, nil
}

func (tw *TaskWorker) handleAuctionSettlement(a *AuctionTask) ([]byte, error) {
	if a == nil {
		return nil, fmt.Errorf("auction task missing")
	}
	tw.logger.Sugar().Infow("Auction settlement task",
		"auction_id", a.AuctionId,
		"pool_id", a.PoolId,
		"oracle_update_id", a.OracleUpdateId,
	)
	// TODO: verify appId/imageDigest against attestation allowlist; submit settlement onchain.
	return []byte("auction_ok"), nil
}

func (tw *TaskWorker) handleInsurancePayout(ins *InsuranceTask) ([]byte, error) {
	if ins == nil {
		return nil, fmt.Errorf("insurance task missing")
	}
	tw.logger.Sugar().Infow("Insurance payout task",
		"batch", ins.PolicyBatchId,
		"events", ins.Events,
		"seed", ins.Seed,
	)
	// TODO: call EigenAI deterministically with seed; compute payout vector; return bytes.
	return []byte("insurance_ok"), nil
}

func main() {
	ctx := context.Background()
	l, _ := zap.NewProduction()

	w := NewTaskWorker(l)

	pp, err := server.NewPonosPerformerWithRpcServer(&server.PonosPerformerConfig{
		Port:    8080,
		Timeout: 5 * time.Second,
	}, w, l)
	if err != nil {
		panic(fmt.Errorf("failed to create performer: %w", err))
	}

	if err := pp.Start(ctx); err != nil {
		panic(err)
	}
}
