// Standalone module for fast local iteration: `go test -tags orbitnet_standalone ./...`.
// The C-boundary tests are opt-in (`-tags orbitnet_cgo_tests`) because Go's
// test driver cannot link cgo test files in this package-main archive outside
// the libtailscale build.
// The build script copies only the *.go files into the libtailscale clone,
// where the same sources compile as extra files of its `package main`.
module orbitnet

go 1.25
