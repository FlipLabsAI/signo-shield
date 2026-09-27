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
