package main

import (
	"github.com/egoist/mygo"
	"github.com/egoist/mygo/plugins/updater"
)

// updatesAvailable reports whether this copy updates itself: a release
// build, installed where it can write.
func updatesAvailable() bool { return mygo.Updater.Enabled() }

func checkForUpdates() { updater.CheckForUpdates() }
