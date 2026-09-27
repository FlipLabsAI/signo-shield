# Mainnet canary

An automated test that runs real mandates on X Layer mainnet (chain 196) from
a team test wallet, through the live Signo app. For each scenario it:

1. describes the condition and the action in words, and compiles both with
   the app's own routes;
2. signs the approval and `registerMandate` from the test wallet, exactly as
   the app's review screen builds them;
3. records the mandate for its agent, which needs the owner's signed proof;
4. fires that one mandate the way the hourly check does;
5. reads the receipt: the token that arrived, the amount spent as a share of
   the balance, and the owner's notice text;
6. revokes the mandate, sets the approval to zero, removes the agent and puts
   any tokens back where they were.

It also checks, on the live app, that only the owner's wallet can pause,
change or delete an agent that executes, and that nobody else can link a new
mandate to an agent.

It runs daily and after each app release that changes Execute. A failed run
is reported to the team at once.

## Runs

| Date (UTC) | App build | Scenario | Result | Transactions |
| --- | --- | --- | --- | --- |
| 2026-09-26 | 4429 | Owner-only changes: a setup in progress refuses outside edits; recording needs the owner's proof; an armed agent pauses only for its owner | Passed | register [`0xfffdaf66…8967`](https://www.oklink.com/x-layer/tx/0xfffdaf669af78fa83732b550eb0efbe423bd95cfa9d18f617428c3f50c748967), revoke [`0x3f7fecf1…0651`](https://www.oklink.com/x-layer/tx/0x3f7fecf1655ceaf06001e61818d76f02e7ca092bb393574f559f91d10f620651) |
| 2026-09-27 | 4433 | Swap 25% of USD₮0 into xETH; send 1 USD₮0; supply 10% of USD₮0 to Aave on a USD₮0 holdings trigger; swap all xETH back; owner-only changes | Failed. The swap spent exactly 25% and passed. The send and the Aave supply never executed: a condition written "USD₮0" did not match the wallet's USDT0 balance (fixed in app build 4435). The swap back was correct; the canary's own check did not allow for the 0.1% fee (fixed). All mandates were revoked. | swap [`0x321ea067…d6a4`](https://www.oklink.com/x-layer/tx/0x321ea067e2a8e076423ca7ecc8cd352ffc4c304610b6c726daae656ff4d6d6a4), swap back [`0x1f42bb74…ed68`](https://www.oklink.com/x-layer/tx/0x1f42bb743a207d8cbb4947577053a3b9d01d55903022855f3808725d709ded68) |
| 2026-09-27 | 4435 | The same five scenarios | Passed. Swap spent 25.0% of the balance; send delivered exactly 1 USD₮0; Aave supply spent 10.0% and was withdrawn after; swap back sold the whole xETH balance less the fee. Every mandate revoked and every approval set to zero after its check. | swap [`0xba80b02d…fe64`](https://www.oklink.com/x-layer/tx/0xba80b02dcd5fc46de0be10e6703862217f7e93aef9f8b58b4418860b4ec9fe64), send [`0x0d016f50…99d6`](https://www.oklink.com/x-layer/tx/0x0d016f50eb0c795602cb6415070d28a678d492e9c1bc5d989ab4cd8c357b99d6), Aave [`0x20720688…2176`](https://www.oklink.com/x-layer/tx/0x20720688ce43956c7411edfc589520345192960bfe6cd1d81f3ffeba75cf2176), swap back [`0x07e2efca…68cb`](https://www.oklink.com/x-layer/tx/0x07e2efca1249f90e16b8b7ab9583ca80753afcb4fe862662ae3c496d355868cb) |
| 2026-09-27 | 4438 | guardian swap: 25% of USD₮0 into xETH; transfer: 1 USD₮0 to the team address; Aave supply: 10% of USD₮0 when the holding is above $5; swap back: all xETH into USD₮0 | Passed | guardian swap [`0xee324a1b…23c5`](https://www.oklink.com/x-layer/tx/0xee324a1b58e64f7594dc579b7d41b788280e3698a6619f522fe08c76089323c5), transfer [`0x77ba91cb…57cb`](https://www.oklink.com/x-layer/tx/0x77ba91cbe363281fdaf1604cd22e834a079fdf0000451baef4c66506b0c057cb), Aave supply [`0x296113ce…d915`](https://www.oklink.com/x-layer/tx/0x296113cebe64cb1addf871c7cb52e151d2cb058c95a8f2c2d7701d76af71d915), swap back [`0x3910bfe8…d813`](https://www.oklink.com/x-layer/tx/0x3910bfe82fa0e7686d3d4dcf90c6acfde143172db5769ba03453b1ca94eed813) |
