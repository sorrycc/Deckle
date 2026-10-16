package main

import (
	"os"
	"path/filepath"
	"runtime"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/ui"
)

// registerFonts registers LXGW WenKai, which ships among the app's
// resources. On macOS the app's Info.plist hands the folder to the system
// (ATSApplicationFontsPath); elsewhere the faces are read here, off the
// main thread, when the settings choose them.
func registerFonts(family string) {
	if runtime.GOOS == "darwin" || family != "LXGW WenKai Lite" {
		return
	}
	dir, err := mygo.App.Path(mygo.PathResources)
	if err != nil {
		return
	}
	go func() {
		for _, f := range []string{"LXGWWenKaiLite-Regular.ttf", "LXGWWenKaiLite-Medium.ttf"} {
			if data, err := os.ReadFile(filepath.Join(dir, "Fonts", f)); err == nil {
				ui.RegisterFont(data, "LXGW WenKai Lite")
			}
		}
	}()
}
