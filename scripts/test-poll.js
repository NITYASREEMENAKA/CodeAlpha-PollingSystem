// scripts/test-poll.js
//
// HOW TO RUN THIS SCRIPT:
//   npx hardhat run scripts/test-poll.js
//
// This script deploys the PollingSystem contract to an in-memory test
// blockchain, creates a poll, casts a vote, and prints the results.
// No manual typing in the console needed — just run the single command above.

const hre = require("hardhat");

async function main() {
  const ethers = hre.ethers;

  console.log("Deploying PollingSystem contract...");
  const Poll = await ethers.getContractFactory("PollingSystem");
  const poll = await Poll.deploy();
  await poll.waitForDeployment();
  console.log("Deployed at address:", await poll.getAddress());

  console.log("\nCreating a poll...");
  const tx = await poll.createPoll(
    "Best language?",
    ["JS", "Python", "Solidity"],
    3600 // voting open for 1 hour
  );
  await tx.wait();
  console.log("Poll created!");

  console.log("\nFetching poll details...");
  const details = await poll.getPoll(1);
  console.log("Title:", details[0]);
  console.log("Options:", details[1]);
  console.log("Deadline (unix timestamp):", details[2].toString());
  console.log("Creator:", details[3]);
  console.log("Total votes so far:", details[4].toString());

  console.log("\nCasting a vote for option index 2 (Solidity)...");
  const voteTx = await poll.vote(1, 2);
  await voteTx.wait();
  console.log("Vote cast!");

  console.log("\nFetching vote counts...");
  const counts = await poll.getAllVoteCounts(1);
  console.log("Vote counts [JS, Python, Solidity]:", counts.map((c) => c.toString()));

  console.log("\nTrying to vote again with the same account (should fail)...");
  try {
    await poll.vote(1, 0);
    console.log("ERROR: this should not have succeeded!");
  } catch (err) {
    console.log("Correctly rejected double vote. Reason:", err.shortMessage || err.message);
  }

  console.log("\nDone! Everything worked as expected.");
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
