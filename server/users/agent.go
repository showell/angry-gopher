// Agents are bot principals: a real user id, no password, authenticate
// only via API key. They never log in interactively and never get an
// auth cookie, so the password concept just doesn't apply to them.
//
// "Authorized" is the umbrella concept: a request acts as an authorized
// principal if it's a password member OR an agent. That's what the
// auth gates throughout the codebase actually want — chat membership,
// API-key resolution, the cookie-session resolver. "Member" still
// means specifically "human with a password" and is only used by the
// interactive login flow.
//
// Today there's exactly one agent: Claude (uid 3). Hardcoding the id
// keeps the bootstrap simple; we'll generalize (a marker file under
// users/<id>/, say) when a second agent appears.
package users

const claudeAgentID = "3"

// IsAgent reports whether a uid belongs to an agent (a bot principal,
// authenticated by API key, never by password).
func IsAgent(id string) bool {
	return id == claudeAgentID
}

// UserIsAuthorized reports whether a uid is a member OR an agent — the
// umbrella "this is a real principal who may act in the system" check.
// Auth gates (chat membership, API key resolution, session lookup)
// want this, not the narrower UserIsMember.
func UserIsAuthorized(id string) bool {
	return UserIsMember(id) || IsAgent(id)
}

// ListAuthorized returns every principal who may chat: every password
// member plus every agent. Sorted by id.
func ListAuthorized() []User {
	out := ListMembers()
	if IsAgent(claudeAgentID) && UserExists(claudeAgentID) {
		// Avoid double-add if (someday) an agent also has a password.
		for _, m := range out {
			if m.ID == claudeAgentID {
				return out
			}
		}
		out = append(out, LoadUser(claudeAgentID))
	}
	return out
}
