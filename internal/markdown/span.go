// Package markdown turns a note's text into the style spans the editor
// draws with, and keeps them current as the note is edited.
package markdown

// A Span is a styled range within one line. Start..End is the piece on its
// line; ElemStart..ElemEnd is the whole element the piece belongs to, which
// may cover several lines: a marker shows while the selection touches its
// element, and a block drawn as a widget covers its element. Offsets are
// UTF-16 units once a Doc returns them, and bytes inside the parser.
type Span struct {
	Start, End         int
	ElemStart, ElemEnd int
	Kind               Kind
	Level              uint8
	Flags              uint16
}

// Kind is what a span styles.
type Kind uint8

const (
	Heading Kind = 1
	// Marker is syntax that is hidden away from the selection.
	Marker        Kind = 2
	Emphasis      Kind = 3
	Strong        Kind = 4
	Strike        Kind = 5
	Code          Kind = 6
	Link          Kind = 7
	LinkDest      Kind = 8
	Image         Kind = 9
	ImageDest     Kind = 10
	WikiLink      Kind = 11
	WikiTarget    Kind = 12
	FootnoteRef   Kind = 13
	FootnoteDef   Kind = 14
	Superscript   Kind = 15
	Subscript     Kind = 16
	InlineMath    Kind = 17
	MathBlock     Kind = 18
	CodeBlock     Kind = 19
	BlockQuote    Kind = 20
	CalloutTag    Kind = 21
	ListMarker    Kind = 22
	TaskMarker    Kind = 23
	ThematicBreak Kind = 24
	Table         Kind = 25
	TableCell     Kind = 26
	HTML          Kind = 27
	FrontMatter   Kind = 28
	Highlight     Kind = 29

	// Tokens of highlighted code.
	TokenKeyword     Kind = 40
	TokenString      Kind = 41
	TokenComment     Kind = 42
	TokenNumber      Kind = 43
	TokenType        Kind = 44
	TokenFunction    Kind = 45
	TokenConstant    Kind = 46
	TokenProperty    Kind = 47
	TokenPunctuation Kind = 48
	TokenInserted    Kind = 49
	TokenDeleted     Kind = 50
)

// Flags of CodeBlock and FrontMatter lines.
const (
	CodeFenceOpen  uint16 = 1
	CodeFenceClose uint16 = 2
	CodeDiagram    uint16 = 4
	CodeMath       uint16 = 8
)

// Flags of Table lines. A TableCell has its alignment in the low bits
// (0 none, 1 left, 2 center, 3 right) and the header flag shifted left by
// four.
const (
	TableHeader    uint16 = 1
	TableDelimiter uint16 = 2
)

// IsToken reports whether k is a token of highlighted code.
func (k Kind) IsToken() bool { return k >= TokenKeyword }
