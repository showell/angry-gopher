package platform

import "io/fs"

// assetFS holds the front-end bundles + puzzle catalogs embedded in
// the binary, wired by main at startup via SetAssets. Serving reads
// go through ReadAsset so the server is self-contained — no
// working-dir or relative-path dependency at runtime.
var assetFS fs.FS

// SetAssets wires the embedded asset filesystem at startup.
func SetAssets(f fs.FS) { assetFS = f }

func ReadAsset(path string) ([]byte, error) { return fs.ReadFile(assetFS, path) }

// AssetVersion is the build id (git commit), used as a ?v= cache-buster on
// served assets so a deploy reliably invalidates the browser cache. Set by
// main via SetVersion; "dev" until then.
var AssetVersion = "dev"

// SetVersion wires the build id at startup.
func SetVersion(v string) { AssetVersion = v }
