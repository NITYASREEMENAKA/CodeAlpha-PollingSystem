// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title PollingSystem
 * @author Solidity Developer
 * @notice A secure, time-restricted on-chain polling/voting system.
 * @dev Design notes:
 *      - Polls are stored in a mapping keyed by an incrementing uint256 ID (no array iteration
 *        needed to fetch a poll, which avoids unbounded gas costs).
 *      - Vote counts and "has voted" tracking use mappings nested inside the Poll struct, as
 *        required, instead of dynamic arrays, to keep storage access O(1) and avoid loops that
 *        scale with the number of voters.
 *      - All state-changing functions follow checks-effects-interactions: validation reverts
 *        happen first, then storage is updated, and only then is an event emitted. There are no
 *        external calls to untrusted contracts and no use of .call/.transfer/.send, so there is
 *        no reentrancy surface in this contract. We still mark vote() and createPoll() with care
 *        (effects committed before any event emission) as defense-in-depth / best practice.
 *      - Winner determination is O(numOptions), bounded by MAX_OPTIONS, so it can never run out
 *        of gas regardless of how many people voted.
 */
contract PollingSystem {
    /// @dev Hard cap on options per poll to bound gas costs of creation and winner-tallying loops.
    uint256 public constant MAX_OPTIONS = 50;

    /// @dev Hard cap on title/option string length to bound storage costs (defense-in-depth).
    uint256 public constant MAX_STRING_LENGTH = 256;

    /**
     * @notice Represents a single poll.
     * @dev `optionVoteCounts` and `hasVoted` are mappings rather than arrays so that vote
     *      casting and lookups remain O(1) regardless of how many voters participate.
     */
    struct Poll {
        string title;                              // Poll title
        string[] options;                          // Array of voting options
        uint256 deadline;                          // Block timestamp after which voting closes
        address creator;                           // Address that created the poll
        uint256 totalVotes;                        // Running total of votes cast (all options)
        mapping(uint256 => uint256) optionVoteCounts; // optionIndex => vote count
        mapping(address => bool) hasVoted;          // voter address => has voted on this poll
        mapping(address => uint256) voteChoice;     // voter address => option index they chose (for transparency/lookup)
    }

    /// @dev pollId => Poll. Starts at 1; 0 is never used so it can mean "not found" if needed.
    mapping(uint256 => Poll) private polls;

    /// @notice Total number of polls created. Also used to generate the next poll ID.
    uint256 public pollCount;

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    /// @notice Emitted when a new poll is created.
    event PollCreated(
        uint256 indexed pollId,
        address indexed creator,
        string title,
        string[] options,
        uint256 deadline
    );

    /// @notice Emitted when a vote is cast.
    event VoteCast(
        uint256 indexed pollId,
        address indexed voter,
        uint256 indexed optionIndex
    );

    /// @notice Emitted when the winner of a poll is queried/finalized off-chain via the winner function.
    event WinnerDeclared(
        uint256 indexed pollId,
        uint256 winningOptionIndex,
        string winningOption,
        uint256 winningVoteCount,
        bool isTie
    );

    // ---------------------------------------------------------------------
    // Custom errors (cheaper than revert strings, but kept descriptive)
    // ---------------------------------------------------------------------

    error EmptyTitle();
    error InvalidOptionsCount();
    error TooManyOptions();
    error EmptyOptionString();
    error StringTooLong();
    error DeadlineNotInFuture();
    error PollDoesNotExist(uint256 pollId);
    error VotingClosed(uint256 pollId, uint256 deadline, uint256 nowTs);
    error VotingStillOpen(uint256 pollId, uint256 deadline, uint256 nowTs);
    error AlreadyVoted(uint256 pollId, address voter);
    error InvalidOptionIndex(uint256 pollId, uint256 optionIndex, uint256 optionCount);
    error NoVotesCast(uint256 pollId);

    // ---------------------------------------------------------------------
    // Modifiers
    // ---------------------------------------------------------------------

    /// @dev Reverts if the poll referenced by `pollId` has never been created.
    modifier pollExists(uint256 pollId) {
        if (pollId == 0 || pollId > pollCount) revert PollDoesNotExist(pollId);
        _;
    }

    // ---------------------------------------------------------------------
    // Poll creation
    // ---------------------------------------------------------------------

    /**
     * @notice Creates a new poll with a title, a list of options, and a voting deadline.
     * @dev The deadline is supplied as a duration in seconds from `block.timestamp`. This avoids
     *      timezone/absolute-timestamp foot-guns for callers while still allowing arbitrarily
     *      long polls. Any address may create a poll (no access restriction, per requirements).
     * @param title The human-readable title of the poll. Must be non-empty and within
     *        MAX_STRING_LENGTH characters.
     * @param options The list of voting options. Must contain at least 2 and at most
     *        MAX_OPTIONS entries; each option must be non-empty and within MAX_STRING_LENGTH
     *        characters.
     * @param votingDurationSeconds How many seconds from now voting should remain open. Must be
     *        greater than zero.
     * @return pollId The unique identifier of the newly created poll.
     */
    function createPoll(
        string calldata title,
        string[] calldata options,
        uint256 votingDurationSeconds
    ) external returns (uint256 pollId) {
        if (bytes(title).length == 0) revert EmptyTitle();
        if (bytes(title).length > MAX_STRING_LENGTH) revert StringTooLong();

        uint256 optionCount = options.length;
        if (optionCount < 2) revert InvalidOptionsCount();
        if (optionCount > MAX_OPTIONS) revert TooManyOptions();

        if (votingDurationSeconds == 0) revert DeadlineNotInFuture();
        uint256 deadline = block.timestamp + votingDurationSeconds;

        // Validate each option before writing any storage, so a bad option can't leave a
        // partially-initialized poll behind.
        for (uint256 i = 0; i < optionCount; i++) {
            if (bytes(options[i]).length == 0) revert EmptyOptionString();
            if (bytes(options[i]).length > MAX_STRING_LENGTH) revert StringTooLong();
        }

        pollCount += 1;
        pollId = pollCount;

        Poll storage newPoll = polls[pollId];
        newPoll.title = title;
        newPoll.deadline = deadline;
        newPoll.creator = msg.sender;

        // Copy calldata options into storage individually (struct contains a dynamic array).
        for (uint256 i = 0; i < optionCount; i++) {
            newPoll.options.push(options[i]);
        }

        emit PollCreated(pollId, msg.sender, title, options, deadline);
    }

    // ---------------------------------------------------------------------
    // Voting
    // ---------------------------------------------------------------------

    /**
     * @notice Casts a vote for a specific option in a specific poll.
     * @dev Effects (storage writes) are fully applied before the event is emitted, and this
     *      contract makes no external calls, so there is no reentrancy vector here. Each address
     *      may vote at most once per poll.
     * @param pollId The ID of the poll to vote in.
     * @param optionIndex The zero-based index of the chosen option within that poll's options array.
     */
    function vote(uint256 pollId, uint256 optionIndex) external pollExists(pollId) {
        Poll storage poll = polls[pollId];

        if (block.timestamp >= poll.deadline) {
            revert VotingClosed(pollId, poll.deadline, block.timestamp);
        }
        if (poll.hasVoted[msg.sender]) {
            revert AlreadyVoted(pollId, msg.sender);
        }
        if (optionIndex >= poll.options.length) {
            revert InvalidOptionIndex(pollId, optionIndex, poll.options.length);
        }

        // Effects: mark voted, record choice, increment tally, bump total — all before the event.
        poll.hasVoted[msg.sender] = true;
        poll.voteChoice[msg.sender] = optionIndex;
        poll.optionVoteCounts[optionIndex] += 1;
        poll.totalVotes += 1;

        emit VoteCast(pollId, msg.sender, optionIndex);
    }

    // ---------------------------------------------------------------------
    // Winner determination
    // ---------------------------------------------------------------------

    /**
     * @notice Determines the winning option of a poll once voting has closed.
     * @dev Can only be called after `block.timestamp >= poll.deadline`. Iterates once over the
     *      (bounded, <= MAX_OPTIONS) options array, so gas cost is constant and independent of
     *      the number of voters. If no votes were cast, reverts with NoVotesCast rather than
     *      silently returning option 0 as a false winner. Ties are detected and reported via
     *      `isTie`; in a tie, `winningOptionIndex` returns the first option index that reached
     *      the maximum vote count.
     * @param pollId The ID of the poll to evaluate.
     * @return winningOptionIndex Index of the (first, if tied) option with the most votes.
     * @return winningOption The string label of that option.
     * @return winningVoteCount The number of votes the winning option received.
     * @return isTie True if two or more options are tied for the highest vote count.
     */
    function getWinner(uint256 pollId)
        external
        view
        pollExists(pollId)
        returns (
            uint256 winningOptionIndex,
            string memory winningOption,
            uint256 winningVoteCount,
            bool isTie
        )
    {
        Poll storage poll = polls[pollId];

        if (block.timestamp < poll.deadline) {
            revert VotingStillOpen(pollId, poll.deadline, block.timestamp);
        }
        if (poll.totalVotes == 0) {
            revert NoVotesCast(pollId);
        }

        uint256 optionCount = poll.options.length;
        uint256 highestCount = 0;
        uint256 highestIndex = 0;
        bool tieFound = false;

        for (uint256 i = 0; i < optionCount; i++) {
            uint256 count = poll.optionVoteCounts[i];
            if (count > highestCount) {
                highestCount = count;
                highestIndex = i;
                tieFound = false;
            } else if (count == highestCount && count > 0) {
                tieFound = true;
            }
        }

        winningOptionIndex = highestIndex;
        winningOption = poll.options[highestIndex];
        winningVoteCount = highestCount;
        isTie = tieFound;
    }

    /**
     * @notice Convenience wrapper around `getWinner` that also emits a `WinnerDeclared` event,
     *         useful for off-chain indexers that want a clear on-chain finalization marker.
     * @dev This is a state-changing call only because it emits an event; it performs no storage
     *      writes to poll data. Can be called multiple times by anyone after the deadline.
     * @param pollId The ID of the poll to finalize/announce.
     */
    function declareWinner(uint256 pollId) external pollExists(pollId) {
        (
            uint256 winningOptionIndex,
            string memory winningOption,
            uint256 winningVoteCount,
            bool isTie
        ) = this.getWinner(pollId);

        emit WinnerDeclared(pollId, winningOptionIndex, winningOption, winningVoteCount, isTie);
    }

    // ---------------------------------------------------------------------
    // View / read helpers
    // ---------------------------------------------------------------------

    /**
     * @notice Returns the core metadata for a poll.
     * @param pollId The ID of the poll to query.
     * @return title The poll's title.
     * @return options The poll's options.
     * @return deadline The poll's voting deadline (unix timestamp).
     * @return creator The address that created the poll.
     * @return totalVotes The total number of votes cast so far.
     */
    function getPoll(uint256 pollId)
        external
        view
        pollExists(pollId)
        returns (
            string memory title,
            string[] memory options,
            uint256 deadline,
            address creator,
            uint256 totalVotes
        )
    {
        Poll storage poll = polls[pollId];
        return (poll.title, poll.options, poll.deadline, poll.creator, poll.totalVotes);
    }

    /**
     * @notice Returns the current vote count for a single option in a poll.
     * @param pollId The ID of the poll to query.
     * @param optionIndex The zero-based index of the option to check.
     * @return voteCount The number of votes that option has received so far.
     */
    function getVoteCount(uint256 pollId, uint256 optionIndex)
        external
        view
        pollExists(pollId)
        returns (uint256 voteCount)
    {
        Poll storage poll = polls[pollId];
        if (optionIndex >= poll.options.length) {
            revert InvalidOptionIndex(pollId, optionIndex, poll.options.length);
        }
        return poll.optionVoteCounts[optionIndex];
    }

    /**
     * @notice Returns vote counts for every option in a poll, in option order.
     * @param pollId The ID of the poll to query.
     * @return counts An array of vote counts, where counts[i] corresponds to options[i].
     */
    function getAllVoteCounts(uint256 pollId)
        external
        view
        pollExists(pollId)
        returns (uint256[] memory counts)
    {
        Poll storage poll = polls[pollId];
        uint256 optionCount = poll.options.length;
        counts = new uint256[](optionCount);
        for (uint256 i = 0; i < optionCount; i++) {
            counts[i] = poll.optionVoteCounts[i];
        }
    }

    /**
     * @notice Checks whether a given address has already voted in a given poll.
     * @param pollId The ID of the poll to query.
     * @param voter The address to check.
     * @return voted True if `voter` has already cast a vote in this poll.
     */
    function hasAddressVoted(uint256 pollId, address voter)
        external
        view
        pollExists(pollId)
        returns (bool voted)
    {
        return polls[pollId].hasVoted[voter];
    }

    /**
     * @notice Returns the option index a given address voted for, if they have voted.
     * @dev Reverts implicitly returns 0 for addresses that have not voted (caller should check
     *      `hasAddressVoted` first to distinguish "voted for option 0" from "did not vote").
     * @param pollId The ID of the poll to query.
     * @param voter The address to check.
     * @return optionIndex The option index the voter chose.
     */
    function getVoteChoice(uint256 pollId, address voter)
        external
        view
        pollExists(pollId)
        returns (uint256 optionIndex)
    {
        return polls[pollId].voteChoice[voter];
    }

    /**
     * @notice Returns whether voting is currently open for a poll.
     * @param pollId The ID of the poll to query.
     * @return open True if `block.timestamp < deadline`.
     */
    function isVotingOpen(uint256 pollId) external view pollExists(pollId) returns (bool open) {
        return block.timestamp < polls[pollId].deadline;
    }
}
