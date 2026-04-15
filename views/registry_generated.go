// Home of self-registration for crudgen-generated pages. Each
// .claude → .go file emits an init() that calls
// registerGeneratedPage here. GetPages() appends
// generatedPages to its hardcoded list so nav bar, index, and
// tour all pick them up automatically.
//
// This removes the main.go/registry.go adjacency-churn that every
// new CRUD page used to create.

package views

var generatedPages []PageDef

func registerGeneratedPage(p PageDef) {
	generatedPages = append(generatedPages, p)
}
