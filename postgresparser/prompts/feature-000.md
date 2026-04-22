Please update all go.mod and *.go files so the packages will reflect
the fork repo location from fork.txt rather than the upstream repo
location so that pkg.go.dev will let users see only this version.

Run `go mod tidy` to regenerate all go.sum files.

Update the README.md with a statement explaining that this repo is a
fork of the upstream repo (with link) that contains fixes other
issues, with a list of other prompts in ../prompts/.

Do not make other changes.