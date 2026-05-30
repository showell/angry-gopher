// Hooks the user lifecycle without coupling lower layers (login) to
// upper layers (chat). When login finishes promoting a guest to a
// member (or allocates a fresh one), it fires the new-member hook;
// chat's sidebar SSE registers a listener at init() and publishes a
// per-user "user-arrived" event to every other authorized principal
// so their open sidebars can upsert a Conversations row.
//
// Hooks are append-only and called in registration order. Not
// concurrent-safe by construction — registration happens at program
// init(), and Fire runs inside the request goroutine after the user
// is fully committed. Best-effort and synchronous: a slow listener
// blocks the firing request; today the only listener is a non-
// blocking channel publish.

package users

var newMemberHooks []func(uid, name string)

// RegisterNewMemberHook installs a callback fired after a new member is
// created (either by promoting an existing guest or by allocating a fresh
// uid + password). Called at program init().
func RegisterNewMemberHook(fn func(uid, name string)) {
	newMemberHooks = append(newMemberHooks, fn)
}

// FireNewMember runs every registered new-member callback. Called by
// login after registerMember succeeds.
func FireNewMember(uid, name string) {
	for _, fn := range newMemberHooks {
		fn(uid, name)
	}
}
