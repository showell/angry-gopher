// Package users handles GET /api/v1/users.
package users

import (
	"database/sql"
	"net/http"

	"angry-gopher/respond"
)

var DB *sql.DB

func HandleUsers(w http.ResponseWriter, r *http.Request) {
	rows, err := DB.Query(`SELECT id, email, full_name, is_admin FROM users`)
	if err != nil {
		respond.Error(w, "Failed to query users")
		return
	}
	defer rows.Close()

	var members []map[string]interface{}
	for rows.Next() {
		var id int
		var email, fullName string
		var isAdmin int
		rows.Scan(&id, &email, &fullName, &isAdmin)
		members = append(members, map[string]interface{}{
			"user_id":   id,
			"email":     email,
			"full_name": fullName,
			"is_admin":  isAdmin == 1,
			"is_bot":    false,
		})
	}

	respond.Success(w, map[string]interface{}{"members": members})
}
