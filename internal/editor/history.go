package editor

import "time"

// A change replaced Old at At with New. Offsets are units.
type change struct {
	at       int
	old, new string
}

// A step is what one undo takes back: changes made together, and the
// selections before and after.
type step struct {
	changes       []change
	before, after [2]int
	kind          stepKind
	at            time.Time
}

type stepKind uint8

const (
	stepEdit stepKind = iota
	stepTyping
	stepDeleting
)

// history is a note's undo and redo.
type history struct {
	undo, redo []step
	// open lets typing join the step before it until a pause or a move.
	open bool
	// saved is the length of undo when the note was saved, or -1 when
	// that step is gone.
	saved int
}

const coalesceGap = 1200 * time.Millisecond

// record adds a step, or joins it to the last when both are typing that
// goes on.
func (h *history) record(s step) {
	h.redo = h.redo[:0]
	if n := len(h.undo); n > 0 && h.open && s.kind != stepEdit && h.undo[n-1].kind == s.kind && s.at.Sub(h.undo[n-1].at) < coalesceGap {
		last := &h.undo[n-1]
		last.changes = append(last.changes, s.changes...)
		last.after = s.after
		last.at = s.at
		return
	}
	if h.saved > len(h.undo) {
		h.saved = -1
	}
	h.undo = append(h.undo, s)
	h.open = s.kind != stepEdit
}

// breakStep ends typing's step, as the caret moves.
func (h *history) breakStep() { h.open = false }

func (h *history) canUndo() bool { return len(h.undo) > 0 }
func (h *history) canRedo() bool { return len(h.redo) > 0 }

func (h *history) markSaved() { h.saved = len(h.undo) }

func (h *history) isSaved() bool { return h.saved == len(h.undo) }
