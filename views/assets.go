package views

import "io/fs"

// assetFS holds the front-end bundles + puzzle catalogs embedded in
// the binary, wired by main at startup via SetAssets. Serving reads
// go through readAsset so the server is self-contained — no
// working-dir or relative-path dependency at runtime.
var assetFS fs.FS

// SetAssets wires the embedded asset filesystem at startup.
func SetAssets(f fs.FS) { assetFS = f }

func readAsset(path string) ([]byte, error) { return fs.ReadFile(assetFS, path) }
