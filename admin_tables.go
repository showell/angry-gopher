// Admin table viewer: browse any database table.

package main

import (
	"fmt"
	"html"
	"net/http"

)

func renderAdminIndex(w http.ResponseWriter) {
	tables := getTableNames()

	fmt.Fprint(w, `<!DOCTYPE html>
<html><head><title>Angry Gopher Admin</title>
<style>
body { font-family: sans-serif; margin: 40px; }
h1 { color: #000080; }
a { color: #000080; font-weight: bold; font-size: 18px; }
.table-list { display: flex; flex-direction: column; gap: 8px; }
.count { color: #888; margin-left: 8px; }
</style>
</head><body>
<h1>🐹 Angry Gopher Admin</h1>
<div class="table-list">`)

	for _, name := range tables {
		count := getRowCount(name)
		fmt.Fprintf(w, `<div><a href="/admin/%s">%s</a><span class="count">(%d rows)</span></div>`,
			html.EscapeString(name), html.EscapeString(name), count)
	}

	fmt.Fprint(w, `</div>`)

	fmt.Fprint(w, `<h2 style="color:#000080;margin-top:30px">In-Memory State</h2>`)
	fmt.Fprint(w, `<div class="table-list">`)
	fmt.Fprint(w, `<div><a href="/admin/ops">ops dashboard</a><span class="count">(live)</span></div>`)
	fmt.Fprint(w, `</div>`)

	fmt.Fprint(w, `</body></html>`)
}

func renderAdminTable(w http.ResponseWriter, tableName string) {
	if !isValidTable(tableName) {
		http.Error(w, "Unknown table", http.StatusNotFound)
		return
	}

	columns, rows := getTableData(tableName)

	fmt.Fprintf(w, `<!DOCTYPE html>
<html><head><title>%s — Angry Gopher Admin</title>
<style>
body { font-family: sans-serif; margin: 40px; }
h1 { color: #000080; }
a { color: #000080; }
table { border-collapse: collapse; margin-top: 12px; }
th { background: #000080; color: white; padding: 6px 12px; text-align: left; }
td { border-bottom: 1px solid #ccc; padding: 6px 12px; max-width: 400px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
tr:hover td { background: #f0f0ff; }
</style>
</head><body>
<a href="/admin/">← Back to tables</a>
<h1>%s</h1>`, html.EscapeString(tableName), html.EscapeString(tableName))

	if len(rows) == 0 {
		fmt.Fprint(w, `<p>No rows.</p>`)
	} else {
		fmt.Fprint(w, `<table><thead><tr>`)
		for _, col := range columns {
			fmt.Fprintf(w, `<th>%s</th>`, html.EscapeString(col))
		}
		fmt.Fprint(w, `</tr></thead><tbody>`)

		for _, row := range rows {
			fmt.Fprint(w, `<tr>`)
			for _, cell := range row {
				fmt.Fprintf(w, `<td>%s</td>`, html.EscapeString(cell))
			}
			fmt.Fprint(w, `</tr>`)
		}

		fmt.Fprint(w, `</tbody></table>`)
	}

	fmt.Fprintf(w, `<p style="color:#888">%d rows</p>`, len(rows))
	fmt.Fprint(w, `</body></html>`)
}


// --- Database helpers for admin ---

func getTableNames() []string {
	rows, err := DB.Query(`SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name`)
	if err != nil {
		return nil
	}
	defer rows.Close()

	var tables []string
	for rows.Next() {
		var name string
		rows.Scan(&name)
		tables = append(tables, name)
	}
	return tables
}

func isValidTable(name string) bool {
	for _, t := range getTableNames() {
		if t == name {
			return true
		}
	}
	return false
}

func getRowCount(tableName string) int {
	var count int
	DB.QueryRow(fmt.Sprintf("SELECT COUNT(*) FROM %s", tableName)).Scan(&count)
	return count
}

func getTableData(tableName string) ([]string, [][]string) {
	rows, err := DB.Query(fmt.Sprintf("SELECT * FROM %s LIMIT 200", tableName))
	if err != nil {
		return nil, nil
	}
	defer rows.Close()

	columns, _ := rows.Columns()

	var result [][]string
	for rows.Next() {
		values := make([]interface{}, len(columns))
		ptrs := make([]interface{}, len(columns))
		for i := range values {
			ptrs[i] = &values[i]
		}
		rows.Scan(ptrs...)

		row := make([]string, len(columns))
		for i, v := range values {
			row[i] = fmt.Sprintf("%v", v)
		}
		result = append(result, row)
	}

	return columns, result
}
