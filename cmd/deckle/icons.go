package main

import "github.com/egoist/mygo/ui"

// The icons of the window, drawn in the text's color.
func icon(paths string) *ui.SVG {
	return ui.MustParseSVG([]byte(`<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round">` + paths + `</svg>`))
}

var (
	iconBack     = icon(`<path d="m15 18-6-6 6-6"/>`)
	iconForward  = icon(`<path d="m9 18 6-6-6-6"/>`)
	iconPlus     = icon(`<path d="M5 12h14M12 5v14"/>`)
	iconSearch   = icon(`<circle cx="11" cy="11" r="7"/><path d="m21 21-4.3-4.3"/>`)
	iconSidebar  = icon(`<rect x="3" y="4" width="18" height="16" rx="3"/><path d="M9 4v16"/>`)
	iconNewNote  = icon(`<path d="M12 4H6a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-6"/><path d="M18.4 2.6a2 2 0 0 1 2.9 2.9L12 14.8l-4 1 1-4z"/>`)
	iconFolder   = icon(`<path d="M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.7-.9l-.8-1.2A2 2 0 0 0 7.9 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z"/>`)
	iconNote     = icon(`<path d="M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7Z"/><path d="M14 2v4a2 2 0 0 0 2 2h4M10 13H8M16 17H8"/>`)
	iconFile     = icon(`<path d="M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7Z"/><path d="M14 2v4a2 2 0 0 0 2 2h4"/>`)
	iconImage    = icon(`<rect x="3" y="3" width="18" height="18" rx="2"/><circle cx="9" cy="9" r="2"/><path d="m21 15-3.1-3.1a2 2 0 0 0-2.8 0L6 21"/>`)
	iconLibrary  = icon(`<path d="m16 6 4 14M12 6v14M8 8v12M4 4v16"/>`)
	iconClock    = icon(`<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>`)
	iconSortAZ   = icon(`<path d="m3 16 4 4 4-4M7 20V4M20 8h-5M15 10V6.5a2.5 2.5 0 0 1 5 0V10M15 14h5l-5 6h5"/>`)
	iconClose    = icon(`<path d="M18 6 6 18M6 6l12 12"/>`)
	iconChevron  = icon(`<path d="m6 9 6 6 6-6"/>`)
	iconStar     = icon(`<path d="M12 2.5l2.9 6 6.6.9-4.8 4.6 1.2 6.5L12 17.4l-5.9 3.1 1.2-6.5L2.5 9.4l6.6-.9z"/>`)
	iconLink     = icon(`<path d="M10 13a5 5 0 0 0 7.5.5l3-3a5 5 0 0 0-7-7l-1.7 1.7"/><path d="M14 11a5 5 0 0 0-7.5-.5l-3 3a5 5 0 0 0 7 7l1.7-1.7"/>`)
	iconHeading  = icon(`<path d="M6 12h12M6 20V4M18 20V4"/>`)
	iconCommand  = icon(`<path d="M15 6v12a3 3 0 1 0 3-3H6a3 3 0 1 0 3 3V6a3 3 0 1 0-3 3h12a3 3 0 1 0-3-3"/>`)
	iconFolderPl = icon(`<path d="M12 10v6M9 13h6"/><path d="M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.7-.9l-.8-1.2A2 2 0 0 0 7.9 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z"/>`)
)
