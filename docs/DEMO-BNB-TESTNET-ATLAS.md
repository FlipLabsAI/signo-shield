# Demo: the Shield reads Atlas on chain (BNB testnet)

A demo for BNB Hack Bangkok (25 Nov 2026). The Shield acts for an agent only
when a condition holds, and it checks the condition itself, on chain, at the
moment of the firing. Here the condition reads the Atlas BNB/USD price feed.

Script: [`script/DemoAtlasBnbTestnet.s.sol`](../script/DemoAtlasBnbTestnet.s.sol).
Fork test: [`test/fork/DemoAtlasBnbTestnet.fork.t.sol`](../test/fork/DemoAtlasBnbTestnet.fork.t.sol).

## What happened

1. The deployer deployed the Shield core, the expression evaluator, and the
   generic executor on BNB testnet (chain 97), and listed one read: Atlas
   BNB/USD `latestRoundData()`, 18 decimals, at most 10 minutes old.
2. The owner wrapped 0.002002 testnet BNB into WBNB (two transfers and their fees) and signed two permissions
   for the agent. Each allows one transfer of 0.001 WBNB to a fixed
   recipient, plus the 10 bps fee:
   - "When BNB is above $100 on Atlas" (true).
   - "When BNB is above $1,000,000 on Atlas" (false).
3. The agent fired both:
   - The first firing passed. In the same transaction, the evaluator called
     the Atlas feed, the condition held, and 0.001 WBNB went to the recipient.
   - The second firing failed with `MandateBlocked(id, TRIGGER_NOT_MET)`.
     No funds moved.

## Addresses (BNB testnet, chain 97)

| Contract | Address |
| --- | --- |
| ShieldV1 | `0xDdA03e096Eaa3AC649965B62F02007970cf22836` |
| ShieldRegistryV1 | `0xc428a88A92Ecec99414152Ad2A5fd4244b222B15` |
| ExpressionEvaluator | `0xE6f6d73c782fb6263F04bB5966af7661b9ebE9d9` |
| GenericExecutorV1 | `0x33AC0359089676974Efc0a83335816120CbADA4C` |
| Atlas BNB/USD (open testnet feed) | `0x3957d289ee9C38272377786787ea34F9dd29788D` |
| WBNB (testnet) | `0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd` |

The addresses differ from mainnet because the deployer's first two testnet
transactions were replaced (gas price too low).

## Transactions

- Firing, condition true (Atlas read, then the transfer):
  [`0xe8f0fb86…a6d9`](https://testnet.bscscan.com/tx/0xe8f0fb862976f99df5dfdda18dec1f0d7d25ae288724a1e0f9dd9fe88f97a6d9)
- Firing, condition false (refused):
  [`0x21bf85f8…7cee`](https://testnet.bscscan.com/tx/0x21bf85f8fbf8f5d234d22045a02e6cd629ddd04919db0b2bb30e8a784c5e7cee)
- Permission registered, true condition:
  [`0x6c98dfec…2c71`](https://testnet.bscscan.com/tx/0x6c98dfec2c8aee9d707077a614a5d965c6641cf9e264dbe3a0283e6e53612c71)
- Permission registered, false condition:
  [`0x7502b6f1…b9a3`](https://testnet.bscscan.com/tx/0x7502b6f10a996b22d08f227e24189720bfc7c26d819cd251a44b41f81c63b9a3)
- Atlas read listed:
  [`0xddd13f34…9c30`](https://testnet.bscscan.com/tx/0xddd13f34a14cc4dabe22975f460b6cf40df7c7e719a186e2e1fcc87806729c30)

## Why testnet

Atlas's mainnet feeds answer only contract callers on an allowlist
(`OnlyAuthorizedCallerAllowed`). Atlas allowlists on testnet only for now, and
gave us testnet feeds that any contract may read. The mainnet Shield on BNB
Chain already lists the Atlas reads, and its price conditions read Chainlink
until Atlas allowlists the evaluator `0xc428a88A92Ecec99414152Ad2A5fd4244b222B15`.

This testnet deployment is a demo only: it is not in
`deployments/manifest.json`, so the Signo app does not offer chain 97.
