"""Agent proposal queue, multi-file navigation, and turn review checkpoints."""
from std.collections import List
from agentsvc import Proposal
from linediff import Hunk
from gitdiff import Side, side_hunks, unified, with_hunk, without_hunk
from swap import delete_file
from util import write_file, read_file, str_bytes, bytes_to_str, path_exists


@fieldwise_init
struct CheckpointEntry(Copyable, Movable):
    """Snapshot of a file before an agent turn."""
    var path: String
    var before_text: String
    var existed: Bool


struct AgentProposalQueue(Movable):
    """Encapsulates the multi-file proposal queue and per-turn review checkpoints."""
    var proposals: List[Proposal]
    var current_idx: Int
    var active: Bool
    var checkpoints: List[CheckpointEntry]

    def __init__(out self):
        self.proposals = List[Proposal]()
        self.current_idx = 0
        self.active = False
        self.checkpoints = List[CheckpointEntry]()

    def enqueue(mut self, p: Proposal):
        """Append a file write proposal to the review queue."""
        self.proposals.append(p.copy())
        if not self.active and len(self.proposals) > 0:
            self.active = True
            self.current_idx = 0

    def current_proposal(self) -> Proposal:
        """Returns the currently active proposal under review."""
        if self.current_idx >= 0 and self.current_idx < len(self.proposals):
            return self.proposals[self.current_idx].copy()
        return Proposal("", "", "", "", False)

    def next_file(mut self) -> Bool:
        """Move to next file in queue (navigating with ']')."""
        if self.current_idx + 1 < len(self.proposals):
            self.current_idx += 1
            return True
        return False

    def prev_file(mut self) -> Bool:
        """Move to previous file in queue (navigating with '[')."""
        if self.current_idx > 0:
            self.current_idx -= 1
            return True
        return False

    def record_checkpoint(mut self, path: String, before: String, existed: Bool):
        """Record file state prior to applying proposal for turn rollback."""
        for k in range(len(self.checkpoints)):
            if self.checkpoints[k].path == path:
                return
        self.checkpoints.append(CheckpointEntry(path, before, existed))

    def accept_current(mut self) -> Bool:
        """Accept current proposal: writes to disk, records snapshot, advances queue."""
        if self.current_idx < 0 or len(self.proposals) == 0 or self.current_idx >= len(self.proposals):
            return False
        var p = self.proposals.pop(self.current_idx)
        self.record_checkpoint(p.path, p.old, p.exists)
        var ok = write_file(p.path, str_bytes(p.new))
        if len(self.proposals) == 0:
            self.active = False
            self.current_idx = 0
        elif self.current_idx >= len(self.proposals):
            self.current_idx = len(self.proposals) - 1
        return ok

    def reject_current(mut self) -> Bool:
        """Reject current proposal: leaves disk untouched, advances queue."""
        if self.current_idx < 0 or len(self.proposals) == 0 or self.current_idx >= len(self.proposals):
            return False
        _ = self.proposals.pop(self.current_idx)
        if len(self.proposals) == 0:
            self.active = False
            self.current_idx = 0
        elif self.current_idx >= len(self.proposals):
            self.current_idx = len(self.proposals) - 1
        return True

    def accept_all_session(mut self):
        """Accept all remaining proposals in queue."""
        while len(self.proposals) > 0:
            _ = self.accept_current()

    def stage_hunk(mut self, hunk_idx: Int) -> Bool:
        """Stage single hunk into current proposal's new text."""
        if self.current_idx < 0 or len(self.proposals) == 0 or self.current_idx >= len(self.proposals):
            return False
        var p = self.proposals[self.current_idx].copy()
        var old_s = Side.of(p.old)
        var new_s = Side.of(p.new)
        var hunks = side_hunks(old_s, new_s)
        if hunk_idx < 0 or hunk_idx >= len(hunks):
            return False
        var applied = with_hunk(old_s, new_s, hunks[hunk_idx])
        self.proposals[self.current_idx].new = applied.text()
        return True

    def unstage_hunk(mut self, hunk_idx: Int) -> Bool:
        """Unstage/revert single hunk from current proposal's new text."""
        if self.current_idx < 0 or len(self.proposals) == 0 or self.current_idx >= len(self.proposals):
            return False
        var p = self.proposals[self.current_idx].copy()
        var old_s = Side.of(p.old)
        var new_s = Side.of(p.new)
        var hunks = side_hunks(old_s, new_s)
        if hunk_idx < 0 or hunk_idx >= len(hunks):
            return False
        var reverted = without_hunk(old_s, new_s, hunks[hunk_idx])
        self.proposals[self.current_idx].new = reverted.text()
        return True

    def revert_last_turn(mut self) -> Int:
        """Roll back all file modifications and deletions recorded in checkpoints."""
        var count = 0
        for k in range(len(self.checkpoints)):
            ref cp = self.checkpoints[k]
            if not cp.existed:
                if path_exists(cp.path):
                    delete_file(cp.path)
                    count += 1
            else:
                _ = write_file(cp.path, str_bytes(cp.before_text))
                count += 1
        self.checkpoints.clear()
        return count
